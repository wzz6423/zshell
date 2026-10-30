import Foundation

/// A session-local record. The command comes from OSC 133 input boundaries,
/// never from recognizing a prompt in rendered text.
struct TerminalCommandRecord: Identifiable, Equatable, Sendable {
    let id: UUID
    var command: String
    var workingDirectory: String?
    let startedAt: Date
    var finishedAt: Date?
    var durationNanos: UInt64?
    var exitCode: Int?
    var outputLocation: TerminalCommandOutputLocation?
}

/// An opaque, live-surface token. Resolve it through TerminalBackendSurface;
/// buffer coordinates change during reflow and must not be persisted.
struct TerminalCommandOutputLocation: Hashable, Sendable {
    let surfaceID: UUID
    let blockID: UInt64
}

struct TerminalCommandPosition: Equatable, Comparable, Sendable {
    let row: UInt64
    let column: UInt32

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.row, lhs.column) < (rhs.row, rhs.column)
    }
}

/// Half-open cell ranges, resolved against the current screen and scrollback.
struct TerminalCommandRegion: Equatable, Sendable {
    let promptStart: TerminalCommandPosition
    let inputStart: TerminalCommandPosition
    let outputStart: TerminalCommandPosition
    let outputEnd: TerminalCommandPosition
}

enum TerminalCommandTextPart: Sendable {
    case command
    case output
    case wholeBlock
}
