import Foundation

private enum TemplateTestFailure: Error { case failed(String) }

@main
struct QuickCommandTemplateTests {
    private static var checks = 0
    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        checks += 1
        guard condition() else { throw TemplateTestFailure.failed(message) }
    }

    private static func rejected(_ command: String, parameters: [QuickCommandParameter]) throws {
        do {
            _ = try QuickCommandTemplate(command: command, parameters: parameters)
            throw TemplateTestFailure.failed("accepted invalid template: " + command)
        } catch is QuickCommandTemplate.ValidationError {
            checks += 1
        }
    }

    static func main() throws {
        let id = UUID()
        let old = Data(#"[{"id":"ID","name":"Saved","command":"echo \"hello\""}]"#.replacingOccurrences(of: "ID", with: id.uuidString).utf8)
        let decoded = try JSONDecoder().decode([QuickCommandPreset].self, from: old)
        try check(
            decoded.first?.parameters == [] && decoded.first?.id == id && decoded.first?.isValid == true,
            "old JSON decodes with stable identity and no parameters")
        let oldEncoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as! [[String: Any]]
        try check(oldEncoded[0]["parameters"] == nil, "fixed command encoding retains the old JSON shape")
        let partial = try JSONDecoder().decode(QuickCommandParameter.self, from: Data(#"{"name":"value"}"#.utf8))
        try check(partial == QuickCommandParameter(name: "value"), "optional parameter fields decode with defaults")
        let parameter = QuickCommandParameter(name: "value", defaultValue: "default value")
        let preset = QuickCommandPreset(id: id, name: "Parameterized", command: "printf '%s\\n' {{value}}", parameters: [parameter])
        let roundTrip = try JSONDecoder().decode(QuickCommandPreset.self, from: JSONEncoder().encode(preset))
        try check(roundTrip == preset && roundTrip.isValid, "new preset round trips")
        let template = try QuickCommandTemplate(command: preset.command, parameters: preset.parameters)
        let defaultLine = try template.render(values: [:], quote: TerminalSession.shellQuote)
        try check(defaultLine == "printf '%s\\n' 'default value'", "absent value uses default")
        let empty = try template.render(values: ["value": ""], quote: TerminalSession.shellQuote)
        try check(empty.hasSuffix(" ''"), "empty text is one empty argument")

        let invalid = [
            "{{value}} arg", "echo '{{value}}'", "echo \"{{value}}\"", "echo --key={{value}}",
            "echo prefix{{value}}", "echo {{value}}suffix", "echo \\\\{{value}}",
            "echo {{value}}; true", "echo {{value}} | cat", "echo {{value}} > out",
            "echo {{value}} && true", "echo $(date) {{value}}", "echo `date` {{value}}",
            "echo \"$(date)\" {{value}}", "echo $HOME {{value}}", "echo * {{value}}",
            "echo '{{value}}", "echo \"literal {{value}}", "echo {{value}}\\\\",
            "echo\t{{value}}", "echo\n{{value}}", "echo {{value}}\r", "echo {{value}}\u{1b}",
            "if {{value}}", "for {{value}}", "echo {{not_defined}}", "echo {{bad-name}}",
            "echo {{value}", "echo value}}",
        ]
        for command in invalid { try rejected(command, parameters: [parameter]) }
        try rejected("echo literal", parameters: [parameter])
        try rejected("echo {{value}}", parameters: [parameter, parameter])
        try rejected("echo {{value}}", parameters: [.init(name: "bad name")])
        let choice = QuickCommandParameter(
            name: "environment", kind: .dropdown, defaultValue: "staging", choices: ["staging", "production"])
        let choiceTemplate = try QuickCommandTemplate(
            command: "deploy {{environment}} {{value}} {{value}}", parameters: [choice, parameter])
        let repeated = try choiceTemplate.render(values: ["value": "你好 👩🏽‍💻", "environment": "production"], quote: TerminalSession.shellQuote)
        try check(repeated == "deploy 'production' '你好 👩🏽‍💻' '你好 👩🏽‍💻'", "Unicode and repeated parameters match")
        for values in [
            ["environment": "unknown"], ["value": "line\nother"], ["value": "line\rother"],
            ["value": "\u{0}"], ["value": "\u{9}"], ["unknown": "value"],
        ] {
            do {
                _ = try choiceTemplate.render(values: values, quote: TerminalSession.shellQuote)
                throw TemplateTestFailure.failed("invalid values accepted")
            } catch is QuickCommandTemplate.ValidationError { checks += 1 }
        }
        for choices in [[], ["staging", "staging"], ["staging", ""], ["staging", "line\nother"]] {
            try rejected(
                "deploy {{environment}}",
                parameters: [.init(name: "environment", kind: .dropdown, defaultValue: "staging", choices: choices)])
        }
        try rejected(
            "deploy {{environment}}", parameters: [.init(name: "environment", kind: .dropdown, defaultValue: "other", choices: ["staging"])]
        )
        try rejected("MODE=ready {{value}}", parameters: [parameter])
        try rejected("echo {{value}}", parameters: (0 ... QuickCommandTemplate.maximumParameters).map { .init(name: "arg" + String($0)) })
        try rejected(String(repeating: "a", count: QuickCommandTemplate.maximumCommandBytes + 1) + " {{value}}", parameters: [parameter])
        try rejected("echo {{value}}", parameters: [.init(name: "value", defaultValue: String(repeating: "a", count: 4_097))])
        try rejected(
            "echo {{value}}", parameters: [.init(name: "value", kind: .dropdown, defaultValue: "0", choices: (0 ... 100).map(String.init))])
        do {
            _ = try template.render(values: ["value": String(repeating: "a", count: 4_097)], quote: TerminalSession.shellQuote)
            throw TemplateTestFailure.failed("oversized value accepted")
        } catch is QuickCommandTemplate.ValidationError { checks += 1 }
        let escaped = try QuickCommandTemplate(
            command: #"env MODE=ready printf '%s\n' "a\"b" c\ d '{literal}' {{value}}"#, parameters: [parameter])
        let escapedLine = try escaped.render(values: ["value": "chosen"], quote: TerminalSession.shellQuote)
        try check(escapedLine.hasSuffix("'chosen'"), "quoted and backslash-escaped literal words remain intact")
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shell.arguments = ["-f", "-c", escapedLine]
        let literalOutput = Pipe()
        shell.standardOutput = literalOutput
        try shell.run()
        let literalData = literalOutput.fileHandleForReading.readDataToEndOfFile()
        shell.waitUntilExit()
        try check(
            shell.terminationStatus == 0 && String(data: literalData, encoding: .utf8) == "a\"b\nc d\n{literal}\nchosen\n",
            "real zsh parses static quotes and backslashes without structure changes")

        let marker = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("injected")
        let values = [
            "", "space value", "O'Reilly", "quote \"value\"", "你好 東京 👩🏽‍💻", "; touch " + marker.path,
            "$(touch " + marker.path + ")", "`touch " + marker.path + "`", "$HOME", "\\\\", "* [a-z] ! # & | < >",
        ]
        let argvTemplate = try QuickCommandTemplate(command: "/usr/bin/printf '%s\\0' {{value}} {{value}}", parameters: [parameter])
        for value in values {
            let line = try argvTemplate.render(values: ["value": value], quote: TerminalSession.shellQuote)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-f", "-c", line]
            let output = Pipe()
            process.standardOutput = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            try check(
                process.terminationStatus == 0 && data == Data((value + "\0" + value + "\0").utf8),
                "real shell receives exactly two literal arguments")
            try check(!FileManager.default.fileExists(atPath: marker.path), "shell metacharacters cannot execute injected command")
        }
        print("Quick command model/template: \(checks) checks passed")
    }
}
