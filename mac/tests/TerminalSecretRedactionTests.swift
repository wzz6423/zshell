import Foundation

private enum RedactionTestFailure: Error { case check(String) }

@main
struct TerminalSecretRedactionTests {
    private static var checks = 0

    static func main() {
        do { try run(); print("Terminal secret redaction: \(checks) checks passed") } catch {
            fputs("Terminal secret redaction failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func run() throws {
        let github = "ghp_" + String(repeating: "a", count: 36)
        let fineGrained = "github_pat_" + String(repeating: "b", count: 82)
        let openAI = "sk-" + String(repeating: "A", count: 48)
        let projectKey = "sk-proj-" + String(repeating: "k", count: 120)
        let anthropic = "sk-ant-api03-" + String(repeating: "Q", count: 95)
        let slack =
            "xoxb-" + String(repeating: "1", count: 10) + "-" + String(repeating: "2", count: 10) + "-" + String(repeating: "a", count: 24)
        let slackApp = "xapp-1-A123456-123456789-" + String(repeating: "a", count: 32)
        let aws = "AKIA" + String(repeating: "A", count: 16)
        let temporaryAWS = "ASIA" + String(repeating: "B", count: 16)
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abcdefghijk1234567890"
        for (name, token) in [
            ("GitHub", github), ("fine-grained GitHub", fineGrained), ("OpenAI", openAI),
            ("OpenAI project", projectKey), ("Anthropic", anthropic), ("Slack", slack),
            ("Slack app", slackApp), ("AWS", aws), ("temporary AWS", temporaryAWS), ("JWT", jwt),
        ] {
            try result("before \(token) after", equals: "before [REDACTED] after", count: 1, name: name)
        }
        for prefix in ["gho_", "ghu_", "ghs_", "ghr_"] {
            try result(prefix + String(repeating: "a", count: 36), equals: "[REDACTED]", count: 1, name: "GitHub prefix")
        }
        for assignment in [
            "API_KEY", "api-key", "OPENAI_API_KEY", "ACCESS_TOKEN", "auth_token", "refresh-token", "CLIENT_SECRET", "secret_key", "token",
            "password", "PASSWD",
        ] {
            try result("\(assignment)=value-123", equals: "\(assignment)=[REDACTED]", count: 1, name: "assignment")
        }
        try result(#"{"api_key": "abc 123", "ok": true}"#, equals: #"{"api_key": "[REDACTED]", "ok": true}"#, count: 1, name: "JSON")
        try result("password='space and emoji 中文😀'\nnext", equals: "password='[REDACTED]'\nnext", count: 1, name: "quoted Unicode")
        try result(
            "Authorization: Bearer short-secret_123\r\n", equals: "Authorization: Bearer [REDACTED]\r\n", count: 1, name: "Bearer CRLF")
        try result("aUtHoRiZaTiOn:\tbeArEr \(jwt)\n", equals: "aUtHoRiZaTiOn:\tbeArEr [REDACTED]\n", count: 1, name: "case and overlap")
        try result(
            "token=\(github)\nAPI_KEY=\(openAI)", equals: "token=[REDACTED]\nAPI_KEY=[REDACTED]", count: 2, name: "assignment overlaps")
        try result(
            "中文👩🏽‍💻 e\u{301} \(github)\r\n次行😀 password=x\n", equals: "中文👩🏽‍💻 e\u{301} [REDACTED]\r\n次行😀 password=[REDACTED]\n", count: 2,
            name: "UTF16 locations")
        for nearMiss in [
            "ghp_short", "github_pat_short", "sk-short", "xoxb-short", "AKIA1234", "ASIA1234",
            "prefix" + github, github + "x", "sk-" + String(repeating: "A", count: 257),
            "eyJshort.eyJshort.short", "Authorization: Basic ordinary", "tokenizer=ordinary",
            "KEYSTONE_API_KEYS=normal", "PASSWORD", "key=value", "path=/Users/example/token/file", "file https://example.com/token",
        ] { try result(nearMiss, equals: nearMiss, count: 0, name: "near miss") }
        try result(#"{"password":"escaped\"secret\nvalue"}"#, equals: #"{"password":"[REDACTED]"}"#, count: 1, name: "JSON escaped value")
        try result(#"password='escaped\'secret'"#, equals: #"password='[REDACTED]'"#, count: 1, name: "escaped quoted value")
        try result("password=\nnext", equals: "password=\nnext", count: 0, name: "empty assignment")
        try result("", equals: "", count: 0, name: "empty text")
        let undetected = "custom-unknown-secret-format"
        try result(undetected, equals: undetected, count: 0, name: "no exhaustive guarantee")
        try check(
            TerminalSecretRedaction.redact(String(repeating: "x", count: TerminalSecretRedaction.maximumBytes + 1)) == nil,
            "oversized input fails without truncation")
        for stress in [
            String(repeating: "x", count: TerminalSecretRedaction.maximumBytes),
            String(repeating: "tokenizer='ordinary' no_secret=aaaa\n", count: 40_000),
            String(repeating: "sk-short sk-proj- password_missing ", count: 40_000),
            String(repeating: "token=x\n", count: 150_000),
        ] {
            let start = Date()
            try check(TerminalSecretRedaction.redact(stress) != nil, "bounded stress input completes")
            try check(Date().timeIntervalSince(start) < 8, "bounded stress input completes within eight seconds")
        }
    }

    private static func result(_ text: String, equals expected: String, count: Int, name: String) throws {
        guard let actual = TerminalSecretRedaction.redact(text) else { throw RedactionTestFailure.check(name + " refused input") }
        try check(actual.text == expected, name + " preserves surrounding text")
        try check(actual.matchCount == count, name + " merges overlapping matches")
    }

    private static func check(_ condition: Bool, _ name: String) throws {
        guard condition else { throw RedactionTestFailure.check(name) }
        checks += 1
    }
}
