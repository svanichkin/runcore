import Foundation

final class RuncoreEngine {
    private var handle: runcore_handle_t = 0
    private var cachedDestHex: String = ""

    var onInbound: ((_ srcHashHex: String, _ messageIDHex: String, _ title: String, _ content: String) -> Void)?
    var onMessageStatus: ((_ destHashHex: String, _ messageIDHex: String, _ state: Int32) -> Void)?
    var onLogLine: ((_ level: Int32, _ line: String) -> Void)?
    var displayName: String = "Me"
    var logLevel: Int32 = 3

    struct ContactAvatarInfo: Decodable {
        let hashHex: String?

        enum CodingKeys: String, CodingKey {
            case hashHex = "hash_hex"
        }
    }

    struct ContactInfo: Decodable {
        let displayName: String?
        let avatar: ContactAvatarInfo?

        enum CodingKeys: String, CodingKey {
            case displayName = "display_name"
            case avatar
        }
    }

    struct ContactAvatarResponse: Decodable {
        let hashHex: String?
        let dataBase64: String?
        let pngBase64: String?
        let mime: String?
        let unchanged: Bool?
        let notPresent: Bool?
        let error: String?

        enum CodingKeys: String, CodingKey {
            case hashHex = "hash_hex"
            case dataBase64 = "data_base64"
            case pngBase64 = "png_base64"
            case mime
            case unchanged
            case notPresent = "not_present"
            case error
        }
    }

    struct StoreAttachmentResponse: Decodable {
        let rc: Int32
        let hashHex: String?
        let mime: String?
        let name: String?
        let size: Int?
        let updated: Int64?
        let error: String?

        enum CodingKeys: String, CodingKey {
            case rc
            case hashHex = "hash_hex"
            case mime
            case name
            case size
            case updated
            case error
        }
    }

    struct ContactAttachmentResponse: Decodable {
        let hashHex: String?
        let path: String?
        let mime: String?
        let name: String?
        let size: Int?
        let notPresent: Bool?
        let error: String?

        enum CodingKeys: String, CodingKey {
            case hashHex = "hash_hex"
            case path
            case mime
            case name
            case size
            case notPresent = "not_present"
            case error
        }
    }


    struct SendResult: Decodable {
        let rc: Int32
        let messageIDHex: String?
        let error: String?

        enum CodingKeys: String, CodingKey {
            case rc
            case messageIDHex = "message_id_hex"
            case error
        }
    }

    func start() {
        guard handle == 0 else { return }

        // Install log hook before starting Reticulum so early init logs are captured.
        runcore_set_log_cb({ userData, level, line in
            guard let userData else { return }
            let engine = Unmanaged<RuncoreEngine>.fromOpaque(userData).takeUnretainedValue()
            let s = line.map { String(cString: $0) } ?? ""
            DispatchQueue.main.async {
                engine.onLogLine?(level, s)
            }
        }, Unmanaged.passUnretained(self).toOpaque())

        let dir = configDir()
        dir.withCString { cDir in
            displayName.withCString { cName in
                handle = runcore_start(cDir, cName, logLevel, 0)
            }
        }
        guard handle != 0 else { return }
        cachedDestHex = destinationHashHex()

        runcore_set_inbound_cb(handle, { userData, srcHash, msgID, title, content in
            guard let userData else { return }
            let engine = Unmanaged<RuncoreEngine>.fromOpaque(userData).takeUnretainedValue()
            let src = srcHash.map { String(cString: $0) } ?? ""
            let mid = msgID.map { String(cString: $0) } ?? ""
            let t = title.map { String(cString: $0) } ?? ""
            let c = content.map { String(cString: $0) } ?? ""
            DispatchQueue.main.async {
                engine.onInbound?(src, mid, t, c)
            }
        }, Unmanaged.passUnretained(self).toOpaque())

        runcore_set_message_status_cb(handle, { userData, destHash, msgID, state in
            guard let userData else { return }
            let engine = Unmanaged<RuncoreEngine>.fromOpaque(userData).takeUnretainedValue()
            let dest = destHash.map { String(cString: $0) } ?? ""
            let mid = msgID.map { String(cString: $0) } ?? ""
            DispatchQueue.main.async {
                engine.onMessageStatus?(dest, mid, state)
            }
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    func stop() {
        guard handle != 0 else { return }
        _ = runcore_stop(handle)
        handle = 0
    }

    func announce(reason: String = "ffi") -> Int32 {
        guard handle != 0 else { return 1 }
        return reason.withCString { cReason in
            runcore_announce_with_reason(handle, cReason)
        }
    }

    func setLogLevel(_ level: Int32) {
        logLevel = level
        runcore_set_loglevel(level)
    }

    func destinationHashHex() -> String {
        guard handle != 0 else { return cachedDestHex }
        guard let ptr = runcore_destination_hash_hex(handle) else { return cachedDestHex }
        return String(cString: ptr)
    }

    func interfaceStatsJSON() -> String {
        guard handle != 0 else { return "{}" }
        guard let ptr = runcore_interface_stats_json(handle) else { return "" }
        defer { runcore_free_string(ptr) }
        return String(cString: ptr)
    }

    func configuredInterfacesJSON() -> String {
        guard handle != 0 else { return "{}" }
        guard let ptr = runcore_configured_interfaces_json(handle) else { return "" }
        defer { runcore_free_string(ptr) }
        return String(cString: ptr)
    }

    func announcesJSON() -> String {
        guard handle != 0 else { return "{}" }
        guard let ptr = runcore_announces_json(handle) else { return "" }
        defer { runcore_free_string(ptr) }
        return String(cString: ptr)
    }

    func contactInfo(destHashHex: String, timeoutMs: Int32 = 1500) -> ContactInfo? {
        guard handle != 0 else { return nil }
        return destHashHex.withCString { cDest in
            guard let ptr = runcore_contact_info_json(handle, cDest, timeoutMs) else { return nil }
            defer { runcore_free_string(ptr) }
            let json = String(cString: ptr)
            guard let data = json.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(ContactInfo.self, from: data)
        }
    }

    func contactAvatar(destHashHex: String, knownHashHex: String?, timeoutMs: Int32 = 5000) -> ContactAvatarResponse? {
        guard handle != 0 else { return nil }
        return destHashHex.withCString { cDest in
            if let knownHashHex, !knownHashHex.isEmpty {
                return knownHashHex.withCString { cKnown in
                    guard let ptr = runcore_contact_avatar_json(handle, cDest, cKnown, timeoutMs) else { return nil }
                    defer { runcore_free_string(ptr) }
                    let json = String(cString: ptr)
                    guard let data = json.data(using: .utf8) else { return nil }
                    return try? JSONDecoder().decode(ContactAvatarResponse.self, from: data)
                }
            }
            guard let ptr = runcore_contact_avatar_json(handle, cDest, nil, timeoutMs) else { return nil }
            defer { runcore_free_string(ptr) }
            let json = String(cString: ptr)
            guard let data = json.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(ContactAvatarResponse.self, from: data)
        }
    }

    private func withOptionalCString<R>(_ s: String?, _ body: (UnsafePointer<CChar>?) -> R) -> R {
        if let s {
            return s.withCString { body($0) }
        }
        return body(nil)
    }

    func storeAttachment(mime: String?, name: String?, data: Data) -> StoreAttachmentResponse? {
        guard handle != 0 else { return nil }
        guard !data.isEmpty else { return StoreAttachmentResponse(rc: 2, hashHex: nil, mime: nil, name: nil, size: nil, updated: nil, error: "empty data") }
        let jsonPtr: UnsafeMutablePointer<CChar>? = data.withUnsafeBytes { buf in
            guard let base = buf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
            return withOptionalCString(mime) { cMime in
                withOptionalCString(name) { cName in
                    runcore_store_attachment_json(handle, cMime, cName, base, Int32(buf.count))
                }
            }
        }
        guard let jsonPtr else { return nil }
        defer { runcore_free_string(jsonPtr) }
        let json = String(cString: jsonPtr)
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(StoreAttachmentResponse.self, from: data)
    }

    func contactAttachment(destHashHex: String, attachmentHashHex: String, timeoutMs: Int32 = 15000) -> ContactAttachmentResponse? {
        guard handle != 0 else { return nil }
        return destHashHex.withCString { cDest in
            attachmentHashHex.withCString { cHash in
                guard let ptr = runcore_contact_attachment_json(handle, cDest, cHash, timeoutMs) else { return nil }
                defer { runcore_free_string(ptr) }
                let json = String(cString: ptr)
                guard let data = json.data(using: .utf8) else { return nil }
                return try? JSONDecoder().decode(ContactAttachmentResponse.self, from: data)
            }
        }
    }


    func setInterfaceEnabled(name: String, enabled: Bool) -> Int32 {
        guard handle != 0 else { return 1 }
        return name.withCString { cName in
            runcore_set_interface_enabled(handle, cName, enabled ? 1 : 0)
        }
    }

    func defaultLXMDConfigText() -> String {
        guard let ptr = runcore_default_lxmd_config() else { return "" }
        defer { runcore_free_string(ptr) }
        return String(cString: ptr)
    }

    func defaultLXMDConfigText(displayName: String) -> String {
        return displayName.withCString { cName in
            guard let ptr = runcore_default_lxmd_config_for_name(cName) else { return "" }
            defer { runcore_free_string(ptr) }
            return String(cString: ptr)
        }
    }

    func defaultRNSConfigText(logLevel: Int32) -> String {
        guard let ptr = runcore_default_rns_config(logLevel) else { return "" }
        defer { runcore_free_string(ptr) }
        return String(cString: ptr)
    }

    func sendResult(destHashHex: String, title: String, content: String) -> SendResult {
        guard handle != 0 else { return SendResult(rc: 1, messageIDHex: nil, error: "engine not started") }
        let jsonPtr: UnsafeMutablePointer<CChar>? = destHashHex.withCString { cDest in
            title.withCString { cTitle in
                content.withCString { cContent in
                    runcore_send_result_json(handle, cDest, cTitle, cContent)
                }
            }
        }
        guard let jsonPtr else { return SendResult(rc: 2, messageIDHex: nil, error: "no response") }
        defer { runcore_free_string(jsonPtr) }
        let json = String(cString: jsonPtr)
        guard let data = json.data(using: .utf8) else {
            return SendResult(rc: 2, messageIDHex: nil, error: "invalid json")
        }
        return (try? JSONDecoder().decode(SendResult.self, from: data)) ?? SendResult(rc: 2, messageIDHex: nil, error: "decode failed")
    }

        func setAvatarImage(mime: String, data: Data) -> Int32 {
        guard handle != 0 else { return 1 }
        return data.withUnsafeBytes { buf in
            guard let base = buf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 2 }
            return mime.withCString { cMime in
                runcore_set_avatar_image(handle, cMime, base, Int32(buf.count))
            }
        }
    }

func setAvatarPNG(_ data: Data) -> Int32 {
        guard handle != 0 else { return 1 }
        guard !data.isEmpty else { return 2 }
        let rc: Int32 = data.withUnsafeBytes { buf in
            guard let base = buf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 2 }
            return runcore_set_avatar_png(handle, base, Int32(buf.count))
        }
        if rc == 0 { _ = announce(reason: "avatar_changed") }
        return rc
    }

    func clearAvatar() -> Int32 {
        guard handle != 0 else { return 1 }
        let rc = runcore_clear_avatar(handle)
        if rc == 0 { _ = announce(reason: "avatar_cleared") }
        return rc
    }

    func updateDisplayNameAndAnnounce(_ name: String) {
        displayName = name
        guard handle != 0 else { return }
        name.withCString { cName in
            _ = runcore_set_display_name(handle, cName)
        }
        _ = announce(reason: "display_name_changed")
    }

    func setDisplayName(_ name: String) {
        displayName = name
        guard handle != 0 else { return }
        name.withCString { cName in
            _ = runcore_set_display_name(handle, cName)
        }
    }

    func restart() {
        guard handle != 0 else { return }
        _ = runcore_restart(handle)
        cachedDestHex = destinationHashHex()
    }

    private func configDir() -> String {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Runcore", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }
}
