import Foundation

struct Contact: Identifiable, Codable, Hashable {
    let id: UUID
    var displayName: String
    var localDisplayName: String?
    var destinationHashHex: String
    var avatarHashHex: String?
    var avatarPNGData: Data?
    var localAvatarData: Data?

    init(id: UUID = UUID(), displayName: String, destinationHashHex: String, avatarHashHex: String? = nil, avatarPNGData: Data? = nil, localDisplayName: String? = nil, localAvatarData: Data? = nil) {
        self.id = id
        self.displayName = displayName
        self.localDisplayName = localDisplayName
        self.destinationHashHex = destinationHashHex
        self.avatarHashHex = avatarHashHex
        self.avatarPNGData = avatarPNGData
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
        localAvatarData ?? avatarPNGData
    }
}

enum MessageDirection: String, Codable {
    case inbound
    case outbound
}

struct ChatMessage: Identifiable, Codable, Hashable {
    let id: UUID
    let timestamp: Date
    let direction: MessageDirection
    let title: String
    let text: String

    init(id: UUID = UUID(), timestamp: Date = Date(), direction: MessageDirection, text: String, title: String = "") {
        self.id = id
        self.timestamp = timestamp
        self.direction = direction
        self.title = title
        self.text = text
    }
}
