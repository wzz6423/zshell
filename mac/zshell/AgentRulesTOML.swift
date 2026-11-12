import Foundation

/// The nested agent file deliberately has its own grammar; config.toml stays
/// flat and retains the app's existing import and migration behavior.
nonisolated enum AgentRulesTOML {
    indirect enum Value: Equatable {
        case string(String)
        case integer(Int)
        case bool(Bool)
        case array([Value])
        case table([String: Value])

        var string: String? { if case let .string(value) = self { value } else { nil } }
        var integer: Int? { if case let .integer(value) = self { value } else { nil } }
        var bool: Bool? { if case let .bool(value) = self { value } else { nil } }
        var array: [Value]? { if case let .array(value) = self { value } else { nil } }
        var table: [String: Value]? { if case let .table(value) = self { value } else { nil } }
    }

    struct Failure: LocalizedError {
        let line: Int
        let reason: String
        var errorDescription: String? { String(localized: "Line \(line): \(reason)") }
    }

    static func parse(_ text: String) throws -> [[String: Value]] {
        guard text.utf8.count <= AgentRecognitionManifest.maximumFileBytes else {
            throw Failure(line: 1, reason: String(localized: "The rules file is too large."))
        }
        var parser = Parser(text)
        return try parser.parse()
    }

    private enum Path { case key(String), index(Int) }

    private struct Parser {
        var characters: [Character]
        var offset = 0
        var line = 1
        var nodes = 0

        init(_ text: String) { characters = Array(text.replacingOccurrences(of: "\r\n", with: "\n")) }
        var current: Character? { offset < characters.count ? characters[offset] : nil }

        mutating func advance() {
            if current == "\n" { line += 1 }
            offset += 1
        }

        mutating func whitespace(newlines: Bool) {
            while let character = current {
                if character == " " || character == "\t" || character == "\r" || newlines && character == "\n" {
                    advance()
                } else if character == "#" {
                    while current != nil, current != "\n" { advance() }
                } else { break }
            }
        }

        mutating func require(_ character: Character) throws {
            guard current == character else { throw failure() }
            advance()
        }

        func failure() -> Failure {
            Failure(line: line, reason: String(localized: "Expected an agent table, key, or TOML value."))
        }

        mutating func key() throws -> String {
            if current == "\"" || current == "'" { return try string() }
            var result = ""
            while let character = current,
                  character.isASCII && (character.isLetter || character.isNumber || character == "_" || character == "-") {
                result.append(character)
                advance()
            }
            guard !result.isEmpty else { throw failure() }
            return result
        }

        mutating func string() throws -> String {
            guard let quote = current, quote == "\"" || quote == "'" else { throw failure() }
            advance()
            var result = ""
            while let character = current {
                advance()
                if character == quote { return result }
                guard character != "\n", character != "\r", !character.unicodeScalars.contains(where: { $0.value < 0x20 && $0 != "\t" }) else {
                    throw failure()
                }
                if character != "\\" || quote == "'" { result.append(character); continue }
                guard let escaped = current else { throw failure() }
                advance()
                switch escaped {
                case "\"", "\\": result.append(escaped)
                case "b": result.append("\u{8}")
                case "t": result.append("\t")
                case "n": result.append("\n")
                case "f": result.append("\u{c}")
                case "r": result.append("\r")
                case "u", "U":
                    var digits = ""
                    for _ in 0..<(escaped == "u" ? 4 : 8) {
                        guard let digit = current, digit.isHexDigit else { throw failure() }
                        digits.append(digit)
                        advance()
                    }
                    guard let number = UInt32(digits, radix: 16), let scalar = UnicodeScalar(number) else { throw failure() }
                    result.unicodeScalars.append(scalar)
                default: throw failure()
                }
            }
            throw failure()
        }

        mutating func value(depth: Int = 0) throws -> Value {
            nodes += 1
            guard depth <= 8, nodes <= 16_384 else {
                throw Failure(line: line, reason: String(localized: "The rules contain too many nested values."))
            }
            whitespace(newlines: false)
            switch current {
            case "\"", "'": return .string(try string())
            case "[":
                advance()
                var values: [Value] = []
                whitespace(newlines: true)
                while current != "]" {
                    values.append(try value(depth: depth + 1))
                    whitespace(newlines: true)
                    if current == "]" { break }
                    try require(",")
                    whitespace(newlines: true)
                }
                try require("]")
                return .array(values)
            case "{":
                advance()
                var values: [String: Value] = [:]
                whitespace(newlines: false)
                while current != "}" {
                    let name = try key()
                    guard values[name] == nil else { throw failure() }
                    whitespace(newlines: false)
                    try require("=")
                    values[name] = try value(depth: depth + 1)
                    whitespace(newlines: false)
                    if current == "}" { break }
                    try require(",")
                    whitespace(newlines: false)
                }
                try require("}")
                return .table(values)
            default:
                var result = ""
                while let character = current, ![" ", "\t", "\r", "\n", ",", "#", "]", "}"].contains(character) {
                    result.append(character)
                    advance()
                }
                if result == "true" { return .bool(true) }
                if result == "false" { return .bool(false) }
                guard let number = Int(result), !result.isEmpty else { throw failure() }
                return .integer(number)
            }
        }

        mutating func parse() throws -> [[String: Value]] {
            var root: Value = .table([:])
            var path: [Path] = []
            whitespace(newlines: true)
            while current != nil {
                if current == "[" {
                    advance()
                    try require("[")
                    var names = [try key()]
                    while current == "." { advance(); names.append(try key()) }
                    try require("]")
                    try require("]")
                    guard names.first == "agents", names.count <= 8,
                          names.dropFirst().allSatisfy({ ["rules", "all", "any", "not"].contains($0) }) else { throw failure() }
                    path = try appendTable(names, to: &root)
                } else {
                    let name = try key()
                    whitespace(newlines: false)
                    try require("=")
                    let entry = try value()
                    guard !path.isEmpty else { throw failure() }
                    try update(&root, path: path[...]) { table in
                        guard table[name] == nil else { throw failure() }
                        table[name] = entry
                    }
                }
                whitespace(newlines: false)
                guard current == nil || current == "\n" else { throw failure() }
                whitespace(newlines: true)
            }
            guard let agents = root.table?["agents"]?.array else { return [] }
            return try agents.map { guard let table = $0.table else { throw failure() }; return table }
        }

        func appendTable(_ names: [String], to root: inout Value) throws -> [Path] {
            var path: [Path] = []
            for (index, name) in names.enumerated() {
                var selected = 0
                try update(&root, path: path[...]) { table in
                    var array = table[name]?.array ?? []
                    if index == names.count - 1 { array.append(.table([:])) }
                    guard !array.isEmpty, array.count <= 256 else { throw failure() }
                    selected = array.count - 1
                    table[name] = .array(array)
                }
                path += [.key(name), .index(selected)]
            }
            return path
        }

        func update(_ value: inout Value, path: ArraySlice<Path>, body: (inout [String: Value]) throws -> Void) throws {
            guard let first = path.first else {
                guard case var .table(table) = value else { throw failure() }
                try body(&table)
                value = .table(table)
                return
            }
            switch (first, value) {
            case let (.key(name), .table(table)):
                var table = table
                var child = table[name] ?? .array([])
                try update(&child, path: path.dropFirst(), body: body)
                table[name] = child
                value = .table(table)
            case let (.index(index), .array(array)):
                var array = array
                guard array.indices.contains(index) else { throw failure() }
                try update(&array[index], path: path.dropFirst(), body: body)
                value = .array(array)
            default: throw failure()
            }
        }
    }
}
