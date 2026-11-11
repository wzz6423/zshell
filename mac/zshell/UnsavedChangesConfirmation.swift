import AppKit

/// A close request owns the prompts until every affected workspace is approved.
/// Discard approvals cover exact buffers so an edit in another window is asked
/// about again before any sessions or projects are destroyed.
@MainActor
final class UnsavedChangesConfirmation {
    private static weak var active: UnsavedChangesConfirmation?
    static var isPending: Bool { active != nil }
    private var discardedText: [UUID: String] = [:]
    private var discardedContents: [UUID: PaneContent] = [:]

    func commitDiscards() {
        for (id, content) in discardedContents where content.unsavedText == discardedText[id] {
            content.discardDraftBackup()
        }
    }

    init?() {
        guard Self.active == nil else { return nil }
        Self.active = self
    }

    func requiresConfirmation(_ content: PaneContent) -> Bool {
        guard let text = content.unsavedText else { return false }
        return discardedText[content.id] != text
    }

    func confirm(_ content: PaneContent, in window: NSWindow?) async -> Bool {
        guard let text = content.unsavedText, requiresConfirmation(content) else { return true }
        guard let host = AppWindowPresentation.hostWindow(relativeTo: window),
              window == nil || host === window,
              host.attachedSheet == nil else { return false }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "Do you want to save the changes you made to \(content.title)?",
            comment: "Unsaved file or diff confirmation. The placeholder is a file name."
        )
        alert.informativeText = String(localized: "Your changes will be lost if you don't save them.")
        alert.addButton(withTitle: String(localized: "Save"))
        let dontSave = alert.addButton(withTitle: String(localized: "Don’t Save"))
        dontSave.keyEquivalent = "d"
        dontSave.keyEquivalentModifierMask = .command
        let cancel = alert.addButton(withTitle: String(localized: "Cancel"))
        cancel.keyEquivalent = "\u{1b}"

        switch await alert.beginSheetModal(for: host) {
        case .alertFirstButtonReturn:
            return content.save() && content.saveError == nil && !content.isDirty
        case .alertSecondButtonReturn:
            discardedText[content.id] = text
            discardedContents[content.id] = content
            return true
        default:
            return false
        }
    }
}
