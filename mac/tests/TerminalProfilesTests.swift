import Darwin
import Foundation

@main
struct TerminalProfilesTests {
    static func main() throws {
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            guard condition else { fatalError(message) }
            checks += 1
        }
        let samples: [(String, String, Bool)] = [
            ("*", "", true), ("", "", true), ("", "text", false),
            ("/work/*", "/work/a/b", true), ("/work/*", "/else/work", false),
            ("dev-?", "dev-1", true), ("dev-?", "dev-12", false),
            ("a*b?c", "axxxbyc", true), ("a*b?c", "axxxbc", false),
            ("*a*a*b", "aaaaab", true), ("*a*a*b", "aaaaac", false),
            ("项目/?", "项目/字", true), ("a.b", "axb", false),
        ]
        for (pattern, value, expected) in samples {
            check(TerminalProfileGlob.matches(pattern, value) == expected, "glob \(pattern) \(value)")
        }
        check(!TerminalProfileGlob.matches(String(repeating: "*", count: 257), "x"), "pattern bound")
        check(!TerminalProfileGlob.matches("*", String(repeating: "x", count: 4097)), "metadata bound")
        check(!TerminalProfileGlob.matches("*", "x\0y"), "no NUL metadata")

        var first = TerminalProfile(name: "Production")
        first.host = "PROD-*"
        first.user = "root"
        first.directory = "/srv/*"
        first.program = "vim"
        first.appearance = .init(themeDark: "Dracula", fontFamily: "Fixture Mono", fontSize: 18,
                                 cursorShape: "block", cursorBlinking: false)
        first.launchSettings = .init(environmentVariables: [.init(name: "MODE", value: "production")],
                                     initializationCommand: "echo initialized")
        first.startupProgram = "/bin/zsh"
        first.startupArguments = "-l"
        var fallback = TerminalProfile(name: "Fallback")
        fallback.appearance.fontSize = 12
        let context = TerminalProfileContext(host: "prod-01", user: "root", directory: "/srv/app", program: "/usr/bin/vim")
        check(context.matches(first), "all four conditions and executable basename")
        check(TerminalProfile.firstMatch(in: [first, fallback], context: context)?.id == first.id, "ordered first match")
        check(TerminalProfile.firstMatch(in: [fallback, first], context: context)?.id == fallback.id, "explicit order wins")
        var disabled = first
        disabled.enabled = false
        check(TerminalProfile.firstMatch(in: [disabled, fallback], context: context)?.id == fallback.id, "disabled rule skipped")
        for partial in [
            TerminalProfileContext(host: "prod-01", user: "root", directory: "/else", program: "/usr/bin/vim"),
            TerminalProfileContext(host: "prod-01", user: "other", directory: "/srv/app", program: "/usr/bin/vim"),
            TerminalProfileContext(host: "prod-01", user: "root", directory: "/srv/app", program: "/usr/bin/zsh"),
            TerminalProfileContext(host: nil, user: "root", directory: "/srv/app", program: "/usr/bin/vim"),
        ] { check(!partial.matches(first), "AND and unknown values do not match") }
        check(TerminalProfile.firstMatch(in: [first], context: .init()) == nil, "no match restores original")
        check(TerminalProfile.firstMatch(in: [fallback], context: .init())?.id == fallback.id, "empty fields wildcard")
        check(context.matches(TerminalProfile(name: "Host alias", host: "prod-*")), "case insensitive hosts")

        let base = TerminalLaunchSettings(environmentVariables: [.init(name: "MODE", value: "base"), .init(name: "KEEP", value: "yes")],
                                          initializationCommand: "base init")
        let applied = first.applyingLaunchSettings(to: base)
        check(applied.environment == ["MODE": "production", "KEEP": "yes"], "launch variable overlay")
        check(base.environment["MODE"] == "base", "base launch immutable")
        check(applied.initializationCommand == "echo initialized", "launch initialization override")
        check(fallback.applyingLaunchSettings(to: base) == base, "unspecified launch settings inherited")

        let remoteOnlyProgram = "/zshell-profile-fixture/remote-only"
        check(TerminalStartupCommand.resolve(program: remoteOnlyProgram, arguments: "'hello world'")
              == .failure(.programNotExecutable), "local startup requires an executable")
        check(TerminalStartupCommand.resolve(program: "  \(remoteOnlyProgram)  ", arguments: "'hello world'",
                                             requireLocalExecutable: false)
              == .success(.init(program: remoteOnlyProgram, arguments: ["hello world"])),
              "remote startup accepts an absolute remote-only executable")
        check(TerminalStartupCommand.resolve(program: "relative", arguments: "", requireLocalExecutable: false)
              == .failure(.programNotExecutable), "remote startup rejects relative programs")
        check(TerminalStartupCommand.resolve(program: remoteOnlyProgram, arguments: "'unterminated",
                                             requireLocalExecutable: false)
              == .failure(.invalidArguments), "remote startup rejects malformed arguments")

        let lines = TerminalProfile.configLines([first, fallback])
        let parsed = TOML.parseStrictly(text: lines.joined(separator: "\n"))
        check(parsed.malformed == nil, "config serialized with existing TOML")
        check(TerminalProfile.read(parsed.values) == [first, fallback], "config round trip preserves order and values")
        var invalid = first
        invalid.launchSettings.environmentVariables.append(.init(name: "ZSHELL_CLI_TOKEN", value: "x"))
        check(!invalid.isValid, "capability variables rejected")
        invalid = first
        invalid.launchSettings.environmentVariables.append(.init(name: "MODE", value: "duplicate"))
        check(!invalid.isValid, "duplicate environment variables rejected")
        invalid = first
        invalid.appearance.fontSize = .infinity
        check(!invalid.isValid, "invalid font size rejected")
        invalid = first
        invalid.directory = String(repeating: "x", count: 257)
        check(!invalid.isValid, "invalid condition rejected")
        invalid = first
        invalid.appearance.cursorShape = "invisible"
        check(!invalid.isValid, "unsupported cursor rejected")
        let malformed = TOML.parseStrictly(text: TerminalProfile.configLines([invalid]).joined(separator: "\n"))
        check(TerminalProfile.read(malformed.values).isEmpty, "invalid persisted profiles skipped")
        check(TerminalProfile.configLines(Array(repeating: fallback, count: 65)).filter { $0.contains(".id =") }.count == 64, "profile limit")

        let pid = getpid()
        check(processWorkingDirectory(pid: pid) != nil, "real kernel cwd")
        check(processExecutablePath(pid: pid)?.hasPrefix("/") == true, "real kernel executable")
        check(processEffectiveUser(pid: pid) == NSUserName(), "real kernel user")
        check(processEffectiveUser(pid: -1) == nil, "unknown process stays unknown")
        print("PASS: \(checks) automatic terminal profile model/config/kernel checks")
    }
}
