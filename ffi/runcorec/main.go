package main

/*
#include <stdint.h>
 #include <stdlib.h>
typedef void (*runcore_inbound_cb)(void* user_data, const char* src_hash_hex, const char* title, const char* content);
typedef void (*runcore_inbound_cb2)(void* user_data, const char* src_hash_hex, const char* msg_id_hex, const char* title, const char* content);
typedef void (*runcore_log_cb)(void* user_data, int32_t level, const char* line);
typedef void (*runcore_message_status_cb)(void* user_data, const char* dest_hash_hex, const char* msg_id_hex, int32_t state);

static inline void runcore_inbound_cb_call(runcore_inbound_cb cb, void* user_data, const char* src, const char* title, const char* content) {
  cb(user_data, src, title, content);
}
static inline void runcore_inbound_cb2_call(runcore_inbound_cb2 cb, void* user_data, const char* src, const char* msg_id, const char* title, const char* content) {
  cb(user_data, src, msg_id, title, content);
}
static inline void runcore_log_cb_call(runcore_log_cb cb, void* user_data, int32_t level, const char* line) {
  cb(user_data, level, line);
}
static inline void runcore_message_status_cb_call(runcore_message_status_cb cb, void* user_data, const char* dest, const char* msg_id, int32_t state) {
  cb(user_data, dest, msg_id, state);
}
*/
import "C"

import (
	"encoding/hex"
	"encoding/json"
	"fmt"
	"strings"
	"sync"
	"time"
	"unsafe"

	"github.com/svanichkin/go-lxmf/lxmf"
	"github.com/svanichkin/go-reticulum/rns"

	"runcore"
)

type nodeHandle struct {
	node     *runcore.Node
	destHex  *C.char
	cb       C.runcore_inbound_cb
	cb2      C.runcore_inbound_cb2
	userData unsafe.Pointer
	statusCB C.runcore_message_status_cb
	statusUD unsafe.Pointer
	mu       sync.RWMutex
}

var (
	nextID  uint64 = 1
	nodes          = map[uint64]*nodeHandle{}
	nodesMu sync.RWMutex

	logMu       sync.RWMutex
	logCB       C.runcore_log_cb
	logUserData unsafe.Pointer
)

func main() {}

func allocCString(s string) *C.char { return C.CString(s) }

//export runcore_free_string
func runcore_free_string(p *C.char) {
	if p == nil {
		return
	}
	C.free(unsafe.Pointer(p))
}

//export runcore_default_lxmd_config
func runcore_default_lxmd_config() *C.char {
	return allocCString(runcore.DefaultLXMDConfigText(""))
}

//export runcore_default_lxmd_config_for_name
func runcore_default_lxmd_config_for_name(displayName *C.char) *C.char {
	name := ""
	if displayName != nil {
		name = C.GoString(displayName)
	}
	return allocCString(runcore.DefaultLXMDConfigText(name))
}

//export runcore_default_rns_config
func runcore_default_rns_config(loglevel C.int32_t) *C.char {
	return allocCString(runcore.DefaultRNSConfigText(int(loglevel)))
}

//export runcore_start
func runcore_start(configDir *C.char, displayName *C.char, loglevel C.int32_t, resetLXMF C.int32_t) C.uint64_t {
	dir := C.GoString(configDir)
	name := ""
	if displayName != nil {
		name = C.GoString(displayName)
	}
	level := int(loglevel)
	reset := resetLXMF != 0

	n, err := runcore.Start(runcore.Options{
		Dir:            dir,
		DisplayName:    name,
		LogLevel:       level,
		ResetLXMFState: reset,
	})
	if err != nil {
		return 0
	}

	h := &nodeHandle{node: n}
	h.destHex = allocCString(n.DestinationHashHex())

	n.SetInboundHandler(func(m *lxmf.LXMessage) {
		if m == nil {
			return
		}
		h.mu.RLock()
		cb := h.cb
		cb2 := h.cb2
		ud := h.userData
		h.mu.RUnlock()
		if cb == nil && cb2 == nil {
			return
		}
		src := hex.EncodeToString(m.SourceHash)
		msgID := hex.EncodeToString(m.MessageID)
		if msgID == "" && len(m.Hash) > 0 {
			msgID = hex.EncodeToString(m.Hash)
		}
		cSrc := allocCString(src)
		cMsgID := allocCString(msgID)
		cTitle := allocCString(m.TitleAsString())
		cContent := allocCString(m.ContentAsString())
		if cb2 != nil {
			C.runcore_inbound_cb2_call(cb2, ud, cSrc, cMsgID, cTitle, cContent)
		} else if cb != nil {
			C.runcore_inbound_cb_call(cb, ud, cSrc, cTitle, cContent)
		}
		C.free(unsafe.Pointer(cSrc))
		C.free(unsafe.Pointer(cMsgID))
		C.free(unsafe.Pointer(cTitle))
		C.free(unsafe.Pointer(cContent))
	})

	nodesMu.Lock()
	id := nextID
	nextID++
	nodes[id] = h
	nodesMu.Unlock()

	return C.uint64_t(id)
}

func getHandle(id C.uint64_t) *nodeHandle {
	nodesMu.RLock()
	h := nodes[uint64(id)]
	nodesMu.RUnlock()
	return h
}

//export runcore_stop
func runcore_stop(handle C.uint64_t) C.int32_t {
	nodesMu.Lock()
	h := nodes[uint64(handle)]
	delete(nodes, uint64(handle))
	nodesMu.Unlock()
	if h == nil {
		return 0
	}
	_ = h.node.Close()
	if h.destHex != nil {
		C.free(unsafe.Pointer(h.destHex))
		h.destHex = nil
	}
	return 0
}

//export runcore_set_inbound_cb
func runcore_set_inbound_cb(handle C.uint64_t, cb C.runcore_inbound_cb, userData unsafe.Pointer) {
	h := getHandle(handle)
	if h == nil {
		return
	}
	h.mu.Lock()
	h.cb = cb
	h.userData = userData
	h.mu.Unlock()
}

//export runcore_set_inbound_cb2
func runcore_set_inbound_cb2(handle C.uint64_t, cb C.runcore_inbound_cb2, userData unsafe.Pointer) {
	h := getHandle(handle)
	if h == nil {
		return
	}
	h.mu.Lock()
	h.cb2 = cb
	h.userData = userData
	h.mu.Unlock()
}

//export runcore_set_message_status_cb
func runcore_set_message_status_cb(handle C.uint64_t, cb C.runcore_message_status_cb, userData unsafe.Pointer) {
	h := getHandle(handle)
	if h == nil {
		return
	}
	h.mu.Lock()
	h.statusCB = cb
	h.statusUD = userData
	h.mu.Unlock()
}

//export runcore_set_log_cb
func runcore_set_log_cb(cb C.runcore_log_cb, userData unsafe.Pointer) {
	logMu.Lock()
	logCB = cb
	logUserData = userData
	logMu.Unlock()

	if cb == nil {
		rns.SetLogDestCallback(nil)
		return
	}
	rns.SetLogDestCallback(func(level int, msg string) {
		logMu.RLock()
		c := logCB
		ud := logUserData
		logMu.RUnlock()
		if c == nil {
			return
		}
		cLine := allocCString(msg)
		C.runcore_log_cb_call(c, ud, C.int32_t(level), cLine)
		C.free(unsafe.Pointer(cLine))
	})

	// Emit a marker so clients can verify the hook works without waiting for network activity.
	rns.Log("runcore: log callback enabled", rns.LOG_NOTICE)
}

//export runcore_set_loglevel
func runcore_set_loglevel(level C.int32_t) {
	rns.SetLogLevel(int(level))
}

//export runcore_destination_hash_hex
func runcore_destination_hash_hex(handle C.uint64_t) *C.char {
	h := getHandle(handle)
	if h == nil {
		return nil
	}
	return h.destHex
}

//export runcore_send
func runcore_send(handle C.uint64_t, destHashHex *C.char, title *C.char, content *C.char) C.int32_t {
	h := getHandle(handle)
	if h == nil || h.node == nil {
		return 1
	}
	dest := C.GoString(destHashHex)
	destHash, err := hex.DecodeString(dest)
	if err != nil || len(destHash) != lxmf.DestinationLength {
		return 4
	}
	if !rns.TransportHasPath(destHash) {
		rns.TransportRequestPath(destHash)
		return 5
	}
	if !strings.EqualFold(dest, C.GoString(h.destHex)) && rns.IdentityRecall(destHash) == nil {
		rns.TransportRequestPath(destHash)
		return 3
	}
	_, err = h.node.SendHex(dest, runcore.SendOptions{
		Method:  lxmf.MethodOpportunistic,
		Title:   C.GoString(title),
		Content: C.GoString(content),
	})
	if err != nil {
		return 2
	}
	return 0
}

//export runcore_send_result_json
func runcore_send_result_json(handle C.uint64_t, destHashHex *C.char, title *C.char, content *C.char) *C.char {
	h := getHandle(handle)
	if h == nil || h.node == nil {
		return allocCString(`{"rc":1,"error":"node not started"}`)
	}
	dest := C.GoString(destHashHex)
	destHash, err := hex.DecodeString(dest)
	if err != nil || len(destHash) != lxmf.DestinationLength {
		b, _ := json.Marshal(map[string]any{"rc": 5, "error": "invalid destination hash"})
		return allocCString(string(b))
	}
	if !rns.TransportHasPath(destHash) {
		rns.TransportRequestPath(destHash)
		b, _ := json.Marshal(map[string]any{"rc": 4, "error": "no path to destination"})
		return allocCString(string(b))
	}
	if !strings.EqualFold(dest, C.GoString(h.destHex)) && rns.IdentityRecall(destHash) == nil {
		rns.TransportRequestPath(destHash)
		b, _ := json.Marshal(map[string]any{"rc": 3, "error": "unknown destination identity"})
		return allocCString(string(b))
	}
	msg, err := h.node.SendHex(dest, runcore.SendOptions{
		Method:  lxmf.MethodOpportunistic,
		Title:   C.GoString(title),
		Content: C.GoString(content),
	})
	if err != nil || msg == nil {
		b, _ := json.Marshal(map[string]any{"rc": 2, "error": fmt.Sprintf("send failed: %v", err)})
		return allocCString(string(b))
	}

	// Attach callbacks for delivery/failed state transitions.
	msg.RegisterDeliveryCallback(func(m *lxmf.LXMessage) {
		if m == nil {
			return
		}
		h.mu.RLock()
		cb := h.statusCB
		ud := h.statusUD
		h.mu.RUnlock()
		if cb == nil {
			return
		}
		destHex := hex.EncodeToString(m.DestinationHash)
		msgIDHex := hex.EncodeToString(m.MessageID)
		if msgIDHex == "" && len(m.Hash) > 0 {
			msgIDHex = hex.EncodeToString(m.Hash)
		}
		cDest := allocCString(destHex)
		cMsgID := allocCString(msgIDHex)
		C.runcore_message_status_cb_call(cb, ud, cDest, cMsgID, C.int32_t(m.State))
		C.free(unsafe.Pointer(cDest))
		C.free(unsafe.Pointer(cMsgID))
	})
	msg.RegisterFailedCallback(func(m *lxmf.LXMessage) {
		if m == nil {
			return
		}
		h.mu.RLock()
		cb := h.statusCB
		ud := h.statusUD
		h.mu.RUnlock()
		if cb == nil {
			return
		}
		destHex := hex.EncodeToString(m.DestinationHash)
		msgIDHex := hex.EncodeToString(m.MessageID)
		if msgIDHex == "" && len(m.Hash) > 0 {
			msgIDHex = hex.EncodeToString(m.Hash)
		}
		cDest := allocCString(destHex)
		cMsgID := allocCString(msgIDHex)
		C.runcore_message_status_cb_call(cb, ud, cDest, cMsgID, C.int32_t(m.State))
		C.free(unsafe.Pointer(cDest))
		C.free(unsafe.Pointer(cMsgID))
	})

	msgIDHex := hex.EncodeToString(msg.MessageID)
	if msgIDHex == "" && len(msg.Hash) > 0 {
		msgIDHex = hex.EncodeToString(msg.Hash)
	}
	resp := map[string]any{"rc": 0, "message_id_hex": msgIDHex}
	b, _ := json.Marshal(resp)
	return allocCString(string(b))
}

//export runcore_announce
func runcore_announce(handle C.uint64_t) C.int32_t {
	h := getHandle(handle)
	if h == nil || h.node == nil {
		return 1
	}
	h.node.AnnounceDelivery()
	return 0
}

//export runcore_set_display_name
func runcore_set_display_name(handle C.uint64_t, displayName *C.char) C.int32_t {
	h := getHandle(handle)
	if h == nil || h.node == nil {
		return 1
	}
	name := ""
	if displayName != nil {
		name = C.GoString(displayName)
	}
	if err := h.node.SetDisplayName(name); err != nil {
		return 2
	}
	return 0
}

//export runcore_restart
func runcore_restart(handle C.uint64_t) C.int32_t {
	h := getHandle(handle)
	if h == nil || h.node == nil {
		return 1
	}
	if err := h.node.Restart(); err != nil {
		return 2
	}
	if h.destHex != nil {
		C.free(unsafe.Pointer(h.destHex))
		h.destHex = nil
	}
	h.destHex = allocCString(h.node.DestinationHashHex())
	return 0
}

//export runcore_interface_stats_json
func runcore_interface_stats_json(handle C.uint64_t) *C.char {
	h := getHandle(handle)
	if h == nil || h.node == nil {
		return nil
	}
	return allocCString(h.node.InterfaceStatsJSON())
}

//export runcore_configured_interfaces_json
func runcore_configured_interfaces_json(handle C.uint64_t) *C.char {
	h := getHandle(handle)
	if h == nil || h.node == nil {
		return nil
	}
	return allocCString(h.node.ConfiguredInterfacesJSON())
}

//export runcore_announces_json
func runcore_announces_json(handle C.uint64_t) *C.char {
	h := getHandle(handle)
	if h == nil || h.node == nil {
		return nil
	}
	return allocCString(h.node.AnnouncesJSON())
}

//export runcore_contact_info_json
func runcore_contact_info_json(handle C.uint64_t, destHashHex *C.char, timeoutMs C.int32_t) *C.char {
	h := getHandle(handle)
	if h == nil || h.node == nil || destHashHex == nil {
		return nil
	}
	timeout := time.Duration(timeoutMs) * time.Millisecond
	info, err := h.node.ContactInfoHex(C.GoString(destHashHex), timeout)
	resp := map[string]any{
		"display_name": info.DisplayName,
		"avatar":       info.Avatar,
	}
	if err != nil {
		resp["error"] = err.Error()
	}
	b, _ := json.Marshal(resp)
	return allocCString(string(b))
}

//export runcore_contact_avatar_json
func runcore_contact_avatar_json(handle C.uint64_t, destHashHex *C.char, knownAvatarHashHex *C.char, timeoutMs C.int32_t) *C.char {
	h := getHandle(handle)
	if h == nil || h.node == nil || destHashHex == nil {
		return nil
	}
	known := ""
	if knownAvatarHashHex != nil {
		known = C.GoString(knownAvatarHashHex)
	}
	timeout := time.Duration(timeoutMs) * time.Millisecond
	av, err := h.node.ContactAvatarPNGBase64Hex(C.GoString(destHashHex), known, timeout)
	resp := map[string]any{
		"hash_hex":    av.HashHex,
		"png_base64":  av.PNGBase64,
		"mime":        av.Mime,
		"unchanged":   av.Unchanged,
		"not_present": av.NotPresent,
	}
	if err != nil {
		resp["error"] = err.Error()
	}
	b, _ := json.Marshal(resp)
	return allocCString(string(b))
}

//export runcore_set_avatar_png
func runcore_set_avatar_png(handle C.uint64_t, pngData *C.uchar, pngLen C.int32_t) C.int32_t {
	h := getHandle(handle)
	if h == nil || h.node == nil {
		return 1
	}
	if pngData == nil || pngLen <= 0 {
		return 2
	}
	b := C.GoBytes(unsafe.Pointer(pngData), C.int(pngLen))
	if err := h.node.SetAvatarPNG(b); err != nil {
		return 3
	}
	return 0
}

//export runcore_clear_avatar
func runcore_clear_avatar(handle C.uint64_t) C.int32_t {
	h := getHandle(handle)
	if h == nil || h.node == nil {
		return 1
	}
	if err := h.node.ClearAvatar(); err != nil {
		return 2
	}
	return 0
}

//export runcore_set_interface_enabled
func runcore_set_interface_enabled(handle C.uint64_t, name *C.char, enabled C.int32_t) C.int32_t {
	h := getHandle(handle)
	if h == nil || h.node == nil {
		return 1
	}
	if name == nil {
		return 2
	}
	if err := h.node.SetInterfaceEnabled(C.GoString(name), enabled != 0); err != nil {
		return 3
	}
	return 0
}
