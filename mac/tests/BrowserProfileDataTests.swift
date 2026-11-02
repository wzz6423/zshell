import AppKit
import Foundation
import WebKit

@main
struct BrowserProfileDataTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let home = URL(fileURLWithPath: CommandLine.arguments[1])
        precondition(FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path == home.standardizedFileURL.path)
        try activeChromeHistory(scratch: home)
        try discoveryDistinguishesMissingFromDenied(scratch: URL(fileURLWithPath: CommandLine.arguments[1]))
        let found = BrowserProfileData.discover(home: home)
        precondition(found.blocked.isEmpty && found.profiles.count == 2)
        let chrome = found.profiles.first { $0.kind == .chrome }!
        let firefox = found.profiles.first { $0.kind == .firefox }!
        precondition(chrome.name == "Fixture Chrome" && firefox.name == "Fixture Firefox")
        let selection: BrowserProfileSelection = [.cookies, .history, .sessions]
        let first = BrowserProfileData.preview(chrome, selection: selection)
        precondition(first.cookieCount == 3 && first.cookieError == nil)
        precondition(first.history.total == 2 && first.history.values.count == 1 && first.history.skipped == 1)
        precondition(first.sessions.total == 2 && first.sessions.skipped == 1)
        precondition(first.sessions.values.map(\.url) == ["https://example.test/current"])
        let cookies = BrowserProfileData.cookies(chrome, password: Data("fixture-password".utf8))
        precondition(cookies.error == nil && cookies.total == 3 && cookies.skipped == 2 && cookies.values.count == 1)
        precondition(cookies.values[0].value == "fixture-only" && cookies.values[0].httpOnly)
        let wrongKey = BrowserProfileData.cookies(chrome, password: Data("incorrect".utf8))
        precondition(wrongKey.values.isEmpty && wrongKey.skipped == 3)
        let second = BrowserProfileData.preview(firefox, selection: selection)
        precondition(second.cookieCount == 4 && second.history.values.count == 1)
        precondition(second.sessions.total == 3 && second.sessions.skipped == 2)
        precondition(second.sessions.values.map(\.url) == ["https://example.test/two"])
        let firefoxCookies = BrowserProfileData.cookies(firefox)
        precondition(firefoxCookies.values.count == 2 && firefoxCookies.skipped == 2)
        precondition(firefoxCookies.values[0].sameSite == "Strict" && firefoxCookies.values[0].expires == 2_000_000_000)
        precondition(firefoxCookies.values[1].name == "session" && firefoxCookies.values[1].expires == -1)
        let bad = firefox.directory.appendingPathComponent("broken.jsonlz4")
        try Data("bad".utf8).write(to: bad)
        do { _ = try BrowserProfileSessionReader.firefox(bad); fatalError("Invalid LZ4 accepted") }
        catch BrowserProfileSessionReader.ReadError.invalidFile { }
        let minimumIndex = firefox.directory.appendingPathComponent("minimum-index.jsonlz4")
        let maximumIndex = firefox.directory.appendingPathComponent("maximum-index.jsonlz4")
        for file in [minimumIndex, maximumIndex] {
            let boundary = try BrowserProfileSessionReader.firefox(file)
            precondition(boundary.values.map(\.url) == ["https://example.test/boundary"])
        }
        let invalidDirectory = home.appendingPathComponent("invalid-profile")
        try FileManager.default.createDirectory(at: invalidDirectory, withIntermediateDirectories: true)
        try Data("invalid SQLite".utf8).write(to: invalidDirectory.appendingPathComponent("cookies.sqlite"))
        let invalid = BrowserProfile(kind: .firefox, name: "Invalid", directory: invalidDirectory)
        precondition(BrowserProfileData.preview(invalid, selection: [.cookies, .sessions]).cookieError != nil)
        precondition(BrowserProfileData.cookies(invalid).error != nil)
        precondition(BrowserProfileData.preview(invalid, selection: [.sessions]).sessions.error != nil)
        try await firefoxSameSite(scratch: home, expires: Double(CommandLine.arguments[2])!)
        print("Profile discovery, Chromium encryption/domain binding, partition skips, Firefox LZ4, history and sessions passed")
    }

    static func activeChromeHistory(scratch: URL) throws {
        for name in ["history-exclusive", "history-journal", "history-wal"] {
            let profile = BrowserProfile(kind: .chrome, name: name, directory: scratch.appendingPathComponent(name))
            let preview = BrowserProfileData.preview(profile, selection: [.history])
            let expected = name == "history-wal"
                ? ["https://example.test/wal", "https://example.test/committed"]
                : ["https://example.test/committed"]
            guard preview.history.error == nil, preview.history.values.map(\.url) == expected,
                  preview.history.values.allSatisfy({ $0.title == "Committed" }) else {
                throw NSError(domain: "HistoryTest", code: 1, userInfo: [NSLocalizedDescriptionKey:
                    "\(name): committed history unavailable: \(preview.history.error ?? "unexpected rows")"])
            }
        }
        let temporary = FileManager.default.temporaryDirectory
        let leftovers = try FileManager.default.contentsOfDirectory(at: temporary, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("zshell-browser-database-") }
        precondition(leftovers.isEmpty, "Private database snapshots were not removed")
        print("Active Chrome history: exclusive lock, rollback recovery, committed WAL and snapshot cleanup passed")
    }

    @MainActor static func firefoxSameSite(scratch: URL, expires: Double) async throws {
        let profile = BrowserProfile(kind: .firefox, name: "SameSite", directory: scratch.appendingPathComponent("same-site-current"))
        let result = BrowserProfileData.cookies(profile)
        precondition(result.error == nil && result.total == 17 && result.skipped == 2 && result.values.count == 15)
        let cookies = Dictionary(uniqueKeysWithValues: result.values.map { ($0.name, $0) })
        for prefix in ["persistent_", "session_"] {
            precondition(cookies[prefix + "unset"]?.sameSite == "Lax")
            precondition(cookies[prefix + "unset_secure"]?.sameSite == "Lax")
            precondition(cookies[prefix + "none_insecure"] == nil, "Explicit None without Secure must stay rejected")
            precondition(cookies[prefix + "none_secure"]?.sameSite == "None")
            precondition(cookies[prefix + "lax"]?.sameSite == "Lax")
            precondition(cookies[prefix + "strict"]?.sameSite == "Strict")
            precondition(cookies[prefix + "null"]?.sameSite == "Lax")
            precondition(cookies[prefix + "unknown"]?.sameSite == "Lax")
        }
        precondition(cookies["session_missing"]?.sameSite == "Lax")
        var imported = result.values
        for kind in ["missing", "null"] {
            let legacy = BrowserProfile(kind: .firefox, name: "Legacy", directory: scratch.appendingPathComponent("same-site-" + kind))
            let records = BrowserProfileData.cookies(legacy)
            precondition(records.error == nil && records.total == 1 && records.skipped == 0 && records.values.count == 1)
            precondition(records.values[0].sameSite == "Lax" && records.values[0].expires == expires)
            imported.append(contentsOf: records.values)
        }
        let dataStore = WKWebsiteDataStore.nonPersistent()
        let store = dataStore.httpCookieStore
        for item in imported {
            var properties: [HTTPCookiePropertyKey: Any] = [
                .name: item.name, .value: item.value, .domain: item.domain, .path: item.path,
                .sameSitePolicy: item.sameSite.lowercased(),
            ]
            if item.secure { properties[.secure] = "TRUE" }
            if item.httpOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
            if item.expires == -1 { properties[.discard] = "TRUE" }
            else { properties[.expires] = Date(timeIntervalSince1970: item.expires) }
            let cookie = HTTPCookie(properties: properties)!
            await withCheckedContinuation { continuation in store.setCookie(cookie) { continuation.resume() } }
        }
        let stored = await withCheckedContinuation { continuation in
            store.getAllCookies { continuation.resume(returning: $0) }
        }
        precondition(stored.count == imported.count,
                     "WebKit retained \(stored.map(\.name)); expected \(imported.map(\.name))")
        for item in imported {
            let cookie = stored.first { $0.name == item.name }!
            precondition(cookie.value == item.value && cookie.isSecure == item.secure && cookie.isHTTPOnly == item.httpOnly)
            precondition(cookie.domain == item.domain && cookie.path == item.path)
            if item.expires == -1 { precondition(cookie.expiresDate == nil) }
            else { precondition(abs(cookie.expiresDate!.timeIntervalSince1970 - item.expires) < 1,
                                "\(item.name) expiry \(cookie.expiresDate!.timeIntervalSince1970), source \(item.expires)") }
            precondition(cookie.sameSitePolicy?.rawValue.lowercased() == item.sameSite.lowercased())
        }
        withExtendedLifetime(dataStore) {}
        print("Firefox missing/NULL/UNSET/unknown SameSite and explicit None restrictions passed; \(stored.count) cookies retained in real WebKit")
    }

    /// An untraversable browser folder must surface as blocked; a missing one must not.
    static func discoveryDistinguishesMissingFromDenied(scratch: URL) throws {
        let manager = FileManager.default
        let home = scratch.appendingPathComponent("discovery-home-\(UUID().uuidString)", isDirectory: true)
        let support = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        try manager.createDirectory(at: support, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: home) }
        let missing = BrowserProfileData.discover(home: home)
        precondition(missing.blocked.isEmpty && missing.profiles.isEmpty)
        let firefox = support.appendingPathComponent("Firefox", isDirectory: true)
        let google = support.appendingPathComponent("Google", isDirectory: true)
        try manager.createDirectory(at: firefox, withIntermediateDirectories: true)
        try Data("[Profile0]\nPath=Profiles/x\nIsRelative=1\n".utf8).write(to: firefox.appendingPathComponent("profiles.ini"))
        try manager.createDirectory(at: google.appendingPathComponent("Chrome"), withIntermediateDirectories: true)
        for folder in [firefox, google] { try manager.setAttributes([.posixPermissions: 0], ofItemAtPath: folder.path) }
        defer { for folder in [firefox, google] { try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) } }
        let denied = BrowserProfileData.discover(home: home)
        precondition(Set(denied.blocked) == [.chrome, .firefox] && denied.profiles.isEmpty, "\(denied.blocked)")
        print("Untraversable Chrome and Firefox folders are reported as blocked; missing folders are not")
    }
}
