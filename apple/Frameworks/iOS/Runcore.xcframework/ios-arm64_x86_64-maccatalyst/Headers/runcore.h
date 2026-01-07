#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Opaque handle to a running runcore node.
typedef uint64_t runcore_handle_t;

// Called on inbound message. Includes LXMF message_id (hex).
// All strings are UTF-8, valid only for the duration of the call.
typedef void (*runcore_inbound_cb)(
    void* user_data,
    const char* src_hash_hex,
    const char* msg_id_hex,
    const char* title,
    const char* content
);

// Called on outbound message status updates.
// `state` corresponds to lxmf.LXMessage.State (eg. 0x08 = delivered).
// All strings are UTF-8, valid only for the duration of the call.
typedef void (*runcore_message_status_cb)(
    void* user_data,
    const char* dest_hash_hex,
    const char* msg_id_hex,
    int32_t state
);

// Called for every internal log line. The line includes timestamp prefix.
typedef void (*runcore_log_cb)(void* user_data, int32_t level, const char* line);

// Set a global log callback (applies process-wide). Pass NULL to disable.
void runcore_set_log_cb(runcore_log_cb cb, void* user_data);

// Set global loglevel (0..7). Applies immediately.
void runcore_set_loglevel(int32_t level);

// Start Reticulum+LXMF node.
// - config_dir: directory for identity + LXMF storage + generated rns config
// - display_name: optional (may be NULL/empty); used in announce metadata
// - loglevel: Reticulum log level 0..7
// - reset_lxmf_state: if non-zero, remove ratchets before start
// Returns 0 on failure.
runcore_handle_t runcore_start(const char* config_dir, const char* display_name, int32_t loglevel, int32_t reset_lxmf_state);

// Persist state and stop (best-effort). Returns 0 on success.
int32_t runcore_stop(runcore_handle_t handle);

// Set inbound callback. Pass NULL to disable.
void runcore_set_inbound_cb(runcore_handle_t handle, runcore_inbound_cb cb, void* user_data);

// Set outbound message status callback. Pass NULL to disable.
void runcore_set_message_status_cb(runcore_handle_t handle, runcore_message_status_cb cb, void* user_data);

// Returns this node's LXMF delivery destination hash as hex (32 chars).
// The returned pointer is owned by the library and remains valid until runcore_stop().
const char* runcore_destination_hash_hex(runcore_handle_t handle);

// Send a message to `dest_hash_hex` (32 hex chars). Returns 0 on success.
int32_t runcore_send(runcore_handle_t handle, const char* dest_hash_hex, const char* title, const char* content);

// Send a message and return JSON with the message_id_hex (best-effort).
// Response: {"rc":0,"message_id_hex":"...","error":"..."}.
// The returned pointer must be freed with runcore_free_string().
char* runcore_send_result_json(runcore_handle_t handle, const char* dest_hash_hex, const char* title, const char* content);

// Announce this node's delivery destination. Returns 0 on success.
int32_t runcore_announce(runcore_handle_t handle);

// Update display_name used in announce app-data (does not restart the node). Returns 0 on success.
int32_t runcore_set_display_name(runcore_handle_t handle, const char* display_name);

// Restart the LXMF router (re-announce on restart). Returns 0 on success.
int32_t runcore_restart(runcore_handle_t handle);

// Set profile avatar PNG bytes (announced via app-data + available over /avatar). Returns 0 on success.
int32_t runcore_set_avatar_png(runcore_handle_t handle, const unsigned char* png_data, int32_t png_len);

// Clear profile avatar. Returns 0 on success.
int32_t runcore_clear_avatar(runcore_handle_t handle);

// Free a C string allocated by the library (eg. runcore_interface_stats_json()).
void runcore_free_string(char* p);

// Return the embedded default runcore (lxmd-style) config.
// The returned pointer must be freed with runcore_free_string().
char* runcore_default_lxmd_config(void);

// Return the embedded default runcore (lxmd-style) config, using display_name.
// The returned pointer must be freed with runcore_free_string().
char* runcore_default_lxmd_config_for_name(const char* display_name);

// Return the embedded default Reticulum config used for configDir/rns/config.
// The returned pointer must be freed with runcore_free_string().
char* runcore_default_rns_config(int32_t loglevel);

// Returns JSON with Reticulum interface stats (includes `interfaces` array with `name`, `type`, `status`, `rxb`, `txb`, etc).
// The returned pointer must be freed with runcore_free_string().
char* runcore_interface_stats_json(runcore_handle_t handle);

// Returns JSON with configured interfaces from Reticulum config (includes disabled ones).
// The returned pointer must be freed with runcore_free_string().
char* runcore_configured_interfaces_json(runcore_handle_t handle);

// Returns JSON with received LXMF delivery announces.
// Response: {"announces":[...], "error":"..."}.
// The returned pointer must be freed with runcore_free_string().
char* runcore_announces_json(runcore_handle_t handle);

// Returns JSON with best-effort contact info for `dest_hash_hex` (32 hex chars).
// Response: {"display_name":"...", "avatar":{...}?, "error":"..."}.
// The returned pointer must be freed with runcore_free_string().
char* runcore_contact_info_json(runcore_handle_t handle, const char* dest_hash_hex, int32_t timeout_ms);

// Returns JSON with best-effort contact avatar for `dest_hash_hex` (32 hex chars).
// Request: known_avatar_hash_hex may be NULL/empty to always fetch.
// Response: {"hash_hex":"..","png_base64":"..","unchanged":bool,"not_present":bool,"error":".."}.
// The returned pointer must be freed with runcore_free_string().
char* runcore_contact_avatar_json(runcore_handle_t handle, const char* dest_hash_hex, const char* known_avatar_hash_hex, int32_t timeout_ms);

// Enable/disable an interface by config section name (eg "Default Interface").
// Returns 0 on success.
int32_t runcore_set_interface_enabled(runcore_handle_t handle, const char* name, int32_t enabled);

#ifdef __cplusplus
}
#endif
