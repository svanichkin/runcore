# Reticulum BLE transport compatibility (go-reticulum)

## What “BLE transport” means in Reticulum

Reticulum’s BLE support is not a new protocol — it is a **byte transport** that carries the normal Reticulum frames.
So iOS↔Android↔Linux compatibility requires matching the same **GATT service/characteristics + send/receive semantics**.

## Wire compatibility extracted from current go-reticulum + Reticulum Python

The implementation used by Reticulum’s `RNodeInterface` is the **Nordic UART Service (NUS)** profile:

- **Service UUID**: `6E400001-B5A3-F393-E0A9-E50E24DCCA9E`
- **RX characteristic UUID** (central writes to peripheral): `6E400002-B5A3-F393-E0A9-E50E24DCCA9E`
- **TX characteristic UUID** (peripheral notifies central): `6E400003-B5A3-F393-E0A9-E50E24DCCA9E`

Data model:

- No extra framing at the BLE layer: it is treated as a **raw byte stream**.
- Writes are done using **Write Without Response** (when available), chunked to the current maximum payload.
- Reads are delivered via **notifications** on the TX characteristic and appended to a receive buffer.
- MTU is negotiated up to 512 where possible; chunk size is derived from negotiated MTU / platform limits.

Discovery / target selection (current Go + Python behavior):

- Scan for advertisements containing the **NUS service UUID**.
- If no explicit target is provided, prefer devices whose local name starts with `"RNode "`.

References in this repo:

- Go (macOS/Linux BLE transport): `third_party/go-reticulum/rns/interfaces/ble/ble_darwin.go`, `third_party/go-reticulum/rns/interfaces/ble/ble_linux.go`
- Python (Android BLEConnection): `third_party/go-reticulum/rns/interfaces/android/RNodeInterface.py` (`BLEConnection.*UUID`)

## What must be implemented for iOS to be compatible

To make iOS a first-class Reticulum BLE peer, we need an iOS backend that provides the same transport semantics using **CoreBluetooth**:

1. **Central role**
   - Scan for peripherals advertising the NUS service UUID.
   - Connect, discover service/characteristics, subscribe to TX notifications.
   - Write outbound bytes to RX characteristic (prefer `.withoutResponse`) with correct chunking.

2. **Peripheral role** (needed for iOS↔Android phone-to-phone)
   - Advertise the NUS service UUID.
   - Provide RX characteristic (write) and TX characteristic (notify).
   - Forward received RX writes into Reticulum, and publish outbound bytes via TX notifications.

3. **Flow control**
   - Respect `maximumWriteValueLength(for:)` on iOS.
   - Handle reconnects, background limitations, and permission prompts.

## Current status

In this repo, BLE is **disabled on iOS/Mac Catalyst** because go-reticulum’s existing BLE backend is macOS/Linux/Windows oriented and not CoreBluetooth based.

Next implementation step is to add an iOS CoreBluetooth backend (likely in Swift/ObjC) and bridge it to the Go transport layer.

