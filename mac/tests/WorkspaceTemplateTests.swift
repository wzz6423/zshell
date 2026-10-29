import Darwin
import Foundation

@main @MainActor
struct WorkspaceTemplateTests {
    static var checks = 0

    static func check(_ condition: @autoclosure () -> Bool, _ label: String) {
        precondition(condition(), label)
        checks += 1
        print("PASS \(label)")
    }

    static func rejects(_ label: String, _ operation: () throws -> Void) {
        do { try operation(); preconditionFailure(label) }
        catch { check(true, label) }
    }

    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let project = root.appendingPathComponent("project", isDirectory: true)
        let other = root.appendingPathComponent("other", isDirectory: true)
        for directory in [project.appendingPathComponent("api"), project.appendingPathComponent("web"), other] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        typealias Snapshot = SessionSnapshot.ProjectSnapshot
        func terminal(_ directory: String) -> WorkspaceTemplate.Layout {
            .pane(Snapshot.PaneSnapshot(content: .session(workingDirectory: directory), weight: 1))
        }
        let layout: WorkspaceTemplate.Layout = .split(axis: .horizontal, fraction: 0.65,
            first: terminal("api"), second: .split(axis: .vertical, fraction: 0.3,
                first: terminal("web"), second: .pane(Snapshot.PaneSnapshot(content: .browser(url: "http://localhost:3000/docs"), weight: 1))))
        let recipe = WorkspaceTemplate(name: "Development", tabs: [
            .init(name: "App", layout: layout, focusedPaneIndex: 1, terminals: [
                .init(paneIndex: 0, program: "/bin/sh", arguments: ["-c", "printf '%s' 'quoted $text'; exec /bin/sh -i"]),
                .init(paneIndex: 1, initializationCommand: "printf 'INITIALIZATION\\n'"),
            ]),
            .init(layout: terminal(other.path), focusedPaneIndex: 0, terminals: [.init(paneIndex: 0)]),
        ], selectedTabIndex: 0)
        let encoded = try recipe.encoded()
        let decoded = try WorkspaceTemplate.decode(encoded)
        let roundTrip = try decoded.encoded()
        check(roundTrip == encoded, "shareable JSON round trip preserves nested layout, argv and names")
        check(decoded.paneCount == 4, "multiple tabs retain every terminal and browser leaf")
        let resolved = try decoded.resolved(forProjectRoot: project.path)
        let contents = WorkspaceTemplate.contents(in: resolved.tabs[0].layout)
        if case .session(let path) = contents[0] { check(path == project.appendingPathComponent("api").path, "relative directory resolves under a new project root") }
        else { preconditionFailure() }
        if case .session(let path) = WorkspaceTemplate.contents(in: resolved.tabs[1].layout)[0] { check(path == other.path, "outside-project absolute directory stays explicit") }
        else { preconditionFailure() }
        if case .split(let axis, let weight, _, .split(let innerAxis, let innerWeight, _, _)) = resolved.tabs[0].layout {
            check(axis == .horizontal && innerAxis == .vertical && weight == 0.65 && innerWeight == 0.3, "nested horizontal and vertical split weights survive resolution")
        } else { preconditionFailure() }
        check(WorkspaceTemplate.relativeDirectory(project.path, to: project.path) == ".", "project root captures as dot")
        check(WorkspaceTemplate.relativeDirectory(project.appendingPathComponent("api").path, to: project.path) == "api", "child path captures relative to the project")
        check(WorkspaceTemplate.relativeDirectory(project.path + "-other", to: project.path) == project.path + "-other", "similarly prefixed sibling is not mistaken for a child")
        check(WorkspaceTemplate.relativeDirectory("/tmp", to: "/") == "tmp", "filesystem-root projects preserve relative paths")
        check(WorkspaceTemplate.capturedBrowserURL("https://user:secret@example.test/docs?token=PRIVATE#auth") == "https://example.test/docs", "captured browser pages remove credentials and token-bearing URL components")
        check(WorkspaceTemplate.capturedBrowserURL("file:///private/document") == nil, "local files do not become shareable browser addresses")
        check(WorkspaceTemplate.capturedBrowserURL(nil) == nil, "blank browser panes stay blank")
        switch TerminalStartupCommand.resolve(program: "/bin/sh", arguments: ["", "two words", "$(literal)"]) {
        case .success(let command): check(command?.argv == ["/bin/sh", "", "two words", "$(literal)"], "startup validation preserves argv boundaries without expansion")
        case .failure: preconditionFailure()
        }
        check(TerminalStartupCommand.resolve(program: "", arguments: ["unexpected"]) == .failure(.invalidArguments), "arguments without a program are invalid")

        func mutated(_ operation: (inout WorkspaceTemplate) -> Void) throws {
            var value = recipe
            operation(&value)
            try value.validate()
        }
        for version in [0, 2, -1] {
            var object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
            object["version"] = version
            do { _ = try WorkspaceTemplate.decode(JSONSerialization.data(withJSONObject: object)); preconditionFailure() }
            catch WorkspaceTemplateError.unsupportedVersion(let actual) { check(actual == version, "unsupported version \(version) reports its version") }
        }
        for version: Any in [true, "1", 1.5] {
            var object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
            object["version"] = version
            rejects("invalid version type is rejected") { _ = try WorkspaceTemplate.decode(JSONSerialization.data(withJSONObject: object)) }
        }
        rejects("malformed JSON is rejected") { _ = try WorkspaceTemplate.decode(Data("{".utf8)) }
        rejects("foreign JSON is rejected") { _ = try WorkspaceTemplate.decode(Data("{}".utf8)) }
        rejects("oversized imports are rejected") { _ = try WorkspaceTemplate.decode(Data(repeating: 32, count: WorkspaceTemplate.maximumBytes + 1)) }
        rejects("blank template names are rejected") { try mutated { $0.name = "  " } }
        rejects("empty layouts are rejected") { try mutated { $0.tabs = [] } }
        rejects("out-of-range selected tabs are rejected") { try mutated { $0.selectedTabIndex = 5 } }
        rejects("out-of-range focused panes are rejected") { try mutated { $0.tabs[0].focusedPaneIndex = 4 } }
        rejects("duplicate terminal positions are rejected") { try mutated { $0.tabs[0].terminals[1].paneIndex = 0 } }
        rejects("missing terminal configuration is rejected") { try mutated { $0.tabs[0].terminals.removeLast() } }
        rejects("command configuration on a browser is rejected") { try mutated { $0.tabs[0].terminals.append(.init(paneIndex: 2)) } }
        var pathProgram = recipe
        pathProgram.tabs[0].terminals[0].program = "sh"
        _ = try pathProgram.encoded()
        _ = try pathProgram.resolved(forProjectRoot: project.path)
        check(true, "PATH startup programs remain portable and are checked on application")
        pathProgram.tabs[0].terminals[0].program = "zshell-missing-template-program"
        _ = try pathProgram.encoded()
        rejects("missing PATH programs are rejected before application") { _ = try pathProgram.resolved(forProjectRoot: project.path) }
        let relativeProgram = project.appendingPathComponent("api/start")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: relativeProgram)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: relativeProgram.path)
        pathProgram.tabs[0].terminals[0].program = "./start"
        _ = try pathProgram.encoded()
        _ = try pathProgram.resolved(forProjectRoot: project.path)
        check(true, "relative programs are checked in their target pane directory")
        pathProgram.tabs[0].terminals[0].program = "./missing"
        rejects("missing relative programs are rejected before application") { _ = try pathProgram.resolved(forProjectRoot: project.path) }
        rejects("NUL arguments are rejected") { try mutated { $0.tabs[0].terminals[0].arguments = ["bad\0argument"] } }
        rejects("an initialization command with direct argv is rejected") { try mutated { $0.tabs[0].terminals[0].initializationCommand = "echo ignored" } }
        rejects("parent-relative directories are rejected") { try mutated { $0.tabs[1].layout = terminal("../other") } }
        rejects("tilde directories are rejected") { try mutated { $0.tabs[1].layout = terminal("~/secret") } }
        rejects("nonexistent target directory is rejected before creation") {
            var value = recipe
            value.tabs[1].layout = terminal("missing")
            _ = try value.resolved(forProjectRoot: project.path)
        }
        var unavailableProgram = recipe
        unavailableProgram.tabs[0].terminals[0].program = "/does/not/exist"
        _ = try unavailableProgram.encoded()
        check(true, "import validation permits a program that may exist on another Mac")
        rejects("applying validates target executable availability") { _ = try unavailableProgram.resolved(forProjectRoot: project.path) }
        for fraction in [0.0, 1.0, -0.1, Double.infinity, Double.nan] {
            rejects("invalid split fractions are rejected") {
                try mutated { $0.tabs[1].layout = .split(axis: .vertical, fraction: fraction, first: terminal("."), second: terminal(".")) }
            }
        }
        for content: Snapshot.PaneContentSnapshot in [
            .file(path: "/private/dirty.swift", editorState: nil),
            .diff(repoRoot: "/private", path: "file", staged: true, untracked: false, origPath: nil),
            .browser(url: "javascript:alert(1)"), .browser(url: "https://user:pass@example.test"),
        ] {
            rejects("nonshareable pane content is rejected") { try mutated { $0.tabs[1].layout = .pane(.init(content: content, weight: 1)) } }
        }
        for key in ["terminalID", "historyKey", "agentResume", "remoteSessionID", "authID", "cookies", "storageState"] {
            var object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
            object[key] = NSNull()
            rejects("import rejects runtime field \(key), even when null") { _ = try WorkspaceTemplate.decode(JSONSerialization.data(withJSONObject: object)) }
        }
        var livePane = Snapshot.PaneSnapshot(content: .session(workingDirectory: "."), weight: 1, terminalID: UUID())
        rejects("runtime terminal identities are rejected from in-memory templates") { try mutated { $0.tabs[1].layout = .pane(livePane) } }
        livePane.terminalID = nil
        livePane.historyKey = "history"
        rejects("runtime history keys are rejected from in-memory templates") { try mutated { $0.tabs[1].layout = .pane(livePane) } }
        var deep = terminal(".")
        for _ in 0..<20 { deep = .split(axis: .horizontal, fraction: 0.5, first: terminal("."), second: deep) }
        rejects("excessive recursive layout depth is rejected") { try mutated { $0.tabs[1].layout = deep } }

        let libraryURL = root.appendingPathComponent("library/templates.json")
        let store = WorkspaceTemplateStore(url: libraryURL)
        let id = try store.add(recipe)
        try store.rename(id, to: "  Shared Development  ")
        check(store.entries.first?.template.name == "Shared Development", "template rename normalizes its label")
        let exportURL = root.appendingPathComponent("export.json")
        try store.exportTemplate(id, to: exportURL)
        let before = store.entries.count
        _ = try store.importTemplate(from: exportURL)
        check(store.entries.count == before + 1 && store.entries[0].id != store.entries[1].id, "import gives a fresh local library identity")
        let exported = String(data: try Data(contentsOf: exportURL), encoding: .utf8)!
        check(!exported.contains(id.uuidString), "export omits the local library identity")
        let permissions = try FileManager.default.attributesOfItem(atPath: libraryURL.path)[.posixPermissions] as! NSNumber
        check(permissions.intValue == 0o600, "template library uses private permissions")
        let loaded = WorkspaceTemplateStore(url: libraryURL)
        check(loaded.loadError == nil && loaded.entries.count == 2, "saved templates reload without losing their layout")
        try loaded.delete(id)
        check(loaded.entries.count == 1, "deleting a template removes only that library entry")
        let corruptURL = root.appendingPathComponent("corrupt.json")
        try Data("invalid".utf8).write(to: corruptURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: corruptURL.path)
        let corrupt = WorkspaceTemplateStore(url: corruptURL)
        check(corrupt.loadError != nil, "unreadable libraries retain a visible error")
        rejects("saving cannot overwrite a corrupt library") { _ = try corrupt.add(recipe) }
        let corruptData = try Data(contentsOf: corruptURL)
        check(corruptData == Data("invalid".utf8), "failed library recovery preserves the original bytes")
        let invalidURL = root.appendingPathComponent("invalid.json")
        try Data("{}".utf8).write(to: invalidURL)
        let count = store.entries.count
        rejects("invalid import does not change the library") { _ = try store.importTemplate(from: invalidURL) }
        check(store.entries.count == count, "failed import leaves existing templates intact")
        let fifo = root.appendingPathComponent("fifo.json")
        precondition(mkfifo(fifo.path, 0o600) == 0)
        let start = Date()
        rejects("nonregular imports cannot block the UI") { _ = try store.importTemplate(from: fifo) }
        check(Date().timeIntervalSince(start) < 0.5, "FIFO import returns immediately")
        check(!FileManager.default.fileExists(atPath: project.appendingPathComponent("sentinel").path), "decode, resolve and library operations do not execute startup commands")
        print("Workspace template probe: \(checks) passed, 0 failed")
    }
}
