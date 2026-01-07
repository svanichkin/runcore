package runcore

import (
	"encoding/hex"
	"errors"
	"fmt"
	"time"

	"github.com/svanichkin/go-reticulum/rns"
	umsgpack "github.com/svanichkin/go-reticulum/rns/vendor"
)

type ContactAvatarInfo struct {
	HashHex string `json:"hash_hex,omitempty"`
	Mime    string `json:"mime,omitempty"`
	Size    int    `json:"size,omitempty"`
	Updated int64  `json:"updated,omitempty"`
}

type ContactInfo struct {
	DisplayName string            `json:"display_name,omitempty"`
	Avatar      *ContactAvatarInfo `json:"avatar,omitempty"`
}

func (n *Node) ContactInfoHex(destinationHashHex string, timeout time.Duration) (ContactInfo, error) {
	if n == nil {
		return ContactInfo{}, errors.New("node not started")
	}
	destHash, err := hex.DecodeString(destinationHashHex)
	if err != nil {
		return ContactInfo{}, fmt.Errorf("decode destination hash: %w", err)
	}
	if len(destHash) != 16 {
		return ContactInfo{}, fmt.Errorf("invalid destination hash length: got %d want %d", len(destHash), 16)
	}

	var id *rns.Identity
	if timeout <= 0 {
		id = rns.IdentityRecall(destHash)
		if id == nil || len(id.AppData) == 0 {
			return ContactInfo{}, nil
		}
	} else {
		// Important for macCatalyst: we can have an identity in cache without having
		// a path/announce, which means AppData (display name + avatar metadata) is empty.
		// Requesting a path triggers peers/routers to announce, which populates AppData.
		rns.TransportRequestPath(destHash)
		deadline := time.Now().Add(timeout)
		for {
			id = rns.IdentityRecall(destHash)
			if id != nil && len(id.AppData) > 0 {
				break
			}
			if time.Now().After(deadline) {
				return ContactInfo{}, nil
			}
			time.Sleep(120 * time.Millisecond)
		}
	}

	var unpacked []any
	if err := umsgpack.Unpackb(id.AppData, &unpacked); err != nil {
		return ContactInfo{}, nil
	}

	out := ContactInfo{}
	if len(unpacked) > 0 {
		switch v := unpacked[0].(type) {
		case []byte:
			if len(v) > 0 {
				out.DisplayName = string(v)
			}
		case string:
			out.DisplayName = v
		}
	}

	// Optional avatar metadata (runcore extension).
	if len(unpacked) > 2 {
		if m, ok := unpacked[2].(map[any]any); ok {
			av := &ContactAvatarInfo{}
			if hv, ok := m["h"]; ok {
				if b, ok := hv.([]byte); ok && len(b) > 0 {
					av.HashHex = hex.EncodeToString(b)
				}
			}
			if tv, ok := m["t"]; ok {
				if s, ok := tv.(string); ok {
					av.Mime = s
				}
			}
			if sv, ok := m["s"]; ok {
				switch n := sv.(type) {
				case int:
					av.Size = n
				case int64:
					av.Size = int(n)
				case float64:
					av.Size = int(n)
				}
			}
			if uv, ok := m["u"]; ok {
				switch n := uv.(type) {
				case int64:
					av.Updated = n
				case int:
					av.Updated = int64(n)
				case float64:
					av.Updated = int64(n)
				}
			}
			if av.HashHex != "" || av.Mime != "" || av.Size != 0 || av.Updated != 0 {
				out.Avatar = av
			}
		}
	}

	return out, nil
}
