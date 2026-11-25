import Foundation

nonisolated enum TerminalSecretRedaction {
    static let maximumBytes = 2 * 1024 * 1024
    static let replacement = "[REDACTED]"

    struct Result: Sendable {
        let text: String
        let matchCount: Int
    }

    private struct Pattern {
        let expression: NSRegularExpression
        let group: Int

        init(_ pattern: String, group: Int = 0) {
            expression = try! NSRegularExpression(pattern: pattern)
            self.group = group
        }
    }

    // Provider prefixes use token boundaries; assignment patterns redact only
    // values so the surrounding error message remains useful when shared.
    private static let patterns: [Pattern] = [
        Pattern(#"(?<![A-Za-z0-9_])gh[pousr]_[A-Za-z0-9_]{36}(?![A-Za-z0-9_])"#),
        Pattern(#"(?<![A-Za-z0-9_])github_pat_[A-Za-z0-9_]{82}(?![A-Za-z0-9_])"#),
        Pattern(#"(?<![A-Za-z0-9_-])sk-(?:proj-|svcacct-|ant-api[0-9]{0,2}-)?[A-Za-z0-9_-]{32,256}(?![A-Za-z0-9_-])"#),
        Pattern(#"(?<![A-Za-z0-9_-])xox[baprs]-[A-Za-z0-9-]{16,256}(?![A-Za-z0-9_-])"#),
        Pattern(#"(?<![A-Za-z0-9_-])xapp-[0-9]{1,16}-[A-Za-z0-9_]{1,64}-[0-9]{1,16}-[a-f0-9]{16,128}(?![A-Za-z0-9_-])"#),
        Pattern(#"(?<![A-Za-z0-9_])(?:AKIA|ASIA)[A-Z0-9]{16}(?![A-Za-z0-9_])"#),
        Pattern(#"(?<![A-Za-z0-9_-])eyJ[A-Za-z0-9_-]{8,2048}\.eyJ[A-Za-z0-9_-]{8,8192}\.[A-Za-z0-9_-]{10,2048}(?![A-Za-z0-9_.-])"#),
        Pattern(
            #"(?i)\bAuthorization[ \t]{0,16}:[ \t]{0,16}Bearer[ \t]{1,16}([A-Za-z0-9._~+/-]{8,8192}={0,2})(?![A-Za-z0-9._~+/-])"#, group: 1),
        Pattern(
            #"(?i)(?<![A-Za-z0-9_])(?:["']?(?:[A-Za-z0-9]{1,32}_)?(?:api[_-]?key|access[_-]?token|auth[_-]?token|refresh[_-]?token|client[_-]?secret|secret[_-]?key|token|password|passwd)["']?)[ \t]{0,16}[:=][ \t]{0,16}"((?:[^"\\\r\n]|\\[^\r\n]){1,8192})""#,
            group: 1),
        Pattern(
            #"(?i)(?<![A-Za-z0-9_])(?:["']?(?:[A-Za-z0-9]{1,32}_)?(?:api[_-]?key|access[_-]?token|auth[_-]?token|refresh[_-]?token|client[_-]?secret|secret[_-]?key|token|password|passwd)["']?)[ \t]{0,16}[:=][ \t]{0,16}'((?:[^'\\\r\n]|\\[^\r\n]){1,8192})'"#,
            group: 1),
        Pattern(
            #"(?i)(?<![A-Za-z0-9_])(?:["']?(?:[A-Za-z0-9]{1,32}_)?(?:api[_-]?key|access[_-]?token|auth[_-]?token|refresh[_-]?token|client[_-]?secret|secret[_-]?key|token|password|passwd)["']?)[ \t]{0,16}[:=][ \t]{0,16}([^\s"',;<>\]\[{}]{1,8192})(?![^\s"',;<>\]\[{}])"#,
            group: 1),
    ]

    static func redact(_ text: String) -> Result? {
        guard text.utf8.count <= maximumBytes else { return nil }
        let fullRange = NSRange(location: 0, length: text.utf16.count)
        var ranges: [NSRange] = []
        for pattern in patterns {
            pattern.expression.enumerateMatches(in: text, range: fullRange) { match, _, _ in
                guard let match else { return }
                let range = match.range(at: pattern.group)
                if range.location != NSNotFound, range.length > 0 { ranges.append(range) }
            }
        }
        ranges.sort { $0.location == $1.location ? $0.length > $1.length : $0.location < $1.location }
        var merged: [NSRange] = []
        for range in ranges {
            if let last = merged.last, range.location < NSMaxRange(last) {
                merged[merged.count - 1] = NSRange(
                    location: last.location, length: max(NSMaxRange(last), NSMaxRange(range)) - last.location)
            } else {
                merged.append(range)
            }
        }
        let source = text as NSString
        var output = ""
        output.reserveCapacity(text.utf8.count)
        var position = 0
        for range in merged {
            output += source.substring(with: NSRange(location: position, length: range.location - position))
            output += replacement
            position = NSMaxRange(range)
        }
        output += source.substring(from: position)
        return Result(text: output, matchCount: merged.count)
    }
}
