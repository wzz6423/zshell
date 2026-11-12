import AppKit
import Combine
import Foundation

nonisolated struct AgentRecognitionIdentity: Equatable, Sendable {
    let id: String
    let name: String
    let kind: ZshellAgentKind
}

nonisolated struct AgentRecognitionManifest: Equatable, Sendable {
    static let maximumFileBytes = 256 << 10
    static let maximumAgents = 64
    static let maximumRules = 32

    var id: String
    var name: String
    var executables: [String]
    var aliases: [String] = []
    var screenEnabled = true
    var rules: [AgentRecognitionScreenRule]

    var kind: ZshellAgentKind { Self.builtinKind(id) ?? .program }
    var identity: AgentRecognitionIdentity { .init(id: id, name: name, kind: kind) }

    static func builtinKind(_ id: String) -> ZshellAgentKind? {
        switch id.lowercased() {
        case "claude-code": return .claude
        case "gemini-cli": return .gemini
        case "grok-build": return .grok
        case "cursor": return .cursor
        case "aider-chat": return .aider
        default: return ZshellAgentKind(rawValue: id.lowercased()).flatMap { $0 == .program ? nil : $0 }
        }
    }

    static func commandName(_ value: String) -> String {
        var name = (value as NSString).lastPathComponent.lowercased()
        for suffix in [".exe", ".js", ".mjs", ".cjs", ".py"] where name.hasSuffix(suffix) {
            name.removeLast(suffix.count)
            break
        }
        return name
    }

    static func parse(_ text: String) throws -> [Self] {
        let tables = try AgentRulesTOML.parse(text)
        guard tables.count <= maximumAgents else { throw failure("", String(localized: "Use at most 64 agents.")) }
        var result: [Self] = []
        var ids: Set<String> = []
        var names: [String: String] = [:]
        for table in tables {
            let id = table["id"]?.string ?? ""
            guard validID(id), Set(table.keys).isSubset(of: [
                "id", "name", "executables", "aliases", "screen_enabled", "rules", "min_engine_version", "version", "updated_at",
            ]) else { throw failure(id, String(localized: "Use a unique agent ID and supported keys.")) }
            let canonical = builtinKind(id)?.rawValue ?? id
            guard ids.insert(canonical).inserted else { throw failure(id, String(localized: "An agent ID appears more than once.")) }
            let version = try integer(table, "min_engine_version", default: 3, id: id)
            guard (0...3).contains(version) else { throw failure(id, String(localized: "This rule format requires a newer engine.")) }
            let name = try string(table, "name", default: builtinKind(id)?.displayName ?? id, id: id)
            guard validText(name, maximum: 128), !name.isEmpty else { throw failure(id, String(localized: "Enter a name of at most 128 bytes.")) }
            let executables = try strings(table, "executables", id: id)
            let aliases = try strings(table, "aliases", id: id)
            let effectiveExecutables = executables.isEmpty && builtinKind(id) == nil ? [id] : executables
            guard effectiveExecutables.count + aliases.count <= 32 else { throw failure(id, String(localized: "Use at most 32 executable names and aliases.")) }
            for executable in effectiveExecutables + aliases {
                guard validID(executable), !ZshellAgentKind.isScriptInterpreter(commandName(executable)) else {
                    throw failure(id, String(localized: "Use executable names without paths; shell and interpreter names are reserved."))
                }
                let normalized = commandName(executable)
                if let builtin = ZshellAgentKind.recognize(executablePath: nil, arguments: [normalized]),
                   builtin.rawValue != canonical {
                    throw failure(id, String(localized: "An executable name is assigned to more than one agent."))
                }
                guard names[normalized] == nil || names[normalized] == canonical else {
                    throw failure(id, String(localized: "An executable name is assigned to more than one agent."))
                }
                names[normalized] = canonical
            }
            let screenEnabled = try boolean(table, "screen_enabled", default: true, id: id)
            let rawRules = table["rules"]?.array ?? []
            guard table["rules"] == nil || table["rules"]?.array != nil, rawRules.count <= maximumRules else {
                throw failure(id, String(localized: "Use at most 32 screen rules per agent."))
            }
            var ruleIDs: Set<String> = []
            let rules = try rawRules.map { value -> AgentRecognitionScreenRule in
                guard let fields = value.table else { throw failure(id, String(localized: "Screen rules must be tables.")) }
                let rule = try AgentRecognitionScreenRule.parse(fields, agentID: id)
                guard ruleIDs.insert(rule.id).inserted else { throw failure(id, String(localized: "A screen rule ID appears more than once.")) }
                return rule
            }
            result.append(.init(id: canonical, name: name, executables: effectiveExecutables,
                                aliases: aliases, screenEnabled: screenEnabled, rules: rules))
        }
        return result
    }

    static func serialize(_ manifests: [Self]) -> String {
        manifests.map { manifest in
            var lines = ["[[agents]]", "id = \(TOML.quote(manifest.id))"]
            lines.append("name = \(TOML.quote(manifest.name))")
            if !manifest.executables.isEmpty { lines.append("executables = \(array(manifest.executables))") }
            if !manifest.aliases.isEmpty { lines.append("aliases = \(array(manifest.aliases))") }
            if !manifest.screenEnabled { lines.append("screen_enabled = false") }
            for rule in manifest.rules {
                lines += ["", "[[agents.rules]]", "id = \(TOML.quote(rule.id))",
                          "state = \(TOML.quote(rule.phase.rawValue))", "priority = \(rule.priority)",
                          "region = \(TOML.quote(rule.region))"]
                if let attention = rule.attention { lines.append("attention = \(TOML.quote(attention.rawValue))") }
                if !rule.enabled { lines.append("enabled = false") }
                if rule.skip { lines.append("skip_state_update = true") }
                lines += rule.gate.fields()
            }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n") + (manifests.isEmpty ? "" : "\n")
    }

    static func array(_ values: [String]) -> String { "[" + values.map(TOML.quote).joined(separator: ", ") + "]" }

    static func editableDefault(_ kind: ZshellAgentKind) -> Self {
        func ignoringCase(_ text: String) -> String {
            NSRegularExpression.escapedPattern(for: text).map { character in
                character.isASCII && character.isLetter ? "[\(character.lowercased())\(character.uppercased())]" : String(character)
            }.joined()
        }
        func approval(_ id: String, heading: [String]) -> AgentRecognitionScreenRule {
            .init(id: id, phase: .blocked, priority: 200, attention: .approval,
                  gate: .init(lineRegex: ["^[ \\t]*(" + heading.map(ignoringCase).joined(separator: "|") + ")[ \\t]*$"],
                              any: [.init(contains: ["esc to cancel"]), .init(contains: ["press enter to confirm"])]))
        }
        var rules: [AgentRecognitionScreenRule] = []
        switch kind {
        case .codex:
            rules.append(approval("approval", heading: ["Would you like to run the following command?"]))
            rules.append(.init(id: "login", phase: .blocked, priority: 200, attention: .login,
                               gate: .init(contains: ["sign in with chatgpt", "sign in with an api key"])))
        case .claude:
            rules.append(approval("approval", heading: ["Do you want to proceed?", "Do you want to make this edit?"]))
            rules.append(.init(id: "login", phase: .blocked, priority: 200, attention: .login,
                               gate: .init(contains: ["/login", "not logged in"])))
        case .gemini:
            rules.append(.init(id: "approval", phase: .blocked, priority: 200, attention: .approval,
                               gate: .init(contains: ["allow execution of:", "allow once", "deny"])))
        case .aider:
            rules.append(.init(id: "question", phase: .blocked, priority: 200, region: "bottom_non_empty_lines(1)", attention: .input,
                               gate: .init(lineRegex: ["^.*" + ignoringCase("(y)es/(n)o [yes]:") + "[ \\t]*$"])))
        default: break
        }
        let interrupt = ignoringCase("esc to interrupt")
        rules.append(.init(id: "activity", phase: .working, priority: 100,
                           gate: .init(lineRegex: ["^[ \\t]*(" + interrupt + "|.{0,139} · " + interrupt
                                                  + "|.{0,141}\\(" + interrupt + "\\)|" + ignoringCase("esc to cancel ·") + ".{0,144})[ \\t]*$"])))
        return .init(id: kind.rawValue, name: kind.displayName, executables: [], rules: rules)
    }

    static var newAgentExample: Self {
        .init(id: "my-agent", name: "My Agent", executables: ["my-agent"], rules: [
            .init(id: "approval", phase: .blocked, priority: 200, region: "bottom_non_empty_lines(6)", attention: .approval,
                  gate: .init(lineRegex: ["^Allow .+\\? \\[y/n\\]$"])),
            .init(id: "activity", phase: .working, priority: 100, gate: .init(contains: ["working…"])),
        ])
    }
    static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0))
        }
    }
    static func validText(_ value: String, maximum: Int) -> Bool {
        value.utf8.count <= maximum && value.unicodeScalars.allSatisfy { $0.value >= 0x20 && !(0x7f...0x9f).contains($0.value) }
    }

    struct Failure: LocalizedError {
        let id: String
        let reason: String
        var errorDescription: String? { id.isEmpty ? reason : "\(id): \(reason)" }
    }
    static func failure(_ id: String, _ reason: String) -> Failure { .init(id: id, reason: reason) }
    static func string(_ fields: [String: AgentRulesTOML.Value], _ key: String, default fallback: String, id: String) throws -> String {
        guard let value = fields[key] else { return fallback }
        guard let string = value.string else { throw failure(id, String(localized: "A text value is required.")) }
        return string
    }
    static func integer(_ fields: [String: AgentRulesTOML.Value], _ key: String, default fallback: Int, id: String) throws -> Int {
        guard let value = fields[key] else { return fallback }
        guard let integer = value.integer else { throw failure(id, String(localized: "An integer value is required.")) }
        return integer
    }
    static func boolean(_ fields: [String: AgentRulesTOML.Value], _ key: String, default fallback: Bool, id: String) throws -> Bool {
        guard let value = fields[key] else { return fallback }
        guard let bool = value.bool else { throw failure(id, String(localized: "A true or false value is required.")) }
        return bool
    }
    static func strings(_ fields: [String: AgentRulesTOML.Value], _ key: String, id: String) throws -> [String] {
        guard let value = fields[key] else { return [] }
        guard let array = value.array, array.count <= 32 else { throw failure(id, String(localized: "Use an array of at most 32 text values.")) }
        return try array.map {
            guard let string = $0.string, !string.isEmpty, validText(string, maximum: 512) else {
                throw failure(id, String(localized: "A condition is empty, too long, or contains control characters."))
            }
            return string
        }
    }
}

nonisolated struct AgentRecognitionScreenRule: Equatable, Sendable {
    var id: String
    var phase: ZshellAgentPhase
    var priority = 0
    var region = "whole_recent"
    var attention: ZshellAgentAttention?
    var enabled = true
    var skip = false
    var gate: AgentRecognitionGate

    static func parse(_ fields: [String: AgentRulesTOML.Value], agentID: String) throws -> Self {
        let id = fields["id"]?.string ?? ""
        guard AgentRecognitionManifest.validID(id), Set(fields.keys).isSubset(of: [
            "id", "state", "priority", "region", "attention", "enabled", "skip_state_update",
            "visible_idle", "visible_working", "visible_blocker", "contains", "regex", "line_regex", "all", "any", "not",
        ]), let phase = fields["state"]?.string.flatMap(ZshellAgentPhase.init(rawValue:)),
              [.idle, .working, .blocked, .unknown].contains(phase) else {
            throw AgentRecognitionManifest.failure(agentID, String(localized: "Screen rules need a unique ID and an idle, working, blocked, or unknown state."))
        }
        let label = "\(agentID)/\(id)"
        let region = try AgentRecognitionManifest.string(fields, "region", default: "whole_recent", id: label)
        guard AgentRecognitionRegion.isValid(region) else { throw AgentRecognitionManifest.failure(label, String(localized: "Use a live footer region or a bottom row count from 1 to 16.")) }
        let priority = try AgentRecognitionManifest.integer(fields, "priority", default: 0, id: label)
        guard (-10_000...10_000).contains(priority) else { throw AgentRecognitionManifest.failure(label, String(localized: "Rule priority must be between -10000 and 10000.")) }
        var attention: ZshellAgentAttention?
        if let value = fields["attention"] {
            guard phase == .blocked, let parsed = value.string.flatMap(ZshellAgentAttention.init(rawValue:)) else {
                throw AgentRecognitionManifest.failure(label, String(localized: "Attention applies only to blocked rules: approval, input, login, or error."))
            }
            attention = parsed
        } else if phase == .blocked { attention = .input }
        for key in ["visible_idle", "visible_working", "visible_blocker"] {
            _ = try AgentRecognitionManifest.boolean(fields, key, default: false, id: label)
        }
        var budget = 0
        let gate = try AgentRecognitionGate.parse(fields.filter { AgentRecognitionGate.keys.contains($0.key) }, id: label, budget: &budget)
        guard gate.hasPositiveCondition else { throw AgentRecognitionManifest.failure(label, String(localized: "Add a text or regular expression condition.")) }
        return .init(id: id, phase: phase, priority: priority, region: region, attention: attention,
                     enabled: try AgentRecognitionManifest.boolean(fields, "enabled", default: true, id: label),
                     skip: try AgentRecognitionManifest.boolean(fields, "skip_state_update", default: false, id: label), gate: gate)
    }
}

nonisolated struct AgentRecognitionGate: Equatable, Sendable {
    static let keys: Set<String> = ["contains", "regex", "line_regex", "all", "any", "not"]
    var contains: [String] = []
    var regex: [String] = []
    var lineRegex: [String] = []
    var all: [Self] = []
    var any: [Self] = []
    var not: [Self] = []
    var hasPositiveCondition: Bool {
        !contains.isEmpty || !regex.isEmpty || !lineRegex.isEmpty
            || all.contains(where: \.hasPositiveCondition) || !any.isEmpty && any.allSatisfy(\.hasPositiveCondition)
    }

    static func parse(_ fields: [String: AgentRulesTOML.Value], id: String, depth: Int = 0, budget: inout Int) throws -> Self {
        budget += 1
        guard depth <= 4, budget <= 32, Set(fields.keys).isSubset(of: keys) else {
            throw AgentRecognitionManifest.failure(id, String(localized: "Use at most 32 condition groups and four nesting levels."))
        }
        func values(_ key: String) throws -> [String] { try AgentRecognitionManifest.strings(fields, key, id: id) }
        var gate = Self(contains: try values("contains"), regex: try values("regex"), lineRegex: try values("line_regex"))
        guard gate.contains.count + gate.regex.count + gate.lineRegex.count <= 16 else {
            throw AgentRecognitionManifest.failure(id, String(localized: "Use at most 16 conditions in each group."))
        }
        for pattern in gate.regex + gate.lineRegex { try AgentRecognitionRegex.validate(pattern, id: id) }
        for key in ["all", "any", "not"] {
            guard let value = fields[key] else { continue }
            guard let array = value.array, array.count <= 16 else { throw AgentRecognitionManifest.failure(id, String(localized: "Condition groups must be arrays.")) }
            let groups = try array.map { value -> Self in
                guard let table = value.table else { throw AgentRecognitionManifest.failure(id, String(localized: "Condition groups must be tables.")) }
                return try parse(table, id: id, depth: depth + 1, budget: &budget)
            }
            switch key { case "all": gate.all = groups; case "any": gate.any = groups; default: gate.not = groups }
        }
        return gate
    }

    func fields() -> [String] {
        var result: [String] = []
        for (key, value) in [("contains", contains), ("regex", regex), ("line_regex", lineRegex)] where !value.isEmpty {
            result.append("\(key) = \(AgentRecognitionManifest.array(value))")
        }
        for (key, value) in [("all", all), ("any", any), ("not", not)] where !value.isEmpty {
            result.append("\(key) = [" + value.map { "{ " + $0.fields().joined(separator: ", ") + " }" }.joined(separator: ", ") + "]")
        }
        return result
    }
}

nonisolated enum AgentRecognitionRegex {
    static func validate(_ pattern: String, id: String) throws {
        // Quantified ambiguous groups and backreferences can make ICU spend
        // unbounded time on a tiny footer. The supported syntax excludes them.
        var groups: [Bool] = []
        var escaped = false
        var characterClass = false
        var riskyClosedGroup = false
        for character in pattern {
            if escaped {
                guard !character.isNumber else { throw invalid(id) }
                escaped = false
                riskyClosedGroup = false
                continue
            }
            if character == "\\" { escaped = true; continue }
            if character == "[", !characterClass { characterClass = true; riskyClosedGroup = false }
            if characterClass { if character == "]" { characterClass = false }; continue }
            if character == "(" { groups.append(false); riskyClosedGroup = false; continue }
            if character == ")" {
                riskyClosedGroup = groups.popLast() ?? false
                if riskyClosedGroup, !groups.isEmpty { groups[groups.count - 1] = true }
                continue
            }
            if "*+{?".contains(character) {
                guard !riskyClosedGroup else { throw invalid(id) }
                if !groups.isEmpty { groups[groups.count - 1] = true }
            } else if character == "|", !groups.isEmpty { groups[groups.count - 1] = true }
            riskyClosedGroup = false
        }
        guard !pattern.contains("(?"), (try? NSRegularExpression(pattern: pattern)) != nil else { throw invalid(id) }
    }

    private static func invalid(_ id: String) -> AgentRecognitionManifest.Failure {
        AgentRecognitionManifest.failure(id, String(localized: "Invalid or unsafe regular expression. Use simple patterns without backreferences or repeated groups."))
    }
}

nonisolated enum AgentRecognitionRegion {
    static func count(_ name: String, prefix: String) -> Int? {
        guard name.hasPrefix(prefix + "("), name.hasSuffix(")"),
              let count = Int(name.dropFirst(prefix.count + 1).dropLast()), (1...16).contains(count) else { return nil }
        return count
    }
    static func isValid(_ name: String) -> Bool {
        ["whole_recent", "prompt_box_body", "above_prompt_box", "last_non_empty_above_prompt_box", "after_last_horizontal_rule"].contains(name)
            || count(name, prefix: "bottom_lines") != nil || count(name, prefix: "bottom_non_empty_lines") != nil
    }
    static func text(_ footer: String, region: String) -> String {
        let lines = footer.components(separatedBy: .newlines)
        if let count = count(region, prefix: "bottom_lines") { return lines.suffix(count).joined(separator: "\n") }
        if let count = count(region, prefix: "bottom_non_empty_lines") {
            return lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.suffix(count).joined(separator: "\n")
        }
        func isRule(_ line: String) -> Bool { line.trimmingCharacters(in: .whitespaces).hasPrefix("───") }
        let borders = lines.indices.filter { isRule(lines[$0]) }
        if region == "after_last_horizontal_rule", let border = borders.last { return lines.dropFirst(border + 1).joined(separator: "\n") }
        if ["prompt_box_body", "above_prompt_box", "last_non_empty_above_prompt_box"].contains(region) {
            guard borders.count >= 2 else { return "" }
            let top = borders[borders.count - 2], bottom = borders[borders.count - 1]
            if region == "prompt_box_body" { return lines[(top + 1)..<bottom].joined(separator: "\n") }
            let above = lines.prefix(top)
            return region == "above_prompt_box" ? above.joined(separator: "\n")
                : above.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
        }
        return footer
    }
}

nonisolated final class AgentRecognitionCompiledGate: @unchecked Sendable {
    let contains: [String]
    let regex: [NSRegularExpression]
    let lineRegex: [NSRegularExpression]
    let all: [AgentRecognitionCompiledGate]
    let any: [AgentRecognitionCompiledGate]
    let not: [AgentRecognitionCompiledGate]

    init(_ gate: AgentRecognitionGate) throws {
        contains = gate.contains.map { $0.lowercased() }
        regex = try gate.regex.map { try NSRegularExpression(pattern: $0) }
        lineRegex = try gate.lineRegex.map { try NSRegularExpression(pattern: $0) }
        all = try gate.all.map(Self.init)
        any = try gate.any.map(Self.init)
        not = try gate.not.map(Self.init)
    }

    func matches(_ text: String, deadline: UInt64) -> Bool {
        guard DispatchTime.now().uptimeNanoseconds < deadline else { return false }
        let lower = text.lowercased()
        guard contains.allSatisfy({ lower.contains($0) }),
              regex.allSatisfy({ matches($0, text: text, deadline: deadline) }),
              lineRegex.allSatisfy({ pattern in text.components(separatedBy: .newlines).contains { matches(pattern, text: $0, deadline: deadline) } }),
              all.allSatisfy({ $0.matches(text, deadline: deadline) }),
              any.isEmpty || any.contains(where: { $0.matches(text, deadline: deadline) }),
              !not.contains(where: { $0.matches(text, deadline: deadline) }) else { return false }
        return DispatchTime.now().uptimeNanoseconds < deadline
    }

    private func matches(_ pattern: NSRegularExpression, text: String, deadline: UInt64) -> Bool {
        var found = false
        pattern.enumerateMatches(in: text, options: [.reportProgress], range: NSRange(text.startIndex..., in: text)) { result, _, stop in
            if DispatchTime.now().uptimeNanoseconds >= deadline { stop.pointee = true }
            else if result != nil { found = true; stop.pointee = true }
        }
        return found
    }
}

nonisolated enum AgentRecognitionScreenMatch: Sendable {
    case evidence(ZshellAgentScreenEvidence)
    case skip
    var evidence: ZshellAgentScreenEvidence? { if case let .evidence(value) = self { value } else { nil } }
}

nonisolated struct AgentRecognitionCompiledManifest: @unchecked Sendable {
    let manifest: AgentRecognitionManifest
    let rules: [(AgentRecognitionScreenRule, AgentRecognitionCompiledGate)]
    init(_ manifest: AgentRecognitionManifest) throws {
        self.manifest = manifest
        rules = try manifest.rules.enumerated().sorted {
            $0.element.priority == $1.element.priority ? $0.offset < $1.offset : $0.element.priority > $1.element.priority
        }.map { ($0.element, try .init($0.element.gate)) }
    }
    func detect(_ text: String) -> ZshellAgentScreenEvidence? { match(text)?.evidence }

    func match(_ text: String) -> AgentRecognitionScreenMatch? {
        guard manifest.screenEnabled, text.utf8.count <= 32_768 else { return nil }
        let footer = text.components(separatedBy: .newlines).suffix(16).joined(separator: "\n")
        let deadline = DispatchTime.now().uptimeNanoseconds + 20_000_000
        for (rule, gate) in rules where rule.enabled {
            if gate.matches(AgentRecognitionRegion.text(footer, region: rule.region), deadline: deadline) {
                if rule.skip { return .skip }
                return .evidence(.init(phase: rule.phase, attention: rule.attention, reason: "\(manifest.id): \(rule.id)"))
            }
        }
        return nil
    }
}

@MainActor
final class AgentRecognitionRulesStore: ObservableObject {
    static let shared = AgentRecognitionRulesStore(url: AppSettings.configURL.deletingLastPathComponent().appendingPathComponent("agents.toml"))
    let url: URL
    @Published private(set) var manifests: [AgentRecognitionManifest] = []
    @Published private(set) var error: String?
    private(set) var revision: UInt64 = 0
    private var compiled: [String: AgentRecognitionCompiledManifest] = [:]
    private let monitor: SettingsConfigMonitor
    private let queue = DispatchQueue(label: "sh.zshell.agent-rules", qos: .utility)
    private var operation: UInt64 = 0
    private var terminationObserver: NSObjectProtocol?

    init(url: URL) {
        self.url = url
        monitor = SettingsConfigMonitor(url: url, missingText: "")
        monitor.start { [weak self] text, fileRevision in
            let result = Self.compile(text)
            Task { @MainActor [weak self] in
                guard let self, self.monitor.isCurrent(fileRevision) else { return }
                self.apply(result)
            }
        }
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [monitor] _ in monitor.flush() }
    }

    deinit { if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) } }

    private nonisolated static func compile(_ text: String) -> Result<[AgentRecognitionCompiledManifest], Error> {
        Result { try AgentRecognitionManifest.parse(text).map(AgentRecognitionCompiledManifest.init) }
    }

    private func apply(_ result: Result<[AgentRecognitionCompiledManifest], Error>) {
        switch result {
        case let .success(values):
            manifests = values.map(\.manifest)
            compiled = Dictionary(uniqueKeysWithValues: values.map { ($0.manifest.id, $0) })
            revision &+= 1
            error = nil
            AgentAutomationMonitor.shared.recognitionSettingsChanged()
        case let .failure(failure): error = failure.localizedDescription
        }
    }

    func save(_ text: String, completion: @escaping (String?) -> Void) {
        operation &+= 1
        let expected = operation
        queue.async { [weak self] in
            let result = Self.compile(text)
            Task { @MainActor [weak self] in
                guard let self, self.operation == expected else { return }
                guard case .success = result else {
                    if case let .failure(failure) = result { completion(failure.localizedDescription) }
                    return
                }
                self.monitor.save(text) { [weak self] failure in
                    Task { @MainActor [weak self] in
                        guard let self, self.operation == expected else { return }
                        guard failure == nil else { completion(failure); return }
                        self.apply(result)
                        completion(nil)
                    }
                }
            }
        }
    }

    func save(_ values: [AgentRecognitionManifest], completion: @escaping (String?) -> Void) {
        save(AgentRecognitionManifest.serialize(values), completion: completion)
    }

    func recognize(processID: pid_t) -> AgentRecognitionIdentity? {
        recognize(executablePath: processExecutablePath(pid: processID), arguments: processArguments(pid: processID) ?? [])
    }

    func recognize(executablePath: String?, arguments: [String]) -> AgentRecognitionIdentity? {
        if AppSettings.shared.customAgentRecognitionRules {
            var operands = [arguments.first, executablePath].compactMap { $0 }
            if let executablePath, ZshellAgentKind.isScriptInterpreter((executablePath as NSString).lastPathComponent),
               let script = ZshellAgentKind.scriptIdentityOperand(arguments) { operands.append(script) }
            for operand in operands {
                let command = AgentRecognitionManifest.commandName(operand)
                if let manifest = manifests.first(where: {
                    ($0.executables + $0.aliases).contains { AgentRecognitionManifest.commandName($0) == command }
                }) { return manifest.identity }
            }
        }
        guard let kind = ZshellAgentKind.recognize(executablePath: executablePath, arguments: arguments) else { return nil }
        let override = AppSettings.shared.customAgentRecognitionRules ? manifests.first { $0.id == kind.rawValue } : nil
        return override?.identity ?? .init(id: kind.rawValue, name: kind.displayName, kind: kind)
    }

    func hasOverride(for id: String) -> Bool { AppSettings.shared.customAgentRecognitionRules && compiled[id] != nil }

    func evaluate(id: String, text: String, completion: @escaping (AgentRecognitionScreenMatch?) -> Void) {
        guard let manifest = compiled[id] else { completion(nil); return }
        queue.async {
            let match = manifest.match(text)
            Task { @MainActor in completion(match) }
        }
    }
}
