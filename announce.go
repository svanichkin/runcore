package runcore

import (
	"encoding/hex"
	"encoding/json"
	"sort"
	"time"

	"github.com/svanichkin/go-reticulum/rns"
	umsgpack "github.com/svanichkin/go-reticulum/rns/vendor"
)

type AnnounceEntry struct {
	DestinationHashHex string `json:"destination_hash_hex"`
	DisplayName        string `json:"display_name,omitempty"`
	LastSeen           int64  `json:"last_seen"`
	AppDataLen         int    `json:"app_data_len,omitempty"`
}

type announceLogger struct {
	node         *Node
	aspectFilter string
}

func newAnnounceLogger(node *Node) *announceLogger {
	return &announceLogger{
		node:         node,
		aspectFilter: "",
	}
}

func (h *announceLogger) AspectFilter() string {
	return h.aspectFilter
}

func (h *announceLogger) ReceivedAnnounce(destinationHash []byte, announcedIdentity *rns.Identity, appData []byte) {
	if h == nil || h.node == nil {
		return
	}
	destHex := hex.EncodeToString(destinationHash)
	displayName := announceDisplayName(appData)
	h.node.recordAnnounce(AnnounceEntry{
		DestinationHashHex: destHex,
		DisplayName:        displayName,
		LastSeen:           time.Now().Unix(),
		AppDataLen:         len(appData),
	})
	if displayName != "" {
		rns.Logf(rns.LOG_DEBUG, "Announce rx %s name=%q", destHex, displayName)
	} else {
		rns.Logf(rns.LOG_DEBUG, "Announce rx %s", destHex)
	}
}

func (n *Node) initAnnounceHandler() {
	if n == nil || n.announceHandler != nil {
		return
	}
	h := newAnnounceLogger(n)
	rns.RegisterAnnounceHandler(h)
	n.announceHandler = h
}

func (n *Node) recordAnnounce(entry AnnounceEntry) {
	if n == nil {
		return
	}
	n.announceMu.Lock()
	if n.announces == nil {
		n.announces = make(map[string]AnnounceEntry)
	}
	n.announces[entry.DestinationHashHex] = entry
	n.announceMu.Unlock()
}

func (n *Node) announceSnapshot() []AnnounceEntry {
	if n == nil {
		return nil
	}
	n.announceMu.Lock()
	entries := make([]AnnounceEntry, 0, len(n.announces))
	for _, entry := range n.announces {
		entries = append(entries, entry)
	}
	n.announceMu.Unlock()
	sort.Slice(entries, func(i, j int) bool {
		return entries[i].LastSeen > entries[j].LastSeen
	})
	return entries
}

func (n *Node) AnnouncesJSON() string {
	if n == nil {
		return `{"announces":[],"error":"node not started"}`
	}
	resp := map[string]any{
		"announces": n.announceSnapshot(),
	}
	b, err := json.Marshal(resp)
	if err != nil {
		return `{"announces":[],"error":"marshal failed"}`
	}
	return string(b)
}

func announceDisplayName(appData []byte) string {
	if len(appData) == 0 {
		return ""
	}
	// Mirror LXMF announce app-data parsing: msgpack([display_name_bytes, stamp_cost?, avatar?]).
	var unpacked []any
	if err := umsgpack.Unpackb(appData, &unpacked); err != nil {
		return ""
	}
	if len(unpacked) == 0 {
		return ""
	}
	switch v := unpacked[0].(type) {
	case []byte:
		if len(v) > 0 {
			return string(v)
		}
	case string:
		return v
	}
	return ""
}
