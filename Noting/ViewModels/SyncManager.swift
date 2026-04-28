import Foundation
import Observation
import SwiftData

enum SyncStatus: Equatable {
    case idle
    case pendingSync
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
    private var scheduledSyncTask: Task<Void, Never>?
    private var pendingSyncRequest: (modelContext: ModelContext, activeNoteId: UUID?)?

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
        // If a sync is already running, remember to sync again right after.
        if syncTask != nil {
            pendingSyncRequest = (modelContext, activeNoteId)
            return
        }

        // An immediate sync supersedes any scheduled one.
        scheduledSyncTask?.cancel()
        scheduledSyncTask = nil

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

            // Run a queued sync request if one was made while we were syncing.
            if let pending = pendingSyncRequest {
                pendingSyncRequest = nil
                sync(modelContext: pending.modelContext, activeNoteId: pending.activeNoteId)
            }
        }
    }

    /// Debounced sync trigger — used after note edits to coalesce rapid
    /// changes into a single sync.
    func scheduleSync(modelContext: ModelContext, activeNoteId: UUID? = nil, delay: Duration = .seconds(3)) {
        guard isConnected else { return }
        scheduledSyncTask?.cancel()
        // Reflect "edits queued for sync" in the UI unless a sync is already
        // running (in which case the .syncing status is more informative).
        if syncTask == nil {
            status = .pendingSync
        }
        scheduledSyncTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.scheduledSyncTask = nil
            self.sync(modelContext: modelContext, activeNoteId: activeNoteId)
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
