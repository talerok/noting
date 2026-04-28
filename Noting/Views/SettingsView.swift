import SwiftUI
#if os(macOS)
import KeyboardShortcuts
#endif

enum AppAppearance: String, CaseIterable {
    case system, light, dark

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    var label: String {
        switch self {
        case .system: String(localized: "appearanceSystem")
        case .light: String(localized: "appearanceLight")
        case .dark: String(localized: "appearanceDark")
        }
    }
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(SyncManager.self) private var syncManager
    @AppStorage("appearance") private var appearance: AppAppearance = .system
    @State private var isConnecting = false

    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "appearance")) {
                    Picker(selection: $appearance) {
                        ForEach(AppAppearance.allCases, id: \.self) { option in
                            Text(option.label).tag(option)
                        }
                    } label: {
                        EmptyView()
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                #if os(macOS)
                Section(String(localized: "shortcuts")) {
                    KeyboardShortcuts.Recorder(
                        String(localized: "autotypeHotkey"),
                        name: .autotype
                    )
                }
                #endif

                Section(String(localized: "account")) {
                    if syncManager.isConnected {
                        LabeledContent("Dropbox") {
                            syncStatusView
                        }

                        Button(String(localized: "sync")) {
                            syncManager.sync(modelContext: modelContext)
                        }
                        .disabled(syncManager.status == .syncing)

                        Button(String(localized: "disconnect"), role: .destructive) {
                            syncManager.disconnect()
                        }
                    } else {
                        Button {
                            connectDropbox()
                        } label: {
                            HStack {
                                Text(String(localized: isConnecting ? "connectingDropbox" : "connectDropbox"))
                                if isConnecting {
                                    Spacer()
                                    ProgressView()
                                        .controlSize(.small)
                                }
                            }
                        }
                        .disabled(isConnecting)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(String(localized: "settings"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "done")) {
                        dismiss()
                    }
                }
            }
        }
        .frame(minWidth: 400, minHeight: 300)
    }

    @ViewBuilder
    private var syncStatusView: some View {
        switch syncManager.status {
        case .idle:
            EmptyView()
        case .pendingSync:
            Text(String(localized: "pendingSync"))
                .font(.caption)
                .foregroundStyle(.secondary)
        case .syncing:
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.small)
                Text(String(localized: "syncing"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .synced:
            Text(String(localized: "synced"))
                .font(.caption)
                .foregroundStyle(.secondary)
        case .error(let msg):
            Text(String(localized: "syncError"))
                .font(.caption)
                .foregroundStyle(.red)
                .help(msg)
        }
    }

    private func connectDropbox() {
        isConnecting = true
        Task {
            do {
                try await syncManager.connect()
                syncManager.sync(modelContext: modelContext)
            } catch {
                // Auth was cancelled or failed
            }
            isConnecting = false
        }
    }
}
