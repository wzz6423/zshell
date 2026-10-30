#if canImport(AppKit) && !canImport(UIKit)
    import AppKit
    import GhosttyKit

    public struct TerminalSemanticCommandPosition: Sendable {
        public let row: UInt64
        public let column: UInt32
    }

    public struct TerminalSemanticCommandRegion: Sendable {
        public let prompt: TerminalSemanticCommandPosition
        public let input: TerminalSemanticCommandPosition
        public let output: TerminalSemanticCommandPosition
        public let end: TerminalSemanticCommandPosition
    }

    extension AppTerminalView {
        public var semanticCommandRevision: UInt64 {
            guard let raw = surface?.rawValue else { return 0 }
            return ghostty_surface_command_revision(raw)
        }

        public func semanticCommandRecords() -> Data? {
            guard let raw = surface?.rawValue else { return nil }
            var result = ghostty_text_s()
            guard ghostty_surface_command_records(raw, &result), let text = result.text else { return nil }
            defer { ghostty_surface_free_text(raw, &result) }
            return Data(bytes: text, count: Int(result.text_len))
        }

        public func semanticCommandRegion(id: UInt64) -> TerminalSemanticCommandRegion? {
            guard let raw = surface?.rawValue else { return nil }
            var result = ghostty_command_region_s()
            guard ghostty_surface_command_region(raw, id, &result) else { return nil }
            func position(_ value: ghostty_command_position_s) -> TerminalSemanticCommandPosition {
                .init(row: value.row, column: value.column)
            }
            return .init(prompt: position(result.prompt), input: position(result.input),
                         output: position(result.output), end: position(result.end))
        }

        public func semanticCommandText(id: UInt64, part: UInt8) -> String? {
            guard let raw = surface?.rawValue else { return nil }
            var result = ghostty_text_s()
            guard ghostty_surface_command_text(raw, id, part, &result), let text = result.text else { return nil }
            defer { ghostty_surface_free_text(raw, &result) }
            return String(decoding: UnsafeRawBufferPointer(start: text, count: Int(result.text_len)), as: UTF8.self)
        }

        @discardableResult
        public func revealSemanticCommand(id: UInt64, select: Bool) -> Bool {
            guard let raw = surface?.rawValue else { return false }
            return ghostty_surface_command_reveal(raw, id, select)
        }

        public func semanticCommandID(at event: NSEvent) -> UInt64? {
            guard let raw = surface?.rawValue else { return nil }
            let point = mousePoint(from: event)
            let id = ghostty_surface_command_at(raw, point.x, point.y)
            return id == 0 ? nil : id
        }
    }
#endif
