import Darwin
import Foundation

enum ZshellAgentAttention: String, Codable, CaseIterable, Sendable {
    case approval
    case input
    case login
    case error

    var displayName: String {
        switch self {
        case .approval: String(localized: "Approval required")
        case .input: String(localized: "Answer required")
        case .login: String(localized: "Login required")
        case .error: String(localized: "Reported error")
        }
    }
}

struct ZshellAgentTaskStatus: Equatable, Sendable {
    let id: String
    let title: String
    let phase: ZshellAgentPhase
    let progress: Int?
    let attention: ZshellAgentAttention?

    var snapshot: ZshellJSONValue {
        .object([
            "id": .string(id), "title": .string(title),
            "state": .string(phase.rawValue),
            "progress": progress.map { .number(Double($0)) } ?? .null,
            "attention": attention.map { .string($0.rawValue) } ?? .null,
        ])
    }
}

/// The PID alone can be reused after exit; reports remain tied to this exact
/// process incarnation rather than a future occupant of the same PID.
struct ZshellAgentProcessIdentity: Equatable, Sendable {
    let pid: pid_t
    let startedSeconds: UInt64
    let startedMicroseconds: UInt64

    init?(pid: pid_t) {
        guard let info = Self.info(pid) else { return nil }
        self.pid = pid
        startedSeconds = info.pbi_start_tvsec
        startedMicroseconds = info.pbi_start_tvusec
    }

    var isAlive: Bool { Self(pid: pid) == self }

    static func parent(of pid: pid_t) -> pid_t? {
        info(pid).map { pid_t($0.pbi_ppid) }
    }

    static func isDescendant(_ pid: pid_t, of ancestor: pid_t) -> Bool {
        guard pid > 1, ancestor > 1 else { return false }
        var current = pid
        for _ in 0..<64 {
            if current == ancestor { return true }
            guard let parent = parent(of: current), parent > 1, parent != current else { return false }
            current = parent
        }
        return false
    }

    private static func info(_ pid: pid_t) -> proc_bsdinfo? {
        guard pid > 1 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
              info.pbi_status != UInt32(SZOMB) else { return nil }
        return info
    }
}

struct ZshellAgentReport: Equatable, Sendable {
    static let maximumTasks = 32
    static let lifetime: TimeInterval = 120

    let name: String
    let phase: ZshellAgentPhase
    let reason: String
    let progress: Int?
    let attention: ZshellAgentAttention?
    let tasks: [ZshellAgentTaskStatus]

    var activityPhase: ZshellAgentPhase {
        if tasks.contains(where: { $0.phase == .blocked }) { return .blocked }
        if (phase == .idle || phase == .done), tasks.contains(where: { $0.phase == .working }) {
            return .working
        }
        return phase
    }

    var activityAttention: ZshellAgentAttention? {
        tasks.first(where: { $0.phase == .blocked })?.attention ?? attention
    }

    init(params: [String: ZshellJSONValue]) throws {
        let allowed: Set<String> = ["name", "state", "reason", "progress", "attention", "tasks", "process_id"]
        guard Set(params.keys).isSubset(of: allowed),
              let state = params["state"]?.stringValue,
              let phase = ZshellAgentPhase(rawValue: state), phase != .created,
              let name = params["name"]?.stringValue, Self.validText(name, maximum: 128), !name.isEmpty
        else { throw Self.invalid("Provide name and state; reports can only update the invoking terminal.") }
        self.name = name
        self.phase = phase
        reason = try Self.text(params["reason"], maximum: 1_024) ?? ""
        progress = try Self.progress(params["progress"])
        attention = try Self.attention(params["attention"], phase: phase)
        if let value = params["tasks"] {
            guard let tasks = value.arrayValue, tasks.count <= Self.maximumTasks else {
                throw Self.invalid("tasks must be an array containing at most 32 tasks.")
            }
            self.tasks = try tasks.map { value in
                guard let task = value.objectValue,
                      Set(task.keys).isSubset(of: ["id", "title", "state", "progress", "attention"]),
                      let id = task["id"]?.stringValue, !id.isEmpty,
                      Self.validText(id, maximum: 128),
                      let title = task["title"]?.stringValue, !title.isEmpty,
                      Self.validText(title, maximum: 256),
                      let state = task["state"]?.stringValue,
                      let phase = ZshellAgentPhase(rawValue: state), phase != .created else {
                    throw Self.invalid("Each task needs a unique id, title, and valid state.")
                }
                return ZshellAgentTaskStatus(
                    id: id, title: title, phase: phase,
                    progress: try Self.progress(task["progress"]),
                    attention: try Self.attention(task["attention"], phase: phase)
                )
            }
            guard Set(self.tasks.map(\.id)).count == self.tasks.count else {
                throw Self.invalid("Task ids must be unique.")
            }
        } else { tasks = [] }
    }

    static func validText(_ text: String, maximum: Int) -> Bool {
        text.utf8.count <= maximum && text.unicodeScalars.allSatisfy {
            $0.value >= 0x20 && !(0x7f...0x9f).contains($0.value)
                && $0.value != 0x2028 && $0.value != 0x2029
        }
    }

    private static func text(_ value: ZshellJSONValue?, maximum: Int) throws -> String? {
        guard let value, value != .null else { return nil }
        guard let text = value.stringValue, validText(text, maximum: maximum) else {
            throw Self.invalid("Report text is too long or contains control characters.")
        }
        return text
    }

    private static func progress(_ value: ZshellJSONValue?) throws -> Int? {
        guard let value, value != .null else { return nil }
        guard let number = value.intValue, (0...100).contains(number) else {
            throw Self.invalid("progress must be an integer from 0 to 100.")
        }
        return number
    }

    private static func attention(_ value: ZshellJSONValue?, phase: ZshellAgentPhase) throws -> ZshellAgentAttention? {
        guard let value, value != .null else { return nil }
        guard phase == .blocked, let name = value.stringValue,
              let attention = ZshellAgentAttention(rawValue: name) else {
            throw Self.invalid("attention requires blocked state and must be approval, input, login, or error.")
        }
        return attention
    }

    private static func invalid(_ message: String) -> ZshellAutomationWireError { .message(message) }
}

struct ZshellAgentProgramObservation {
    let report: ZshellAgentReport
    let owner: ZshellAgentProcessIdentity
    let updatedAt: Date

    func isCurrent(at date: Date) -> Bool {
        date.timeIntervalSince(updatedAt) < ZshellAgentReport.lifetime && owner.isAlive
    }
}

struct ZshellAgentLifecycleEvent {
    let phase: ZshellAgentPhase
    let attention: ZshellAgentAttention?
    let reason: String
    let task: ZshellAgentTaskStatus?
    let endsSession: Bool

    static func parse(provider: ZshellAgentKind, payload: [String: ZshellJSONValue]) -> Self? {
        guard provider == .codex || provider == .claude,
              let event = payload["hook_event_name"]?.stringValue else { return nil }
        var phase: ZshellAgentPhase = .working
        var attention: ZshellAgentAttention?
        var task: ZshellAgentTaskStatus?
        var endsSession = false
        switch event {
        case "SessionStart": phase = .idle
        case "UserPromptSubmit", "PostToolUse", "PostCompact", "ElicitationResult": break
        case "PreToolUse":
            if ["AskUserQuestion", "request_user_input"].contains(payload["tool_name"]?.stringValue ?? "") {
                phase = .blocked
                attention = .input
            }
        case "PermissionRequest": phase = .blocked; attention = .approval
        case "Elicitation": phase = .blocked; attention = .input
        case "StopFailure":
            guard provider == .claude else { return nil }
            phase = .blocked
            attention = payload["error"]?.stringValue == "authentication_failed" ? .login : .error
        case "Notification":
            guard provider == .claude else { return nil }
            switch payload["notification_type"]?.stringValue {
            case "permission_prompt": phase = .blocked; attention = .approval
            case "elicitation_dialog", "agent_needs_input": phase = .blocked; attention = .input
            case "auth_success": phase = .idle
            default: return nil
            }
        case "SubagentStart", "SubagentStop":
            guard let id = payload["agent_id"]?.stringValue, !id.isEmpty,
                  ZshellAgentReport.validText(id, maximum: 128) else { return nil }
            let title = payload["agent_type"]?.stringValue ?? id
            guard ZshellAgentReport.validText(title, maximum: 256) else { return nil }
            task = ZshellAgentTaskStatus(
                id: id, title: title.isEmpty ? id : title,
                phase: event == "SubagentStart" ? .working : .done,
                progress: nil, attention: nil
            )
        case "Stop": phase = .idle
        case "Interrupt":
            guard provider == .codex else { return nil }
            phase = .idle
        case "SessionEnd": phase = .idle; endsSession = true
        default: return nil
        }
        // A child finishing must never finish the parent turn. Tool events in
        // a child can still identify that child as waiting for a human.
        if task == nil, let id = payload["agent_id"]?.stringValue, !id.isEmpty {
            guard ZshellAgentReport.validText(id, maximum: 128) else { return nil }
            let title = payload["agent_type"]?.stringValue ?? id
            guard ZshellAgentReport.validText(title, maximum: 256) else { return nil }
            task = ZshellAgentTaskStatus(id: id, title: title, phase: phase, progress: nil, attention: attention)
        }
        if task != nil { endsSession = false }
        return Self(phase: phase, attention: attention, reason: "\(provider.displayName): \(event)", task: task, endsSession: endsSession)
    }
}

struct ZshellAgentScreenEvidence: Equatable {
    let phase: ZshellAgentPhase
    let attention: ZshellAgentAttention?
    let reason: String

    /// Only the live viewport footer is inspected. Paired UI affordances make
    /// quoted prose less likely to look like a prompt; this is never completion
    /// evidence and never authorizes input or an approval.
    static func detect(kind: ZshellAgentKind, text: String) -> Self? {
        guard text.utf8.count <= 32_768 else { return nil }
        let lines = text.components(separatedBy: .newlines).suffix(16)
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        let footer = lines.joined(separator: "\n")
        let confirmation = footer.contains("esc to cancel") || footer.contains("press enter to confirm")
        switch kind {
        case .codex:
            if confirmation && lines.contains(where: { $0 == "would you like to run the following command?" }) {
                return Self(phase: .blocked, attention: .approval, reason: "Possible Codex approval prompt")
            }
            if footer.contains("sign in with chatgpt") && footer.contains("sign in with an api key") {
                return Self(phase: .blocked, attention: .login, reason: "Possible Codex sign-in prompt")
            }
        case .claude:
            if confirmation && lines.contains(where: { $0 == "do you want to proceed?" || $0 == "do you want to make this edit?" }) {
                return Self(phase: .blocked, attention: .approval, reason: "Possible Claude Code approval prompt")
            }
            if footer.contains("/login") && footer.contains("not logged in") {
                return Self(phase: .blocked, attention: .login, reason: "Possible Claude Code sign-in prompt")
            }
        case .gemini:
            if footer.contains("allow execution of:") && footer.contains("allow once") && footer.contains("deny") {
                return Self(phase: .blocked, attention: .approval, reason: "Possible Gemini CLI approval prompt")
            }
        case .aider:
            if lines.last(where: { !$0.isEmpty })?.hasSuffix("(y)es/(n)o [yes]:") == true {
                return Self(phase: .blocked, attention: .input, reason: "Possible Aider question")
            }
        default: break
        }
        if lines.contains(where: {
            $0.count <= 160 && ($0 == "esc to interrupt"
                || $0.hasSuffix(" · esc to interrupt") || $0.hasSuffix("(esc to interrupt)")
                || $0.hasPrefix("esc to cancel ·"))
        }) {
            return Self(phase: .working, attention: nil, reason: "Agent activity visible in terminal footer")
        }
        return nil
    }
}

extension ZshellAgentPhase {
    var statusDescription: String {
        switch self {
        case .created: String(localized: "Agent starting")
        case .working: String(localized: "Agent working")
        case .blocked: String(localized: "Agent needs attention")
        case .done: String(localized: "Agent finished")
        case .idle: String(localized: "Agent idle")
        case .unknown: String(localized: "Agent state unknown")
        }
    }
}
