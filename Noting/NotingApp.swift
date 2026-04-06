import SwiftData
import SwiftUI

@main
struct NotingApp: App {
    @State private var syncManager = SyncManager()
    @AppStorage("appearance") private var appearance: AppAppearance = .system

    private let container: ModelContainer = {
        try! ModelContainer(for: Note.self)
    }()

    #if os(macOS)
    @State private var autotypeService: AutotypeService?
    #endif

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(syncManager)
                .preferredColorScheme(appearance.colorScheme)
                .onOpenURL { url in
                    syncManager.dropboxAuth.handleCallback(url: url)
                }
                #if os(macOS)
                .onAppear {
                    if autotypeService == nil {
                        autotypeService = AutotypeService(container: container)
                    }
                }
                #endif
        }
        .handlesExternalEvents(matching: ["*"])
        .modelContainer(container)
    }
}
