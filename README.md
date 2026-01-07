# runcore

`runcore` is an `lxmd`-compatible (config/behavior) LXMF daemon that runs Reticulum in-process (no separate `rnsd`).

## Implemented (current)

### Go core

- Reticulum+LXMF in a single process (no `rnsd`), `lxmd`-compatible config/storage layout.
- Announces: `runcore_announce()` + receive announces (snapshot via `AnnouncesJSON()` / `runcore_announces_json()`).
- Profile: `display_name` + avatar (set/clear), serve avatar via `/avatar`, best-effort avatar fetch for a contact.
- Messages: receive via inbound callback, send (opportunistic), outbound status updates via callback.
- Interfaces: stats (`InterfaceStatsJSON`) + configured interfaces list + enable/disable interface by section name.

### SwiftUI (iOS + Mac Catalyst)

- Contacts/chats/profile/log are stored in `Documents/Runcore/state.json` (JSON).
- Outbound pending: if there is no path/identity, the message stays `pending` and the app retries delivery.
- Diagnostics screen: logs, interfaces, view/edit `config` and `rns/config`, announces list.
- Blocklist: inbound from blocked destination hashes are dropped at the UI level.

## Quick start

Running without arguments creates an `lxmd`-compatible config directory and a default `config`.

```bash
go run ./cmd/runcore
```

Print an example config and exit:

```bash
go run ./cmd/runcore -exampleconfig
```

By default, the Reticulum config is generated once into `<configdir>/rns/config` from an embedded template (after that you can edit it manually). To regenerate LXMF transient state (ratchets), use `-reset-lxmf`.

## Using as a library

Minimal example:

```go
cfgDir := "/path/to/AppSupport/runcore"
_, _ = runcore.EnsureLXMDConfig(cfgDir)
_, _ = runcore.EnsureRNSConfig(cfgDir, 4)

n, err := runcore.Start(runcore.Options{Dir: cfgDir})
if err != nil { panic(err) }
defer n.Close()

n.SetInboundHandler(func(m *lxmf.LXMessage) {
	// m.TitleAsString(), m.ContentAsString(), m.SourceHash, ...
})
```

Config management (load/edit/save/reset defaults):

- Load: `runcore.LoadLXMDConfig(cfgDir)`
- Save: `runcore.SaveLXMDConfig(cfg, cfgDir)`
- Reset: `runcore.ResetLXMDConfig(cfgDir)`

Reticulum config:

- Ensure exists: `runcore.EnsureRNSConfig(cfgDir, logLevel)`
- Reset: `runcore.ResetRNSConfig(cfgDir, logLevel)`

## Two instances

Reticulum in `go-reticulum` is a singleton, so to run two nodes you must run two separate processes with different `-config` directories:

```bash
go run ./cmd/runcore -config .nodeA -reset-lxmf -v
go run ./cmd/runcore -config .nodeB -reset-lxmf -v
```
