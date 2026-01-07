import Foundation
import CryptoKit
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
    @Published var blockedDestinations: [String] = []
    @Published var inboundPrompt: InboundPrompt?
    @Published var inboundPromptAvatarData: Data?
    @Published var inboundPromptAvatarHashHex: String?
    @Published var inboundPromptIsLoadingAvatar: Bool = false

    private let persistence = Persistence()
    private let engine = RuncoreEngine()
    private var pendingAnnounceTask: Task<Void, Never>?
    private var statsPollTask: Task<Void, Never>?
    private var pendingRawLogLines: [String] = []
    private var rawLogFlushTask: Task<Void, Never>?
    private var inboundPromptQueue: [InboundPrompt] = []
    private var inboundAvatarTask: Task<Void, Never>?
    private var lastAnnounceRequestAt: Date?

    private let readReceiptTitle = "_read"
    private var outboundRetryTask: Task<Void, Never>?
    private var outboundRetryInFlight: Set<UUID> = []

    struct InboundPrompt: Identifiable, Equatable {
        let id: UUID
        let destHashHex: String
        let messageIDHex: String
        let title: String
        let content: String
        let receivedAt: Date

        init(destHashHex: String, messageIDHex: String, title: String, content: String, receivedAt: Date = Date()) {
            self.id = UUID()
            self.destHashHex = destHashHex
            self.messageIDHex = messageIDHex
            self.title = title
            self.content = content
            self.receivedAt = receivedAt
        }
    }

    init() {
        load()
        engine.displayName = profileName
        engine.setLogLevel(debugLoggingEnabled ? 6 : 3)
        engine.onLogLine = { [weak self] _, line in
            guard let self else { return }
            self.appendRawLog(line)
        }
        engine.onInbound = { [weak self] srcHex, messageIDHex, title, content in
            guard let self else { return }
            let src = self.normalizeDestinationHashHex(srcHex)
            let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            self.appendLog("inbound src=\(src) title=\(trimmedTitle)")

            if self.isBlockedDestination(src) {
                self.appendLog("inbound dropped (blocked) src=\(src)")
                return
            }

            if trimmedTitle == self.readReceiptTitle {
                self.applyReadReceipt(from: src, content: content)
                return
            }

            if let contact = self.contacts.first(where: { $0.destinationHashHex == src }) {
                if let parsed = self.parseAttachmentMessage(title: trimmedTitle, content: content) {
                    let localID = UUID()
                    self.messagesByContactID[contact.id, default: []].append(
                        ChatMessage(
                            id: localID,
                            direction: .inbound,
                            text: parsed.caption,
                            attachment: MessageAttachment(
                                hashHex: parsed.hashHex,
                                mime: parsed.mime,
                                name: parsed.name,
                                size: parsed.size,
                                localPath: nil
                            ),
                            title: "img",
                            lxmfMessageIDHex: messageIDHex
                        )
                    )
                    self.save()
                    self.fetchAttachment(remoteHashHex: src, contactID: contact.id, localMessageID: localID, attachmentHashHex: parsed.hashHex)
                    return
                }
                self.messagesByContactID[contact.id, default: []].append(
                    ChatMessage(direction: .inbound, text: content, title: trimmedTitle, lxmfMessageIDHex: messageIDHex)
                )
                self.save()
                return
            }

            self.enqueueInboundPrompt(InboundPrompt(destHashHex: src, messageIDHex: messageIDHex, title: trimmedTitle, content: content))
        }
        engine.onMessageStatus = { [weak self] destHex, messageIDHex, state in
            guard let self else { return }
            self.applyOutboundStatus(destHashHex: destHex, messageIDHex: messageIDHex, state: state)
        }
        engine.start()
        appendLog("engine started (iOS stub)")
        if let avatar = profileAvatarData, !avatar.isEmpty {
            let normalized = normalizeAvatarData(avatar) ?? avatar
            let rc = engine.setAvatarImage(mime: "image/heic", data: normalized)
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

        outboundRetryTask?.cancel()
        outboundRetryTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if Task.isCancelled { return }
                self.retryPendingOutboundIfNeeded()
            }
        }
    }

    func requestAnnounce(reason: String) {
        let now = Date()
        if let last = lastAnnounceRequestAt, now.timeIntervalSince(last) < 3 {
            return
        }
        lastAnnounceRequestAt = now
        let rc = engine.announce(reason: reason)
        if rc == 0 {
            appendLog("announce requested (\(reason))")
        } else {
            appendLog("announce requested (\(reason)) failed rc=\(rc)")
        }
    }

    func sendImageAttachment(to contactID: UUID, data: Data, suggestedName: String?, caption: String) {
        guard !data.isEmpty else { return }
        guard let contact = contacts.first(where: { $0.id == contactID }) else { return }

        let stored = engine.storeAttachment(mime: nil, name: suggestedName, data: data)
        guard let stored else {
            appendLog("store attachment failed: no response")
            return
        }
        if let err = stored.error, !err.isEmpty {
            appendLog("store attachment failed: \(err)")
            return
        }
        guard stored.rc == 0, let hash = stored.hashHex, !hash.isEmpty else {
            appendLog("store attachment failed rc=\(stored.rc)")
            return
        }

        let outPath = self.outboundAttachmentPath(hashHex: hash)
        do {
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: outPath).deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: outPath), options: [.atomic])
        } catch {
            appendLog("attachment save failed: \(error)")
        }

        let messageText = caption
        var msg = ChatMessage(
            direction: .outbound,
            text: messageText,
            attachment: MessageAttachment(
                hashHex: hash,
                mime: stored.mime,
                name: stored.name ?? suggestedName,
                size: stored.size,
                localPath: outPath
            ),
            title: "img",
            outboundStatus: .pending
        )
        messagesByContactID[contactID, default: []].append(msg)
        save()

        let payload = formatAttachmentMessage(hashHex: hash, mime: stored.mime, name: stored.name ?? suggestedName, size: stored.size, caption: caption)
        let localMsgID = msg.id
        Task.detached { [weak self] in
            guard let self else { return }
            let result = self.engine.sendResult(destHashHex: contact.destinationHashHex, title: "img", content: payload)
            await MainActor.run {
                self.updateOutboundMessage(contactID: contactID, localID: localMsgID, sendResult: result)
            }
        }
    }

    private func formatAttachmentMessage(hashHex: String, mime: String?, name: String?, size: Int?, caption: String) -> String {
        var lines: [String] = []
        lines.append("hash=\(hashHex)")
        if let mime, !mime.isEmpty { lines.append("mime=\(mime)") }
        if let name, !name.isEmpty { lines.append("name=\(name)") }
        if let size { lines.append("size=\(size)") }
        lines.append("caption=\(caption)")
        return lines.joined(separator: "\n")
    }

    private struct AttachmentParsed {
        let hashHex: String
        let mime: String?
        let name: String?
        let size: Int?
        let caption: String
    }

    private func parseAttachmentMessage(title: String, content: String) -> AttachmentParsed? {
        guard title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "img" else { return nil }
        var hash: String?
        var mime: String?
        var name: String?
        var size: Int?
        var caption = ""
        for line in content.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = String(parts[1])
            switch key {
            case "hash":
                hash = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            case "mime":
                mime = value.trimmingCharacters(in: .whitespacesAndNewlines)
            case "name":
                name = value.trimmingCharacters(in: .whitespacesAndNewlines)
            case "size":
                size = Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
            case "caption":
                caption = value
            default:
                continue
            }
        }
        guard let hash, !hash.isEmpty else { return nil }
        return AttachmentParsed(hashHex: hash, mime: mime, name: name, size: size, caption: caption)
    }

    private func outboundAttachmentPath(hashHex: String) -> String {
        let hash = hashHex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let base = appSupport.appendingPathComponent("Runcore", isDirectory: true)
        return base.appendingPathComponent("attachments", isDirectory: true)
            .appendingPathComponent("out", isDirectory: true)
            .appendingPathComponent("\(hash).bin")
            .path
    }

    private func fetchAttachment(remoteHashHex: String, contactID: UUID, localMessageID: UUID, attachmentHashHex: String) {
        let remote = normalizeDestinationHashHex(remoteHashHex)
        let hash = attachmentHashHex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !remote.isEmpty, !hash.isEmpty else { return }
        Task.detached { [weak self] in
            guard let self else { return }
            let resp = self.engine.contactAttachment(destHashHex: remote, attachmentHashHex: hash, timeoutMs: 20000)
            await MainActor.run {
                guard let resp else { return }
                if let err = resp.error, !err.isEmpty {
                    self.appendLog("attachment fetch failed for \(remote): \(err)")
                    return
                }
                guard let path = resp.path, !path.isEmpty else { return }
                self.setAttachmentPath(contactID: contactID, localMessageID: localMessageID, path: path)
            }
        }
    }

    private func setAttachmentPath(contactID: UUID, localMessageID: UUID, path: String) {
        guard var list = messagesByContactID[contactID] else { return }
        guard let idx = list.firstIndex(where: { $0.id == localMessageID }) else { return }
        guard var att = list[idx].attachment else { return }
        att.localPath = path
        list[idx].attachment = att
        messagesByContactID[contactID] = list
        save()
    }

    deinit {
        statsPollTask?.cancel()
        outboundRetryTask?.cancel()
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

    func clearLogs() {
        rawLogFlushTask?.cancel()
        rawLogFlushTask = nil
        pendingRawLogLines.removeAll(keepingCapacity: true)
        logs.removeAll(keepingCapacity: true)
        save()
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
            let rc = engine.setAvatarImage(mime: "image/heic", data: normalized)
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
        if let heic = encodeHEIC(output, quality: 0.05) {
            return heic
        }
        return output.jpegData(compressionQuality: 0.05) ?? output.pngData() ?? data
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
        let previous = announces
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

            let prevByDest: [String: Int64] = Dictionary(
                uniqueKeysWithValues: previous.map { (normalizeDestinationHashHex($0.destinationHashHex), $0.lastSeen) }
            )
            for entry in snapshot.announces {
                let dest = normalizeDestinationHashHex(entry.destinationHashHex)
                guard !dest.isEmpty else { continue }
                let prevSeen = prevByDest[dest]
                if prevSeen == nil || (prevSeen ?? 0) < entry.lastSeen {
                    retryPendingOutboundNow(destHashHex: dest)
                }
            }
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
                self.contacts.first(where: { $0.id == contactID })?.avatarData != nil
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
            if let b64 = (resp?.dataBase64 ?? resp?.pngBase64),
               let data = Data(base64Encoded: b64), !data.isEmpty {
                await MainActor.run {
                    guard let idx = self.contacts.firstIndex(where: { $0.id == contactID }) else { return }
                    self.contacts[idx].avatarData = data
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
            if let b64 = (resp?.dataBase64 ?? resp?.pngBase64),
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
        var msg = ChatMessage(direction: .outbound, text: text, title: "msg", outboundStatus: .pending)
        messagesByContactID[contactID, default: []].append(msg)
        save()
        guard let contact = contacts.first(where: { $0.id == contactID }) else { return }
        let dest = contact.destinationHashHex
        let localMsgID = msg.id
        Task.detached { [weak self] in
            guard let self else { return }
            let result = self.engine.sendResult(destHashHex: dest, title: "msg", content: text)
            await MainActor.run {
                self.updateOutboundMessage(contactID: contactID, localID: localMsgID, sendResult: result)
            }
        }
    }

    func markChatRead(contactID: UUID) {
        guard let contact = contacts.first(where: { $0.id == contactID }) else { return }
        let dest = contact.destinationHashHex
        let ids: [String] = (messagesByContactID[contactID] ?? []).compactMap { m in
            guard m.direction == .inbound else { return nil }
            guard m.didSendReadReceipt == false else { return nil }
            let mid = (m.lxmfMessageIDHex ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !mid.isEmpty else { return nil }
            return mid
        }
        guard !ids.isEmpty else { return }

        Task.detached { [weak self] in
            guard let self else { return }
            let result = self.engine.sendResult(destHashHex: dest, title: self.readReceiptTitle, content: ids.joined(separator: "\n"))
            await MainActor.run {
                if result.rc == 0 {
                    self.markInboundReadReceiptsSent(contactID: contactID, messageIDs: ids)
                    self.appendLog("read receipts sent to=\(dest) n=\(ids.count)")
                } else {
                    self.appendLog("read receipts send failed rc=\(result.rc) to=\(dest)")
                }
            }
        }
    }

    private func updateOutboundMessage(contactID: UUID, localID: UUID, sendResult: RuncoreEngine.SendResult) {
        guard var list = messagesByContactID[contactID] else { return }
        guard let idx = list.firstIndex(where: { $0.id == localID }) else { return }

        let dest = contacts.first(where: { $0.id == contactID })?.destinationHashHex ?? ""
        list[idx].outboundAttemptCount += 1
        list[idx].lastOutboundAttemptAt = Date()
        if sendResult.rc == 0 {
            let mid = (sendResult.messageIDHex ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            list[idx].lxmfMessageIDHex = mid.isEmpty ? nil : mid
            list[idx].outboundStatus = .pending
            messagesByContactID[contactID] = list
            save()
            appendLog("send queued to=\(dest)")
        } else {
            // Retry later; only count hard failures (not "no path"/"no identity").
            if sendResult.rc != 3 && sendResult.rc != 4 {
                list[idx].outboundFailureCount += 1
            }
            if list[idx].outboundFailureCount >= 6 {
                list[idx].outboundStatus = .failed
            } else {
                list[idx].outboundStatus = .pending
            }
            messagesByContactID[contactID] = list
            save()
            let suffix = (sendResult.error?.isEmpty == false) ? " err=\(sendResult.error!)" : ""
            appendLog("send pending rc=\(sendResult.rc) to=\(dest)\(suffix)")
        }
    }

    private func retryPendingOutboundIfNeeded() {
        for contact in contacts {
            guard var list = messagesByContactID[contact.id] else { continue }
            guard let idx = list.firstIndex(where: { msg in
                msg.direction == .outbound &&
                    msg.outboundStatus == .pending &&
                    normalizeDestinationHashHex(msg.lxmfMessageIDHex ?? "").isEmpty &&
                    msg.outboundFailureCount < 6 &&
                    !outboundRetryInFlight.contains(msg.id)
            }) else { continue }

            let msgID = list[idx].id
            let now = Date()
            let backoff = min(pow(2.0, Double(max(0, list[idx].outboundAttemptCount))) * 1.5, 30.0)
            if let last = list[idx].lastOutboundAttemptAt, now.timeIntervalSince(last) < backoff {
                continue
            }

            outboundRetryInFlight.insert(msgID)
            let text = list[idx].text
            let title = list[idx].title
            messagesByContactID[contact.id] = list

            Task.detached { [weak self] in
                guard let self else { return }
                let result = self.engine.sendResult(destHashHex: contact.destinationHashHex, title: title, content: text)
                await MainActor.run {
                    self.updateOutboundMessage(contactID: contact.id, localID: msgID, sendResult: result)
                    self.outboundRetryInFlight.remove(msgID)
                }
            }

            // Do one retry per tick to avoid spamming.
            return
        }
    }

    private func retryPendingOutboundNow(destHashHex: String) {
        let dest = normalizeDestinationHashHex(destHashHex)
        guard let contact = contacts.first(where: { $0.destinationHashHex == dest }) else { return }
        guard var list = messagesByContactID[contact.id] else { return }
        guard let idx = list.firstIndex(where: { msg in
            msg.direction == .outbound &&
                msg.outboundStatus == .pending &&
                normalizeDestinationHashHex(msg.lxmfMessageIDHex ?? "").isEmpty &&
                msg.outboundFailureCount < 6 &&
                !outboundRetryInFlight.contains(msg.id)
        }) else { return }

        let msgID = list[idx].id
        outboundRetryInFlight.insert(msgID)
        let text = list[idx].text
        let title = list[idx].title
        messagesByContactID[contact.id] = list

        Task.detached { [weak self] in
            guard let self else { return }
            let result = self.engine.sendResult(destHashHex: dest, title: title, content: text)
            await MainActor.run {
                self.updateOutboundMessage(contactID: contact.id, localID: msgID, sendResult: result)
                self.outboundRetryInFlight.remove(msgID)
            }
        }
    }

    private func applyOutboundStatus(destHashHex: String, messageIDHex: String, state: Int32) {
        let dest = normalizeDestinationHashHex(destHashHex)
        let mid = normalizeDestinationHashHex(messageIDHex)
        guard !dest.isEmpty, !mid.isEmpty else { return }
        guard let contact = contacts.first(where: { $0.destinationHashHex == dest }) else { return }
        guard var list = messagesByContactID[contact.id] else { return }
        guard let idx = list.firstIndex(where: { $0.direction == .outbound && normalizeDestinationHashHex($0.lxmfMessageIDHex ?? "") == mid }) else {
            return
        }

        switch state {
        case 0x08: // delivered
            if list[idx].outboundStatus != .read {
                list[idx].outboundStatus = .delivered
            }
        case 0xFD, 0xFE, 0xFF: // rejected/cancelled/failed
            list[idx].outboundStatus = .failed
        default:
            break
        }
        messagesByContactID[contact.id] = list
        save()
    }

    private func applyReadReceipt(from srcHashHex: String, content: String) {
        let src = normalizeDestinationHashHex(srcHashHex)
        guard let contact = contacts.first(where: { $0.destinationHashHex == src }) else { return }

        let ids = content
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == " " || $0 == "\t" || $0 == "," || $0 == ";" })
            .map { normalizeDestinationHashHex(String($0)) }
            .filter { !$0.isEmpty }
        guard !ids.isEmpty else { return }

        guard var list = messagesByContactID[contact.id] else { return }
        var changed = false
        for i in list.indices {
            guard list[i].direction == .outbound else { continue }
            let mid = normalizeDestinationHashHex(list[i].lxmfMessageIDHex ?? "")
            if ids.contains(mid) {
                list[i].outboundStatus = .read
                changed = true
            }
        }
        if changed {
            messagesByContactID[contact.id] = list
            save()
        }
    }

    private func markInboundReadReceiptsSent(contactID: UUID, messageIDs: [String]) {
        guard var list = messagesByContactID[contactID] else { return }
        let set = Set(messageIDs.map { normalizeDestinationHashHex($0) })
        var changed = false
        for i in list.indices {
            guard list[i].direction == .inbound else { continue }
            let mid = normalizeDestinationHashHex(list[i].lxmfMessageIDHex ?? "")
            if set.contains(mid) {
                if list[i].didSendReadReceipt == false {
                    list[i].didSendReadReceipt = true
                    changed = true
                }
            }
        }
        if changed {
            messagesByContactID[contactID] = list
            save()
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
            blockedDestinations = snapshot.blockedDestinations ?? []
            selectedContactID = contacts.first?.id
        } catch {
            contacts = []
            messagesByContactID = [:]
            logs = []
            profileName = "Me"
            profileAvatarData = nil
            debugLoggingEnabled = false
            blockedDestinations = []
        }
    }

    private func save() {
        let snapshot = Snapshot(
            contacts: contacts,
            messagesByContactID: messagesByContactID,
            logs: logs,
            profileName: profileName,
            profileAvatarData: profileAvatarData,
            debugLoggingEnabled: debugLoggingEnabled,
            blockedDestinations: blockedDestinations
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

    private func normalizeDestinationHashHex(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func displayNameForDestinationHashHex(_ destHashHex: String) -> String {
        let dest = normalizeDestinationHashHex(destHashHex)
        if let contact = contacts.first(where: { $0.destinationHashHex == dest }) {
            return contact.resolvedDisplayName
        }
        if let entry = announces.first(where: { normalizeDestinationHashHex($0.destinationHashHex) == dest }) {
            let trimmed = entry.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        return "Unknown"
    }

    func isBlockedDestination(_ destHashHex: String) -> Bool {
        let dest = normalizeDestinationHashHex(destHashHex)
        return blockedDestinations.contains(dest)
    }

    func blockDestination(_ destHashHex: String) {
        let dest = normalizeDestinationHashHex(destHashHex)
        guard !dest.isEmpty else { return }
        guard !blockedDestinations.contains(dest) else { return }
        blockedDestinations.append(dest)
        save()
    }

    func unblockDestination(_ destHashHex: String) {
        let dest = normalizeDestinationHashHex(destHashHex)
        blockedDestinations.removeAll(where: { $0 == dest })
        save()
    }

    func acceptInboundPrompt(_ prompt: InboundPrompt) {
        let dest = normalizeDestinationHashHex(prompt.destHashHex)
        guard !dest.isEmpty else {
            finishInboundPrompt()
            return
        }
        if isBlockedDestination(dest) {
            finishInboundPrompt()
            return
        }
        let contactID: UUID
        if let existing = contacts.first(where: { $0.destinationHashHex == dest }) {
            contactID = existing.id
        } else {
            let initialName = displayNameForDestinationHashHex(dest)
            let contact = Contact(
                displayName: initialName == "Unknown" ? dest : initialName,
                destinationHashHex: dest,
                avatarHashHex: inboundPromptAvatarHashHex,
                avatarData: inboundPromptAvatarData
            )
            contacts.append(contact)
            contactID = contact.id
        }
            if let idx = contacts.firstIndex(where: { $0.id == contactID }) {
                if let inboundPromptAvatarData {
                contacts[idx].avatarData = inboundPromptAvatarData
                }
                if let inboundPromptAvatarHashHex {
                    contacts[idx].avatarHashHex = inboundPromptAvatarHashHex
                }
            }
        messagesByContactID[contactID, default: []].append(
            ChatMessage(direction: .inbound, text: prompt.content, title: prompt.title, lxmfMessageIDHex: prompt.messageIDHex)
        )
        selectedContactID = contactID
        save()
        finishInboundPrompt()
    }

    func declineInboundPrompt(_ prompt: InboundPrompt) {
        appendLog("inbound declined src=\(prompt.destHashHex)")
        finishInboundPrompt()
    }

    func blockInboundPrompt(_ prompt: InboundPrompt) {
        blockDestination(prompt.destHashHex)
        appendLog("inbound blocked src=\(prompt.destHashHex)")
        finishInboundPrompt()
    }

    private func enqueueInboundPrompt(_ prompt: InboundPrompt) {
        inboundPromptQueue.append(prompt)
        if inboundPrompt == nil {
            inboundPrompt = inboundPromptQueue.first
            prefetchInboundPromptAvatarIfNeeded()
        }
    }

    private func finishInboundPrompt() {
        if !inboundPromptQueue.isEmpty {
            inboundPromptQueue.removeFirst()
        }
        inboundPrompt = inboundPromptQueue.first
        prefetchInboundPromptAvatarIfNeeded()
    }

    private func prefetchInboundPromptAvatarIfNeeded() {
        inboundAvatarTask?.cancel()
        inboundPromptAvatarData = nil
        inboundPromptAvatarHashHex = nil
        inboundPromptIsLoadingAvatar = false

        guard let prompt = inboundPrompt else { return }
        let promptID = prompt.id
        let dest = normalizeDestinationHashHex(prompt.destHashHex)
        guard !dest.isEmpty else { return }

        inboundPromptIsLoadingAvatar = true
        inboundAvatarTask = Task { @MainActor in
            let preview = await resolveContactPreview(destHashHex: dest, timeoutMs: 20_000)
            guard inboundPrompt?.id == promptID else { return }

            if let avatar = preview?.avatarData, !avatar.isEmpty {
                inboundPromptAvatarData = avatar
            } else {
                appendLog("inbound avatar preview empty for \(dest)")
            }

            let hash = preview?.avatarHashHex?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            inboundPromptAvatarHashHex = (hash?.isEmpty == false) ? hash : nil
            inboundPromptIsLoadingAvatar = false
        }
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
    var blockedDestinations: [String]?
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
