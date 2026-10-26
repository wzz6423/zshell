import Foundation

enum BrowserStorageStateTests {
    static func verify() throws {
        let url = URL(string: "https://example.test/app")!
        let expiration = floor(Date().timeIntervalSince1970) + 3_600
        let cookie: [String: ZshellJSONValue] = [
            "name": .string("fixture"), "value": .string("test-only"), "domain": .string("example.test"),
            "path": .string("/"), "expires": .number(expiration), "httpOnly": .bool(true),
            "secure": .bool(true), "sameSite": .string("Strict"),
        ]
        func data(_ cookies: [[String: ZshellJSONValue]], origin: String = "https://example.test",
                  entries: [ZshellJSONValue] = [.object(["name": .string("login"), "value": .string("fixture-only")])]) throws -> Data {
            try JSONEncoder().encode(ZshellJSONValue.object([
                "cookies": .array(cookies.map(ZshellJSONValue.object)),
                "origins": .array([.object(["origin": .string(origin), "localStorage": .array(entries)])]),
            ]))
        }
        let initial = try BrowserStorageState.decode(data([cookie]), format: .storageState, for: url)
        precondition(initial.cookies.count == 1 && initial.localStorage?["login"] == "fixture-only")
        let restored = initial.cookies[0]
        precondition(restored.isHTTPOnly && restored.isSecure && restored.sameSitePolicy?.rawValue.lowercased() == "strict")
        precondition(restored.expiresDate?.timeIntervalSince1970 == expiration)
        let encoded = try initial.encoded(format: .storageState, for: url)
        let roundTrip = try BrowserStorageState.decode(encoded, format: .storageState, for: url)
        let reencoded = try roundTrip.encoded(format: .storageState, for: url)
        precondition(reencoded == encoded)

        var plain = cookie
        plain["httpOnly"] = .bool(false)
        plain["secure"] = .bool(false)
        plain["expires"] = .number(-1)
        plain["sameSite"] = .string("Lax")
        let session = try BrowserStorageState.decode(data([plain]), format: .storageState, for: url).cookies[0]
        precondition(!session.isHTTPOnly && !session.isSecure && session.expiresDate == nil && session.isSessionOnly)
        var none = cookie
        none["sameSite"] = .string("None")
        let noneCookie = try BrowserStorageState.decode(data([none]), format: .storageState, for: url).cookies[0]
        precondition(noneCookie.sameSitePolicy?.rawValue.lowercased() == "none")

        let netscape = try initial.encoded(format: .cookies, for: url)
        let imported = try BrowserStorageState.decode(netscape, format: .cookies, for: url)
        precondition(imported.cookies[0].isHTTPOnly && imported.cookies[0].isSecure && imported.localStorage == nil)
        precondition(imported.cookies[0].expiresDate == restored.expiresDate)
        let sessions = try BrowserStorageState(cookies: [session], localStorage: nil).encoded(format: .cookies, for: url)
        let importedSession = try BrowserStorageState.decode(sessions, format: .cookies, for: url).cookies[0]
        precondition(!importedSession.isSecure && !importedSession.isHTTPOnly && importedSession.expiresDate == nil)

        func reject(_ input: Data, format: BrowserStorageState.Format = .storageState, target: URL = url) throws {
            do {
                _ = try BrowserStorageState.decode(input, format: format, for: target)
                fatalError("Unsafe storage state was accepted")
            } catch let error as BrowserAutomationError { precondition(error.code == "invalid_storage_state") }
        }
        for origin in ["http://example.test", "https://other.test", "https://example.test:444", "https://example.test/", "file:///tmp"] {
            try reject(data([cookie], origin: origin))
        }
        for (key, value) in [
            ("domain", ZshellJSONValue.string("other.test")), ("domain", .string(".test")),
            ("domain", .string(".parent.example.test")), ("path", .string("invalid")),
            ("path", .string("/\r\nInjected")), ("name", .string("bad name")),
            ("value", .string("bad;value")), ("secure", .string("false")),
            ("httpOnly", .number(1)), ("expires", .string("-1")),
            ("expires", .number(-2)), ("expires", .number(1e20)), ("sameSite", .string("invalid")),
            ("partitionKey", .string("https://other.test")),
        ] {
            var invalid = cookie
            invalid[key] = value
            try reject(data([invalid]))
        }
        try reject(data([cookie, cookie]))
        try reject(data(Array(repeating: cookie, count: 257)))
        try reject(data([cookie], entries: [.object(["name": .string("x"), "value": .bool(true)])]))
        try reject(data([cookie], entries: [.object(["name": .string("x"), "value": .string(String(repeating: "a", count: 65_537))])]))
        try reject(data([cookie]), target: URL(string: "http://example.test")!)
        try reject(Data(repeating: 65, count: BrowserStorageState.maximumBytes + 1))
        try reject(Data("[]".utf8))
        try reject(Data("example.test\tINVALID\t/\tFALSE\t0\tx\ty\n".utf8), format: .cookies)
        try reject(Data(".other.test\tTRUE\t/\tFALSE\t0\tx\ty\n".utf8), format: .cookies)
        try reject(data([cookie]), target: URL(string: "https://app.example.test")!)
        var parent = cookie
        parent["domain"] = .string(".example.test")
        let subdomain = URL(string: "https://app.example.test")!
        let parentState = try BrowserStorageState.decode(data([parent], origin: "https://app.example.test"), format: .storageState, for: subdomain)
        precondition(parentState.cookies.first?.domain == ".example.test")
        let withoutDot = Data("example.test\tTRUE\t/\tFALSE\t0\tfixture\ttest-only\n".utf8)
        let includedSubdomains = try BrowserStorageState.decode(withoutDot, format: .cookies, for: subdomain)
        precondition(includedSubdomains.cookies.first?.domain == ".example.test")
        let dottedHostOnly = Data(".example.test\tFALSE\t/\tFALSE\t0\tfixture\ttest-only\n".utf8)
        let hostOnly = try BrowserStorageState.decode(dottedHostOnly, format: .cookies, for: url)
        precondition(hostOnly.cookies.first?.domain == "example.test")
        try reject(dottedHostOnly, format: .cookies, target: subdomain)
        if CommandLine.arguments.count > 1 {
            let curlJar = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
            let curlState = try BrowserStorageState.decode(curlJar, format: .cookies, for: subdomain)
            precondition(curlState.cookies.first?.domain == ".example.test" && curlState.cookies.first?.isHTTPOnly == true)
        }
        try reject(data([parent], origin: "https://evil-example.test"), target: URL(string: "https://evil-example.test")!)
        for (host, domain) in [("app.example.com", ".com"), ("app.example.co.uk", ".co.uk")] {
            var suffix = cookie
            suffix["domain"] = .string(domain)
            try reject(data([suffix], origin: "https://" + host), target: URL(string: "https://" + host)!)
        }
        let normalized = try BrowserStorageState.origin(for: URL(string: "https://EXAMPLE.test:443/a?q=1")!)
        precondition(normalized == "https://example.test")
        print("Storage-state codec: JSON/Netscape round trips, attributes, origin/domain/public-suffix scope, type and size rejection passed")
    }
}
