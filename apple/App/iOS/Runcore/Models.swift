import Foundation

struct Contact: Identifiable, Codable, Hashable {
    let id: UUID
    var displayName: String
    var localDisplayName: String?
    var destinationHashHex: String
    var avatarHashHex: String?
    var avatarData: Data?
    var localAvatarData: Data?

    init(id: UUID = UUID(), displayName: String, destinationHashHex: String, avatarHashHex: String? = nil, avatarData: Data? = nil, localDisplayName: String? = nil, localAvatarData: Data? = nil) {
        self.id = id
        self.displayName = displayName
        self.localDisplayName = localDisplayName
        self.destinationHashHex = destinationHashHex
        self.avatarHashHex = avatarHashHex
        self.avatarData = avatarData
        self.localAvatarData = localAvatarData
    }
}

extension Contact {
    var resolvedDisplayName: String {
        let trimmed = localDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty { return trimmed }
        return displayName
    }

    var resolvedAvatarData: Data? {
        localAvatarData ?? avatarData
    }
}

enum MessageDirection: String, Codable {
    case inbound
    case outbound
}

enum OutboundStatus: String, Codable {
    case pending
    case delivered
    case read
    case failed
}

struct MessageAttachment: Codable, Hashable {
    let hashHex: String
    var mime: String?
    var name: String?
    var size: Int?
    var localPath: String?
}

struct ChatMessage: Identifiable, Codable, Hashable {
    let id: UUID
    let timestamp: Date
    let direction: MessageDirection
    let title: String
    let text: String
    var attachment: MessageAttachment?
    var lxmfMessageIDHex: String?
    var outboundStatus: OutboundStatus?
    var didSendReadReceipt: Bool
    var outboundAttemptCount: Int
    var outboundFailureCount: Int
    var lastOutboundAttemptAt: Date?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        direction: MessageDirection,
        text: String,
        attachment: MessageAttachment? = nil,
        title: String = "",
        lxmfMessageIDHex: String? = nil,
        outboundStatus: OutboundStatus? = nil,
        didSendReadReceipt: Bool = false,
        outboundAttemptCount: Int = 0,
        outboundFailureCount: Int = 0,
        lastOutboundAttemptAt: Date? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.direction = direction
        self.title = title
        self.text = text
        self.attachment = attachment
        self.lxmfMessageIDHex = lxmfMessageIDHex
        self.outboundStatus = outboundStatus
        self.didSendReadReceipt = didSendReadReceipt
        self.outboundAttemptCount = outboundAttemptCount
        self.outboundFailureCount = outboundFailureCount
        self.lastOutboundAttemptAt = lastOutboundAttemptAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case timestamp
        case direction
        case title
        case text
        case attachment
        case lxmfMessageIDHex
        case outboundStatus
        case didSendReadReceipt
        case outboundAttemptCount
        case outboundFailureCount
        case lastOutboundAttemptAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        direction = try container.decode(MessageDirection.self, forKey: .direction)
        title = try container.decode(String.self, forKey: .title)
        text = try container.decode(String.self, forKey: .text)
        attachment = try container.decodeIfPresent(MessageAttachment.self, forKey: .attachment)
        lxmfMessageIDHex = try container.decodeIfPresent(String.self, forKey: .lxmfMessageIDHex)
        outboundStatus = try container.decodeIfPresent(OutboundStatus.self, forKey: .outboundStatus)
        didSendReadReceipt = try container.decodeIfPresent(Bool.self, forKey: .didSendReadReceipt) ?? false
        outboundAttemptCount = try container.decodeIfPresent(Int.self, forKey: .outboundAttemptCount) ?? 0
        outboundFailureCount = try container.decodeIfPresent(Int.self, forKey: .outboundFailureCount) ?? 0
        lastOutboundAttemptAt = try container.decodeIfPresent(Date.self, forKey: .lastOutboundAttemptAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(direction, forKey: .direction)
        try container.encode(title, forKey: .title)
        try container.encode(text, forKey: .text)
        try container.encodeIfPresent(attachment, forKey: .attachment)
        try container.encodeIfPresent(lxmfMessageIDHex, forKey: .lxmfMessageIDHex)
        try container.encodeIfPresent(outboundStatus, forKey: .outboundStatus)
        try container.encode(didSendReadReceipt, forKey: .didSendReadReceipt)
        try container.encode(outboundAttemptCount, forKey: .outboundAttemptCount)
        try container.encode(outboundFailureCount, forKey: .outboundFailureCount)
        try container.encodeIfPresent(lastOutboundAttemptAt, forKey: .lastOutboundAttemptAt)
    }
}
