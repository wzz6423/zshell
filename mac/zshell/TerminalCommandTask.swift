import Foundation

/// A task belongs to the command submitted by automation, never whichever
/// command happened to finish most recently in the same pane.
struct TerminalCommandTask {
    enum State: String {
        case pending, running, completed, closed, unsupported, unavailable

        var isTerminal: Bool {
            self != .pending && self != .running
        }
    }

    let id: UUID
    let projectID: UUID
    let paneID: UUID
    let terminalID: UUID
    let argv: [String]
    let createdAt: Date
    private(set) var state: State = .pending
    private(set) var exitCode: Int?
    private(set) var durationNanos: UInt64?
    private(set) var completionSequence: UInt64?
    private(set) var output: String?
    private(set) var errorCode: String?
    private(set) var errorMessage: String?
    private var startedAtNanos: UInt64?
    static let outputLimitBytes = 131_072
    static let outputLimitLines = 160
    static let outputLimitColumns = 400

    init(id: UUID = UUID(), projectID: UUID, paneID: UUID, terminalID: UUID, argv: [String]) {
        self.id = id
        self.projectID = projectID
        self.paneID = paneID
        self.terminalID = terminalID
        self.argv = argv
        createdAt = Date()
    }

    mutating func start() {
        guard state == .pending else { return }
        startedAtNanos = DispatchTime.now().uptimeNanoseconds
        state = .running
    }

    @discardableResult
    mutating func observeCompletion(
        sequence: UInt64,
        shellResult: TerminalCommandTaskShellResult?,
        output: () -> String
    ) -> Bool {
        guard state == .running,
              let shellResult, shellResult.taskID == id else { return false }
        // Prompt hooks can overwrite the status in OSC 133;D. The wrapper's
        // result captures the command's own status before any prompt work.
        self.exitCode = shellResult.exitCode
        self.durationNanos = shellResult.durationNanos
            ?? startedAtNanos.map { DispatchTime.now().uptimeNanoseconds - $0 }
        completionSequence = sequence
        let text = output()
        var tail = text.utf8.suffix(Self.outputLimitBytes)
        // The byte limit must not turn a split Unicode scalar into output.
        while tail.first.map({ $0 & 0xC0 == 0x80 }) == true { tail = tail.dropFirst() }
        self.output = String(decoding: tail, as: UTF8.self)
        state = .completed
        return true
    }

    mutating func stop(state: State, code: String, message: String) {
        guard !self.state.isTerminal else { return }
        self.state = state
        errorCode = code
        errorMessage = message
    }

    var json: ZshellJSONValue {
        .object([
            "task_id": .string(id.uuidString),
            "project_id": .string(projectID.uuidString),
            "pane_id": .string(paneID.uuidString),
            "terminal_id": .string(terminalID.uuidString),
            "argv": .array(argv.map(ZshellJSONValue.string)),
            "created_at": .string(ISO8601DateFormatter().string(from: createdAt)),
            "state": .string(state.rawValue),
            "exit_code": exitCode.map { .number(Double($0)) } ?? .null,
            "duration_ms": durationNanos.map { .number(Double($0) / 1_000_000) } ?? .null,
            "output": output.map(ZshellJSONValue.string) ?? .null,
            "output_kind": .string("recent_terminal_text"),
            "output_complete": .bool(false),
            "output_limit_bytes": .number(Double(Self.outputLimitBytes)),
            "output_limit_lines": .number(Double(Self.outputLimitLines)),
            "output_limit_columns": .number(Double(Self.outputLimitColumns)),
            "error": errorCode.map { code in
                .object([
                    "code": .string(code),
                    "message": .string(errorMessage ?? ""),
                ])
            } ?? .null,
        ])
    }
}
