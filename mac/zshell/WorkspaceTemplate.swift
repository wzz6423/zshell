import Foundation

/// A shareable recipe, deliberately separate from a restorable live session.
/// The existing recursive layout owns split axes and weights; terminal launch
/// configuration is indexed by leaf position rather than any runtime identity.
struct WorkspaceTemplate: Codable {
    typealias Layout = SessionSnapshot.ProjectSnapshot.LayoutSnapshot
    typealias Content = SessionSnapshot.ProjectSnapshot.PaneContentSnapshot

    struct Terminal: Codable {
        var paneIndex: Int
        var program: String?
        var arguments: [String] = []
        var initializationCommand: String?

        var argv: [String]? { program.map { [$0] + arguments } }
    }

    struct Tab: Codable {
        var name: String?
        var layout: Layout
        var focusedPaneIndex: Int
        var terminals: [Terminal]
    }

    static let currentVersion = 1
    static let fileFormat = "zshell-workspace-template"
    static let maximumBytes = 1_048_576
    static let maximumPanes = 128
    static let maximumTabs = 32

    var format = fileFormat
    var version = currentVersion
    var name: String
    var tabs: [Tab]
    var selectedTabIndex: Int
    var simplifiedPaneCount = 0

    var paneCount: Int { tabs.reduce(0) { $0 + Self.contents(in: $1.layout).count } }

    static func decode(_ data: Data) throws -> WorkspaceTemplate {
        guard data.count <= maximumBytes else { throw WorkspaceTemplateError.fileTooLarge }
        let object: Any
        do { object = try JSONSerialization.jsonObject(with: data) }
        catch { throw WorkspaceTemplateError.invalidFile }
        guard let envelope = object as? [String: Any],
              envelope["format"] as? String == fileFormat,
              let version = envelope["version"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(),
              version.doubleValue == Double(version.intValue) else {
            throw WorkspaceTemplateError.invalidFile
        }
        guard version.intValue == currentVersion else {
            throw WorkspaceTemplateError.unsupportedVersion(version.intValue)
        }
        // Bound nesting before Codable traverses the recursive enum. This
        // also prevents a small, deeply nested import from exhausting the stack.
        try checkJSONDepth(object, depth: 0)
        let template: WorkspaceTemplate
        do { template = try JSONDecoder().decode(Self.self, from: data) }
        catch { throw WorkspaceTemplateError.invalidFile }
        try template.validate()
        return template
    }

    func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumBytes else { throw WorkspaceTemplateError.fileTooLarge }
        return data
    }

    func validate() throws {
        guard format == Self.fileFormat else { throw WorkspaceTemplateError.invalidFile }
        guard version == Self.currentVersion else { throw WorkspaceTemplateError.unsupportedVersion(version) }
        guard Self.validName(name) else { throw WorkspaceTemplateError.invalidName }
        guard !tabs.isEmpty, tabs.count <= Self.maximumTabs,
              tabs.indices.contains(selectedTabIndex) else { throw WorkspaceTemplateError.invalidLayout }
        var totalPanes = 0
        for tab in tabs {
            if let name = tab.name, !Self.validName(name) { throw WorkspaceTemplateError.invalidLayout }
            var contents: [Content] = []
            try Self.validate(tab.layout, depth: 0, contents: &contents)
            totalPanes += contents.count
            guard totalPanes <= Self.maximumPanes, contents.indices.contains(tab.focusedPaneIndex) else {
                throw WorkspaceTemplateError.invalidLayout
            }
            let terminalIndexes = contents.indices.filter {
                if case .session = contents[$0] { return true }
                return false
            }
            guard tab.terminals.count == terminalIndexes.count,
                  Set(tab.terminals.map(\.paneIndex)) == Set(terminalIndexes) else {
                throw WorkspaceTemplateError.invalidLayout
            }
            for terminal in tab.terminals {
                if let program = terminal.program {
                    guard Self.validText(program, maximum: 4096),
                          program == program.trimmingCharacters(in: .whitespacesAndNewlines) else {
                        throw WorkspaceTemplateError.invalidCommand
                    }
                } else if !terminal.arguments.isEmpty { throw WorkspaceTemplateError.invalidCommand }
                guard terminal.arguments.count <= 256,
                      terminal.arguments.allSatisfy({ Self.validText($0, maximum: 32_768, allowsEmpty: true) }),
                      terminal.arguments.reduce(0, { $0 + $1.utf8.count }) <= 32_768 else {
                    throw WorkspaceTemplateError.invalidCommand
                }
                if let command = terminal.initializationCommand,
                   (!Self.validText(command, maximum: 32_768) || terminal.program != nil) {
                    throw WorkspaceTemplateError.invalidCommand
                }
            }
        }
        guard (0...totalPanes).contains(simplifiedPaneCount) else { throw WorkspaceTemplateError.invalidLayout }
    }

    /// Resolves all paths and executables before the caller creates any pane.
    /// Importing remains portable when an executable only exists on its target.
    func resolved(forProjectRoot root: String) throws -> WorkspaceTemplate {
        try validate()
        guard root.hasPrefix("/"), Self.validText(root, maximum: 4096) else {
            throw WorkspaceTemplateError.missingDirectory(root)
        }
        let rootURL = URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL
        try Self.requireDirectory(rootURL.path)
        var result = self
        for index in result.tabs.indices {
            result.tabs[index].layout = try Self.resolve(result.tabs[index].layout, root: rootURL)
            let contents = Self.contents(in: result.tabs[index].layout)
            for terminal in result.tabs[index].terminals {
                guard let program = terminal.program else { continue }
                guard case .session(let directory) = contents[terminal.paneIndex] else {
                    throw WorkspaceTemplateError.invalidLayout
                }
                if case .failure = TerminalStartupCommand.resolve(
                    program: program, arguments: terminal.arguments, workingDirectory: directory
                ) {
                    throw WorkspaceTemplateError.programNotExecutable(program)
                }
            }
        }
        return result
    }

    static func relativeDirectory(_ directory: String, to root: String) -> String {
        let path = URL(fileURLWithPath: directory, isDirectory: true).standardizedFileURL.path
        let root = URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL.path
        if path == root { return "." }
        let prefix = root == "/" ? "/" : root + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    /// Runtime browser storage is never inspected. Captured addresses omit
    /// userinfo, queries and fragments, which can carry one-time login tokens.
    static func capturedBrowserURL(_ raw: String?) -> String? {
        guard let raw, var components = URLComponents(string: raw),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              components.host?.isEmpty == false else { return nil }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.string
    }

    static func contents(in layout: Layout) -> [Content] {
        switch layout {
        case .pane(let pane): return [pane.content]
        case .split(_, _, let first, let second): return contents(in: first) + contents(in: second)
        }
    }

    private static func validate(_ layout: Layout, depth: Int, contents: inout [Content]) throws {
        guard depth <= 16, contents.count < maximumPanes else { throw WorkspaceTemplateError.invalidLayout }
        switch layout {
        case .pane(let pane):
            guard pane.historyKey == nil, pane.agentResume == nil, pane.terminalID == nil,
                  pane.remoteSessionID == nil, pane.worktree == nil else {
                throw WorkspaceTemplateError.runtimeState
            }
            guard pane.weight == 1 else { throw WorkspaceTemplateError.invalidLayout }
            switch pane.content {
            case .session(let directory):
                guard validText(directory, maximum: 4096),
                      directory.hasPrefix("/") || !directory.split(separator: "/").contains(".."),
                      !directory.hasPrefix("~") else { throw WorkspaceTemplateError.invalidDirectory }
            case .browser(let rawURL):
                if let rawURL {
                    guard validText(rawURL, maximum: 8192), let url = URLComponents(string: rawURL),
                          ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                          url.host?.isEmpty == false, url.user == nil, url.password == nil else {
                        throw WorkspaceTemplateError.invalidBrowserURL
                    }
                }
            case .file, .diff, .commitDiff: throw WorkspaceTemplateError.runtimeState
            }
            contents.append(pane.content)
        case .split(_, let fraction, let first, let second):
            guard fraction.isFinite, fraction > 0, fraction < 1 else { throw WorkspaceTemplateError.invalidLayout }
            try validate(first, depth: depth + 1, contents: &contents)
            try validate(second, depth: depth + 1, contents: &contents)
        }
    }

    private static func resolve(_ layout: Layout, root: URL) throws -> Layout {
        switch layout {
        case .pane(var pane):
            if case .session(let directory) = pane.content {
                let path = (directory.hasPrefix("/") ? URL(fileURLWithPath: directory)
                    : root.appendingPathComponent(directory)).standardizedFileURL.path
                try requireDirectory(path)
                pane.content = .session(workingDirectory: path)
            }
            return .pane(pane)
        case .split(let axis, let fraction, let first, let second):
            return .split(axis: axis, fraction: fraction,
                          first: try resolve(first, root: root), second: try resolve(second, root: root))
        }
    }

    private static func requireDirectory(_ path: String) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw WorkspaceTemplateError.missingDirectory(path)
        }
    }

    private static func validText(_ text: String, maximum: Int, allowsEmpty: Bool = false) -> Bool {
        (allowsEmpty || !text.isEmpty) && text.utf8.count <= maximum && !text.contains("\0")
    }

    private static func validName(_ name: String) -> Bool {
        validText(name, maximum: 512) && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func checkJSONDepth(_ value: Any, depth: Int) throws {
        guard depth <= 64 else { throw WorkspaceTemplateError.invalidLayout }
        if let object = value as? [String: Any] {
            let runtimeKeys: Set<String> = [
                "terminalID", "remoteSessionID", "historyKey", "agentResume", "worktree",
                "conversationHistoryProjectID", "contextSessionIndex", "credentialID",
                "authID", "cookies", "localStorage", "storageState",
            ]
            guard runtimeKeys.isDisjoint(with: object.keys) else { throw WorkspaceTemplateError.runtimeState }
            for value in object.values { try checkJSONDepth(value, depth: depth + 1) }
        } else if let array = value as? [Any] {
            for value in array { try checkJSONDepth(value, depth: depth + 1) }
        }
    }
}

enum WorkspaceTemplateError: LocalizedError {
    case invalidFile, fileTooLarge, invalidName, invalidLayout, runtimeState, invalidDirectory
    case invalidCommand, invalidBrowserURL, libraryUnavailable
    case unsupportedVersion(Int), missingDirectory(String), programNotExecutable(String)

    var errorDescription: String? {
        switch self {
        case .invalidFile: return String(localized: "Choose a valid Zshell workspace template JSON file.")
        case .fileTooLarge: return String(localized: "Workspace template files must be 1 MB or smaller.")
        case .invalidName: return String(localized: "Enter a template name.")
        case .unsupportedVersion(let version): return String(localized: "Workspace template version \(version) is not supported.")
        case .invalidLayout: return String(localized: "The template layout or pane positions are invalid.")
        case .runtimeState: return String(localized: "Templates cannot contain live session, history, agent, worktree, editor or diff state.")
        case .invalidDirectory: return String(localized: "Use a project-relative directory without “..”, or an absolute directory.")
        case .missingDirectory(let path): return String(localized: "The directory “\(path)” is unavailable. Choose another project root or edit the template.")
        case .invalidCommand: return String(localized: "Use a valid startup program and arguments, or a login-shell initialization command.")
        case .programNotExecutable(let program): return String(localized: "The startup program “\(program)” is not an executable file on this Mac.")
        case .invalidBrowserURL: return String(localized: "Template browser pages must use HTTP or HTTPS URLs without embedded credentials.")
        case .libraryUnavailable: return String(localized: "The workspace template library could not be loaded. Restore or remove the library file before saving templates.")
        }
    }
}
