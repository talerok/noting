import SwiftData
import SwiftUI

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(SyncManager.self) private var syncManager
    @State private var selectedNoteId: UUID?
    @State private var showSettings = false
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            NotesList(
                selectedNoteId: $selectedNoteId,
                onSettingsTap: { showSettings = true }
            )
            .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 400)
        } detail: {
            if let noteId = selectedNoteId {
                NoteEditor(noteId: noteId, onDelete: { selectedNoteId = nil })
            } else {
                ContentUnavailableView(
                    String(localized: "selectNoteOrCreate"),
                    systemImage: "note.text"
                )
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .onAppear {
            if syncManager.isConnected {
                syncManager.sync(modelContext: modelContext)
            }
        }
    }
}
