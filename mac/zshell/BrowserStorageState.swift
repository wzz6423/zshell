import Foundation

/// 网站存储由 WebKit 共享，自动化只允许读写目标来源的状态。
struct BrowserStorageState {
    enum Format: String {
        case storageState = "storage-state"
        case cookies
    }

    static let maximumBytes = 262_144
    static let maximumCookies = 256
    static let maximumStorageEntries = 1_000

    let cookies: [HTTPCookie]
    let localStorage: [String: String]?

    static func origin(for url: URL) throws -> String {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host?.lowercased(), !host.isEmpty,
              url.user == nil, url.password == nil,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw invalid("Storage state requires an HTTP or HTTPS page without embedded credentials.")
        }
        components.scheme = scheme
        components.host = host
        if components.port == (scheme == "https" ? 443 : 80) { components.port = nil }
        components.path = ""
        components.query = nil
        components.fragment = nil
        guard let origin = components.string else { throw invalid("Invalid page origin.") }
        return origin
    }

    static func includes(_ cookie: HTTPCookie, for url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        let domain = cookie.domain.lowercased()
        let matches = domain.hasPrefix(".")
            ? host == String(domain.dropFirst()) || host.hasSuffix(domain)
            : host == domain
        return matches
            && (!cookie.isSecure || url.scheme?.lowercased() == "https")
    }

    func encoded(format: Format, for url: URL) throws -> Data {
        let data: Data
        switch format {
        case .storageState:
            let storage = (localStorage ?? [:]).sorted(by: { $0.key < $1.key }).map {
                ZshellJSONValue.object(["name": .string($0.key), "value": .string($0.value)])
            }
            let value = ZshellJSONValue.object([
                "cookies": .array(cookies.map { Self.cookieJSON($0) }),
                "origins": .array([.object([
                    "origin": .string(try Self.origin(for: url)), "localStorage": .array(storage),
                ])]),
            ])
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            data = try encoder.encode(value)
        case .cookies:
            var text = "# Netscape HTTP Cookie File\n# SameSite and localStorage require storage-state JSON.\n"
            for cookie in cookies {
                let domain = (cookie.isHTTPOnly ? "#HttpOnly_" : "") + cookie.domain
                let fields = [domain, cookie.domain.hasPrefix(".") ? "TRUE" : "FALSE", cookie.path,
                              cookie.isSecure ? "TRUE" : "FALSE",
                              String(Int(cookie.expiresDate?.timeIntervalSince1970 ?? 0)), cookie.name, cookie.value]
                guard fields.allSatisfy({ !$0.contains(where: { $0 == "\t" || $0 == "\n" || $0 == "\r" }) }) else {
                    throw Self.invalid("A cookie cannot be represented in Netscape format.")
                }
                text += fields.joined(separator: "\t") + "\n"
            }
            data = Data(text.utf8)
        }
        guard data.count <= Self.maximumBytes else { throw Self.invalid("Storage state is limited to 256 KiB.") }
        return data
    }

    static func decode(_ data: Data, format: Format, for url: URL) throws -> Self {
        guard !data.isEmpty, data.count <= maximumBytes else { throw invalid("Storage state is limited to 256 KiB.") }
        let origin = try origin(for: url)
        let values: [ZshellJSONValue]
        var storage: [String: String]?
        switch format {
        case .storageState:
            guard let json = try? JSONDecoder().decode(ZshellJSONValue.self, from: data),
                  let object = json.objectValue,
                  Set(object.keys).isSubset(of: ["cookies", "origins"]),
                  let cookies = object["cookies"]?.arrayValue,
                  let origins = object["origins"]?.arrayValue, origins.count <= 1 else {
                throw invalid("Expected Playwright storage-state JSON with cookies and at most the current origin.")
            }
            values = cookies
            if let entry = origins.first {
                guard let object = entry.objectValue, Set(object.keys) == ["origin", "localStorage"],
                      object["origin"]?.stringValue == origin,
                      let entries = object["localStorage"]?.arrayValue else {
                    throw invalid("Every storage origin must exactly match the target page origin.")
                }
                storage = try decodeLocalStorage(entries)
            }
        case .cookies:
            guard let text = String(data: data, encoding: .utf8) else { throw invalid("Cookie files must contain UTF-8 text.") }
            var entries: [ZshellJSONValue] = []
            for line in text.components(separatedBy: .newlines) where !line.isEmpty {
                let httpOnly = line.hasPrefix("#HttpOnly_")
                if line.hasPrefix("#"), !httpOnly { continue }
                let fields = (httpOnly ? String(line.dropFirst(10)) : line).components(separatedBy: "\t")
                guard fields.count == 7, ["TRUE", "FALSE"].contains(fields[1]),
                      ["TRUE", "FALSE"].contains(fields[3]), let expires = Double(fields[4]),
                      !fields[4].isEmpty, fields[4].utf8.allSatisfy({ (48...57).contains($0) }),
                      expires.isFinite, expires >= 0 else {
                    throw invalid("Invalid Netscape cookie record.")
                }
                let host = fields[0].hasPrefix(".") ? String(fields[0].dropFirst()) : fields[0]
                let domain = (fields[1] == "TRUE" ? "." : "") + host
                entries.append(.object([
                    "name": .string(fields[5]), "value": .string(fields[6]), "domain": .string(domain),
                    "path": .string(fields[2]), "secure": .bool(fields[3] == "TRUE"), "httpOnly": .bool(httpOnly),
                    "expires": .number(expires == 0 ? -1 : expires), "sameSite": .string("Lax"),
                ]))
            }
            values = entries
        }
        guard values.count <= maximumCookies else { throw invalid("Storage state supports at most 256 cookies.") }
        var identities = Set<String>()
        let cookies = try values.map { value -> HTTPCookie in
            let cookie = try decodeCookie(value, for: url)
            guard identities.insert("\(cookie.domain)\n\(cookie.path)\n\(cookie.name)").inserted else {
                throw invalid("Duplicate cookie identity.")
            }
            return cookie
        }
        return Self(cookies: cookies, localStorage: storage)
    }

    static func decodeLocalStorage(_ entries: [ZshellJSONValue]) throws -> [String: String] {
        guard entries.count <= maximumStorageEntries else { throw invalid("localStorage supports at most 1000 entries.") }
        var storage: [String: String] = [:]
        for entry in entries {
            guard let object = entry.objectValue, Set(object.keys) == ["name", "value"],
                  let key = object["name"]?.stringValue, key.utf8.count <= 4_096,
                  let value = object["value"]?.stringValue, value.utf8.count <= 65_536,
                  storage.updateValue(value, forKey: key) == nil else {
                throw invalid("Invalid, duplicate, or oversized localStorage entry.")
            }
        }
        return storage
    }

    private static func decodeCookie(_ value: ZshellJSONValue, for url: URL) throws -> HTTPCookie {
        guard let object = value.objectValue,
              Set(object.keys) == ["name", "value", "domain", "path", "expires", "httpOnly", "secure", "sameSite"],
              let name = object["name"]?.stringValue, !name.isEmpty, name.utf8.count <= 4_096,
              name.utf8.allSatisfy({ (33...126).contains($0) && !Array("()<>@,;:\\\"/[]?={} \t".utf8).contains($0) }),
              let content = object["value"]?.stringValue, content.utf8.count <= 4_096,
              !content.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || $0 == ";" }),
              let domain = object["domain"]?.stringValue, domain.utf8.count <= 253,
              let path = object["path"]?.stringValue, path.hasPrefix("/"), path.utf8.count <= 2_048,
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || $0 == ";" }),
              case .number(let expires) = object["expires"], expires.isFinite,
              expires == -1 || (expires >= 0 && expires <= 253_402_300_799),
              let httpOnly = object["httpOnly"]?.boolValue, let secure = object["secure"]?.boolValue,
              let sameSite = object["sameSite"]?.stringValue, ["None", "Lax", "Strict"].contains(sameSite),
              sameSite != "None" || secure,
              !name.hasPrefix("__Secure-") || secure,
              !name.hasPrefix("__Host-") || (secure && path == "/" && !domain.hasPrefix(".")) else {
            throw invalid("Invalid cookie attributes or unsupported storage-state fields.")
        }
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name, .value: content, .domain: domain, .path: path,
            .sameSitePolicy: sameSite.lowercased(),
        ]
        if secure { properties[.secure] = "TRUE" }
        if httpOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        if expires == -1 { properties[.discard] = "TRUE" }
        else { properties[.expires] = Date(timeIntervalSince1970: expires) }
        guard let cookie = HTTPCookie(properties: properties), includes(cookie, for: url) else {
            throw invalid("Cookie domains must apply to the target host; Secure cookies require HTTPS.")
        }
        // 使用系统 Cookie 接收规则校验公有后缀，避免手写不完整的 PSL。
        guard let validationStore = URLSessionConfiguration.ephemeral.httpCookieStorage else { throw invalid("System cookie validation is unavailable.") }
        validationStore.cookieAcceptPolicy = .onlyFromMainDocumentDomain
        var validationProperties = properties
        validationProperties.removeValue(forKey: .expires)
        guard let validationCookie = HTTPCookie(properties: validationProperties) else { throw invalid("Invalid cookie.") }
        validationStore.setCookies([validationCookie], for: url, mainDocumentURL: url)
        guard validationStore.cookies?.contains(where: { $0.name == name && $0.domain == cookie.domain && $0.path == path }) == true else {
            throw invalid("Cookie domain was rejected by the system's site and public-suffix rules.")
        }
        return cookie
    }

    private static func cookieJSON(_ cookie: HTTPCookie) -> ZshellJSONValue {
        let sameSite: String
        switch cookie.sameSitePolicy?.rawValue.lowercased() {
        case "none": sameSite = "None"
        case "strict": sameSite = "Strict"
        default: sameSite = "Lax"
        }
        return .object([
            "name": .string(cookie.name), "value": .string(cookie.value), "domain": .string(cookie.domain),
            "path": .string(cookie.path), "expires": .number(cookie.expiresDate?.timeIntervalSince1970 ?? -1),
            "httpOnly": .bool(cookie.isHTTPOnly), "secure": .bool(cookie.isSecure), "sameSite": .string(sameSite),
        ])
    }

    private static func invalid(_ message: String) -> BrowserAutomationError {
        BrowserAutomationError(code: "invalid_storage_state", message: message)
    }
}
