import Foundation

@main @MainActor
struct TerminalSessionDirectoryTests {
    static var checks = 0

    static func check(_ condition: Bool, _ label: String) {
        precondition(condition, label)
        checks += 1
    }

    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let fm = FileManager.default
        let home = root.appendingPathComponent("home").path
        let current = root.appendingPathComponent("current/subfolder").path
        let project = root.appendingPathComponent("current").path
        let custom = root.appendingPathComponent("custom space 中").path
        let explicit = root.appendingPathComponent("explicit").path
        let pinned = root.appendingPathComponent("pinned").path
        let group = root.appendingPathComponent("group").path
        for directory in [home, current, custom, explicit, pinned, group] {
            try fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }
        let context = TerminalSessionDirectory.Context(currentDirectory: current, projectDirectory: project)
        func resolve(_ policy: NewSessionDirectoryPolicy, explicit: String? = nil,
                     pin: String? = nil, group: String? = nil, custom: String? = nil,
                     context suppliedContext: TerminalSessionDirectory.Context? = nil) -> String {
            TerminalSessionDirectory.resolve(explicitDirectory: explicit, pinnedDirectory: pin,
                groupDirectory: group, context: suppliedContext ?? context, policy: policy,
                customDirectory: custom ?? root.appendingPathComponent("custom space 中").path,
                homeDirectory: home)
        }
        check(resolve(.current) == current, "current preserves the active shell subdirectory")
        check(resolve(.project) == project, "project uses the supplied panel root")
        check(resolve(.home) == home, "home uses the account home")
        check(resolve(.custom) == custom, "custom accepts spaces and Unicode")
        for policy in NewSessionDirectoryPolicy.allCases {
            check(resolve(policy, explicit: explicit, pin: pinned, group: group) == explicit,
                  "explicit wins over every policy")
            check(resolve(policy, pin: pinned, group: group) == pinned, "project pin wins over every policy")
            check(resolve(policy, group: group) == group, "group intent wins over every policy")
            check(resolve(policy, explicit: root.appendingPathComponent("missing").path) == home,
                  "unavailable explicit intent falls back to home without choosing global custom")
        }
        check(resolve(.current, context: .init()) == home, "no local context falls back to home")
        check(resolve(.project, context: .init(currentDirectory: current)) == current,
              "project without a known root follows the current directory")
        check(resolve(.custom, custom: "relative") == current, "relative custom input falls back to current")
        check(resolve(.custom, custom: root.appendingPathComponent("missing").path) == current,
              "missing custom directory falls back to current")
        try fm.createDirectory(atPath: home + "/work", withIntermediateDirectories: true)
        check(TerminalSessionDirectory.customDirectory("~/work", homeDirectory: home) == .success(home + "/work"),
              "home-relative custom input expands using the current account")
        check(TerminalSessionDirectory.customDirectory("~", homeDirectory: home) == .success(home), "bare tilde uses home")
        check(TerminalSessionDirectory.customDirectory("  ~/work  ", homeDirectory: home) == .success(home + "/work"),
              "custom input ignores surrounding whitespace")
        check(TerminalSessionDirectory.customDirectory("~someone/work", homeDirectory: home) == .failure(.invalidPath),
              "another user's tilde is not interpreted")
        check(TerminalSessionDirectory.customDirectory("", homeDirectory: home) == .failure(.invalidPath), "empty input is invalid")
        check(TerminalSessionDirectory.customDirectory("relative", homeDirectory: home) == .failure(.invalidPath), "relative input is invalid")
        check(TerminalSessionDirectory.customDirectory(custom + "\0", homeDirectory: home) == .failure(.invalidPath), "NUL input is invalid")
        let file = root.appendingPathComponent("file").path
        try "fixture".write(toFile: file, atomically: true, encoding: .utf8)
        check(TerminalSessionDirectory.customDirectory(file, homeDirectory: home) == .failure(.notDirectory), "files are rejected")
        check(resolve(.custom, custom: file) == current, "file custom input falls back to current")
        let denied = root.appendingPathComponent("denied").path
        try fm.createDirectory(atPath: denied, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: denied)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: denied) }
        check(TerminalSessionDirectory.customDirectory(denied, homeDirectory: home) == .failure(.inaccessibleDirectory),
              "directory without search permission is rejected before spawning")
        let link = root.appendingPathComponent("link").path
        try fm.createSymbolicLink(atPath: link, withDestinationPath: custom)
        check(resolve(.custom, custom: link) == link, "valid symlink folders remain usable")
        let physical = root.appendingPathComponent("physical/nested/deeper").path
        try fm.createDirectory(atPath: physical, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("alias").path
        try fm.createSymbolicLink(atPath: alias, withDestinationPath: physical)
        check(resolve(.current, explicit: alias + "/..") == alias + "/..",
              "explicit symlink parent semantics remain unchanged")
        let spaced = root.appendingPathComponent(" literal folder ").path
        try fm.createDirectory(atPath: spaced, withIntermediateDirectories: true)
        check(resolve(.custom, explicit: spaced) == spaced, "explicit directory whitespace remains literal")
        check(resolve(.custom, custom: spaced) == spaced, "folder-picker paths with trailing spaces remain literal")
        check(TerminalSessionDirectory.validatedOrHome(file, homeDirectory: home) == home,
              "terminal validation shares the same safe fallback")
        check(NewSessionDirectoryPolicy(persisted: "unknown") == .current, "unknown policy preserves the compatible default")
        check(NewSessionDirectoryPolicy(persisted: nil) == .current, "omitted policy preserves the compatible default")
        print("TerminalSessionDirectory: \(checks) checks passed")
    }
}
