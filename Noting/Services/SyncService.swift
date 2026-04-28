import CryptoKit
import Foundation
import OSLog
import SwiftData

private let logger = Logger(subsystem: "com.artem.noting", category: "Sync")

/// Manifest-based sync service.
/// Compares SHA-256 hashes of local note JSON against a remote manifest
/// to determine what needs uploading/downloading.
final class SyncService {
    private let provider: DropboxSync

    init(provider: DropboxSync) {
        self.provider = provider
    }

    @MainActor
    func sync(modelContext: ModelContext, activeNoteId: UUID? = nil) async throws {

        // 1. Download remote manifest
        let (manifestJson, rev) = try await provider.downloadManifest()
        let remoteManifest = try manifestJson.map { try SyncManifest.fromJsonString($0) } ?? .empty()
        var currentRev = rev

        // 2. Build local hashes
        let descriptor = FetchDescriptor<Note>()
        let localNotes = try modelContext.fetch(descriptor)
        let localMap = Dictionary(uniqueKeysWithValues: localNotes.map { ($0.id.uuidString, $0) })
        var localHashes: [String: String] = [:]
        for note in localNotes {
            let dto = NoteDTO(from: note)
            localHashes[note.id.uuidString] = hashContent(dto.toJsonString())
        }

        // 3. List remote files
        let remoteFiles = try await provider.listRemoteNotes()
        let remoteFileMap = Dictionary(uniqueKeysWithValues: remoteFiles.map { ($0.noteId, $0) })

        // 4. Determine changes
        let allNoteIds = Set(localHashes.keys).union(remoteManifest.noteHashes.keys)
        var toUpload: [String] = []
        var toDownload: [String] = []
        var toDeleteRemote: [String] = []
        var toDeleteLocal: [String] = []
        var updatedHashes = remoteManifest.noteHashes
        var deletedIds = Set(remoteManifest.deletedNoteIds)
        var failedCount = 0

        for noteId in allNoteIds {
            let localHash = localHashes[noteId]
            let remoteHash = remoteManifest.noteHashes[noteId]
            let localNote = localMap[noteId]

            if localHash != nil && remoteHash == nil {
                // Local only
                if deletedIds.contains(noteId) {
                    toDeleteLocal.append(noteId)
                    continue
                }
                if localNote?.isDeleted == true { continue }
                toUpload.append(noteId)
            } else if localHash == nil && remoteHash != nil {
                // Remote only
                if deletedIds.contains(noteId) { continue }
                if noteId == activeNoteId?.uuidString { continue }
                toDownload.append(noteId)
            } else if localHash != nil && remoteHash != nil && localHash != remoteHash {
                // Both exist, hashes differ — conflict
                if localNote?.isDeleted == true {
                    toDeleteRemote.append(noteId)
                    continue
                }

                guard let remoteFile = remoteFileMap[noteId] else {
                    toUpload.append(noteId)
                    continue
                }

                do {
                    let remoteDTO = try await provider.downloadNote(remoteFile.remoteId)
                    let remoteNote = try remoteDTO.toNote()

                    if let localNote, localWins(local: localNote, remote: remoteNote) {
                        toUpload.append(noteId)
                    } else {
                        // Remote wins — save locally
                        upsertNote(remoteNote, into: modelContext)
                        let savedJson = NoteDTO(from: remoteNote).toJsonString()
                        updatedHashes[noteId] = hashContent(savedJson)
                    }
                } catch {
                    // Don't blindly fall back to upload — that can clobber
                    // remote changes we just failed to fetch. Defer to next sync.
                    logger.error("Conflict download failed for note \(noteId, privacy: .public): \(error.localizedDescription, privacy: .private)")
                    failedCount += 1
                }
            }
        }

        // 5. Execute uploads
        for noteId in toUpload {
            guard let note = localMap[noteId] else { continue }
            do {
                let dto = NoteDTO(from: note)
                try await provider.uploadNote(dto)
                updatedHashes[noteId] = hashContent(dto.toJsonString())
            } catch {
                logger.error("Upload failed for note \(noteId, privacy: .public): \(error.localizedDescription, privacy: .private)")
                failedCount += 1
            }
        }

        // 6. Execute downloads
        for noteId in toDownload {
            guard let remoteFile = remoteFileMap[noteId] else { continue }
            do {
                let dto = try await provider.downloadNote(remoteFile.remoteId)
                let note = try dto.toNote()
                upsertNote(note, into: modelContext)
            } catch {
                logger.error("Download failed for note \(noteId, privacy: .public): \(error.localizedDescription, privacy: .private)")
                failedCount += 1
            }
        }

        // 7. Remote deletes
        for noteId in toDeleteRemote {
            do {
                if let remoteFile = remoteFileMap[noteId] {
                    try await provider.deleteRemoteNote(remoteFile.remoteId)
                }
                updatedHashes.removeValue(forKey: noteId)
                deletedIds.insert(noteId)
            } catch {
                logger.error("Remote delete failed for note \(noteId, privacy: .public): \(error.localizedDescription, privacy: .private)")
                failedCount += 1
            }
        }

        // 8. Local deletes
        for noteId in toDeleteLocal {
            if let note = localMap[noteId] {
                modelContext.delete(note)
            }
            updatedHashes.removeValue(forKey: noteId)
        }

        // 9. Purge notes soft-deleted >30 days ago
        let cutoff = Date.now.addingTimeInterval(-30 * 24 * 3600)
        for note in localNotes where note.isDeleted {
            guard let deletedAt = note.deletedAt, deletedAt < cutoff else { continue }
            let noteId = note.id.uuidString
            if let remoteFile = remoteFileMap[noteId] {
                do {
                    try await provider.deleteRemoteNote(remoteFile.remoteId)
                } catch {
                    logger.error("Purge of remote note \(noteId, privacy: .public) failed: \(error.localizedDescription, privacy: .private)")
                }
            }
            updatedHashes.removeValue(forKey: noteId)
            deletedIds.remove(noteId)
            modelContext.delete(note)
        }

        do {
            try modelContext.save()
        } catch {
            logger.error("modelContext.save() during sync failed: \(error.localizedDescription, privacy: .private)")
        }

        // 10. Upload manifest
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let finalManifest = SyncManifest(
            noteHashes: updatedHashes,
            deletedNoteIds: Array(deletedIds),
            updatedAt: formatter.string(from: .now)
        )
        do {
            currentRev = try await provider.uploadManifest(finalManifest.toJsonString(), rev: currentRev)
        } catch {
            // If we can't upload the manifest, the just-uploaded notes are
            // effectively orphaned until next sync — surface this as a failure
            // so the caller knows the sync wasn't fully successful.
            logger.error("Manifest upload failed: \(error.localizedDescription, privacy: .private)")
            failedCount += 1
        }

        logger.info("Sync done — uploaded: \(toUpload.count), downloaded: \(toDownload.count), remoteDeletes: \(toDeleteRemote.count), localDeletes: \(toDeleteLocal.count), failed: \(failedCount)")

        if failedCount > 0 {
            throw SyncError.partialFailure(failedCount)
        }
    }

    // MARK: - Helpers

    private func hashContent(_ content: String) -> String {
        let data = Data(content.utf8)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func localWins(local: Note, remote: Note) -> Bool {
        if local.version != remote.version {
            return local.version > remote.version
        }
        return local.updatedAt > remote.updatedAt
    }

    private func upsertNote(_ incoming: Note, into context: ModelContext) {
        let id = incoming.id
        let descriptor = FetchDescriptor<Note>(predicate: #Predicate { $0.id == id })
        if let existing = try? context.fetch(descriptor).first {
            existing.title = incoming.title
            existing.content = incoming.content
            existing.createdAt = incoming.createdAt
            existing.updatedAt = incoming.updatedAt
            existing.deletedAt = incoming.deletedAt
            existing.version = incoming.version
            existing.isEncrypted = incoming.isEncrypted
            existing.encryptedContent = incoming.encryptedContent
            existing.salt = incoming.salt
            existing.iv = incoming.iv
            existing.isPinned = incoming.isPinned
        } else {
            context.insert(incoming)
        }
    }
}

enum SyncError: LocalizedError {
    case partialFailure(Int)

    var errorDescription: String? {
        switch self {
        case .partialFailure(let count):
            "Sync completed with \(count) failed note(s)"
        }
    }
}
