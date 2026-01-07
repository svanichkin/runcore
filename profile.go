package runcore

import (
	"bytes"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"time"

	"github.com/svanichkin/go-lxmf/lxmf"
	"github.com/svanichkin/go-reticulum/rns"
)

const (
	profileAppName   = "runcore"
	profileAspect    = "profile"
	profileAvatarReq = "/avatar"
	profileAvatarRes = "avatar"
)

func (n *Node) initProfileDestination() error {
	if n == nil || n.identity == nil {
		return errors.New("node not started")
	}
	if n.profileDestIn != nil {
		return nil
	}
	dest, err := rns.NewDestination(n.identity, rns.DestinationIN, rns.DestinationSINGLE, profileAppName, profileAspect)
	if err != nil {
		return fmt.Errorf("create profile destination: %w", err)
	}
	if err := n.registerAvatarRequestHandler(dest); err != nil {
		return fmt.Errorf("register avatar handler on profile dest: %w", err)
	}
	if err := n.registerAttachmentRequestHandler(dest); err != nil {
		return fmt.Errorf("register attachment handler on profile dest: %w", err)
	}
	n.profileDestIn = dest
	if err := n.registerAvatarRequestHandler(n.deliveryDestIn); err != nil {
		return fmt.Errorf("register avatar handler on delivery dest: %w", err)
	}
	if err := n.registerAttachmentRequestHandler(n.deliveryDestIn); err != nil {
		return fmt.Errorf("register attachment handler on delivery dest: %w", err)
	}
	return nil
}

func (n *Node) registerAvatarRequestHandler(dest *rns.Destination) error {
	if n == nil || dest == nil {
		return nil
	}
	return dest.RegisterRequestHandler(
		profileAvatarReq,
		func(path string, reqData any, requestID []byte, linkID []byte, remoteIdentity *rns.Identity, requestedAt time.Time) any {
			if n == nil {
				return nil
			}
			remoteHex := ""
			if remoteIdentity != nil {
				remoteHex = remoteIdentity.HexHash
			}
			var knownHash []byte
			if m, ok := reqData.(map[any]any); ok {
				if hv, ok := m["h"]; ok {
					if b, ok := hv.([]byte); ok && len(b) > 0 {
						knownHash = b
					}
				}
			}

			hash := append([]byte(nil), n.avatarHash...)
			avatarData := append([]byte(nil), n.avatarPNG...)
			mtime := n.avatarMTime
			mime := n.avatarMime
			if mime == "" {
				mime = detectAvatarMime(avatarData)
			}

			if len(hash) == 0 || len(avatarData) == 0 {
				rns.Logf(rns.LOG_NOTICE, "avatar req: none available remote=%s", remoteHex)
				return map[any]any{"ok": false}
			}
			if len(knownHash) > 0 && bytes.Equal(knownHash, hash) {
				rns.Logf(rns.LOG_NOTICE, "avatar req: unchanged remote=%s size=%d", remoteHex, len(avatarData))
				return map[any]any{"ok": true, "unchanged": true, "h": hash, "t": mime, "s": len(avatarData), "u": mtime}
			}
			link := findActiveLink(linkID)
			if link == nil {
				rns.Logf(rns.LOG_NOTICE, "avatar req: link not found remote=%s", remoteHex)
				return map[any]any{"ok": false, "error": "link not found"}
			}
			meta := map[any]any{
				"kind": profileAvatarRes,
				"h":    hash,
				"t":    mime,
				"s":    len(avatarData),
				"u":    mtime,
			}
			if _, err := rns.NewResource(avatarData, nil, link, meta, true, false, nil, nil, nil, 0, nil, nil, false, 0); err != nil {
				rns.Logf(rns.LOG_NOTICE, "avatar req: resource send failed remote=%s err=%v", remoteHex, err)
				return map[any]any{"ok": false, "error": "resource send failed"}
			}
			rns.Logf(rns.LOG_NOTICE, "avatar req: resource queued remote=%s size=%d", remoteHex, len(avatarData))
			return map[any]any{"ok": true, "h": hash, "t": mime, "s": len(avatarData), "u": mtime, "resource": true}
		},
		rns.DestinationALLOW_ALL,
		nil,
		true,
	)
}

type ContactAvatarFetch struct {
	HashHex    string `json:"hash_hex,omitempty"`
	DataBase64 string `json:"data_base64,omitempty"`
	PNGBase64  string `json:"png_base64,omitempty"`
	Mime       string `json:"mime,omitempty"`
	Unchanged  bool   `json:"unchanged,omitempty"`
	NotPresent bool   `json:"not_present,omitempty"`
	Error      string `json:"error,omitempty"`
}

func (n *Node) ContactAvatarDataBase64Hex(destinationHashHex string, knownAvatarHashHex string, timeout time.Duration) (ContactAvatarFetch, error) {
	if n == nil || n.identity == nil {
		return ContactAvatarFetch{}, errors.New("node not started")
	}
	if timeout <= 0 {
		timeout = 5 * time.Second
	}

	id, err := n.WaitForIdentityHex(destinationHashHex, timeout)
	if err != nil {
		return ContactAvatarFetch{}, err
	}
	if id == nil {
		return ContactAvatarFetch{}, errors.New("unknown destination identity")
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
		rns.Logf(rns.LOG_NOTICE, "avatar fetch: try %s dest=%s", spec.label, destinationHashHex)
		outDest, err := rns.NewDestination(id, rns.DestinationOUT, rns.DestinationSINGLE, spec.app, spec.aspect)
		if err != nil {
			lastErr = fmt.Errorf("create %s outbound destination: %w", spec.label, err)
			continue
		}
		resp, err := n.fetchAvatarViaDestination(outDest, knownAvatarHashHex, timeout)
		if err == nil {
			return resp, nil
		}
		lastErr = err
	}
	if lastErr != nil {
		return ContactAvatarFetch{}, lastErr
	}
	return ContactAvatarFetch{}, errors.New("avatar request failed")
}

func (n *Node) fetchAvatarViaDestination(outDest *rns.Destination, knownAvatarHashHex string, timeout time.Duration) (ContactAvatarFetch, error) {
	if outDest == nil {
		return ContactAvatarFetch{}, errors.New("nil destination")
	}

	// If we don't have a path yet, link establishment will usually just time out.
	// This is common on macCatalyst when multicast announce reception is flaky.
	if !rns.TransportHasPath(outDest.Hash()) {
		rns.Logf(rns.LOG_NOTICE, "avatar fetch: no path yet, requesting path dest=%s", hex.EncodeToString(outDest.Hash()))
		rns.TransportRequestPath(outDest.Hash())
		waitDeadline := time.Now().Add(minDuration(timeout, 4*time.Second))
		for !rns.TransportHasPath(outDest.Hash()) && time.Now().Before(waitDeadline) {
			time.Sleep(150 * time.Millisecond)
		}
		if rns.TransportHasPath(outDest.Hash()) {
			rns.Logf(rns.LOG_NOTICE, "avatar fetch: path acquired dest=%s", hex.EncodeToString(outDest.Hash()))
		}
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
		rns.Logf(rns.LOG_NOTICE, "avatar fetch: open link failed: %v", err)
		return ContactAvatarFetch{}, fmt.Errorf("open link: %w", err)
	}
	defer link.Teardown()

	deadline := time.NewTimer(timeout)
	defer deadline.Stop()
	select {
	case <-established:
	case <-closed:
		rns.Logf(rns.LOG_NOTICE, "avatar fetch: link closed before establishment")
		return ContactAvatarFetch{}, errors.New("link closed before establishment")
	case <-deadline.C:
		rns.Logf(rns.LOG_NOTICE, "avatar fetch: link establish timeout")
		return ContactAvatarFetch{}, errors.New("timeout establishing link")
	}

	// Provide caller identity (optional, but useful for allow-lists in the future).
	link.Identify(n.identity)

	req := map[any]any{}
	if knownAvatarHashHex != "" {
		if b, err := hex.DecodeString(knownAvatarHashHex); err == nil && len(b) > 0 {
			req["h"] = b
		}
	}

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
		profileAvatarReq,
		req,
		func(rr *rns.RequestReceipt) { respCh <- rr.Response() },
		func(rr *rns.RequestReceipt) { failCh <- struct{}{} },
		nil,
		timeout.Seconds(),
	)
	if rr == nil {
		rns.Logf(rns.LOG_NOTICE, "avatar fetch: request send failed")
		return ContactAvatarFetch{}, errors.New("failed to send avatar request")
	}

	var respHash []byte
	var respMime string
	var respUnchanged bool

	for {
		select {
		case resp := <-respCh:
			switch v := resp.(type) {
			case map[any]any:
				ok, _ := v["ok"].(bool)
				if !ok {
					rns.Logf(rns.LOG_NOTICE, "avatar fetch: not present")
					return ContactAvatarFetch{NotPresent: true}, nil
				}
				respUnchanged, _ = v["unchanged"].(bool)
				if hv, ok := v["h"].([]byte); ok {
					respHash = append([]byte(nil), hv...)
				}
				if tv, ok := v["t"].(string); ok {
					respMime = tv
				}
				if respUnchanged {
					out := ContactAvatarFetch{
						HashHex:   hex.EncodeToString(respHash),
						Mime:      respMime,
						Unchanged: true,
					}
					rns.Logf(rns.LOG_NOTICE, "avatar fetch: unchanged")
					return out, nil
				}
			case []byte:
				// Compatibility: handler may return raw bytes.
				rns.Logf(rns.LOG_NOTICE, "avatar fetch: ok raw size=%d", len(v))
				b64 := base64.StdEncoding.EncodeToString(v)
				return ContactAvatarFetch{DataBase64: b64, PNGBase64: b64}, nil
			default:
				rns.Logf(rns.LOG_NOTICE, "avatar fetch: unexpected response %T", resp)
				return ContactAvatarFetch{}, errors.New("unexpected avatar response type")
			}
		case res := <-resCh:
			if res == nil {
				return ContactAvatarFetch{}, errors.New("avatar resource nil")
			}
			if res.Status() != rns.ResourceComplete {
				return ContactAvatarFetch{}, errors.New("avatar resource failed")
			}
			meta := res.Metadata()
			kind, _ := meta["kind"].(string)
			if kind != "" && kind != profileAvatarRes {
				return ContactAvatarFetch{}, errors.New("unexpected avatar resource kind")
			}
			if hv, ok := meta["h"].([]byte); ok && len(hv) > 0 {
				respHash = append([]byte(nil), hv...)
			}
			if tv, ok := meta["t"].(string); ok && tv != "" {
				respMime = tv
			}
			data, err := os.ReadFile(res.DataFile())
			if err != nil {
				return ContactAvatarFetch{}, fmt.Errorf("read avatar resource: %w", err)
			}
			out := ContactAvatarFetch{
				HashHex:   hex.EncodeToString(respHash),
				Mime:      respMime,
				Unchanged: false,
			}
			if len(data) > 0 {
				b64 := base64.StdEncoding.EncodeToString(data)
				out.DataBase64 = b64
				out.PNGBase64 = b64
			}
			rns.Logf(rns.LOG_NOTICE, "avatar fetch: ok resource size=%d", len(data))
			return out, nil
		case <-failCh:
			rns.Logf(rns.LOG_NOTICE, "avatar fetch: request failed")
			return ContactAvatarFetch{}, errors.New("avatar request failed")
		case <-deadline.C:
			rns.Logf(rns.LOG_NOTICE, "avatar fetch: request timeout")
			return ContactAvatarFetch{}, errors.New("avatar request timeout")
		}
	}
}

func minDuration(a, b time.Duration) time.Duration {
	if a <= 0 {
		return b
	}
	if a < b {
		return a
	}
	return b
}

func findActiveLink(linkID []byte) *rns.Link {
	if len(linkID) == 0 {
		return nil
	}
	for _, l := range rns.TransportActiveLinks() {
		if l == nil || len(l.LinkID) == 0 {
			continue
		}
		if bytes.Equal(l.LinkID, linkID) {
			return l
		}
	}
	return nil
}
