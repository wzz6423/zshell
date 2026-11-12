import Foundation

enum TerminalRightClickAction: String, CaseIterable, Sendable {
    case contextMenu = "context-menu"
    case paste
    case copyOrPaste = "copy-or-paste"

    var title: String {
        switch self {
        case .contextMenu: String(localized: "Context Menu")
        case .paste: String(localized: "Paste")
        case .copyOrPaste: String(localized: "Copy or Paste")
        }
    }

    static var explanation: String {
        String(localized: "Shift-right-click always opens the menu. Mouse-reporting applications handle ordinary right-clicks.")
    }
}
