import CommonCrypto
import CryptoKit
import Foundation
import Security
import SQLite3

nonisolated struct BrowserProfile: Sendable {
    enum Kind: Sendable {
        case chrome, firefox
        var browserName: String { self == .chrome ? "Google Chrome" : "Firefox" }
        func root(home: URL) -> URL {
            home.appendingPathComponent(self == .chrome ? "Library/Application Support/Google/Chrome"
                                                        : "Library/Application Support/Firefox", isDirectory: true)
        }
    }
    let kind: Kind
    let name: String
    let directory: URL

    var browserName: String { kind.browserName }
}

nonisolated struct BrowserProfileCookie: Sendable {
    let name: String
    let value: String
    let domain: String
    let path: String
    let expires: Double
    let secure: Bool
    let httpOnly: Bool
    let sameSite: String
}

nonisolated struct BrowserProfileResult<Value: Sendable>: Sendable {
    var values: [Value] = []
    var total = 0
    var skipped = 0
    var error: String?
}

nonisolated struct BrowserProfilePreview: Sendable {
    var cookieCount = 0
    var cookieDomains: [String] = []
    var cookieError: String?
    var cookieWarning: String?
    var history = BrowserProfileResult<BrowserImportedPage>()
    var sessions = BrowserProfileResult<BrowserImportedPage>()
}

nonisolated struct BrowserProfileSelection: OptionSet, Sendable {
    let rawValue: Int
    static let cookies = Self(rawValue: 1)
    static let history = Self(rawValue: 2)
    static let sessions = Self(rawValue: 4)
}

nonisolated enum BrowserProfileData {
    private static let historyLimit = 50_000
    private static let chromeEpoch = 11_644_473_600.0

    /// macOS 27 App Data Protection lets only the browser itself list these folders; `blocked` names each
    /// browser whose folder exists but could not be read, so one denial never hides the other browser.
    static func discover(home: URL) -> (profiles: [BrowserProfile], blocked: [BrowserProfile.Kind]) {
        let chrome = BrowserProfile.Kind.chrome.root(home: home)
        let firefox = BrowserProfile.Kind.firefox.root(home: home)
        var profiles: [BrowserProfile] = []
        var blocked: [BrowserProfile.Kind] = []
        let manager = FileManager.default
        // Read instead of checking existence first: an untraversable folder makes
        // `fileExists` report false, which would hide the browser from `blocked`.
        do {
            let state = try? Data(contentsOf: chrome.appendingPathComponent("Local State"))
            let json = state.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let cache = (json?["profile"] as? [String: Any])?["info_cache"] as? [String: [String: Any]] ?? [:]
            for directory in try manager.contentsOfDirectory(at: chrome, includingPropertiesForKeys: nil)
                where directory.lastPathComponent == "Default" || directory.lastPathComponent.hasPrefix("Profile ") {
                guard manager.fileExists(atPath: directory.appendingPathComponent("History").path)
                        || manager.fileExists(atPath: directory.appendingPathComponent("Cookies").path)
                        || manager.fileExists(atPath: directory.appendingPathComponent("Network/Cookies").path) else { continue }
                let name = cache[directory.lastPathComponent]?["name"] as? String ?? directory.lastPathComponent
                profiles.append(BrowserProfile(kind: .chrome, name: name, directory: directory))
            }
        } catch { if !isMissing(error) { blocked.append(.chrome) } }
        let ini = firefox.appendingPathComponent("profiles.ini")
        do {
            let text = try String(contentsOf: ini, encoding: .utf8)
            var sections: [[String: String]] = []
            var current: [String: String]?
            for raw in text.components(separatedBy: .newlines) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("[") {
                    if let current { sections.append(current) }
                    current = line.hasPrefix("[Profile") ? [:] : nil
                } else if let split = line.firstIndex(of: "="), current != nil {
                    current?[String(line[..<split])] = String(line[line.index(after: split)...])
                }
            }
            if let current { sections.append(current) }
            for section in sections {
                guard let path = section["Path"], !path.isEmpty else { continue }
                let directory = section["IsRelative"] == "1"
                    ? firefox.appendingPathComponent(path, isDirectory: true)
                    : URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
                guard manager.fileExists(atPath: directory.path) else { continue }
                profiles.append(BrowserProfile(kind: .firefox, name: section["Name"] ?? directory.lastPathComponent, directory: directory))
            }
        } catch { if !isMissing(error) { blocked.append(.firefox) } }
        return (profiles.sorted { ($0.browserName, $0.name) < ($1.browserName, $1.name) }, blocked)
    }

    private static func isMissing(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain, [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { return true }
        let posix = error.userInfo[NSUnderlyingErrorKey] as? NSError ?? error
        return posix.domain == NSPOSIXErrorDomain && [Int(ENOENT), Int(ENOTDIR)].contains(posix.code)
    }

    static func preview(_ profile: BrowserProfile, selection: BrowserProfileSelection) -> BrowserProfilePreview {
        var preview = BrowserProfilePreview()
        if selection.contains(.cookies) {
            do {
                let db = try Database(cookieFile(profile))
                let table = profile.kind == .chrome ? "cookies" : "moz_cookies"
                let domain = profile.kind == .chrome ? "host_key" : "host"
                try db.rows("SELECT COUNT(*) FROM \(table)") { preview.cookieCount = Int(sqlite3_column_int64($0, 0)) }
                try db.rows("SELECT DISTINCT \(domain) FROM \(table) ORDER BY \(domain) LIMIT 8") {
                    preview.cookieDomains.append(Database.text($0, 0))
                }
                if profile.kind == .firefox {
                    do {
                        if let session = try firefoxSessionFile(profile) {
                            let sessionCookies = try BrowserProfileSessionReader.firefoxCookies(session)
                            preview.cookieCount += sessionCookies.total
                            preview.cookieDomains.append(contentsOf: sessionCookies.values.prefix(8).map(\.domain))
                        }
                    } catch { preview.cookieWarning = error.localizedDescription }
                }
            } catch { preview.cookieError = error.localizedDescription }
        }
        if selection.contains(.history) { preview.history = history(profile) }
        if selection.contains(.sessions) { preview.sessions = sessions(profile) }
        return preview
    }

    static func cookies(_ profile: BrowserProfile, password: Data? = nil) -> BrowserProfileResult<BrowserProfileCookie> {
        var result = BrowserProfileResult<BrowserProfileCookie>()
        do {
            let db = try Database(cookieFile(profile))
            if profile.kind == .chrome {
                var version = 0
                try db.rows("SELECT value FROM meta WHERE key='version'") { version = Int(Database.text($0, 0)) ?? 0 }
                let columns = try db.columns("cookies")
                let partition = columns.contains("top_frame_site_key") ? "top_frame_site_key" : "''"
                let hasExpires = columns.contains("has_expires") ? "has_expires" : "expires_utc != 0"
                let sameSite = columns.contains("samesite") ? "samesite" : "-1"
                var key: Data?
                var keyError: Error?
                try db.rows("SELECT host_key,name,value,encrypted_value,path,expires_utc,is_secure,is_httponly,\(hasExpires),\(sameSite),\(partition) FROM cookies") { row in
                    result.total += 1
                    let host = Database.text(row, 0)
                    guard Database.text(row, 10).isEmpty else { result.skipped += 1; return }
                    let encrypted = Database.blob(row, 3)
                    var value = Database.text(row, 2)
                    if !encrypted.isEmpty {
                        if key == nil && keyError == nil {
                            do { key = try chromeKey(password: password ?? keychainPassword()) }
                            catch { keyError = error }
                        }
                        guard let key, let decrypted = try? decrypt(encrypted, key: key, domain: host, version: version) else {
                            result.skipped += 1
                            return
                        }
                        value = decrypted
                    }
                    let expires = sqlite3_column_int(row, 8) == 0 ? -1 : Double(sqlite3_column_int64(row, 5)) / 1_000_000 - chromeEpoch
                    let same = sqlite3_column_int(row, 9)
                    result.values.append(BrowserProfileCookie(name: Database.text(row, 1), value: value, domain: host,
                        path: Database.text(row, 4), expires: expires, secure: sqlite3_column_int(row, 6) != 0,
                        httpOnly: sqlite3_column_int(row, 7) != 0, sameSite: same == 0 ? "None" : same == 2 ? "Strict" : "Lax"))
                }
                if let keyError { result.error = keyError.localizedDescription }
            } else {
                let columns = try db.columns("moz_cookies")
                let attributes = columns.contains("originAttributes") ? "originAttributes" : "''"
                let sameSite = columns.contains("sameSite") ? "sameSite" : "0"
                // Firefox 142 (cookie schema 16) migrated expiry from seconds to milliseconds.
                var schema: Int32 = 0
                try db.rows("PRAGMA user_version") { schema = sqlite3_column_int($0, 0) }
                let expiryScale: Double = schema >= 16 ? 1_000 : 1
                try db.rows("SELECT host,name,value,path,expiry,isSecure,isHttpOnly,\(sameSite),\(attributes) FROM moz_cookies") { row in
                    result.total += 1
                    let attributes = Database.text(row, 8)
                    guard attributes.isEmpty || attributes == "{}" else { result.skipped += 1; return }
                    let same = sqlite3_column_int(row, 7)
                    guard same != 0 || sqlite3_column_int(row, 5) != 0 else { result.skipped += 1; return }
                    result.values.append(BrowserProfileCookie(name: Database.text(row, 1), value: Database.text(row, 2),
                        domain: Database.text(row, 0), path: Database.text(row, 3),
                        expires: Double(sqlite3_column_int64(row, 4)) / expiryScale, secure: sqlite3_column_int(row, 5) != 0,
                        httpOnly: sqlite3_column_int(row, 6) != 0, sameSite: same == 2 ? "Strict" : same == 0 && sqlite3_column_int(row, 5) != 0 ? "None" : "Lax"))
                }
                do {
                    if let session = try firefoxSessionFile(profile) {
                        let sessionCookies = try BrowserProfileSessionReader.firefoxCookies(session)
                        result.total += sessionCookies.total
                        result.skipped += sessionCookies.skipped
                        result.values.append(contentsOf: sessionCookies.values)
                    }
                } catch { result.error = error.localizedDescription }
            }
        } catch { result.error = error.localizedDescription }
        return result
    }

    private static func history(_ profile: BrowserProfile) -> BrowserProfileResult<BrowserImportedPage> {
        var result = BrowserProfileResult<BrowserImportedPage>()
        do {
            let file = profile.directory.appendingPathComponent(profile.kind == .chrome ? "History" : "places.sqlite")
            let db = try Database(file)
            let table = profile.kind == .chrome ? "urls" : "moz_places"
            let time = profile.kind == .chrome ? "last_visit_time" : "last_visit_date"
            try db.rows("SELECT COUNT(*) FROM \(table) WHERE \(time) > 0") { result.total = Int(sqlite3_column_int64($0, 0)) }
            try db.rows("SELECT url,title,\(time) FROM \(table) WHERE \(time) > 0 ORDER BY \(time) DESC LIMIT \(historyLimit)") { row in
                let url = Database.text(row, 0)
                guard BrowserImportedPage.safeURL(url) else { result.skipped += 1; return }
                let raw = Double(sqlite3_column_int64(row, 2)) / 1_000_000
                let visited = profile.kind == .chrome && raw > 0 ? raw - chromeEpoch : raw
                result.values.append(BrowserImportedPage(url: url, title: Database.text(row, 1), visitedAt: visited))
            }
            result.skipped += max(0, result.total - historyLimit)
        } catch { result.error = error.localizedDescription }
        return result
    }

    private static func sessions(_ profile: BrowserProfile) -> BrowserProfileResult<BrowserImportedPage> {
        var result = BrowserProfileResult<BrowserImportedPage>()
        do {
            let directory = profile.directory
            let file: URL
            if profile.kind == .chrome {
                let sessionDirectory = directory.appendingPathComponent("Sessions", isDirectory: true)
                let candidates = try FileManager.default.contentsOfDirectory(at: sessionDirectory, includingPropertiesForKeys: nil)
                    .filter { $0.lastPathComponent.hasPrefix("Session_") }.sorted { $0.lastPathComponent > $1.lastPathComponent }
                guard let latest = candidates.first else { throw CocoaError(.fileNoSuchFile) }
                file = latest
                result = try BrowserProfileSessionReader.chromium(file)
            } else {
                guard let existing = try firefoxSessionFile(profile) else { throw CocoaError(.fileNoSuchFile) }
                file = existing
                result = try BrowserProfileSessionReader.firefox(file)
            }
        } catch { result.error = error.localizedDescription }
        return result
    }

    private static func firefoxSessionFile(_ profile: BrowserProfile) throws -> URL? {
        let directory = profile.directory
        let candidates = [directory.appendingPathComponent("sessionstore-backups/recovery.jsonlz4"),
                          directory.appendingPathComponent("sessionstore.jsonlz4"),
                          directory.appendingPathComponent("sessionstore-backups/previous.jsonlz4")]
        for candidate in candidates {
            do {
                _ = try FileManager.default.attributesOfItem(atPath: candidate.path)
                return candidate
            } catch let error as NSError where error.domain == NSCocoaErrorDomain &&
                (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError) {
                continue
            }
        }
        return nil
    }

    private static func cookieFile(_ profile: BrowserProfile) -> URL {
        if profile.kind == .firefox { return profile.directory.appendingPathComponent("cookies.sqlite") }
        let direct = profile.directory.appendingPathComponent("Cookies")
        return FileManager.default.fileExists(atPath: direct.path) ? direct : profile.directory.appendingPathComponent("Network/Cookies")
    }

    private static func keychainPassword() throws -> Data {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: "Chrome Safe Storage",
                                      kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data, !data.isEmpty else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey:
                (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain access failed."])
        }
        return data
    }

    private static func chromeKey(password: Data) throws -> Data {
        let salt = Array("saltysalt".utf8)
        var key = Data(count: kCCKeySizeAES128)
        let status = key.withUnsafeMutableBytes { output in
            password.withUnsafeBytes { input in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), input.baseAddress?.assumingMemoryBound(to: Int8.self),
                    password.count, salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                    output.baseAddress?.assumingMemoryBound(to: UInt8.self), kCCKeySizeAES128)
            }
        }
        guard status == kCCSuccess else { throw CocoaError(.coderInvalidValue) }
        return key
    }

    private static func decrypt(_ encrypted: Data, key: Data, domain: String, version: Int) throws -> String {
        guard encrypted.starts(with: Data("v10".utf8)) else { throw CocoaError(.coderInvalidValue) }
        let cipher = Data(encrypted.dropFirst(3))
        var plain = Data(count: cipher.count + kCCBlockSizeAES128)
        let iv = [UInt8](repeating: 32, count: kCCBlockSizeAES128)
        var written = 0
        let status = plain.withUnsafeMutableBytes { output in
            key.withUnsafeBytes { keyBytes in
                cipher.withUnsafeBytes { input in
                    CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                        keyBytes.baseAddress, key.count, iv, input.baseAddress, cipher.count,
                        output.baseAddress, cipher.count + kCCBlockSizeAES128, &written)
                }
            }
        }
        guard status == kCCSuccess else { throw CocoaError(.coderInvalidValue) }
        plain.count = written
        if version >= 24 {
            let digest = Data(SHA256.hash(data: Data(domain.utf8)))
            guard plain.count >= digest.count, plain.prefix(digest.count) == digest else { throw CocoaError(.coderInvalidValue) }
            plain.removeFirst(digest.count)
        }
        guard let value = String(data: plain, encoding: .utf8) else { throw CocoaError(.coderInvalidValue) }
        return value
    }

    private final class Database {
        private var handle: OpaquePointer?
        init(_ file: URL) throws {
            let status = sqlite3_open_v2(file.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
            guard status == SQLITE_OK else {
                let message = handle.flatMap { sqlite3_errmsg($0) }.map(String.init(cString:)) ?? "SQLite open failed."
                if let handle { sqlite3_close(handle) }
                handle = nil
                throw NSError(domain: "SQLite", code: Int(status), userInfo: [NSLocalizedDescriptionKey: message])
            }
            sqlite3_busy_timeout(handle, 2_000)
        }
        deinit { sqlite3_close(handle) }
        func rows(_ sql: String, _ body: (OpaquePointer) -> Void) throws {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw error() }
            defer { sqlite3_finalize(statement) }
            var status = sqlite3_step(statement)
            while status == SQLITE_ROW { body(statement); status = sqlite3_step(statement) }
            guard status == SQLITE_DONE else { throw error() }
        }
        func columns(_ table: String) throws -> Set<String> {
            var result = Set<String>()
            try rows("PRAGMA table_info(\(table))") { result.insert(Self.text($0, 1)) }
            return result
        }
        private func error() -> NSError {
            NSError(domain: "SQLite", code: Int(sqlite3_errcode(handle)),
                    userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(handle))])
        }
        static func text(_ row: OpaquePointer, _ index: Int32) -> String {
            guard let value = sqlite3_column_text(row, index) else { return "" }
            return String(cString: value)
        }
        static func blob(_ row: OpaquePointer, _ index: Int32) -> Data {
            let length = Int(sqlite3_column_bytes(row, index))
            guard length > 0, let value = sqlite3_column_blob(row, index) else { return Data() }
            return Data(bytes: value, count: length)
        }
    }
}
