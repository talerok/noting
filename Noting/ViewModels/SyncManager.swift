import Foundation
import Observation
import SwiftData

enum SyncStatus: Equatable {
    case idle
    case syncing
    case synced
    case error(String)
}

@Observable
@MainActor
final class SyncManager {
    var status: SyncStatus = .idle
    var lastSyncTime: Date?

    private var syncTask: Task<Void, Never>?

    let dropboxAuth: DropboxAuth
    private let dropboxSync: DropboxSync
    private let syncService: SyncService

    init() {
        let auth = DropboxAuth()
        self.dropboxAuth = auth
        let sync = DropboxSync(auth: auth)
        self.dropboxSync = sync
        self.syncService = SyncService(provider: sync)
    }

    var isConnected: Bool {
        dropboxAuth.isConnected
    }

    func sync(modelContext: ModelContext, activeNoteId: UUID? = nil) {
        guard syncTask == nil else { return }

        status = .syncing
        syncTask = Task {
            do {
                try await syncService.sync(modelContext: modelContext, activeNoteId: activeNoteId)
                status = .synced
                lastSyncTime = .now
            } catch {
                status = .error(error.localizedDescription)
            }
            syncTask = nil
        }
    }

    func connect() async throws {
        try await dropboxAuth.authorize()
    }

    func disconnect() {
        dropboxAuth.clearTokens()
        status = .idle
        lastSyncTime = nil
    }
}
