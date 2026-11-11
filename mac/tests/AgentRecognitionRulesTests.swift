import AppKit
import Foundation
@testable import zshell
@main @MainActor struct AgentRecognitionRulesTests {
    static var checks = 0
    static func check(_ condition: Bool, _ message: String) {
        guard condition else { fatalError(message) }; checks += 1
    }
    static func rejects(_ text: String) {
        do { _ = try AgentRecognitionManifest.parse(text); fatalError("accepted invalid rules") } catch { checks += 1 }
    }
    static func main() throws {
        let text = """
        [[agents]]
        id = "frog"
        name = "原始工具名"
        executables = ["frog", "frog-cli"]
        aliases = ["frog-wrapper"]
        [[agents.rules]]
        id = "asking"
        state = "blocked"
        priority = 200
        region = "bottom_non_empty_lines(6)"
        visible_blocker = true
        line_regex = ['^Allow .+\\? \\[y/n\\]$']
        [[agents.rules]]
        id = "hopping"
        state = "working"
        any = [{ contains = ["hopping…"] }, { regex = ['[⠋⠙] Working'] }]
        """
        let manifests = try AgentRecognitionManifest.parse(text)
        check(try AgentRecognitionManifest.parse(text.replacingOccurrences(of:"\n",with:"\r\n")) == manifests,"CRLF format failed")
        check(manifests.count == 1 && manifests[0].name == "原始工具名", "lost raw name")
        check(manifests[0].kind == .program && manifests[0].identity.id == "frog", "custom borrowed provider")
        check(try AgentRecognitionManifest.parse(AgentRecognitionManifest.serialize(manifests)) == manifests, "roundtrip changed rules")
        let compiled = try AgentRecognitionCompiledManifest(manifests[0])
        check(compiled.detect("Allow update? [y/n]")?.attention == .input, "Kero example did not detect")
        check(compiled.detect("hopping…")?.phase == .working, "inline any did not match")
        check(compiled.detect("⠋ Working")?.phase == .working, "regex branch did not match")
        check(compiled.detect("quote\n" + String(repeating:"new\n",count:17)) == nil, "history became footer")
        let nested = text.replacingOccurrences(of: "any = [{ contains = [\"hopping…\"] }, { regex = ['[⠋⠙] Working'] }]", with: "[[agents.rules.any]]\ncontains = [\"hopping…\"]\n[[agents.rules.any]]\nregex = ['[⠋⠙] Working']")
        check(try AgentRecognitionManifest.parse(nested) == manifests, "array table conditions failed")
        for kind in ZshellAgentKind.allCases where kind != .program {
            let manifest = AgentRecognitionManifest.editableDefault(kind)
            check(try AgentRecognitionManifest.parse(AgentRecognitionManifest.serialize([manifest])) == [manifest], "invalid builtin edit template \(kind)")
        }
        var off = manifests[0]; off.screenEnabled = false
        check(try AgentRecognitionCompiledManifest(off).detect("hopping…") == nil, "screen disabled still matched")
        off.screenEnabled = true; off.rules[1].enabled = false
        check(try AgentRecognitionCompiledManifest(off).detect("hopping…") == nil, "disabled rule matched")
        for addition in ["typo = true", "executables = [\"/tmp/frog\"]", "executables = [\"node\"]", "min_engine_version = 4"] {
            rejects("[[agents]]\nid = \"bad\"\n" + addition)
        }
        rejects(text + "\n[[agents]]\nid = \"frog\"")
        rejects(text + "\n[[agents]]\nid = \"other\"\nexecutables = [\"frog-cli.exe\"]")
        rejects(text.replacingOccurrences(of:"bottom_non_empty_lines(6)",with:"top_non_empty_lines(20)"))
        rejects(text.replacingOccurrences(of:"'^[A]$'",with:"'(' ").replacingOccurrences(of:"'^Allow .+\\? \\[y/n\\]$'",with:"'('"))
        rejects(text.replacingOccurrences(of:"'^Allow .+\\? \\[y/n\\]$'",with:"'(a+)+'"))
        rejects(text.replacingOccurrences(of:"'^Allow .+\\? \\[y/n\\]$'",with:"'(a|aa)+'"))
        rejects("[[agents]]\nid = \"bad\"\nname = 123")
        rejects("[[agents]]\nid = \"bad\"\n[[agents.rules]]\nid=\"bad\"\nstate=\"done\"\ncontains=[\"Done\"]")
        rejects(String(repeating:"#x\n",count:100000))
        check(ZshellAgentKind.recognize(executablePath:"/bin/zsh",arguments:["zsh","-c","echo", "codex"]) == nil,"command payload recognized")
        check(ZshellAgentKind.recognize(executablePath:"/usr/bin/python3",arguments:["python3","-c","code", "aider"]) == nil,"python payload recognized")
        check(ZshellAgentKind.recognize(executablePath:"/opt/node",arguments:["node","--eval=foo","codex"]) == nil,"eval option recognized")
        check(ZshellAgentKind.recognize(executablePath:"/opt/node",arguments:["node","/a/@openai/codex/bin/codex.js","--prompt","claude"]) == .codex,"native script lost")
        var equal = manifests[0]
        equal.rules[0].gate = .init(contains:["hopping…"])
        equal.rules[0].priority = 100
        equal.rules[1].priority = 100
        check(try AgentRecognitionCompiledManifest(equal).detect("hopping…")?.phase == .blocked,"equal priority lost source order")
        equal.rules[0].skip = true
        let skip = try AgentRecognitionCompiledManifest(equal).match("hopping…")
        if case .skip = skip { checks += 1 } else { fatalError("skip did not preserve existing state") }
        check(ZshellAgentKind.recognize(executablePath:"/bin/zsh",arguments:["zsh","-lc","printf", "codex"]) == nil,"combined command payload recognized")
        check(ZshellAgentKind.recognize(executablePath:"/opt/node",arguments:["node","-efoo","codex"]) == nil,"short eval recognized")
        for command in ["claude", "codex", "gemini", "grok", "grok-1.0-macos-aarch64", "opencode", "cursor-agent", "aider-chat", "amp", "pi", "CLAUDE.EXE"] {
            rejects("[[agents]]\nid = \"my-tool\"\nexecutables = [\"\(command)\"]")
        }
        rejects("[[agents]]\nid = \"codex\"\naliases = [\"claude\"]")
        rejects("[[agents]]\nid = \"my-tool\"\naliases = [\"claude.js\"]")
        let ownBuiltin = try AgentRecognitionManifest.parse("[[agents]]\nid = \"claude-code\"\nexecutables = [\"CLAUDE.EXE\"]\naliases = [\"claude-wrapper\"]")
        check(ownBuiltin[0].id == "claude" && ownBuiltin[0].kind == .claude, "same built-in alias was rejected")
        let safePattern = text.replacingOccurrences(of: "'^Allow .+\\? \\[y/n\\]$'", with: "'^(Allow|Deny)[ ]*$'")
        let safeRules = try AgentRecognitionManifest.parse(safePattern)
        check(try AgentRecognitionCompiledManifest(safeRules[0]).detect("Allow  ")?.phase == .blocked,
              "character-class repetition was treated as group repetition")
        rejects(safePattern.replacingOccurrences(of: "'^(Allow|Deny)[ ]*$'", with: "'^(Allow|Deny)[ ]*(a|aa)+$'"))
        let emptyAny = text.replacingOccurrences(of: "any = [{ contains = [\"hopping…\"] }, { regex = ['[⠋⠙] Working'] }]", with: "contains = [\"hopping…\"]\nany = []")
        let emptyAnyRules = try AgentRecognitionManifest.parse(emptyAny)
        check(try AgentRecognitionCompiledManifest(emptyAnyRules[0]).detect("hopping…")?.phase == .working, "empty any added a constraint")
        check(try AgentRecognitionCompiledManifest(emptyAnyRules[0]).detect("unrelated") == nil, "empty any removed other conditions")
        print("Agent recognition model: \(checks) checks passed")
    }
}
