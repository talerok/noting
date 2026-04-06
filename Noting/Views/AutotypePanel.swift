#if os(macOS)
import AppKit

struct AutotypeNoteItem {
    let id: UUID
    let title: String
    let preview: String
    let isEncrypted: Bool
}

class AutotypePanel: NSPanel, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {

    var onNoteSelected: ((UUID) -> Void)?
    var onDecryptRequested: ((UUID, String) -> Void)?
    var onDismiss: (() -> Void)?

    private var allNotes: [AutotypeNoteItem] = []
    private var filteredNotes: [AutotypeNoteItem] = []
    private var selectedEncryptedNoteId: UUID?

    private let searchField = NSTextField()
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private let passwordContainer = NSView()
    private let passwordField = NSSecureTextField()
    private let errorLabel = NSTextField(labelWithString: "")
    private let encryptedNoteLabel = NSTextField(labelWithString: "")

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 360),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        collectionBehavior.insert(.fullScreenAuxiliary)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        isOpaque = false
        backgroundColor = .clear
        hidesOnDeactivate = false

        setupUI()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    // MARK: - UI Setup

    private func setupUI() {
        let visualEffect = NSVisualEffectView()
        visualEffect.material = .popover
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 12
        visualEffect.layer?.masksToBounds = true

        contentView = visualEffect

        // Search field
        searchField.placeholderString = "Search notes to paste..."
        searchField.isBordered = false
        searchField.focusRingType = .none
        searchField.font = NSFont.systemFont(ofSize: 16)
        searchField.backgroundColor = .clear
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false

        let searchIcon = NSImageView()
        searchIcon.image = NSImage(named: "NSSearchTemplate")
        searchIcon.contentTintColor = .secondaryLabelColor
        searchIcon.translatesAutoresizingMaskIntoConstraints = false

        let searchRow = NSView()
        searchRow.translatesAutoresizingMaskIntoConstraints = false
        searchRow.addSubview(searchIcon)
        searchRow.addSubview(searchField)

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        // Table view
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("note"))
        column.width = 400
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 48
        tableView.backgroundColor = .clear
        tableView.dataSource = self
        tableView.delegate = self
        tableView.doubleAction = #selector(tableDoubleClicked)
        tableView.target = self

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        // Password container (hidden by default)
        passwordContainer.translatesAutoresizingMaskIntoConstraints = false
        passwordContainer.isHidden = true

        let lockIcon = NSImageView()
        lockIcon.image = NSImage(named: NSImage.lockLockedTemplateName)
        lockIcon.contentTintColor = .secondaryLabelColor
        lockIcon.translatesAutoresizingMaskIntoConstraints = false

        encryptedNoteLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        encryptedNoteLabel.textColor = .labelColor
        encryptedNoteLabel.lineBreakMode = .byTruncatingTail
        encryptedNoteLabel.translatesAutoresizingMaskIntoConstraints = false

        passwordField.placeholderString = "Enter password"
        passwordField.font = NSFont.systemFont(ofSize: 14)
        passwordField.translatesAutoresizingMaskIntoConstraints = false
        passwordField.delegate = self

        errorLabel.font = NSFont.systemFont(ofSize: 12)
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true
        errorLabel.translatesAutoresizingMaskIntoConstraints = false

        let noteRow = NSView()
        noteRow.translatesAutoresizingMaskIntoConstraints = false
        noteRow.addSubview(lockIcon)
        noteRow.addSubview(encryptedNoteLabel)

        passwordContainer.addSubview(noteRow)
        passwordContainer.addSubview(passwordField)
        passwordContainer.addSubview(errorLabel)

        // Layout
        let cv = self.contentView!
        cv.addSubview(searchRow)
        cv.addSubview(separator)
        cv.addSubview(scrollView)
        cv.addSubview(passwordContainer)

        NSLayoutConstraint.activate([
            searchRow.topAnchor.constraint(equalTo: cv.topAnchor, constant: 12),
            searchRow.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 12),
            searchRow.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -12),
            searchRow.heightAnchor.constraint(equalToConstant: 28),

            searchIcon.leadingAnchor.constraint(equalTo: searchRow.leadingAnchor),
            searchIcon.centerYAnchor.constraint(equalTo: searchRow.centerYAnchor),
            searchIcon.widthAnchor.constraint(equalToConstant: 18),
            searchIcon.heightAnchor.constraint(equalToConstant: 18),

            searchField.leadingAnchor.constraint(equalTo: searchIcon.trailingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: searchRow.trailingAnchor),
            searchField.centerYAnchor.constraint(equalTo: searchRow.centerYAnchor),

            separator.topAnchor.constraint(equalTo: searchRow.bottomAnchor, constant: 8),
            separator.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: cv.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: cv.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: cv.bottomAnchor),

            passwordContainer.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 12),
            passwordContainer.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 16),
            passwordContainer.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -16),

            noteRow.topAnchor.constraint(equalTo: passwordContainer.topAnchor),
            noteRow.leadingAnchor.constraint(equalTo: passwordContainer.leadingAnchor),
            noteRow.trailingAnchor.constraint(equalTo: passwordContainer.trailingAnchor),
            noteRow.heightAnchor.constraint(equalToConstant: 20),

            lockIcon.leadingAnchor.constraint(equalTo: noteRow.leadingAnchor),
            lockIcon.centerYAnchor.constraint(equalTo: noteRow.centerYAnchor),
            lockIcon.widthAnchor.constraint(equalToConstant: 14),
            lockIcon.heightAnchor.constraint(equalToConstant: 14),

            encryptedNoteLabel.leadingAnchor.constraint(equalTo: lockIcon.trailingAnchor, constant: 6),
            encryptedNoteLabel.trailingAnchor.constraint(equalTo: noteRow.trailingAnchor),
            encryptedNoteLabel.centerYAnchor.constraint(equalTo: noteRow.centerYAnchor),

            passwordField.topAnchor.constraint(equalTo: noteRow.bottomAnchor, constant: 10),
            passwordField.leadingAnchor.constraint(equalTo: passwordContainer.leadingAnchor),
            passwordField.trailingAnchor.constraint(equalTo: passwordContainer.trailingAnchor),

            errorLabel.topAnchor.constraint(equalTo: passwordField.bottomAnchor, constant: 4),
            errorLabel.leadingAnchor.constraint(equalTo: passwordContainer.leadingAnchor),
            errorLabel.bottomAnchor.constraint(equalTo: passwordContainer.bottomAnchor),
        ])
    }

    // MARK: - Show / Hide

    func showWithNotes(_ notes: [AutotypeNoteItem]) {
        allNotes = notes
        filteredNotes = notes
        selectedEncryptedNoteId = nil

        searchField.stringValue = ""
        passwordField.stringValue = ""
        errorLabel.isHidden = true
        passwordContainer.isHidden = true
        scrollView.isHidden = false

        tableView.reloadData()
        if !filteredNotes.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }

        center()
        makeKeyAndOrderFront(nil)
        makeFirstResponder(searchField)
    }

    func showPasswordError() {
        errorLabel.stringValue = "Wrong password"
        errorLabel.isHidden = false
        passwordField.stringValue = ""
        makeFirstResponder(passwordField)
    }

    private func showPasswordMode(for note: AutotypeNoteItem) {
        selectedEncryptedNoteId = note.id
        encryptedNoteLabel.stringValue = note.title
        passwordField.stringValue = ""
        errorLabel.isHidden = true

        scrollView.isHidden = true
        passwordContainer.isHidden = false
        makeFirstResponder(passwordField)
    }

    private func exitPasswordMode() {
        selectedEncryptedNoteId = nil
        scrollView.isHidden = false
        passwordContainer.isHidden = true
        makeFirstResponder(searchField)
    }

    private func selectNote(at row: Int) {
        guard row >= 0, row < filteredNotes.count else { return }
        let note = filteredNotes[row]

        if note.isEncrypted {
            showPasswordMode(for: note)
        } else {
            onNoteSelected?(note.id)
        }
    }

    private func submitPassword() {
        let password = passwordField.stringValue
        guard !password.isEmpty, let noteId = selectedEncryptedNoteId else { return }
        onDecryptRequested?(noteId, password)
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field === searchField else { return }

        let query = searchField.stringValue
        if query.isEmpty {
            filteredNotes = allNotes
        } else {
            filteredNotes = allNotes.filter { $0.title.localizedCaseInsensitiveContains(query) }
        }
        tableView.reloadData()
        if !filteredNotes.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            if selectedEncryptedNoteId != nil {
                exitPasswordMode()
            } else {
                onDismiss?()
            }
            return true
        }

        if control === searchField {
            if selector == #selector(NSResponder.moveDown(_:)) {
                let next = min(tableView.selectedRow + 1, filteredNotes.count - 1)
                tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
                tableView.scrollRowToVisible(next)
                return true
            }
            if selector == #selector(NSResponder.moveUp(_:)) {
                let prev = max(tableView.selectedRow - 1, 0)
                tableView.selectRowIndexes(IndexSet(integer: prev), byExtendingSelection: false)
                tableView.scrollRowToVisible(prev)
                return true
            }
            if selector == #selector(NSResponder.insertNewline(_:)) {
                selectNote(at: tableView.selectedRow)
                return true
            }
        }

        if control === passwordField {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                submitPassword()
                return true
            }
        }

        return false
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        filteredNotes.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let note = filteredNotes[row]

        let cellId = NSUserInterfaceItemIdentifier("NoteCell")
        let cell: NSTableCellView

        if let reused = tableView.makeView(withIdentifier: cellId, owner: nil) as? NSTableCellView {
            cell = reused
            if let stack = cell.subviews.first as? NSStackView {
                if let titleRow = stack.arrangedSubviews.first as? NSStackView {
                    (titleRow.arrangedSubviews.first as? NSTextField)?.stringValue = note.title
                    let lockView = titleRow.arrangedSubviews.last as? NSImageView
                    lockView?.isHidden = !note.isEncrypted
                }
                (stack.arrangedSubviews.last as? NSTextField)?.stringValue = note.isEncrypted ? "Encrypted" : note.preview
            }
        } else {
            cell = NSTableCellView()
            cell.identifier = cellId

            let titleLabel = NSTextField(labelWithString: note.title)
            titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
            titleLabel.lineBreakMode = .byTruncatingTail

            let lockImage = NSImageView()
            lockImage.image = NSImage(named: NSImage.lockLockedTemplateName)
            lockImage.contentTintColor = .secondaryLabelColor
            lockImage.isHidden = !note.isEncrypted
            lockImage.setContentHuggingPriority(.required, for: .horizontal)

            let titleRow = NSStackView(views: [titleLabel, lockImage])
            titleRow.orientation = .horizontal
            titleRow.spacing = 4

            let previewLabel = NSTextField(labelWithString: note.isEncrypted ? "Encrypted" : note.preview)
            previewLabel.font = NSFont.systemFont(ofSize: 11)
            previewLabel.textColor = .secondaryLabelColor
            previewLabel.lineBreakMode = .byTruncatingTail

            let stack = NSStackView(views: [titleRow, previewLabel])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 2
            stack.translatesAutoresizingMaskIntoConstraints = false

            cell.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
                stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -12),
                stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }

        return cell
    }

    @objc private func tableDoubleClicked() {
        let row = tableView.clickedRow
        guard row >= 0 else { return }
        selectNote(at: row)
    }
}
#endif
