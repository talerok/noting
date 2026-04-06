import SwiftData
import SwiftUI

struct NotesList: View {
    @Binding var selectedNoteId: UUID?
    var onSettingsTap: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(SyncManager.self) private var syncManager

    @Query(sort: \Note.updatedAt, order: .reverse)
    private var allNotes: [Note]

    @State private var searchText = ""

    private var notes: [Note] {
        let active = allNotes.filter { $0.deletedAt == nil }
        let sorted = active.sorted { a, b in
            if a.isPinned != b.isPinned { return a.isPinned }
            return a.updatedAt > b.updatedAt
        }
        guard !searchText.isEmpty else { return sorted }
        return sorted.filter {
            $0.title.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        noteListContent
            .searchable(text: $searchText, placement: .sidebar, prompt: String(localized: "search"))
        .navigationTitle(String(localized: "appTitle"))
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button(action: createNote) {
                    Label(String(localized: "newNote"), systemImage: "plus")
                }
                Button(action: onSettingsTap) {
                    Label(String(localized: "settings"), systemImage: "gearshape")
                }
            }
        }
    }

    @ViewBuilder
    private var noteListContent: some View {
        if notes.isEmpty {
            ContentUnavailableView(
                searchText.isEmpty
                    ? String(localized: "noNotes")
                    : String(localized: "noNotesFound"),
                systemImage: searchText.isEmpty ? "note.text" : "magnifyingglass"
            )
        } else {
            List(notes, selection: $selectedNoteId) { note in
                NoteRow(note: note, syncManager: syncManager)
                    .tag(note.id)
            }
            .listStyle(.sidebar)
        }
    }


    private func createNote() {
        let note = Note(title: String(localized: "newNote"))
        modelContext.insert(note)
        try? modelContext.save()
        selectedNoteId = note.id
    }
}

// MARK: - NoteRow

private struct NoteRow: View {
    let note: Note
    let syncManager: SyncManager

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(note.title)
                    .lineLimit(1)
                    .font(.body)

                Spacer()

                if note.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if note.isEncrypted {
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                syncStatusIcon
            }

            Text(note.updatedAt.relativeFormatted)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var syncStatusIcon: some View {
        let isSynced = syncManager.lastSyncTime.map { note.updatedAt <= $0 } ?? false

        switch syncManager.status {
        case .syncing:
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .symbolEffect(.rotate)
        default:
            Image(systemName: isSynced ? "checkmark.icloud" : "icloud.and.arrow.up")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Date Formatting

extension Date {
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd.MM.yyyy"
        return f
    }()

    var relativeFormatted: String {
        let diff = Date.now.timeIntervalSince(self)

        if diff < 60 {
            return String(localized: "justNow")
        } else if diff < 3600 {
            let minutes = Int(diff / 60)
            return String(localized: "minutesAgo \(minutes)")
        } else if diff < 86400 {
            let hours = Int(diff / 3600)
            return String(localized: "hoursAgo \(hours)")
        } else if diff < 604_800 {
            let days = Int(diff / 86400)
            return String(localized: "daysAgo \(days)")
        } else {
            return Self.dateFormatter.string(from: self)
        }
    }
}
