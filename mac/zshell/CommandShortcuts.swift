//
//  CommandShortcuts.swift
//  zshell
//

import AppKit
import Carbon.HIToolbox

/// A recorded in-app command shortcut: the key character plus the modifier
/// flags it was pressed with. The character is normalized to lowercase so a
/// shifted letter (⇧⌘A types "A") matches the same chord as its unshifted
/// form, the way menu key equivalents are written.
struct CommandShortcut: Equatable {
    /// Modifier-only chords are meaningless for menus, and shift alone just
    /// types text, so a recording needs command, option, or control.
    static let allowedModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
    static let requiredModifiers: NSEvent.ModifierFlags = [.command, .option, .control]

    let character: Character
    let modifiers: NSEvent.ModifierFlags

    init(character: Character, modifiers: NSEvent.ModifierFlags) {
        self.character = Self.normalized(character)
        self.modifiers = modifiers.intersection(Self.allowedModifiers)
    }

    /// Reads a chord from a key event, rejecting the combinations a menu
    /// shortcut cannot carry: no key (a bare modifier press), keys that don't
    /// produce a single printable character (arrows, function keys), and
    /// chords without a command-level modifier.
    init?(event: NSEvent) {
        var modifiers: NSEvent.ModifierFlags = []
        if event.modifierFlags.contains(.command) { modifiers.insert(.command) }
        if event.modifierFlags.contains(.option) { modifiers.insert(.option) }
        if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
        if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
        guard modifiers.intersection(Self.requiredModifiers) != [] else { return nil }
        guard
            let characters = event.charactersIgnoringModifiers,
            characters.count == 1,
            let character = characters.first,
            Self.isRecordable(character)
        else { return nil }
        self.character = Self.normalized(character)
        self.modifiers = modifiers.intersection(Self.allowedModifiers)
    }

    /// Persists as `u<hex>:<modifiers>` — for example `u74:cmd` or
    /// `u67:cmd+shift` — so any recordable character survives the round trip
    /// through `config.toml` without string escaping.
    init?(persistedValue: String?) {
        guard let persistedValue else { return nil }
        let components = persistedValue.split(separator: ":", omittingEmptySubsequences: false)
        guard components.count == 2, components[0].hasPrefix("u"),
              let code = UInt32(components[0].dropFirst(), radix: 16),
              let scalar = Unicode.Scalar(code),
              Self.isRecordable(Character(String(scalar)))
        else { return nil }
        var modifiers: NSEvent.ModifierFlags = []
        for part in components[1].split(separator: "+") {
            switch part {
            case "cmd": modifiers.insert(.command)
            case "opt": modifiers.insert(.option)
            case "ctrl": modifiers.insert(.control)
            case "shift": modifiers.insert(.shift)
            default: return nil
            }
        }
        guard modifiers.intersection(Self.requiredModifiers) != [] else { return nil }
        self.character = Self.normalized(Character(String(scalar)))
        self.modifiers = modifiers.intersection(Self.allowedModifiers)
    }

    var persistedValue: String {
        let code = character.unicodeScalars.first?.value ?? 0
        var parts: [String] = []
        if modifiers.contains(.command) { parts.append("cmd") }
        if modifiers.contains(.option) { parts.append("opt") }
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.shift) { parts.append("shift") }
        return "u\(String(code, radix: 16)):\(parts.joined(separator: "+"))"
    }

    var displayString: String {
        var result = ""
        if modifiers.contains(.control) { result += "⌃" }
        if modifiers.contains(.option) { result += "⌥" }
        if modifiers.contains(.shift) { result += "⇧" }
        if modifiers.contains(.command) { result += "⌘" }
        return result + character.uppercased()
    }

    /// This chord in the Carbon flag encoding `QuickTerminalShortcut` and the
    /// hotkey registration API use, so Settings can tell when a recording
    /// would shadow the Quick Terminal's global hotkey.
    var carbonModifiers: UInt32 {
        var result: UInt32 = 0
        if modifiers.contains(.command) { result |= UInt32(cmdKey) }
        if modifiers.contains(.option) { result |= UInt32(optionKey) }
        if modifiers.contains(.control) { result |= UInt32(controlKey) }
        if modifiers.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    /// ANSI key code for the characters the remappable defaults use. Key
    /// codes can't be derived for every character, so `nil` just means the
    /// Quick Terminal overlap check doesn't apply.
    var ansiKeyCode: UInt16? {
        QuickTerminalShortcut.keyCode(for: character).map(UInt16.init)
    }

    /// Menus can't carry bare whitespace, and function keys arrive as
    /// private-use characters SwiftUI can't display.
    private static func isRecordable(_ character: Character) -> Bool {
        guard
            character.unicodeScalars.count == 1,
            let scalar = character.unicodeScalars.first,
            scalar.value > 0x20, scalar.value < 0xF700
        else { return false }
        return true
    }

    /// ASCII letters only; exotic uppercase forms can lowercase to multiple
    /// scalars, which a single-character key equivalent can't hold.
    private static func normalized(_ character: Character) -> Character {
        guard
            character.unicodeScalars.count == 1,
            let scalar = character.unicodeScalars.first,
            scalar.value >= UInt32(UInt8(ascii: "A")),
            scalar.value <= UInt32(UInt8(ascii: "Z"))
        else { return character }
        return Character(Unicode.Scalar(scalar.value + 0x20)!)
    }
}

/// The core commands whose menu shortcuts can be remapped in Settings. The
/// raw value is the stable `config.toml` key under `shortcuts`; the title
/// reuses each command's menu item string, so the catalog entries — and their
/// translations — stay the same one source of truth.
enum AppCommand: String, CaseIterable {
    case newSession = "new-session"
    case newProject = "new-project"
    case newWindow = "new-window"
    case closePane = "close-pane"
    case commandPalette = "command-palette"
    case toggleLeftSidebar = "toggle-left-sidebar"
    case toggleRightSidebar = "toggle-right-sidebar"
    case toggleFilesPanel = "toggle-files-panel"
    case toggleGitPanel = "toggle-git-panel"
    case nextProject = "next-project"
    case previousProject = "previous-project"
    case clearTerminal = "clear-terminal"

    var title: String {
        switch self {
        case .newSession: String(localized: "New Session")
        case .newProject: String(localized: "New Project")
        case .newWindow: String(localized: "New Window")
        case .closePane: String(localized: "Close Pane")
        case .commandPalette: String(localized: "Command Palette…")
        case .toggleLeftSidebar: String(localized: "Toggle Left Sidebar")
        case .toggleRightSidebar: String(localized: "Toggle Right Sidebar")
        case .toggleFilesPanel: String(localized: "Toggle Files Panel")
        case .toggleGitPanel: String(localized: "Toggle Git Panel")
        case .nextProject: String(localized: "Next Project")
        case .previousProject: String(localized: "Previous Project")
        case .clearTerminal: String(localized: "Clear Terminal")
        }
    }

    /// The shortcut the menu ships with, which also serves as the value a
    /// restored binding returns to.
    var defaultShortcut: CommandShortcut {
        switch self {
        case .newSession: CommandShortcut(character: "t", modifiers: .command)
        case .newProject: CommandShortcut(character: "n", modifiers: .command)
        case .newWindow: CommandShortcut(character: "n", modifiers: [.command, .shift])
        case .closePane: CommandShortcut(character: "w", modifiers: .command)
        case .commandPalette: CommandShortcut(character: "p", modifiers: .command)
        case .toggleLeftSidebar: CommandShortcut(character: "b", modifiers: .command)
        case .toggleRightSidebar: CommandShortcut(character: "b", modifiers: [.command, .shift])
        case .toggleFilesPanel: CommandShortcut(character: "e", modifiers: [.command, .shift])
        case .toggleGitPanel: CommandShortcut(character: "g", modifiers: [.command, .shift])
        case .nextProject: CommandShortcut(character: "]", modifiers: [.command, .option])
        case .previousProject: CommandShortcut(character: "[", modifiers: [.command, .option])
        case .clearTerminal: CommandShortcut(character: "k", modifiers: .command)
        }
    }
}
