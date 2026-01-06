package main

import (
	"errors"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"time"

	"github.com/svanichkin/configobj"
	"github.com/svanichkin/go-lxmf/lxmf"
	"github.com/svanichkin/go-reticulum/rns"

	"runcore"
)

const (
	deferredJobsDelay = 10 * time.Second
	jobsInterval      = 5 * time.Second
)

// Mostly copied from go-lxmf/cmd/lxmd.go for behavioural parity.
const defaultConfigFile = `# This is an example LXM Daemon config file.
# You should probably edit it to suit your
# intended usage.

[propagation]

# Whether to enable propagation node

enable_node = no

# Automatic announce interval in minutes.
# 6 hours by default.

announce_interval = 360

# Whether to announce when the node starts.

announce_at_start = yes

# Wheter to automatically peer with other
# propagation nodes on the network.

autopeer = yes

# The maximum peering depth (in hops) for
# automatically peered nodes.

autopeer_maxdepth = 4

# message_storage_limit = 500
# propagation_message_max_accepted_size = 256
# propagation_sync_max_accepted_size = 10240
# propagation_stamp_cost_target = 16
# propagation_stamp_cost_flexibility = 3
# peering_cost = 18
# remote_peering_cost_max = 26
# max_peers = 20

[lxmf]

display_name = Anonymous Peer

announce_at_start = no

# announce_interval = 0

delivery_transfer_max_accepted_size = 1000

[logging]
loglevel = 4
`

type activeConfiguration struct {
	DisplayName                     string
	PeerAnnounceAtStart             bool
	PeerAnnounceInterval            time.Duration
	DeliveryTransferMaxAcceptedSize int
	OnInbound                       string

	EnablePropagationNode              bool
	NodeName                           string
	AuthRequired                       bool
	NodeAnnounceAtStart                bool
	AutoPeer                           bool
	AutoPeerMaxDepth                   int
	NodeAnnounceInterval               time.Duration
	MessageStorageLimitMB              int
	PropagationTransferMaxAcceptedSize int
	PropagationMessageMaxAcceptedSize  int
	PropagationSyncMaxAcceptedSize     int
	PropagationStampCostTarget         int
	PropagationStampCostFlexibility    int
	PeeringCost                        int
	RemotePeeringCostMax               int
	MaxPeers                           int
}

var (
	configPath   string
	identityPath string
	storageDir   string
	messagesDir  string

	targetLogLevel = 4
	lxmdConfig     *configobj.Config
	activeConfig   = activeConfiguration{}

	node *runcore.Node

	lastPeerAnnounce time.Time
	lastNodeAnnounce time.Time
)

func getSection(name string) *configobj.Section {
	if lxmdConfig == nil {
		return nil
	}
	return lxmdConfig.Section(name)
}

func stringKey(section, key, def string) string {
	sec := getSection(section)
	if sec == nil {
		return def
	}
	if value, ok := sec.Get(key); ok && value != "" {
		return value
	}
	return def
}

func boolKey(section, key string, def bool) bool {
	sec := getSection(section)
	if sec == nil {
		return def
	}
	if value, err := sec.AsBool(key); err == nil {
		return value
	}
	return def
}

func intKey(section, key string, def int) int {
	sec := getSection(section)
	if sec == nil {
		return def
	}
	if value, err := sec.AsInt(key); err == nil {
		return value
	}
	return def
}

func floatKey(section, key string, def float64) float64 {
	sec := getSection(section)
	if sec == nil {
		return def
	}
	if value, err := sec.AsFloat(key); err == nil {
		return value
	}
	return def
}

func applyConfig() error {
	if lxmdConfig == nil {
		return errors.New("configuration missing")
	}

	activeConfig.DisplayName = stringKey("lxmf", "display_name", "Anonymous Peer")
	activeConfig.PeerAnnounceAtStart = boolKey("lxmf", "announce_at_start", false)
	activeConfig.PeerAnnounceInterval = time.Duration(intKey("lxmf", "announce_interval", 0)) * time.Minute
	activeConfig.DeliveryTransferMaxAcceptedSize = int(floatKey("lxmf", "delivery_transfer_max_accepted_size", 1000))

	activeConfig.EnablePropagationNode = boolKey("propagation", "enable_node", false)
	activeConfig.NodeName = stringKey("propagation", "node_name", "")
	activeConfig.NodeAnnounceAtStart = boolKey("propagation", "announce_at_start", true)
	activeConfig.NodeAnnounceInterval = time.Duration(intKey("propagation", "announce_interval", 360)) * time.Minute
	activeConfig.AutoPeer = boolKey("propagation", "autopeer", true)
	activeConfig.AutoPeerMaxDepth = intKey("propagation", "autopeer_maxdepth", 4)

	activeConfig.MessageStorageLimitMB = intKey("propagation", "message_storage_limit", 500)
	activeConfig.PropagationMessageMaxAcceptedSize = int(floatKey("propagation", "propagation_message_max_accepted_size", 256))
	activeConfig.PropagationSyncMaxAcceptedSize = int(floatKey("propagation", "propagation_sync_max_accepted_size", 10240))
	activeConfig.PropagationStampCostTarget = intKey("propagation", "propagation_stamp_cost_target", 16)
	activeConfig.PropagationStampCostFlexibility = intKey("propagation", "propagation_stamp_cost_flexibility", 3)
	activeConfig.PeeringCost = intKey("propagation", "peering_cost", 18)
	activeConfig.RemotePeeringCostMax = intKey("propagation", "remote_peering_cost_max", 26)
	activeConfig.MaxPeers = intKey("propagation", "max_peers", 20)

	targetLogLevel = intKey("logging", "loglevel", 4)
	return nil
}

func programSetup(configDir, rnsConfigDir string, forcePropagationNode bool, onInbound string, verbosity, quietness int, service bool, resetLXMF bool) {
	if configDir == "" {
		home, _ := os.UserHomeDir()
		if home != "" {
			configDir = filepath.Join(home, ".config", "lxmd")
		} else {
			configDir = ".lxmd"
		}
	}

	if err := os.MkdirAll(configDir, 0o755); err != nil {
		fmt.Fprintln(os.Stderr, "could not create config dir:", err)
		os.Exit(1)
	}

	configPath = filepath.Join(configDir, "config")
	identityPath = filepath.Join(configDir, "identity")
	storageDir = filepath.Join(configDir, "storage")
	messagesDir = filepath.Join(storageDir, "messages")

	if err := os.MkdirAll(messagesDir, 0o755); err != nil {
		fmt.Fprintln(os.Stderr, "could not create storage dirs:", err)
		os.Exit(1)
	}
	if !fileExists(configPath) {
		if err := os.WriteFile(configPath, []byte(defaultConfigFile), 0o644); err != nil {
			fmt.Fprintln(os.Stderr, "failed to create default config:", err)
			os.Exit(1)
		}
	}

	var err error
	lxmdConfig, err = configobj.Load(configPath)
	if err != nil {
		fmt.Fprintln(os.Stderr, "could not parse config:", err)
		os.Exit(1)
	}
	if err := applyConfig(); err != nil {
		fmt.Fprintln(os.Stderr, "error applying config:", err)
		os.Exit(1)
	}

	level := targetLogLevel + verbosity - quietness
	if level < 0 {
		level = 0
	}
	if level > 7 {
		level = 7
	}

	var logDest any = rns.LOG_STDOUT
	if service {
		logDest = rns.LOG_FILE
	}

	opts := runcore.Options{
		Dir:            configDir,
		RNSConfigDir:   rnsConfigDir,
		DisplayName:    activeConfig.DisplayName,
		LogLevel:       level,
		LogDest:        logDest,
		ResetLXMFState: resetLXMF,
	}
	node, err = runcore.Start(opts)
	if err != nil {
		fmt.Fprintln(os.Stderr, "start:", err)
		os.Exit(1)
	}

	router := node.Router()
	router.DeliveryPerTransferLimit = activeConfig.DeliveryTransferMaxAcceptedSize
	router.AutoPeer = activeConfig.AutoPeer
	router.AutoPeerMaxDepth = activeConfig.AutoPeerMaxDepth
	if activeConfig.MaxPeers > 0 {
		router.MaxPeers = activeConfig.MaxPeers
	}

	if onInbound != "" {
		activeConfig.OnInbound = onInbound
	}

	node.SetInboundHandler(func(m *lxmf.LXMessage) {
		if m == nil {
			return
		}
		written, err := m.WriteToDirectory(messagesDir)
		if err != nil {
			rns.Log("Error saving inbound LXMF message: "+err.Error(), rns.LOG_ERROR)
			return
		}
		rns.Log("Received "+m.String()+" written to "+written, rns.LOG_INFO)
		if activeConfig.OnInbound != "" {
			cmd := exec.Command(activeConfig.OnInbound, written)
			cmd.Stdout = os.Stdout
			cmd.Stderr = os.Stderr
			if err := cmd.Run(); err != nil {
				rns.Log("Inbound action failed: "+err.Error(), rns.LOG_ERROR)
			}
		}
	})

	// Print "ready" line like lxmd.
	rns.Log("LXMF Router ready to receive on "+rns.PrettyHexRep(node.DeliveryDestination().Hash()), rns.LOG_NOTICE)

	if forcePropagationNode {
		activeConfig.EnablePropagationNode = true
	}
	if activeConfig.EnablePropagationNode {
		_ = router.EnablePropagation()
		if router.PropagationDestination != nil {
			rns.Log("LXMF Propagation Node started on "+rns.PrettyHexRep(router.PropagationDestination.Hash()), rns.LOG_NOTICE)
		}
	}

	time.Sleep(100 * time.Millisecond)
	go deferredStartJobs()

	select {}
}

func deferredStartJobs() {
	time.Sleep(deferredJobsDelay)
	if node == nil || node.Router() == nil || node.DeliveryDestination() == nil {
		return
	}
	r := node.Router()
	if activeConfig.PeerAnnounceAtStart {
		r.Announce(node.DeliveryDestination().Hash(), nil)
	}
	if activeConfig.EnablePropagationNode && activeConfig.NodeAnnounceAtStart {
		r.AnnouncePropagationNode()
	}
	lastPeerAnnounce = time.Now()
	lastNodeAnnounce = time.Now()
	go jobs()
}

func jobs() {
	for {
		if node != nil && node.Router() != nil && node.DeliveryDestination() != nil {
			if activeConfig.PeerAnnounceInterval > 0 && time.Since(lastPeerAnnounce) >= activeConfig.PeerAnnounceInterval {
				node.Router().Announce(node.DeliveryDestination().Hash(), nil)
				lastPeerAnnounce = time.Now()
			}
			if activeConfig.EnablePropagationNode && activeConfig.NodeAnnounceInterval > 0 && time.Since(lastNodeAnnounce) >= activeConfig.NodeAnnounceInterval {
				node.Router().AnnouncePropagationNode()
				lastNodeAnnounce = time.Now()
			}
		}
		time.Sleep(jobsInterval)
	}
}

func fileExists(path string) bool {
	info, err := os.Stat(path)
	return err == nil && !info.IsDir()
}

func main() {
	configDir := flag.String("config", "", "path to config directory (lxmd-compatible layout)")
	rnsConfigDir := flag.String("rnsconfig", "", "path to alternative Reticulum config directory (optional)")
	propagationNode := flag.Bool("propagation-node", false, "run as an LXMF Propagation Node")
	onInbound := flag.String("on-inbound", "", "command run when a message is received (arg: message file path)")
	service := flag.Bool("service", false, "log to file (Reticulum logdest)")
	resetLXMF := flag.Bool("reset-lxmf", false, "remove LXMF transient state under config dir before starting")
	example := flag.Bool("exampleconfig", false, "print verbose configuration example and exit")
	version := flag.Bool("version", false, "print version and exit")

	var verboseCount int
	var quietCount int
	flag.Func("v", "increase verbosity", func(string) error { verboseCount++; return nil })
	flag.Func("verbose", "increase verbosity", func(string) error { verboseCount++; return nil })
	flag.Func("q", "increase quietness", func(string) error { quietCount++; return nil })
	flag.Func("quiet", "increase quietness", func(string) error { quietCount++; return nil })
	flag.Parse()

	if *example {
		fmt.Print(defaultConfigFile)
		return
	}
	if *version {
		fmt.Printf("runcore (lxmd-compatible) %s\n", lxmf.Version)
		return
	}

	// If rnsconfig is empty, runcore.Start will use configDir/rns with an inline default.
	programSetup(*configDir, *rnsConfigDir, *propagationNode, *onInbound, verboseCount, quietCount, *service, *resetLXMF)
}
