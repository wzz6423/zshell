import Foundation

/// Conservative ABP conversion: unsupported filters are skipped as a whole,
/// so an option we cannot represent never silently widens a blocking rule.
nonisolated enum BrowserContentRules {
    struct Result: Sendable {
        let lists: [String]
        let converted: Int
        let skipped: Int
    }

    struct Rule: Encodable, Sendable {
        var trigger: Trigger
        let action: Action
    }

    struct Trigger: Encodable, Sendable {
        var urlFilter: String
        var caseSensitive: Bool?
        var ifDomain: [String]?
        var unlessDomain: [String]?
        var resourceType: [String]?
        var loadType: [String]?
        var loadContext: [String]?

        enum CodingKeys: String, CodingKey {
            case urlFilter = "url-filter", caseSensitive = "url-filter-is-case-sensitive"
            case ifDomain = "if-domain", unlessDomain = "unless-domain"
            case resourceType = "resource-type", loadType = "load-type", loadContext = "load-context"
        }
    }

    struct Action: Encodable, Sendable {
        let type: String
        var selector: String?
    }

    private struct Scope {
        var included: [String] = []
        var excluded: [String] = []
    }

    private struct Hiding {
        let selector: String
        let scope: Scope
        let exception: Bool
    }

    private static let types: [String: String] = [
        "script": "script", "image": "image", "stylesheet": "style-sheet",
        "font": "font", "media": "media", "xmlhttprequest": "raw",
        "subdocument": "document", "ping": "ping", "other": "raw",
    ]
    private static let subresources = ["image", "style-sheet", "script", "font", "raw", "svg-document", "media", "ping"]
    static let maximumFilters = 300_000
    static let maximumRulesPerList = 40_000

    static func convert(_ texts: [String], rulesPerList: Int = maximumRulesPerList) throws -> Result {
        var filters: [String] = []
        var seen: Set<String> = []
        for text in texts {
            for raw in text.split(whereSeparator: \.isNewline) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty || line.hasPrefix("!") || line.hasPrefix("[") { continue }
                guard filters.count < maximumFilters, line.utf8.count <= 16_384 else { throw ConversionError.limit }
                if seen.insert(line).inserted { filters.append(line) }
            }
            try Task.checkCancellation()
        }
        var blocks: [Rule] = []
        var exceptions: [Rule] = []
        var hiding: [Hiding] = []
        var skipped = 0
        for (index, line) in filters.enumerated() {
            if index % 1_024 == 0 { try Task.checkCancellation() }
            if let range = line.range(of: "#@#") ?? line.range(of: "##") {
                let selector = String(line[range.upperBound...])
                guard validSelector(selector), let scope = scope(String(line[..<range.lowerBound]), separator: ",") else {
                    skipped += 1
                    continue
                }
                hiding.append(Hiding(selector: selector, scope: scope, exception: line[range] == "#@#"))
            } else if let rules = network(line) {
                if line.hasPrefix("@@") { exceptions += rules } else { blocks += rules }
            } else { skipped += 1 }
        }

        let cosmeticExceptions = Dictionary(grouping: hiding.filter(\.exception), by: \.selector)
        var cosmetic: [Rule] = []
        for hide in hiding where !hide.exception {
            var scope = hide.scope
            let except = cosmeticExceptions[hide.selector] ?? []
            // Negated cosmetic exceptions cannot be represented by one native
            // trigger. Skipping this selector preserves the exception safely.
            if except.contains(where: { $0.scope.included.isEmpty || !$0.scope.excluded.isEmpty }) {
                skipped += 1
                continue
            }
            scope.excluded += except.flatMap(\.scope.included)
            guard let trigger = scoped(Trigger(urlFilter: ".*"), scope: scope) else {
                skipped += 1
                continue
            }
            cosmetic.append(Rule(trigger: trigger, action: Action(type: "css-display-none", selector: hide.selector)))
        }
        guard exceptions.count < rulesPerList else { throw ConversionError.limit }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var lists: [String] = []
        // Each native list evaluates exceptions independently. Repeat every
        // network exception in each chunk, keeping cosmetics in separate lists.
        let room = rulesPerList - exceptions.count
        guard (blocks.count + room - 1) / room + (cosmetic.count + rulesPerList - 1) / rulesPerList <= 12 else { throw ConversionError.limit }
        var encodedBytes = 0
        func encode(_ rules: [Rule]) throws -> String {
            let data = try encoder.encode(rules)
            encodedBytes += data.count
            guard data.count <= 16 * 1_024 * 1_024, encodedBytes <= 64 * 1_024 * 1_024 else { throw ConversionError.limit }
            return String(decoding: data, as: UTF8.self)
        }
        for start in stride(from: 0, to: blocks.count, by: room) {
            let chunk = Array(blocks[start..<min(start + room, blocks.count)]) + exceptions
            lists.append(try encode(chunk))
        }
        for start in stride(from: 0, to: cosmetic.count, by: rulesPerList) {
            lists.append(try encode(Array(cosmetic[start..<min(start + rulesPerList, cosmetic.count)])))
        }
        return Result(lists: lists, converted: filters.count - skipped, skipped: skipped)
    }

    private static func network(_ line: String) -> [Rule]? {
        var pattern = line.hasPrefix("@@") ? String(line.dropFirst(2)) : line
        var options: [Substring] = []
        if let dollar = pattern.lastIndex(of: "$") {
            options = pattern[pattern.index(after: dollar)...].split(separator: ",", omittingEmptySubsequences: false)
            pattern = String(pattern[..<dollar])
        }
        guard !pattern.isEmpty, !(pattern.hasPrefix("/") && pattern.hasSuffix("/")),
              !pattern.contains("#"), let regex = urlFilter(pattern) else { return nil }
        var trigger = Trigger(urlFilter: regex)
        var domainScope = Scope()
        var included: Set<String> = []
        var excluded: Set<String> = []
        for raw in options {
            let negated = raw.hasPrefix("~")
            let option = negated ? raw.dropFirst() : raw
            if let type = types[String(option)] {
                if negated { excluded.insert(type) } else { included.insert(type) }
            } else if option == "third-party" {
                trigger.loadType = [negated ? "first-party" : "third-party"]
            } else if option == "match-case", !negated {
                trigger.caseSensitive = true
            } else if option.hasPrefix("domain="), !negated,
                      let parsed = scope(String(option.dropFirst(7)), separator: "|") {
                domainScope = parsed
            } else { return nil }
        }
        let selected = (included.isEmpty ? Set(subresources + ["document"]) : included).subtracting(excluded)
        guard !selected.isEmpty, let scopedTrigger = scoped(trigger, scope: domainScope) else { return nil }
        let action = Action(type: line.hasPrefix("@@") ? "ignore-previous-rules" : "block")
        var rules: [Rule] = []
        let nonDocuments = selected.subtracting(["document"]).sorted()
        if !nonDocuments.isEmpty {
            var resource = scopedTrigger
            resource.resourceType = nonDocuments
            rules.append(Rule(trigger: resource, action: action))
        }
        if selected.contains("document") {
            var frame = scopedTrigger
            frame.resourceType = ["document"]
            frame.loadContext = ["child-frame"]
            rules.append(Rule(trigger: frame, action: action))
        }
        return rules
    }

    private static func scope(_ text: String, separator: Character) -> Scope? {
        if text.isEmpty { return Scope() }
        var result = Scope()
        for part in text.split(separator: separator, omittingEmptySubsequences: false) {
            let negative = part.hasPrefix("~")
            let domain = String(negative ? part.dropFirst() : part[...]).lowercased()
            guard !domain.isEmpty, !domain.hasPrefix("."), !domain.hasSuffix("."),
                  domain.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || [45, 46, 95].contains($0) }) else { return nil }
            if negative { result.excluded.append(domain) } else { result.included.append(domain) }
        }
        return result
    }

    private static func scoped(_ trigger: Trigger, scope: Scope) -> Trigger? {
        var result = trigger
        if scope.included.isEmpty {
            if !scope.excluded.isEmpty { result.unlessDomain = Array(Set(scope.excluded)).sorted().map { "*" + $0 } }
        } else {
            let includes = scope.included.filter { domain in
                !scope.excluded.contains { domain == $0 || domain.hasSuffix("." + $0) }
            }
            guard !includes.isEmpty else { return nil }
            // Native WebKit forbids combining domain inclusions and exclusions.
            // An excluded child domain must never be discarded to widen a rule.
            guard !includes.contains(where: { domain in scope.excluded.contains { $0.hasSuffix("." + domain) } }) else { return nil }
            result.ifDomain = Array(Set(includes)).sorted().map { "*" + $0 }
        }
        return result
    }

    private static func validSelector(_ text: String) -> Bool {
        guard !text.isEmpty, !text.hasPrefix("+js("), !text.hasPrefix("^"),
              !text.contains("{"), !text.contains("}"), text.utf8.allSatisfy({ $0 >= 32 && $0 < 127 }) else { return false }
        let unsupported = [":-abp-", ":has-text(", ":contains(", ":xpath(", ":matches-", ":upward(", ":remove(", ":style(", ":min-text-length(", ":watch-", ":others(", ":if(", ":if-not(", ":nth-ancestor(", ":-ext-", ":remove-attr(", ":remove-class("]
        return !unsupported.contains(where: text.contains)
    }

    static func urlFilter(_ text: String) -> String? {
        guard text.utf8.allSatisfy({ $0 >= 32 && $0 < 127 }) else { return nil }
        var pattern = text
        var result = ""
        var inHost = false
        if pattern.hasPrefix("||") {
            pattern.removeFirst(2)
            guard let first = pattern.first, first != "*", first != "^" else { return nil }
            result = #"^[^:]+://+([^:/]+\.)?"#
            inHost = true
        } else if pattern.hasPrefix("|") {
            pattern.removeFirst()
            result = "^"
        }
        let anchoredEnd = pattern.hasSuffix("|")
        if anchoredEnd { pattern.removeLast() }
        for (index, character) in pattern.enumerated() {
            switch character {
            case "*":
                if !result.hasSuffix(".*") { result += ".*" }
            case "^":
                if inHost {
                    result += "[:/]"
                    inHost = false
                } else if index == pattern.count - 1 {
                    result += anchoredEnd ? #"[^a-zA-Z0-9_.%-]?$"# : #"([^a-zA-Z0-9_.%-].*)?$"#
                } else { result += #"[^a-zA-Z0-9_.%-]"# }
            default:
                if #".+?()[]{}\$|"#.contains(character) { result += "\\" }
                result.append(character)
                if "/:?#".contains(character) { inHost = false }
            }
        }
        if anchoredEnd && !result.hasSuffix("$") { result += "$" }
        return result.isEmpty ? ".*" : result
    }

    enum ConversionError: Error { case limit }
}
