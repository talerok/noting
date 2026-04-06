#if os(macOS)
import AppKit
import Carbon
import SwiftData

@MainActor
final class AutotypeService {
    private let container: ModelContainer
    private var hotKeyRef: EventHotKeyRef?
    private var previousApp: NSRunningApplication?
    private var panel: AutotypePanel?

    init(container: ModelContainer) {
        self.container = container
        registerHotkey()
    }

    // MARK: - Global Hotkey

    private func registerHotkey() {
        if !AXIsProcessTrusted() {
            let key = "AXTrustedCheckOptionPrompt" as CFString
            let options = [key: true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
        }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData -> OSStatus in
                guard let userData else { return OSStatus(eventNotHandledErr) }
                let service = Unmanaged<AutotypeService>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async {
                    service.onHotkeyPressed()
                }
                return noErr
            },
            1,
            &eventType,
            selfPtr,
            nil
        )

        let hotKeyID = EventHotKeyID(
            signature: OSType(0x4E4F5447), // "NOTG"
            id: 1
        )
        let modifiers: UInt32 = UInt32(cmdKey | shiftKey)
        RegisterEventHotKey(
            UInt32(kVK_ANSI_V),
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    private func onHotkeyPressed() {
        previousApp = NSWorkspace.shared.frontmostApplication

        let context = ModelContext(container)
        var descriptor = FetchDescriptor<Note>()
        descriptor.sortBy = [SortDescriptor(\Note.updatedAt, order: .reverse)]
        guard let notes = try? context.fetch(descriptor) else { return }

        let active = notes.filter { $0.deletedAt == nil }
        let sorted = active.sorted { a, b in
            if a.isPinned != b.isPinned { return a.isPinned }
            return a.updatedAt > b.updatedAt
        }
        let items: [AutotypeNoteItem] = sorted.map { note in
            let preview: String
            if note.isEncrypted {
                preview = ""
            } else {
                preview = note.content.prefix(100)
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
            }
            return AutotypeNoteItem(
                id: note.id,
                title: note.title,
                preview: preview,
                isEncrypted: note.isEncrypted
            )
        }

        showPanel(with: items)
    }

    // MARK: - Panel

    private func showPanel(with notes: [AutotypeNoteItem]) {
        if panel == nil {
            panel = AutotypePanel()
        }

        panel?.onNoteSelected = { [weak self] noteId in
            self?.onNoteSelected(noteId)
        }
        panel?.onDecryptRequested = { [weak self] noteId, password in
            self?.onDecryptRequested(noteId, password: password)
        }
        panel?.onDismiss = { [weak self] in
            self?.dismissPanel()
        }

        panel?.showWithNotes(notes)
    }

    private func onNoteSelected(_ noteId: UUID) {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<Note>(predicate: #Predicate { $0.id == noteId })
        guard let note = try? context.fetch(descriptor).first else { return }
        pasteText(note.content)
    }

    private func onDecryptRequested(_ noteId: UUID, password: String) {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<Note>(predicate: #Predicate { $0.id == noteId })
        guard let note = try? context.fetch(descriptor).first,
              let encrypted = note.encryptedContent,
              let salt = note.salt,
              let iv = note.iv else { return }

        Task {
            do {
                let (text, _) = try await CryptoService.decrypt(
                    encrypted, saltBase64: salt, ivBase64: iv, password: password
                )
                pasteText(text)
            } catch {
                panel?.showPasswordError()
            }
        }
    }

    private func pasteText(_ text: String) {
        panel?.orderOut(nil)

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        if let app = previousApp {
            app.activate()
        }
        previousApp = nil

        DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 0.2) {
            self.simulatePaste()
        }
    }

    private func dismissPanel() {
        panel?.orderOut(nil)
        previousApp = nil
    }

    private nonisolated func simulatePaste() {
        let source = CGEventSource(stateID: .hidSystemState)

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true) else { return }
        keyDown.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)

        guard let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else { return }
        keyUp.flags = .maskCommand
        keyUp.post(tap: .cghidEventTap)
    }
}
#endif
