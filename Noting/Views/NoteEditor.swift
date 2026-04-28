import SwiftData
import SwiftUI

extension Notification.Name {
    /// Posted when the app is about to leave the foreground or otherwise needs
    /// any pending in-memory edits flushed to the persistent store immediately.
    static let flushPendingEdits = Notification.Name("noting.flushPendingEdits")
}

struct NoteEditor: View {
    let noteId: UUID
    var onDelete: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.openURL) private var openURL
    @Environment(SyncManager.self) private var syncManager

    @State private var note: Note?
    @State private var content = ""
    @State private var loadedContent: String? = nil
    @State private var hasPendingSave = false
    /// Last plaintext we successfully wrote to disk. For encrypted notes
    /// `note.content` is empty, so we keep our own copy to detect no-op saves
    /// (otherwise every keystroke re-encrypts and bumps the version).
    @State private var savedPlaintext: String = ""
    @State private var selectedText = ""
    @State private var showRenameAlert = false
    @State private var showDeleteConfirm = false
    @State private var showSaveError = false
    @State private var newTitle = ""

    // Encryption
    @State private var isLocked = true
    @State private var showPasswordPrompt = false
    @State private var showSetPassword = false
    @State private var showChangePassword = false
    @State private var passwordInput = ""
    @State private var newPasswordInput = ""
    @State private var confirmPasswordInput = ""
    @State private var passwordError = ""
    @State private var decryptedKey: Data?

    private let debouncer = Debouncer()

    var body: some View {
        Group {
            if let note {
                if note.isEncrypted && isLocked {
                    lockedView(note: note)
                } else {
                    editorView(note: note)
                }
            } else {
                ProgressView()
            }
        }
        .task(id: noteId) {
            loadNote()
        }
        .onDisappear {
            flushPendingSave()
        }
        .onReceive(NotificationCenter.default.publisher(for: .flushPendingEdits)) { _ in
            flushPendingSave()
        }
    }

    // MARK: - Locked View

    private func lockedView(note: Note) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.fill")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(String(localized: "noteIsLocked"))
                .font(.headline)
            Button(String(localized: "unlock")) {
                passwordInput = ""
                passwordError = ""
                showPasswordPrompt = true
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(note.title)
        .alert(String(localized: "enterPassword"), isPresented: $showPasswordPrompt) {
            SecureField(String(localized: "enterPassword"), text: $passwordInput)
            Button(String(localized: "cancel"), role: .cancel) {}
            Button(String(localized: "unlock")) { unlockNote(note: note) }
        } message: {
            if !passwordError.isEmpty {
                Text(passwordError)
            }
        }
    }

    // MARK: - Editor View

    private func editorView(note: Note) -> some View {
        Group {
            #if os(macOS)
            MacTextEditor(text: $content, selectedText: $selectedText)
            #else
            iOSTextEditor(text: $content, selectedText: $selectedText)
            #endif
        }
        .navigationTitle(note.title)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button(action: { beginRename(note: note) }) {
                            Label(String(localized: "rename"), systemImage: "pencil")
                        }

                        Divider()

                        Button(action: { togglePin(note: note) }) {
                            Label(
                                note.isPinned
                                    ? String(localized: "unpin")
                                    : String(localized: "pin"),
                                systemImage: note.isPinned ? "pin.slash" : "pin"
                            )
                        }

                        Divider()

                        #if os(macOS)
                        Button(action: { runInTerminal() }) {
                            Label(String(localized: "runInTerminal"), systemImage: "terminal")
                        }
                        #endif

                        if !selectedText.isEmpty {
                            Button(action: { openInBrowser() }) {
                                Label(String(localized: "openInBrowser"), systemImage: "safari")
                            }
                        }

                        Divider()

                        if note.isEncrypted && !isLocked {
                            Button(action: { beginChangePassword() }) {
                                Label(String(localized: "changePassword"), systemImage: "key")
                            }
                            Button(action: { removePassword(note: note) }) {
                                Label(String(localized: "removePassword"), systemImage: "lock.open")
                            }
                        } else if !note.isEncrypted {
                            Button(action: { beginSetPassword() }) {
                                Label(String(localized: "setPassword"), systemImage: "lock")
                            }
                        }

                        Divider()

                        Button(role: .destructive, action: { showDeleteConfirm = true }) {
                            Label(String(localized: "delete"), systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .onChange(of: content) { _, newValue in
                if let loaded = loadedContent {
                    loadedContent = nil
                    if newValue == loaded { return }
                }
                hasPendingSave = true
                debouncer.debounce {
                    saveContent(newValue, note: note)
                }
            }
            .alert(String(localized: "rename"), isPresented: $showRenameAlert) {
                TextField(String(localized: "noteTitle"), text: $newTitle)
                Button(String(localized: "cancel"), role: .cancel) {}
                Button(String(localized: "save")) { renameNote(note: note) }
            }
            .confirmationDialog(
                String(localized: "deleteNoteConfirm"),
                isPresented: $showDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button(String(localized: "delete"), role: .destructive) {
                    deleteNote(note: note)
                }
                Button(String(localized: "cancel"), role: .cancel) {}
            } message: {
                Text(String(localized: "deleteNoteMessage"))
            }
            .alert(String(localized: "setPassword"), isPresented: $showSetPassword) {
                SecureField(String(localized: "newPassword"), text: $newPasswordInput)
                SecureField(String(localized: "confirmPassword"), text: $confirmPasswordInput)
                Button(String(localized: "cancel"), role: .cancel) {}
                Button(String(localized: "save")) { setPassword(note: note) }
            } message: {
                if !passwordError.isEmpty {
                    Text(passwordError)
                }
            }
            .alert(String(localized: "changePassword"), isPresented: $showChangePassword) {
                SecureField(String(localized: "currentPassword"), text: $passwordInput)
                SecureField(String(localized: "newPassword"), text: $newPasswordInput)
                SecureField(String(localized: "confirmPassword"), text: $confirmPasswordInput)
                Button(String(localized: "cancel"), role: .cancel) {}
                Button(String(localized: "save")) { changePassword(note: note) }
            } message: {
                if !passwordError.isEmpty {
                    Text(passwordError)
                }
            }
            .alert(String(localized: "syncError"), isPresented: $showSaveError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(String(localized: "saveFailed"))
            }
    }

    // MARK: - Actions

    private func loadNote() {
        // Flush any in-flight edits for the previously loaded note before
        // we replace `note`/`content` with the new selection.
        flushPendingSave()

        let id = noteId
        let descriptor = FetchDescriptor<Note>(predicate: #Predicate { $0.id == id })
        note = try? modelContext.fetch(descriptor).first
        if let note {
            if note.isEncrypted {
                isLocked = true
                loadedContent = ""
                content = ""
                savedPlaintext = ""
            } else {
                isLocked = false
                loadedContent = note.content
                content = note.content
                savedPlaintext = note.content
            }
        }
    }

    /// Forces any pending debounced save to run synchronously. Called when
    /// the editor is about to switch notes or disappear, so the user's last
    /// keystrokes never get stranded inside the debouncer.
    private func flushPendingSave() {
        debouncer.cancel()
        guard hasPendingSave, let note else { return }
        saveContent(content, note: note)
    }

    private func saveContent(_ text: String, note: Note) {
        hasPendingSave = false

        guard !note.isEncrypted || !isLocked else { return }

        if note.isEncrypted, let key = decryptedKey, let salt = note.salt {
            // Skip re-encrypting (and bumping the version) when the plaintext
            // hasn't actually changed since the last save.
            if savedPlaintext == text { return }
            do {
                let payload = try CryptoService.encrypt(text, withDerivedKey: key, saltBase64: salt)
                note.encryptedContent = payload.encryptedContent
                note.iv = payload.iv
            } catch {
                showSaveError = true
                return
            }
        } else {
            if note.content == text { return }
            note.content = text
        }

        note.updatedAt = .now
        note.version += 1
        do {
            try modelContext.save()
            savedPlaintext = text
            syncManager.scheduleSync(modelContext: modelContext, activeNoteId: note.id)
        } catch {
            showSaveError = true
        }
    }

    private func beginRename(note: Note) {
        newTitle = note.title
        showRenameAlert = true
    }

    private func renameNote(note: Note) {
        guard !newTitle.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        note.title = newTitle.trimmingCharacters(in: .whitespaces)
        note.updatedAt = .now
        note.version += 1
        save()
    }

    private func togglePin(note: Note) {
        note.isPinned.toggle()
        note.updatedAt = .now
        note.version += 1
        save()
    }

    #if os(macOS)
    private func runInTerminal() {
        let textToRun = selectedText.isEmpty ? content : selectedText
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("noting_run.command")
        do {
            try textToRun.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: url.path
            )
        } catch { return }
        NSWorkspace.shared.open(url)
    }
    #endif

    private func openInBrowser() {
        var urlString = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !urlString.hasPrefix("http://") && !urlString.hasPrefix("https://") {
            urlString = "https://" + urlString
        }
        guard let url = URL(string: urlString) else { return }
        openURL(url)
    }

    private func deleteNote(note: Note) {
        note.softDelete()
        save()
        onDelete()
    }

    private func save() {
        do {
            try modelContext.save()
            syncManager.scheduleSync(modelContext: modelContext, activeNoteId: noteId)
        } catch {
            showSaveError = true
        }
    }

    // MARK: - Encryption

    private func unlockNote(note: Note) {
        guard let encrypted = note.encryptedContent,
              let salt = note.salt,
              let iv = note.iv else { return }

        Task {
            do {
                let (text, key) = try await CryptoService.decrypt(
                    encrypted, saltBase64: salt, ivBase64: iv, password: passwordInput
                )
                loadedContent = text
                content = text
                savedPlaintext = text
                decryptedKey = key
                isLocked = false
                passwordError = ""
            } catch {
                passwordError = String(localized: "wrongPassword")
                showPasswordPrompt = true
            }
        }
    }

    private func beginSetPassword() {
        newPasswordInput = ""
        confirmPasswordInput = ""
        passwordError = ""
        showSetPassword = true
    }

    private func setPassword(note: Note) {
        guard !newPasswordInput.isEmpty else { return }
        guard newPasswordInput == confirmPasswordInput else {
            passwordError = String(localized: "passwordsDoNotMatch")
            showSetPassword = true
            return
        }

        Task {
            do {
                let payload = try await CryptoService.encrypt(content, withPassword: newPasswordInput)
                note.isEncrypted = true
                note.encryptedContent = payload.encryptedContent
                note.salt = payload.salt
                note.iv = payload.iv
                note.content = ""
                note.updatedAt = .now
                note.version += 1

                let key = try await CryptoService.deriveKey(
                    password: newPasswordInput,
                    saltBase64: payload.salt
                )
                decryptedKey = key
                savedPlaintext = content

                try modelContext.save()
                syncManager.scheduleSync(modelContext: modelContext, activeNoteId: note.id)
            } catch {
                showSaveError = true
            }
        }
    }

    private func beginChangePassword() {
        passwordInput = ""
        newPasswordInput = ""
        confirmPasswordInput = ""
        passwordError = ""
        showChangePassword = true
    }

    private func changePassword(note: Note) {
        guard !newPasswordInput.isEmpty, newPasswordInput == confirmPasswordInput else {
            passwordError = String(localized: "passwordsDoNotMatch")
            showChangePassword = true
            return
        }

        Task {
            // Verify current password
            guard let encrypted = note.encryptedContent,
                  let salt = note.salt,
                  let iv = note.iv else { return }

            do {
                let (text, _) = try await CryptoService.decrypt(
                    encrypted, saltBase64: salt, ivBase64: iv, password: passwordInput
                )
                // Re-encrypt with new password
                let payload = try await CryptoService.encrypt(text, withPassword: newPasswordInput)
                note.encryptedContent = payload.encryptedContent
                note.salt = payload.salt
                note.iv = payload.iv
                note.updatedAt = .now
                note.version += 1

                let key = try await CryptoService.deriveKey(
                    password: newPasswordInput,
                    saltBase64: payload.salt
                )
                decryptedKey = key

                try modelContext.save()
                syncManager.scheduleSync(modelContext: modelContext, activeNoteId: note.id)
            } catch is CryptoError {
                passwordError = String(localized: "wrongPassword")
                showChangePassword = true
            } catch {
                showSaveError = true
            }
        }
    }

    private func removePassword(note: Note) {
        guard !isLocked else { return }
        guard !content.isEmpty || note.content.isEmpty else { return }
        note.content = content
        note.isEncrypted = false
        note.encryptedContent = nil
        note.salt = nil
        note.iv = nil
        note.updatedAt = .now
        note.version += 1
        decryptedKey = nil
        savedPlaintext = content
        save()
    }
}

#if os(macOS)
import AppKit

private struct MacTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var selectedText: String

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .legacy
        scrollView.autohidesScrollers = false
        scrollView.drawsBackground = false

        let textView = scrollView.documentView as! NSTextView
        textView.font = NSFont.preferredFont(forTextStyle: .body)
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 11, height: 8)
        textView.textContainer?.lineFragmentPadding = 5
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.allowsUndo = true
        textView.delegate = context.coordinator
        textView.string = text

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MacTextEditor

        init(_ parent: MacTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let ranges = textView.selectedRanges
            if let range = ranges.first?.rangeValue, range.length > 0 {
                parent.selectedText = (textView.string as NSString).substring(with: range)
            } else {
                parent.selectedText = ""
            }
        }
    }
}
#endif

#if os(iOS)
import UIKit

private struct iOSTextEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var selectedText: String

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.font = UIFont.preferredFont(forTextStyle: .body)
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        textView.textContainer.lineFragmentPadding = 0
        textView.delegate = context.coordinator
        textView.text = text
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        if textView.text != text {
            textView.text = text
        }
    }

    class Coordinator: NSObject, UITextViewDelegate {
        var parent: iOSTextEditor

        init(_ parent: iOSTextEditor) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            let range = textView.selectedRange
            if range.length > 0 {
                parent.selectedText = (textView.text as NSString).substring(with: range)
            } else {
                parent.selectedText = ""
            }
        }
    }
}
#endif
