import Foundation

nonisolated enum VimMode: String, Equatable, CaseIterable {
    case normal, insert, replace, visual, visualLine, visualBlock, select, commandLine, search

    var title: String {
        switch self {
        case .normal: String(localized: "Normal")
        case .insert: String(localized: "Insert")
        case .replace: String(localized: "Replace")
        case .visual: String(localized: "Visual")
        case .visualLine: String(localized: "Visual Line")
        case .visualBlock: String(localized: "Visual Block")
        case .select: String(localized: "Select")
        case .commandLine: String(localized: "Command line")
        case .search: String(localized: "Search")
        }
    }

    var commands: [VimCommandHint] {
        let escape = VimCommandHint("Esc", String(localized: "Return to Normal mode"))
        let movement = VimCommandHint("h j k l · w b", String(localized: "Move by character or word"))
        let undo = VimCommandHint("u · Ctrl-R", String(localized: "Undo / redo"))
        let save = VimCommandHint(":w · :wq", String(localized: "Save / save and quit"))
        let quit = VimCommandHint(":q · :q!", String(localized: "Quit / discard changes and quit"))
        switch self {
        case .normal:
            return [save, quit,
                .init("yy · p / P", String(localized: "Yank line / paste after or before")),
                .init("dd · x", String(localized: "Delete line / character")), undo,
                .init("i · a · o", String(localized: "Insert / append / open line")),
                .init("v · V · Ctrl-V", String(localized: "Select characters / lines / block")),
                .init("/text · n / N", String(localized: "Search / next or previous match")),
                movement, .init("gg · G · 0 · $", String(localized: "First / last line; line start / end"))]
        case .insert:
            return [escape,
                .init("Ctrl-W", String(localized: "Delete previous word")),
                .init("Ctrl-U", String(localized: "Delete back to the start of insertion")),
                .init("Ctrl-R {register}", String(localized: "Insert a register, e.g. Ctrl-R 0")),
                .init("Ctrl-N / Ctrl-P", String(localized: "Complete next / previous word")),
                .init("Ctrl-O {command}", String(localized: "Run one Normal command"))]
        case .replace:
            return [escape,
                .init("Type", String(localized: "Replace characters under the cursor")),
                .init("Backspace", String(localized: "Restore the previous replaced character")),
                .init("Ctrl-O {command}", String(localized: "Run one Normal command"))]
        case .visual, .visualLine:
            return [
                .init("y · d · c", String(localized: "Yank / delete / change selection")),
                .init("p", String(localized: "Replace selection with a register")),
                .init("> / <", String(localized: "Indent / unindent selection")),
                .init("o", String(localized: "Move to the other end of selection")),
                .init("U / u", String(localized: "Uppercase / lowercase selection")),
                .init(":", String(localized: "Run an Ex command on selected lines")),
                movement, escape]
        case .visualBlock:
            return [
                .init("I / A → text → Esc", String(localized: "Insert / append text on each selected line")),
                .init("y · d · c", String(localized: "Yank / delete / change block")),
                .init("p", String(localized: "Replace block with a register")),
                .init("o / O", String(localized: "Move to opposite / adjacent corner")),
                .init("> / <", String(localized: "Indent / unindent selected lines")),
                .init("$", String(localized: "Extend block to the end of each line")),
                movement, escape]
        case .select:
            return [
                .init("Type", String(localized: "Replace the selected text")),
                .init("Ctrl-G", String(localized: "Switch to Visual mode")), escape]
        case .commandLine:
            return [save, quit,
                .init(":%s/old/new/gc", String(localized: "Replace throughout file, with confirmation")),
                .init("Tab · ↑ / ↓", String(localized: "Complete command / browse history")),
                .init("Enter", String(localized: "Execute command")), escape]
        case .search:
            return [
                .init("Enter · Esc", String(localized: "Confirm / cancel search")),
                .init("n / N", String(localized: "After confirming: next / previous match")),
                .init("\\c / \\C", String(localized: "Ignore / match case")),
                .init(":noh", String(localized: "Clear search highlighting"))]
        }
    }
}

nonisolated struct VimCommandHint: Hashable {
    let keys: String
    let explanation: String

    init(_ keys: String, _ explanation: String) {
        self.keys = keys
        self.explanation = explanation
    }
}

nonisolated struct VimCommandReference {
    let command: VimCommandHint
    let modes: [VimMode]

    var modeDescription: String { modes.map(\.title).joined(separator: " · ") }

    func matches(_ query: String) -> Bool {
        let terms = query.split(whereSeparator: \.isWhitespace)
        let searchable = [command.keys, command.explanation, modeDescription]
            + modes.map(\.rawValue)
        return terms.allSatisfy { term in searchable.contains { $0.localizedStandardContains(term) } }
    }
}

nonisolated enum VimCommandCatalog {
    static let all: [VimCommandReference] = {
        var commands: [VimCommandHint] = []
        var modesByCommand: [VimCommandHint: [VimMode]] = [:]
        for mode in VimMode.allCases {
            for command in mode.commands {
                if modesByCommand[command] == nil { commands.append(command) }
                modesByCommand[command, default: []].append(mode)
            }
        }
        return commands.map { VimCommandReference(command: $0, modes: modesByCommand[$0] ?? []) }
    }()

    static func ordered(for mode: VimMode, query: String = "") -> [VimCommandReference] {
        let preferred = mode.commands
        let priorities = Dictionary(uniqueKeysWithValues: preferred.enumerated().map { ($0.element, $0.offset) })
        return all.enumerated().filter { $0.element.matches(query) }.sorted {
            let left = priorities[$0.element.command] ?? (preferred.count + $0.offset)
            let right = priorities[$1.element.command] ?? (preferred.count + $1.offset)
            return left < right
        }.map(\.element)
    }
}

/// Passive hints use the editor's visible status, never intercepted keystrokes:
/// mappings, macros and remote input would make a host-side input model drift.
nonisolated enum VimModeDetection {
    static let editors: Set<String> = ["vi", "vim", "nvim", "view", "rview", "rvim", "vimdiff", "nvimdiff", "gvim", "gview"]
    static let transports: Set<String> = ["ssh", "mosh-client", "tmux", "screen", "sudo", "doas"]

    static func canInspect(executable: String) -> Bool {
        editors.contains(executable) || transports.contains(executable)
    }

    static func detect(executable: String, title: String, text: String, previouslyDetected: Bool) -> VimMode? {
        guard canInspect(executable: executable) else { return nil }
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        // Keep physical rows: dropping blank lines can turn file contents into
        // a fake status line when Vim's actual command line is empty.
        let status = Array(lines.suffix(2))
        let visibleMode = status.compactMap(modeIndicator).last
        let hasFiller = lines.filter { $0 == "~" }.count >= 2
        let hasRuler = status.contains { matches(#"\b\d+,\d+(?:-\d+)?\s+(?:All|Top|Bot|\d+%)$"#, $0) }
        let hasFileMessage = status.contains { matches(#"^\".+\"\s+(?:\[|\d+L)"#, $0) }
        let hasEditorTitle = matches(#"(?i)(?:^(?:n?vim|vi|view)(?:\s|$)|\s[-–]\s(?:N?VIM|VI)$)"#, title)
        let welcome = text.contains("VIM - Vi IMproved") || text.contains("NVIM v")
        let isEditor = editors.contains(executable) || visibleMode != nil || welcome
            || (hasFiller && (hasRuler || hasFileMessage || hasEditorTitle || previouslyDetected))
            || hasRuler
        guard isEditor else { return nil }
        let commandLine = lines.last ?? ""
        if commandLine.hasPrefix(":") { return .commandLine }
        if commandLine.hasPrefix("/") || commandLine.hasPrefix("?") { return .search }
        return visibleMode ?? .normal
    }

    private static func modeIndicator(_ line: String) -> VimMode? {
        for (mode, pattern) in indicators where matches(pattern, line) { return mode }
        return nil
    }

    private static let indicators: [(VimMode, String)] = [
        (.visualBlock, #"(?i)^(?:--\s*)?(?:VISUAL[ -]BLOCK|V-BLOCK|可视\s*块|可視\s*ブロック)(?:\s|--|$)"#),
        (.visualLine, #"(?i)^(?:--\s*)?(?:VISUAL[ -]LINE|V-LINE|可视\s*行|可視\s*行)(?:\s|--|$)"#),
        (.visual, #"(?i)^(?:--\s*)?(?:VISUAL|可视|ビジュアル)(?:\s|--|$)"#),
        (.insert, #"(?i)^(?:--\s*)?(?:INSERT|插入|挿入)(?:\s|--|$)"#),
        (.replace, #"(?i)^(?:--\s*)?(?:V?REPLACE|替换|置換)(?:\s|--|$)"#),
        (.select, #"(?i)^(?:--\s*)?(?:SELECT(?:[ -](?:LINE|BLOCK))?|选择|選択)(?:\s|--|$)"#),
        (.normal, #"(?i)^(?:--\s*)?NORMAL(?:\s|--|$)"#),
        (.commandLine, #"(?i)^(?:--\s*)?COMMAND(?:\s|--|$)"#),
    ]

    private static func matches(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }
}
