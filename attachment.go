package runcore

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/svanichkin/go-lxmf/lxmf"
	"github.com/svanichkin/go-reticulum/rns"
)

const (
	attachmentReqPath = "/attachment"
	attachmentResKind = "attachment"
)

type AttachmentInfo struct {
	HashHex  string `json:"hash_hex,omitempty"`
	Mime     string `json:"mime,omitempty"`
	Name     string `json:"name,omitempty"`
	Size     int    `json:"size,omitempty"`
	Updated  int64  `json:"updated,omitempty"`
	Outgoing bool   `json:"outgoing,omitempty"`
}

type AttachmentFetch struct {
	HashHex    string `json:"hash_hex,omitempty"`
	Path       string `json:"path,omitempty"`
	Mime       string `json:"mime,omitempty"`
	Name       string `json:"name,omitempty"`
	Size       int    `json:"size,omitempty"`
	NotPresent bool   `json:"not_present,omitempty"`
}

func (n *Node) outgoingAttachmentsDir() string {
	if n == nil {
		return ""
	}
	return filepath.Join(n.opts.Dir, "attachments", "out")
}

func (n *Node) incomingAttachmentsDir(remoteHashHex string) string {
	if n == nil {
		return ""
	}
	remoteHashHex = strings.ToLower(strings.TrimSpace(remoteHashHex))
	return filepath.Join(n.opts.Dir, "attachments", "in", remoteHashHex)
}

func sanitizeAttachmentName(name string) string {
	name = strings.TrimSpace(name)
	if name == "" {
		return ""
	}
	name = filepath.Base(name)
	name = strings.Map(func(r rune) rune {
		switch r {
		case 0, '/', '\\', ':':
			return '-'
		default:
			if r < 32 {
				return -1
			}
			return r
		}
	}, name)
	name = strings.TrimSpace(name)
	if name == "" {
		return ""
	}
	if len(name) > 180 {
		name = name[:180]
	}
	return name
}

func (n *Node) StoreOutgoingAttachment(data []byte, mime, name string) (AttachmentInfo, error) {
	if n == nil {
		return AttachmentInfo{}, errors.New("node not started")
	}
	if len(data) == 0 {
		return AttachmentInfo{}, errors.New("empty attachment")
	}

	sum := sha256.Sum256(data)
	hashHex := hex.EncodeToString(sum[:])
	outDir := n.outgoingAttachmentsDir()
	if outDir == "" {
		return AttachmentInfo{}, errors.New("no attachment dir")
	}
	if err := os.MkdirAll(outDir, 0o755); err != nil {
		return AttachmentInfo{}, fmt.Errorf("create out dir: %w", err)
	}
	binPath := filepath.Join(outDir, hashHex+".bin")
	mimePath := filepath.Join(outDir, hashHex+".mime")
	namePath := filepath.Join(outDir, hashHex+".name")

	// Idempotent write.
	if _, err := os.Stat(binPath); errors.Is(err, os.ErrNotExist) {
		if err := os.WriteFile(binPath, data, 0o644); err != nil {
			return AttachmentInfo{}, fmt.Errorf("write attachment: %w", err)
		}
	}

	mime = strings.TrimSpace(mime)
	if mime != "" {
		_ = os.WriteFile(mimePath, []byte(mime), 0o644)
	}
	name = sanitizeAttachmentName(name)
	if name != "" {
		_ = os.WriteFile(namePath, []byte(name), 0o644)
	}

	st, _ := os.Stat(binPath)
	updated := int64(0)
	if st != nil {
		updated = st.ModTime().Unix()
	}
	return AttachmentInfo{
		HashHex:  hashHex,
		Mime:     mime,
		Name:     name,
		Size:     len(data),
		Updated:  updated,
		Outgoing: true,
	}, nil
}

func (n *Node) loadOutgoingAttachmentByHashHex(hashHex string) (AttachmentInfo, []byte, error) {
	if n == nil {
		return AttachmentInfo{}, nil, errors.New("node not started")
	}
	hashHex = strings.ToLower(strings.TrimSpace(hashHex))
	if hashHex == "" {
		return AttachmentInfo{}, nil, errors.New("empty hash")
	}
	binPath := filepath.Join(n.outgoingAttachmentsDir(), hashHex+".bin")
	b, err := os.ReadFile(binPath)
	if err != nil {
		return AttachmentInfo{}, nil, err
	}
	mime := strings.TrimSpace(string(readFileOrNil(filepath.Join(n.outgoingAttachmentsDir(), hashHex+".mime"))))
	name := strings.TrimSpace(string(readFileOrNil(filepath.Join(n.outgoingAttachmentsDir(), hashHex+".name"))))
	st, _ := os.Stat(binPath)
	updated := int64(0)
	if st != nil {
		updated = st.ModTime().Unix()
	}
	return AttachmentInfo{HashHex: hashHex, Mime: mime, Name: name, Size: len(b), Updated: updated, Outgoing: true}, b, nil
}

func (n *Node) registerAttachmentRequestHandler(dest *rns.Destination) error {
	if n == nil || dest == nil {
		return nil
	}
	return dest.RegisterRequestHandler(
		attachmentReqPath,
		func(path string, data any, requestID []byte, linkID []byte, remoteIdentity *rns.Identity, requestedAt time.Time) any {
			remoteHex := ""
			if remoteIdentity != nil {
				remoteHex = remoteIdentity.HexHash
			}
			var reqHash []byte
			if m, ok := data.(map[any]any); ok {
				if hv, ok := m["h"]; ok {
					if b, ok := hv.([]byte); ok && len(b) > 0 {
						reqHash = append([]byte(nil), b...)
					}
				}
			}
			if len(reqHash) == 0 {
				rns.Logf(rns.LOG_NOTICE, "attachment req: missing hash remote=%s", remoteHex)
				return map[any]any{"ok": false, "error": "missing hash"}
			}
			hashHex := hex.EncodeToString(reqHash)
			info, bytes, err := n.loadOutgoingAttachmentByHashHex(hashHex)
			if err != nil || len(bytes) == 0 {
				rns.Logf(rns.LOG_NOTICE, "attachment req: not found remote=%s hash=%s", remoteHex, hashHex)
				return map[any]any{"ok": false}
			}

			link := findActiveLink(linkID)
			if link == nil {
				rns.Logf(rns.LOG_NOTICE, "attachment req: link not found remote=%s", remoteHex)
				return map[any]any{"ok": false, "error": "link not found"}
			}

			meta := map[any]any{
				"kind": attachmentResKind,
				"h":    reqHash,
				"t":    info.Mime,
				"n":    info.Name,
				"s":    info.Size,
				"u":    info.Updated,
			}
			if _, err := rns.NewResource(bytes, nil, link, meta, true, false, nil, nil, nil, 0, nil, nil, false, 0); err != nil {
				rns.Logf(rns.LOG_NOTICE, "attachment req: resource send failed remote=%s err=%v", remoteHex, err)
				return map[any]any{"ok": false, "error": "resource send failed"}
			}
			rns.Logf(rns.LOG_NOTICE, "attachment req: resource queued remote=%s hash=%s size=%d", remoteHex, hashHex, info.Size)
			return map[any]any{"ok": true, "h": reqHash, "t": info.Mime, "n": info.Name, "s": info.Size, "u": info.Updated, "resource": true}
		},
		rns.DestinationALLOW_ALL,
		nil,
		true,
	)
}

func (n *Node) ContactAttachmentPathHex(destinationHashHex, attachmentHashHex string, timeout time.Duration) (AttachmentFetch, error) {
	if n == nil || n.identity == nil {
		return AttachmentFetch{}, errors.New("node not started")
	}
	if timeout <= 0 {
		timeout = 10 * time.Second
	}
	remote := strings.ToLower(strings.TrimSpace(destinationHashHex))
	hashHex := strings.ToLower(strings.TrimSpace(attachmentHashHex))
	if remote == "" || hashHex == "" {
		return AttachmentFetch{}, errors.New("missing params")
	}

	// Cache hit.
	cachePath := filepath.Join(n.incomingAttachmentsDir(remote), hashHex+".bin")
	if st, err := os.Stat(cachePath); err == nil && st.Size() > 0 {
		mime := strings.TrimSpace(string(readFileOrNil(filepath.Join(n.incomingAttachmentsDir(remote), hashHex+".mime"))))
		name := strings.TrimSpace(string(readFileOrNil(filepath.Join(n.incomingAttachmentsDir(remote), hashHex+".name"))))
		return AttachmentFetch{HashHex: hashHex, Path: cachePath, Mime: mime, Name: name, Size: int(st.Size())}, nil
	}

	// Self-hit: allow loopback by using local outgoing attachment.
	if n.deliveryDestIn != nil && strings.EqualFold(remote, n.DestinationHashHex()) {
		info, _, err := n.loadOutgoingAttachmentByHashHex(hashHex)
		if err == nil {
			binPath := filepath.Join(n.outgoingAttachmentsDir(), hashHex+".bin")
			return AttachmentFetch{HashHex: hashHex, Path: binPath, Mime: info.Mime, Name: info.Name, Size: info.Size}, nil
		}
	}

	hashBytes, err := hex.DecodeString(hashHex)
	if err != nil || len(hashBytes) == 0 {
		return AttachmentFetch{}, errors.New("invalid attachment hash")
	}

	id, err := n.WaitForIdentityHex(remote, timeout)
	if err != nil {
		return AttachmentFetch{}, err
	}
	if id == nil {
		return AttachmentFetch{}, errors.New("unknown destination identity")
	}

	var lastErr error
	destinations := []struct {
		app    string
		aspect string
		label  string
	}{
		{app: lxmf.AppName, aspect: "delivery", label: "lxmf.delivery"},
		{app: profileAppName, aspect: profileAspect, label: "runcore.profile"},
	}
	for _, spec := range destinations {
		rns.Logf(rns.LOG_NOTICE, "attachment fetch: try %s dest=%s hash=%s", spec.label, remote, hashHex)
		outDest, err := rns.NewDestination(id, rns.DestinationOUT, rns.DestinationSINGLE, spec.app, spec.aspect)
		if err != nil {
			lastErr = fmt.Errorf("create %s outbound destination: %w", spec.label, err)
			continue
		}
		resp, err := n.fetchAttachmentViaDestination(outDest, remote, hashBytes, timeout)
		if err == nil {
			return resp, nil
		}
		lastErr = err
	}
	if lastErr != nil {
		return AttachmentFetch{}, lastErr
	}
	return AttachmentFetch{}, errors.New("attachment request failed")
}

func (n *Node) fetchAttachmentViaDestination(outDest *rns.Destination, remoteHashHex string, hashBytes []byte, timeout time.Duration) (AttachmentFetch, error) {
	if outDest == nil {
		return AttachmentFetch{}, errors.New("nil destination")
	}
	if len(hashBytes) == 0 {
		return AttachmentFetch{}, errors.New("empty hash")
	}

	established := make(chan struct{})
	closed := make(chan struct{})
	link, err := rns.NewOutgoingLink(outDest, -1, func(*rns.Link) {
		select {
		case <-established:
		default:
			close(established)
		}
	}, func(*rns.Link) {
		select {
		case <-closed:
		default:
			close(closed)
		}
	})
	if err != nil {
		return AttachmentFetch{}, fmt.Errorf("open link: %w", err)
	}
	defer link.Teardown()

	deadline := time.NewTimer(timeout)
	defer deadline.Stop()
	select {
	case <-established:
	case <-closed:
		return AttachmentFetch{}, errors.New("link closed before establishment")
	case <-deadline.C:
		return AttachmentFetch{}, errors.New("timeout establishing link")
	}

	link.Identify(n.identity)

	req := map[any]any{"h": hashBytes}
	respCh := make(chan any, 1)
	failCh := make(chan struct{}, 1)
	resCh := make(chan *rns.Resource, 1)
	link.SetResourceStrategy(rns.LinkAcceptAll)
	link.SetResourceConcludedCallback(func(res *rns.Resource) {
		select {
		case resCh <- res:
		default:
		}
	})
	rr := link.Request(
		attachmentReqPath,
		req,
		func(rr *rns.RequestReceipt) { respCh <- rr.Response() },
		func(rr *rns.RequestReceipt) { failCh <- struct{}{} },
		nil,
		timeout.Seconds(),
	)
	if rr == nil {
		return AttachmentFetch{}, errors.New("failed to send attachment request")
	}

	remoteHashHex = strings.ToLower(strings.TrimSpace(remoteHashHex))
	hashHex := hex.EncodeToString(hashBytes)
	var respMime string
	var respName string

	for {
		select {
		case resp := <-respCh:
			switch v := resp.(type) {
			case map[any]any:
				ok, _ := v["ok"].(bool)
				if !ok {
					return AttachmentFetch{HashHex: hashHex, NotPresent: true}, nil
				}
				if tv, ok := v["t"].(string); ok {
					respMime = tv
				}
				if nv, ok := v["n"].(string); ok {
					respName = nv
				}
			case []byte:
				// Compatibility: handler may return raw bytes.
				cachePath := filepath.Join(n.incomingAttachmentsDir(remoteHashHex), hashHex+".bin")
				if err := os.MkdirAll(filepath.Dir(cachePath), 0o755); err != nil {
					return AttachmentFetch{}, err
				}
				if err := os.WriteFile(cachePath, v, 0o644); err != nil {
					return AttachmentFetch{}, err
				}
				return AttachmentFetch{HashHex: hashHex, Path: cachePath, Mime: respMime, Name: respName, Size: len(v)}, nil
			default:
				return AttachmentFetch{}, errors.New("unexpected attachment response type")
			}
		case res := <-resCh:
			if res == nil {
				return AttachmentFetch{}, errors.New("attachment resource nil")
			}
			if res.Status() != rns.ResourceComplete {
				return AttachmentFetch{}, errors.New("attachment resource failed")
			}
			meta := res.Metadata()
			kind, _ := meta["kind"].(string)
			if kind != "" && kind != attachmentResKind {
				return AttachmentFetch{}, errors.New("unexpected attachment resource kind")
			}
			if tv, ok := meta["t"].(string); ok && tv != "" {
				respMime = tv
			}
			if nv, ok := meta["n"].(string); ok && nv != "" {
				respName = nv
			}

			cachePath := filepath.Join(n.incomingAttachmentsDir(remoteHashHex), hashHex+".bin")
			if err := os.MkdirAll(filepath.Dir(cachePath), 0o755); err != nil {
				return AttachmentFetch{}, err
			}
			src, err := os.Open(res.DataFile())
			if err != nil {
				return AttachmentFetch{}, fmt.Errorf("open attachment resource: %w", err)
			}
			defer src.Close()
			dst, err := os.Create(cachePath)
			if err != nil {
				return AttachmentFetch{}, fmt.Errorf("create attachment cache: %w", err)
			}
			if _, err := io.Copy(dst, src); err != nil {
				_ = dst.Close()
				return AttachmentFetch{}, fmt.Errorf("write attachment cache: %w", err)
			}
			_ = dst.Close()

			if respMime != "" {
				_ = os.WriteFile(filepath.Join(n.incomingAttachmentsDir(remoteHashHex), hashHex+".mime"), []byte(respMime), 0o644)
			}
			respName = sanitizeAttachmentName(respName)
			if respName != "" {
				_ = os.WriteFile(filepath.Join(n.incomingAttachmentsDir(remoteHashHex), hashHex+".name"), []byte(respName), 0o644)
			}
			st, _ := os.Stat(cachePath)
			sz := 0
			if st != nil {
				sz = int(st.Size())
			}
			return AttachmentFetch{HashHex: hashHex, Path: cachePath, Mime: respMime, Name: respName, Size: sz}, nil
		case <-failCh:
			return AttachmentFetch{}, errors.New("attachment request failed")
		case <-deadline.C:
			return AttachmentFetch{}, errors.New("attachment request timeout")
		}
	}
}
