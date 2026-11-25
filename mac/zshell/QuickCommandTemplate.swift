import Foundation

struct QuickCommandParameter: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case text
        case dropdown
    }

    var name: String
    var kind: Kind = .text
    var defaultValue = ""
    var choices: [String] = []

    init(name: String, kind: Kind = .text, defaultValue: String = "", choices: [String] = []) {
        self.name = name
        self.kind = kind
        self.defaultValue = defaultValue
        self.choices = choices
    }

    private enum CodingKeys: String, CodingKey { case name, kind, defaultValue, choices }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .text
        defaultValue = try container.decodeIfPresent(String.self, forKey: .defaultValue) ?? ""
        choices = try container.decodeIfPresent([String].self, forKey: .choices) ?? []
    }

    var isValid: Bool {
        guard Self.isValidName(name), name.utf8.count <= 64,
            QuickCommandTemplate.isSingleLine(defaultValue), defaultValue.utf8.count <= QuickCommandTemplate.maximumValueBytes
        else { return false }
        switch kind {
        case .text:
            return choices.isEmpty
        case .dropdown:
            return !choices.isEmpty && choices.count <= QuickCommandTemplate.maximumChoices && Set(choices).count == choices.count
                && choices.allSatisfy {
                    !$0.isEmpty && QuickCommandTemplate.isSingleLine($0) && $0.utf8.count <= QuickCommandTemplate.maximumValueBytes
                }
                && choices.contains(defaultValue)
        }
    }

    static func isValidName(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil
    }
}

struct QuickCommandPreset: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var command: String
    var parameters: [QuickCommandParameter]

    init(id: UUID = UUID(), name: String, command: String, parameters: [QuickCommandParameter] = []) {
        self.id = id
        self.name = name
        self.command = command
        self.parameters = parameters
    }

    private enum CodingKeys: String, CodingKey { case id, name, command, parameters }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        command = try container.decode(String.self, forKey: .command)
        parameters = try container.decodeIfPresent([QuickCommandParameter].self, forKey: .parameters) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(command, forKey: .command)
        if !parameters.isEmpty { try container.encode(parameters, forKey: .parameters) }
    }

    var validationError: QuickCommandTemplate.ValidationError? {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            QuickCommandTemplate.isSingleLine(name), QuickCommandTemplate.isSingleLine(command)
        else { return .invalidPreset }
        guard !parameters.isEmpty else { return nil }
        do {
            _ = try QuickCommandTemplate(command: command, parameters: parameters)
            return nil
        } catch let error as QuickCommandTemplate.ValidationError {
            return error
        } catch {
            return .invalidTemplate
        }
    }

    var isValid: Bool { validationError == nil }

    @MainActor
    func resolvedCommand(values: [String: String]) throws -> String {
        if let error = validationError { throw error }
        guard !parameters.isEmpty else { return command }
        return try QuickCommandTemplate(command: command, parameters: parameters)
            .render(values: values, quote: TerminalSession.shellQuote)
    }
}

/// Only complete, unquoted words may be replaced. Literal command text keeps
/// its original spelling so the preview and the terminal receive the same line.
struct QuickCommandTemplate {
    static let maximumParameters = 16
    static let maximumChoices = 100
    static let maximumValueBytes = 4_096
    static let maximumCommandBytes = 16_384
    enum ValidationError: Error, Equatable, LocalizedError {
        case invalidPreset
        case invalidTemplate
        case invalidParameter(String)
        case unknownParameter(String)
        case unusedParameter(String)
        case invalidValue(String)
        case invalidChoice(String)
        case tooLarge

        var errorDescription: String? {
            switch self {
            case .invalidPreset:
                return String(localized: "Enter a name and a single-line command.")
            case .invalidTemplate:
                return String(
                    localized: "Use {{name}} as a separate, unquoted argument in a single command without shell expansions or operators.")
            case .invalidParameter(let name):
                return String(localized: "Check the name, default value, and choices for parameter “\(name)”.")
            case .unknownParameter(let name):
                return String(localized: "Define parameter “\(name)” before using it.")
            case .unusedParameter(let name):
                return String(localized: "Add {{\(name)}} to the command or remove this parameter.")
            case .invalidValue(let name):
                return String(localized: "Enter a single-line value for parameter “\(name)”.")
            case .invalidChoice(let name):
                return String(localized: "Choose a listed value for parameter “\(name)”.")
            case .tooLarge:
                return String(localized: "Use at most 16 parameters, 100 choices per parameter, 4 KB per value, and a 16 KB command.")
            }
        }
    }

    private enum Part {
        case literal(String)
        case parameter(String)
    }

    private let parts: [Part]
    private let parameters: [QuickCommandParameter]

    init(command: String, parameters: [QuickCommandParameter]) throws {
        guard Self.isSingleLine(command), !command.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ValidationError.invalidTemplate
        }
        guard command.utf8.count <= Self.maximumCommandBytes, parameters.count <= Self.maximumParameters else {
            throw ValidationError.tooLarge
        }
        var names = Set<String>()
        for parameter in parameters {
            guard parameter.isValid, names.insert(parameter.name).inserted else {
                throw ValidationError.invalidParameter(parameter.name)
            }
        }
        var parts: [Part] = []
        var usedNames = Set<String>()
        var index = command.startIndex
        var literalStart = index
        var wordCount = 0
        var hasCommandWord = false
        while index < command.endIndex {
            if command[index] == " " {
                index = command.index(after: index)
                continue
            }
            let wordStart = index
            var quote: Character?
            var escaped = false
            while index < command.endIndex {
                let character = command[index]
                if escaped {
                    escaped = false
                } else if character == "\\", quote != "'" {
                    escaped = true
                } else if let currentQuote = quote {
                    if character == currentQuote { quote = nil }
                } else if character == "'" || character == "\"" {
                    quote = character
                } else if character == " " {
                    break
                }
                index = command.index(after: index)
            }
            guard quote == nil, !escaped else { throw ValidationError.invalidTemplate }
            let word = String(command[wordStart ..< index])
            if word.hasPrefix("{{"), word.hasSuffix("}}") {
                let name = String(word.dropFirst(2).dropLast(2))
                guard hasCommandWord, QuickCommandParameter.isValidName(name) else { throw ValidationError.invalidTemplate }
                guard names.contains(name) else { throw ValidationError.unknownParameter(name) }
                parts.append(.literal(String(command[literalStart ..< wordStart])))
                parts.append(.parameter(name))
                literalStart = index
                usedNames.insert(name)
            } else {
                guard Self.isLiteralWord(word, isCommand: !hasCommandWord) else { throw ValidationError.invalidTemplate }
                if !hasCommandWord, word.range(of: #"^[A-Za-z_][A-Za-z0-9_]*="#, options: .regularExpression) == nil {
                    hasCommandWord = true
                }
            }
            wordCount += 1
        }
        guard wordCount > 0, hasCommandWord else { throw ValidationError.invalidTemplate }
        for parameter in parameters where !usedNames.contains(parameter.name) {
            throw ValidationError.unusedParameter(parameter.name)
        }
        parts.append(.literal(String(command[literalStart...])))
        self.parts = parts
        self.parameters = parameters
    }

    func render(values: [String: String], quote: (String) -> String) throws -> String {
        let names = Set(parameters.map(\.name))
        if let unknown = values.keys.sorted().first(where: { !names.contains($0) }) {
            throw ValidationError.unknownParameter(unknown)
        }
        var resolved: [String: String] = [:]
        for parameter in parameters {
            let value = values[parameter.name] ?? parameter.defaultValue
            guard Self.isSingleLine(value), value.utf8.count <= Self.maximumValueBytes else {
                throw ValidationError.invalidValue(parameter.name)
            }
            guard parameter.kind != .dropdown || parameter.choices.contains(value) else {
                throw ValidationError.invalidChoice(parameter.name)
            }
            resolved[parameter.name] = quote(value)
        }
        let command = parts.map { part in
            switch part {
            case .literal(let text): return text
            case .parameter(let name): return resolved[name]!
            }
        }.joined()
        guard command.utf8.count <= Self.maximumCommandBytes else { throw ValidationError.tooLarge }
        return command
    }

    static func isSingleLine(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy {
            $0.value > 0x1f && !(0x7f ... 0x9f).contains($0.value) && $0.value != 0x2028 && $0.value != 0x2029
        }
    }

    private static func isLiteralWord(_ word: String, isCommand: Bool) -> Bool {
        // Reserved words start compound shell syntax even without an operator.
        let reserved = [
            "if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac", "function", "select", "repeat",
            "coproc", "[[", "]]",
        ]
        guard !(isCommand && reserved.contains(word)), !word.contains("{{"), !word.contains("}}") else { return false }
        var quote: Character?
        var escaped = false
        for character in word {
            if escaped {
                escaped = false
            } else if character == "\\", quote != "'" {
                escaped = true
            } else if let currentQuote = quote {
                if character == currentQuote {
                    quote = nil
                } else if currentQuote == "\"", "$`!".contains(character) {
                    return false
                }
            } else if character == "'" || character == "\"" {
                quote = character
            } else if ";&|<>(){}$`#!*?[]~".contains(character) {
                return false
            }
        }
        return quote == nil && !escaped
    }
}
