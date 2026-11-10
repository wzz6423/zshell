import AppKit

@MainActor
final class FileSaveConflictController: NSObject {
    enum Choice { case keepDraft, reload, overwrite }
    enum SaveResult {
        case saved(FileSaveSnapshot)
        case reload
        case cancelled
    }

    static func save(
        text: String,
        path: String,
        baseline: FileSaveSnapshot?,
        protectionEnabled: Bool,
        in window: NSWindow?,
        resolveConflict: ((FileSaveCoordinator.Conflict, String) -> Choice)? = nil
    ) throws -> SaveResult {
        var overwrite: FileSaveSnapshot?
        while true {
            switch try FileSaveCoordinator.save(text: text, path: path, baseline: baseline,
                                                protectionEnabled: protectionEnabled, overwrite: overwrite) {
            case .saved(let snapshot): return .saved(snapshot)
            case .conflict(let conflict):
                let choice: Choice
                if let resolveConflict { choice = resolveConflict(conflict, text) }
                else {
                    guard AppWindowPresentation.hostWindow(relativeTo: window) != nil else { return .cancelled }
                    choice = FileSaveConflictController(conflict: conflict, draft: text).resolve()
                }
                switch choice {
                case .keepDraft: return .cancelled
                case .reload: return .reload
                case .overwrite:
                    guard conflict.current.canWrite else { return .cancelled }
                    // Approval covers the compared disk version; later agent edits ask again.
                    overwrite = conflict.current
                }
            }
        }
    }

    private let alert = NSAlert()
    private let conflict: FileSaveCoordinator.Conflict
    private let draft: String
    private let compareButton = NSButton(title: "", target: nil, action: nil)

    init(conflict: FileSaveCoordinator.Conflict, draft: String) {
        self.conflict = conflict
        self.draft = draft
        super.init()
        alert.alertStyle = .warning
        let name = URL(fileURLWithPath: conflict.path).lastPathComponent
        alert.messageText = String(
            localized: "“\(name)” changed on disk.",
            comment: "Save conflict title. The placeholder is a file name."
        )
        alert.informativeText = String(localized: "Compare the disk version with your draft before saving. Reloading discards your draft; overwriting replaces the disk version.")
        let keep = alert.addButton(withTitle: String(localized: "Keep Draft"))
        keep.keyEquivalent = "\u{1b}"
        alert.addButton(withTitle: String(localized: "Reload from Disk"))
        let overwrite = alert.addButton(withTitle: String(localized: "Overwrite File"))
        overwrite.hasDestructiveAction = true
        overwrite.keyEquivalent = ""
        overwrite.isEnabled = conflict.current.canWrite
        compareButton.title = String(localized: "Compare…")
        compareButton.bezelStyle = .rounded
        compareButton.target = self
        compareButton.action = #selector(compare)
        let accessory = NSStackView(views: [compareButton])
        accessory.orientation = .vertical
        accessory.alignment = .leading
        alert.accessoryView = accessory
    }

    func resolve() -> Choice {
        switch alert.runModal() {
        case .alertSecondButtonReturn: return .reload
        case .alertThirdButtonReturn: return .overwrite
        default: return .keepDraft
        }
    }

    @objc private func compare() {
        guard let accessory = alert.accessoryView as? NSStackView,
              accessory.arrangedSubviews.count == 1 else { return }
        let diskText: String
        if conflict.current.isMissing {
            diskText = String(localized: "The file was deleted.")
        } else if !conflict.current.isRegular {
            diskText = String(localized: "The path no longer points to a regular file.")
        } else if conflict.current.data == nil {
            diskText = String(localized: "The disk version is too large to compare.")
        } else {
            diskText = conflict.current.text ?? String(localized: "The disk version is not UTF-8 text.")
        }
        let comparison = NSStackView(views: [
            preview(title: String(localized: "On Disk"), text: diskText),
            preview(title: String(localized: "Your Draft"), text: draft),
        ])
        comparison.orientation = .horizontal
        comparison.alignment = .top
        comparison.distribution = .fillEqually
        comparison.spacing = 12
        for column in comparison.arrangedSubviews {
            column.heightAnchor.constraint(equalTo: comparison.heightAnchor).isActive = true
        }
        accessory.addArrangedSubview(comparison)
        NSLayoutConstraint.activate([
            comparison.widthAnchor.constraint(equalToConstant: 660),
            comparison.heightAnchor.constraint(equalToConstant: 280),
        ])
        compareButton.isHidden = true
        alert.layout()
    }

    private func preview(title: String, text: String) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        let scroll = NSScrollView()
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 310, height: 250))
        editor.isEditable = false
        editor.isRichText = false
        editor.isHorizontallyResizable = true
        editor.isVerticallyResizable = true
        editor.autoresizingMask = .width
        editor.minSize = NSSize(width: 0, height: 0)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.containerSize = editor.maxSize
        editor.textContainer?.widthTracksTextView = false
        editor.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        editor.textContainerInset = NSSize(width: 8, height: 8)
        editor.string = text
        editor.setAccessibilityLabel(title)
        scroll.documentView = editor
        let stack = NSStackView(views: [label, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        label.setContentHuggingPriority(.required, for: .vertical)
        return stack
    }
}
