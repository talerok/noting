import Foundation
import SwiftData

@Model
final class Note {
    @Attribute(.unique) var id: UUID
    var title: String
    var content: String
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?
    var version: Int
    var isEncrypted: Bool
    var encryptedContent: String?
    var salt: String?
    var iv: String?
    var isPinned: Bool

    init(
        id: UUID = UUID(),
        title: String = "",
        content: String = "",
        createdAt: Date = .now,
        updatedAt: Date = .now,
        deletedAt: Date? = nil,
        version: Int = 1,
        isEncrypted: Bool = false,
        encryptedContent: String? = nil,
        salt: String? = nil,
        iv: String? = nil,
        isPinned: Bool = false
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.version = version
        self.isEncrypted = isEncrypted
        self.encryptedContent = encryptedContent
        self.salt = salt
        self.iv = iv
        self.isPinned = isPinned
    }

    var isDeleted: Bool { deletedAt != nil }

    func softDelete() {
        deletedAt = .now
        updatedAt = .now
        version += 1
    }
}
