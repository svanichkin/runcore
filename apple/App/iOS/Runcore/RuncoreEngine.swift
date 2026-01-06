import Foundation

final class RuncoreEngine {
    private var handle: runcore_handle_t = 0
    private var cachedDestHex: String = ""

    var onInbound: ((_ destHashHex: String, _ title: String, _ content: String) -> Void)?
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
        let pngBase64: String?
        let unchanged: Bool?
        let notPresent: Bool?
        let error: String?

        enum CodingKeys: String, CodingKey {
            case hashHex = "hash_hex"
            case pngBase64 = "png_base64"
            case unchanged
            case notPresent = "not_present"
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

        runcore_set_inbound_cb(handle, { userData, srcHash, title, content in
            guard let userData else { return }
            let engine = Unmanaged<RuncoreEngine>.fromOpaque(userData).takeUnretainedValue()
            let src = srcHash.map { String(cString: $0) } ?? ""
            let t = title.map { String(cString: $0) } ?? ""
            let c = content.map { String(cString: $0) } ?? ""
            DispatchQueue.main.async {
                engine.onInbound?(src, t, c)
            }
        }, Unmanaged.passUnretained(self).toOpaque())

        _ = runcore_announce(handle)
    }

    func stop() {
        guard handle != 0 else { return }
        _ = runcore_stop(handle)
        handle = 0
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

    func send(destHashHex: String, title: String, content: String) -> Int32 {
        guard handle != 0 else { return 1 }
        return destHashHex.withCString { cDest in
            title.withCString { cTitle in
                content.withCString { cContent in
                    runcore_send(handle, cDest, cTitle, cContent)
                }
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
        if rc == 0 { _ = runcore_announce(handle) }
        return rc
    }

    func clearAvatar() -> Int32 {
        guard handle != 0 else { return 1 }
        let rc = runcore_clear_avatar(handle)
        if rc == 0 { _ = runcore_announce(handle) }
        return rc
    }

    func updateDisplayNameAndAnnounce(_ name: String) {
        displayName = name
        guard handle != 0 else { return }
        name.withCString { cName in
            _ = runcore_set_display_name(handle, cName)
        }
        _ = runcore_announce(handle)
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
