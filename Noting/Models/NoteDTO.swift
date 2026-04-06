import Foundation

/// Data transfer object for syncing notes with Dropbox.
/// Matches the JSON format stored in /Noting/notes/{id}.json.
struct NoteDTO: Codable {
    let id: String
    let title: String
    let content: String
    let createdAt: String
    let updatedAt: String
    let deletedAt: String?
    let version: Int
    let isEncrypted: Bool?
    let encryptedContent: String?
    let salt: String?
    let iv: String?
    let isPinned: Bool?

    init(from note: Note) {
        self.id = note.id.uuidString
        self.title = note.title
        self.content = note.content
        self.createdAt = Self.formatter.string(from: note.createdAt)
        self.updatedAt = Self.formatter.string(from: note.updatedAt)
        self.deletedAt = note.deletedAt.map { Self.formatter.string(from: $0) }
        self.version = note.version
        self.isEncrypted = note.isEncrypted ? true : nil
        self.encryptedContent = note.encryptedContent
        self.salt = note.salt
        self.iv = note.iv
        self.isPinned = note.isPinned ? true : nil
    }

    func toNote() throws -> Note {
        guard let uuid = UUID(uuidString: id) else {
            throw NoteDTOError.invalidUUID(id)
        }
        guard let created = Self.formatter.date(from: createdAt),
              let updated = Self.formatter.date(from: updatedAt) else {
            throw NoteDTOError.invalidDate
        }
        return Note(
            id: uuid,
            title: title,
            content: content,
            createdAt: created,
            updatedAt: updated,
            deletedAt: deletedAt.flatMap { Self.formatter.date(from: $0) },
            version: version,
            isEncrypted: isEncrypted ?? false,
            encryptedContent: encryptedContent,
            salt: salt,
            iv: iv,
            isPinned: isPinned ?? false
        )
    }

    func toJsonString() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try! encoder.encode(self)
        return String(data: data, encoding: .utf8)!
    }

    static func fromJsonString(_ json: String) throws -> NoteDTO {
        guard let data = json.data(using: .utf8) else {
            throw NoteDTOError.invalidEncoding
        }
        return try JSONDecoder().decode(NoteDTO.self, from: data)
    }

    private nonisolated(unsafe) static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

enum NoteDTOError: LocalizedError {
    case invalidUUID(String)
    case invalidDate
    case invalidEncoding

    var errorDescription: String? {
        switch self {
        case .invalidUUID(let id): "Invalid note UUID: \(id)"
        case .invalidDate: "Invalid date format"
        case .invalidEncoding: "Invalid string encoding"
        }
    }
}

/// Manifest for Dropbox sync: tracks hashes and tombstones.
struct SyncManifest: Codable {
    var noteHashes: [String: String]
    var deletedNoteIds: [String]
    var updatedAt: String

    static func empty() -> SyncManifest {
        SyncManifest(
            noteHashes: [:],
            deletedNoteIds: [],
            updatedAt: ISO8601DateFormatter().string(from: .now)
        )
    }

    func toJsonString() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try! encoder.encode(self)
        return String(data: data, encoding: .utf8)!
    }

    static func fromJsonString(_ json: String) throws -> SyncManifest {
        guard let data = json.data(using: .utf8) else {
            throw NoteDTOError.invalidEncoding
        }
        return try JSONDecoder().decode(SyncManifest.self, from: data)
    }
}
