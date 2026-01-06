import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

@MainActor
final class AppStore: ObservableObject {
    enum ConfigKind: Int, CaseIterable {
        case runcore = 0
        case rns = 1
    }

    @Published var contacts: [Contact] = []
    @Published var messagesByContactID: [UUID: [ChatMessage]] = [:]
    @Published var selectedContactID: UUID?
    @Published var isPresentingAddContact = false
    @Published var logs: [String] = []
    @Published var profileName: String = "Me"
    @Published var profileAvatarData: Data?
    @Published var interfaceStats: InterfaceStatsSnapshot = .empty
    @Published var interfaceStatsUpdatedAt: Date?
    @Published var lastInterfaceStatsJSON: String = ""
    @Published var lastInterfaceStatsError: String?
    @Published var configuredInterfaces: [ConfiguredInterface] = []
    @Published var lastConfiguredInterfacesJSON: String = ""
    @Published var lastConfiguredInterfacesError: String?
    @Published var announces: [AnnounceEntry] = []
    @Published var lastAnnouncesJSON: String = ""
    @Published var lastAnnouncesError: String?
    @Published var debugLoggingEnabled: Bool = false

    private let persistence = Persistence()
    private let engine = RuncoreEngine()
    private var pendingAnnounceTask: Task<Void, Never>?
    private var statsPollTask: Task<Void, Never>?
    private var pendingRawLogLines: [String] = []
    private var rawLogFlushTask: Task<Void, Never>?

    init() {
        load()
        engine.displayName = profileName
        engine.setLogLevel(debugLoggingEnabled ? 6 : 3)
        engine.onLogLine = { [weak self] _, line in
            guard let self else { return }
            self.appendRawLog(line)
        }
        engine.onInbound = { [weak self] destHex, title, content in
            guard let self else { return }
            self.appendLog("inbound src=\(destHex) title=\(title)")
            if let contact = self.contacts.first(where: { $0.destinationHashHex == destHex }) {
                self.messagesByContactID[contact.id, default: []].append(ChatMessage(direction: .inbound, text: content, title: title))
                self.save()
            }
        }
        engine.start()
        appendLog("engine started (iOS stub)")
        if let avatar = profileAvatarData, !avatar.isEmpty {
            let rc = engine.setAvatarPNG(avatar)
            if rc != 0 { appendLog("set avatar failed rc=\(rc)") }
        }
        refreshInterfaceStats()
        refreshConfiguredInterfaces()
        refreshAnnounces()
        statsPollTask?.cancel()
        statsPollTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if Task.isCancelled { return }
                self.refreshInterfaceStats()
                self.refreshConfiguredInterfaces()
                self.refreshAnnounces()
            }
        }
    }

    deinit {
        statsPollTask?.cancel()
    }

    var destinationHashHex: String { engine.destinationHashHex() }
    var logsText: String { logs.suffix(200).joined(separator: "\n") }
    var configText: String { loadTextFile(at: configPath()) ?? "(no runcore config file found)" }
    var rnsConfigText: String { loadTextFile(at: rnsConfigPath()) ?? "(no rns config file found)" }

    func loadConfigText(_ kind: ConfigKind) -> String {
        switch kind {
        case .runcore:
            return loadTextFile(at: configPath()) ?? ""
        case .rns:
            return loadTextFile(at: rnsConfigPath()) ?? ""
        }
    }

    func defaultConfigText(_ kind: ConfigKind) -> String {
        switch kind {
        case .runcore:
            return engine.defaultLXMDConfigText(displayName: profileName)
        case .rns:
            return engine.defaultRNSConfigText(logLevel: 3)
        }
    }

    func saveConfigText(_ kind: ConfigKind, text: String) throws {
        let url: URL
        switch kind {
        case .runcore:
            url = configPath()
        case .rns:
            url = rnsConfigPath()
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = text.data(using: .utf8) else {
            throw NSError(domain: "Runcore", code: 1, userInfo: [NSLocalizedDescriptionKey: "failed to encode config as UTF-8"])
        }
        try data.write(to: url, options: [.atomic])
        appendLog("saved \(kind == .runcore ? "runcore" : "rns") config")
    }

    func resetConfig(_ kind: ConfigKind) throws {
        let text = defaultConfigText(kind)
        try saveConfigText(kind, text: text)
    }

    func appendLog(_ line: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        logs.append("[\(ts)] \(line)")
        if logs.count > 5000 { logs.removeFirst(logs.count - 5000) }
    }

    func appendRawLog(_ line: String) {
        NSLog("%@", line)
        pendingRawLogLines.append(line)
        if rawLogFlushTask != nil { return }
        rawLogFlushTask = Task { @MainActor in
            defer { rawLogFlushTask = nil }
            try? await Task.sleep(nanoseconds: 250_000_000)
            if pendingRawLogLines.isEmpty { return }
            logs.append(contentsOf: pendingRawLogLines)
            pendingRawLogLines.removeAll(keepingCapacity: true)
            if logs.count > 5000 { logs.removeFirst(logs.count - 5000) }
        }
    }

    func setDebugLoggingEnabled(_ enabled: Bool) {
        debugLoggingEnabled = enabled
        engine.setLogLevel(enabled ? 6 : 3)
        appendLog("loglevel set to \(enabled ? 6 : 3)")
        save()
    }

    func setProfileAvatarData(_ data: Data?) {
        let normalized = normalizeAvatarData(data)
        profileAvatarData = normalized
        save()
        if let normalized, !normalized.isEmpty {
            let rc = engine.setAvatarPNG(normalized)
            if rc != 0 { appendLog("set avatar failed rc=\(rc)") }
            return
        }
        let rc = engine.clearAvatar()
        if rc != 0 { appendLog("clear avatar failed rc=\(rc)") }
    }

    private func normalizeAvatarData(_ data: Data?) -> Data? {
        guard let data, !data.isEmpty else { return nil }
        guard let image = UIImage(data: data) else { return data }
        let maxSide: CGFloat = 1024
        let size = image.size
        let longest = max(size.width, size.height)
        let targetSize: CGSize
        if longest > maxSide, longest > 0 {
            let scale = maxSide / longest
            targetSize = CGSize(width: size.width * scale, height: size.height * scale)
        } else {
            targetSize = size
        }
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        let output = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        if let heic = encodeHEIC(output, quality: 0.78) {
            return heic
        }
        return output.jpegData(compressionQuality: 0.85) ?? output.pngData() ?? data
    }

    private func encodeHEIC(_ image: UIImage, quality: CGFloat) -> Data? {
        guard let cgImage = image.cgImage else { return nil }
        if #available(iOS 14.0, macCatalyst 14.0, *) {
            let data = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(data, UTType.heic.identifier as CFString, 1, nil) else {
                return nil
            }
            let options = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
            CGImageDestinationAddImage(dest, cgImage, options)
            guard CGImageDestinationFinalize(dest) else { return nil }
            return data as Data
        }
        return nil
    }

    func refreshInterfaceStats() {
        let json = engine.interfaceStatsJSON()
        lastInterfaceStatsJSON = json
        if json.isEmpty {
            interfaceStats = .empty
            interfaceStatsUpdatedAt = nil
            lastInterfaceStatsError = "runcore_interface_stats_json returned NULL"
            return
        }
        do {
            let data = json.data(using: .utf8) ?? Data()
            interfaceStats = try JSONDecoder().decode(InterfaceStatsSnapshot.self, from: data)
            interfaceStatsUpdatedAt = Date()
            lastInterfaceStatsError = nil
        } catch {
            appendLog("failed to parse interface stats: \(error)")
            interfaceStats = .empty
            interfaceStatsUpdatedAt = nil
            lastInterfaceStatsError = String(describing: error)
        }
    }

    func refreshConfiguredInterfaces() {
        let json = engine.configuredInterfacesJSON()
        lastConfiguredInterfacesJSON = json
        if json.isEmpty {
            configuredInterfaces = []
            lastConfiguredInterfacesError = "runcore_configured_interfaces_json returned NULL"
            return
        }
        do {
            let data = json.data(using: .utf8) ?? Data()
            let snapshot = try JSONDecoder().decode(ConfiguredInterfacesSnapshot.self, from: data)
            configuredInterfaces = snapshot.interfaces
            lastConfiguredInterfacesError = snapshot.error
        } catch {
            appendLog("failed to parse configured interfaces: \(error)")
            configuredInterfaces = []
            lastConfiguredInterfacesError = String(describing: error)
        }
    }

    func refreshAnnounces() {
        let json = engine.announcesJSON()
        lastAnnouncesJSON = json
        if json.isEmpty {
            announces = []
            lastAnnouncesError = "runcore_announces_json returned NULL"
            return
        }
        do {
            let data = json.data(using: .utf8) ?? Data()
            let snapshot = try JSONDecoder().decode(AnnounceSnapshot.self, from: data)
            announces = snapshot.announces
            lastAnnouncesError = snapshot.error
        } catch {
            appendLog("failed to parse announces: \(error)")
            announces = []
            lastAnnouncesError = String(describing: error)
        }
    }

    func setInterfaceEnabled(name: String, enabled: Bool) {
        let rc = engine.setInterfaceEnabled(name: name, enabled: enabled)
        if rc != 0 {
            appendLog("set interface enabled failed rc=\(rc) name=\(name)")
        }
        refreshInterfaceStats()
        refreshConfiguredInterfaces()
    }

    var selectedContact: Contact? {
        guard let id = selectedContactID else { return nil }
        return contacts.first(where: { $0.id == id })
    }

    func addContact(displayName: String, destinationHashHex: String) {
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let dest = destinationHashHex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let initialName = trimmedName.isEmpty ? dest : trimmedName

        let contact = Contact(displayName: initialName, destinationHashHex: dest)
        let contactID = contact.id
        let shouldResolveName = trimmedName.isEmpty
        contacts.append(contact)
        if selectedContactID == nil { selectedContactID = contact.id }
        save()

        Task.detached { [weak self] in
            guard let self else { return }
            let info = self.engine.contactInfo(destHashHex: dest, timeoutMs: 2500)

            if shouldResolveName,
               let resolved = info?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
               !resolved.isEmpty {
                await MainActor.run {
                    guard let idx = self.contacts.firstIndex(where: { $0.id == contactID }) else { return }
                    self.contacts[idx].displayName = resolved
                    self.save()
                    self.appendLog("resolved contact name for \(dest): \(resolved)")
                }
            }

            let announcedAvatarHash = info?.avatar?.hashHex?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let knownHash: String? = await MainActor.run {
                self.contacts.first(where: { $0.id == contactID })?.avatarHashHex?.lowercased()
            }
            let alreadyHaveAvatar: Bool = await MainActor.run {
                self.contacts.first(where: { $0.id == contactID })?.avatarPNGData != nil
            }

            let shouldFetchAvatar: Bool = {
                if let announcedAvatarHash, !announcedAvatarHash.isEmpty {
                    return !(knownHash == announcedAvatarHash && alreadyHaveAvatar)
                }
                return !alreadyHaveAvatar
            }()
            if !shouldFetchAvatar {
                return
            }

            let resp = self.engine.contactAvatar(destHashHex: dest, knownHashHex: knownHash, timeoutMs: 20000)
            if let err = resp?.error, !err.isEmpty {
                await MainActor.run { self.appendLog("avatar fetch failed for \(dest): \(err)") }
                return
            }
            if resp?.notPresent == true {
                return
            }
            if resp?.unchanged == true {
                await MainActor.run {
                    guard let idx = self.contacts.firstIndex(where: { $0.id == contactID }) else { return }
                    self.contacts[idx].avatarHashHex = resp?.hashHex ?? announcedAvatarHash
                    self.save()
                }
                return
            }
            if let b64 = resp?.pngBase64,
               let data = Data(base64Encoded: b64), !data.isEmpty {
                await MainActor.run {
                    guard let idx = self.contacts.firstIndex(where: { $0.id == contactID }) else { return }
                    self.contacts[idx].avatarPNGData = data
                    self.contacts[idx].avatarHashHex = resp?.hashHex ?? announcedAvatarHash
                    self.save()
                    self.appendLog("fetched avatar for \(dest)")
                }
            }
        }
    }

    func resolveContactDisplayName(destHashHex: String, timeoutMs: Int32 = 2500) async -> String? {
        let dest = destHashHex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !dest.isEmpty else { return nil }
        return await Task.detached { [engine] in
            guard let info = engine.contactInfo(destHashHex: dest, timeoutMs: timeoutMs) else { return nil }
            let resolved = info.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let resolved, !resolved.isEmpty {
                return resolved
            }
            return nil
        }.value
    }

    func resolveContactPreview(destHashHex: String, timeoutMs: Int32 = 2500) async -> ContactPreview? {
        let dest = destHashHex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !dest.isEmpty else { return nil }
        return await Task.detached { [engine] in
            var preview = ContactPreview()
            let info = engine.contactInfo(destHashHex: dest, timeoutMs: timeoutMs)
            if let name = info?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                preview.displayName = name
            }
            let announcedHash = info?.avatar?.hashHex?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let announcedHash, !announcedHash.isEmpty {
                preview.avatarHashHex = announcedHash
            }
            let resp = engine.contactAvatar(destHashHex: dest, knownHashHex: nil, timeoutMs: 15000)
            if let err = resp?.error, !err.isEmpty {
                await MainActor.run {
                    self.appendLog("avatar preview failed for \(dest): \(err)")
                }
            }
            if resp == nil {
                await MainActor.run {
                    self.appendLog("avatar preview returned no response for \(dest)")
                }
            }
            if let b64 = resp?.pngBase64,
               let data = Data(base64Encoded: b64), !data.isEmpty {
                preview.avatarData = data
                if preview.avatarHashHex == nil {
                    preview.avatarHashHex = resp?.hashHex?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                }
            }
            return preview
        }.value
    }

    func removeContact(id: UUID) {
        guard let idx = contacts.firstIndex(where: { $0.id == id }) else { return }
        contacts.remove(at: idx)
        messagesByContactID[id] = nil
        if selectedContactID == id { selectedContactID = contacts.first?.id }
        save()
    }

    func setContactLocalName(id: UUID, name: String?) {
        guard let idx = contacts.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        contacts[idx].localDisplayName = trimmed.isEmpty ? nil : trimmed
        save()
    }

    func setContactLocalAvatar(id: UUID, data: Data?) {
        guard let idx = contacts.firstIndex(where: { $0.id == id }) else { return }
        contacts[idx].localAvatarData = normalizeAvatarData(data)
        save()
    }

    func messages(for contactID: UUID) -> [ChatMessage] {
        messagesByContactID[contactID] ?? []
    }

    func lastMessageID(for contactID: UUID) -> UUID? {
        messages(for: contactID).last?.id
    }

    func sendMessage(to contactID: UUID, text: String) {
        let msg = ChatMessage(direction: .outbound, text: text, title: "")
        messagesByContactID[contactID, default: []].append(msg)
        save()
        guard let contact = contacts.first(where: { $0.id == contactID }) else { return }
        let dest = contact.destinationHashHex
        Task.detached { [weak self] in
            guard let self else { return }
            let rc = self.engine.send(destHashHex: dest, title: "msg", content: text)
            await MainActor.run {
                if rc == 0 {
                    self.appendLog("send to=\(dest)")
                } else {
                    self.appendLog("send failed rc=\(rc) to=\(dest)")
                }
            }
        }
    }

    func persist() {
        save()
    }

    func restartEngineSilently() {
        let name = nameForAnnounce()
        engine.setDisplayName(name)
        engine.restart()
        appendLog("engine restarted")
        refreshInterfaceStats()
    }

    private func nameForAnnounce() -> String {
        let trimmed = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Me" : trimmed
    }

    private func load() {
        do {
            let snapshot = try persistence.load()
            contacts = snapshot.contacts
            messagesByContactID = snapshot.messagesByContactID
            logs = snapshot.logs ?? []
            profileName = snapshot.profileName ?? "Me"
            profileAvatarData = snapshot.profileAvatarData
            debugLoggingEnabled = snapshot.debugLoggingEnabled ?? false
            selectedContactID = contacts.first?.id
        } catch {
            contacts = []
            messagesByContactID = [:]
            logs = []
            profileName = "Me"
            profileAvatarData = nil
            debugLoggingEnabled = false
        }
    }

    private func save() {
        let snapshot = Snapshot(
            contacts: contacts,
            messagesByContactID: messagesByContactID,
            logs: logs,
            profileName: profileName,
            profileAvatarData: profileAvatarData,
            debugLoggingEnabled: debugLoggingEnabled
        )
        try? persistence.save(snapshot)
    }

    private func configPath() -> URL {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Runcore", isDirectory: true)
        return dir.appendingPathComponent("config")
    }

    private func rnsConfigPath() -> URL {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Runcore", isDirectory: true)
        return dir.appendingPathComponent("rns", isDirectory: true).appendingPathComponent("config")
    }

    private func loadTextFile(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

struct InterfaceStatsSnapshot: Decodable, Equatable {
    struct InterfaceEntry: Decodable, Identifiable, Equatable {
        var id: String { name }
        let name: String
        let short_name: String?
        let type: String?
        let status: Bool?
        let rxb: UInt64?
        let txb: UInt64?
        let bitrate: Int?
        let clients: Int?
        let peers: Int?
        let mode: Int?
    }

    let interfaces: [InterfaceEntry]
    let error: String?

    static let empty = InterfaceStatsSnapshot(interfaces: [], error: nil)
}

struct ConfiguredInterfacesSnapshot: Decodable, Equatable {
    let interfaces: [ConfiguredInterface]
    let error: String?

    static let empty = ConfiguredInterfacesSnapshot(interfaces: [], error: nil)
}

struct ConfiguredInterface: Decodable, Identifiable, Equatable {
    var id: String { name }
    let name: String
    let type: String?
    let enabled: Bool
}

struct AnnounceSnapshot: Decodable, Equatable {
    let announces: [AnnounceEntry]
    let error: String?

    static let empty = AnnounceSnapshot(announces: [], error: nil)
}

struct AnnounceEntry: Decodable, Identifiable, Equatable {
    var id: String { destinationHashHex }
    let destinationHashHex: String
    let displayName: String?
    let lastSeen: Int64
    let appDataLen: Int?

    private enum CodingKeys: String, CodingKey {
        case destinationHashHex = "destination_hash_hex"
        case displayName = "display_name"
        case lastSeen = "last_seen"
        case appDataLen = "app_data_len"
    }
}

struct ContactPreview: Equatable {
    var displayName: String?
    var avatarData: Data?
    var avatarHashHex: String?
}

extension InterfaceStatsSnapshot {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        interfaces = (try? container.decode([InterfaceEntry].self, forKey: .interfaces)) ?? []
        error = try? container.decode(String.self, forKey: .error)
    }

    private enum CodingKeys: String, CodingKey {
        case interfaces
        case error
    }
}

struct Snapshot: Codable {
    var contacts: [Contact]
    var messagesByContactID: [UUID: [ChatMessage]]
    var logs: [String]?
    var profileName: String?
    var profileAvatarData: Data?
    var debugLoggingEnabled: Bool?
}

private struct Persistence {
    private let fileURL: URL = {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("Runcore", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("state.json")
    }()

    func load() throws -> Snapshot {
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(Snapshot.self, from: data)
    }

    func save(_ snapshot: Snapshot) throws {
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: fileURL, options: [.atomic])
    }
}
