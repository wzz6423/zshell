import Compression
import Foundation

nonisolated struct BrowserImportedPage: Codable, Hashable, Sendable {
    let url: String
    let title: String
    let visitedAt: Double

    static func safeURL(_ string: String) -> Bool {
        guard let url = URL(string: string), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), url.host?.isEmpty == false,
              url.user == nil, url.password == nil else { return false }
        return true
    }
}

nonisolated enum BrowserProfileSessionReader {
    enum ReadError: LocalizedError {
        case invalidFile, unsupportedVersion, tooLarge
        var errorDescription: String? {
            switch self {
            case .invalidFile: String(localized: "Invalid session file.")
            case .unsupportedVersion: String(localized: "Unsupported session file version.")
            case .tooLarge: String(localized: "Session file exceeds 64 MB.")
            }
        }
    }
    private static let maximumBytes = 64 * 1_024 * 1_024

    private static func firefoxRoot(_ file: URL) throws -> [String: Any] {
        let data = try boundedData(file)
        guard data.count >= 12, data.prefix(8) == Data("mozLz40\0".utf8),
              let size = integer(data, 8), size > 0, size <= maximumBytes else { throw ReadError.invalidFile }
        var decoded = Data(count: size)
        let written = decoded.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                compression_decode_buffer(destination.bindMemory(to: UInt8.self).baseAddress!, size,
                                          source.bindMemory(to: UInt8.self).baseAddress!.advanced(by: 12),
                                          data.count - 12, nil, COMPRESSION_LZ4_RAW)
            }
        }
        guard written == size,
              let root = try JSONSerialization.jsonObject(with: decoded) as? [String: Any] else { throw ReadError.invalidFile }
        return root
    }

    static func firefox(_ file: URL) throws -> BrowserProfileResult<BrowserImportedPage> {
        let root = try firefoxRoot(file)
        guard let windows = root["windows"] as? [[String: Any]] else { throw ReadError.invalidFile }
        var result = BrowserProfileResult<BrowserImportedPage>()
        for window in windows {
            for tab in window["tabs"] as? [[String: Any]] ?? [] {
                result.total += 1
                guard (tab["userContextId"] as? Int ?? 0) == 0,
                      let entries = tab["entries"] as? [[String: Any]], !entries.isEmpty else { result.skipped += 1; continue }
                let index = max(0, min((tab["index"] as? Int ?? entries.count) - 1, entries.count - 1))
                let entry = entries[index]
                guard let url = entry["url"] as? String, BrowserImportedPage.safeURL(url) else { result.skipped += 1; continue }
                result.values.append(BrowserImportedPage(url: url, title: entry["title"] as? String ?? "", visitedAt: 0))
            }
        }
        return result
    }

    static func firefoxCookies(_ file: URL) throws -> BrowserProfileResult<BrowserProfileCookie> {
        let root = try firefoxRoot(file)
        let windows = root["windows"] as? [[String: Any]] ?? []
        let records = (root["cookies"] as? [[String: Any]] ?? [])
            + windows.flatMap { $0["cookies"] as? [[String: Any]] ?? [] }
        var result = BrowserProfileResult<BrowserProfileCookie>()
        for record in records {
            result.total += 1
            let attributes = record["originAttributes"] as? [String: Any] ?? [:]
            let scoped = attributes.values.contains { value in
                if let string = value as? String { return !string.isEmpty }
                if let number = value as? NSNumber { return number.intValue != 0 }
                return true
            }
            let secure = record["secure"] as? Bool ?? false
            let sameSite = record["sameSite"] as? Int ?? 0
            guard (record["originAttributes"] == nil || record["originAttributes"] is [String: Any]),
                  !scoped, record["isPartitioned"] as? Bool != true,
                  sameSite != 0 || secure,
                  let domain = record["host"] as? String, let name = record["name"] as? String,
                  let value = record["value"] as? String else { result.skipped += 1; continue }
            result.values.append(BrowserProfileCookie(name: name, value: value, domain: domain,
                path: record["path"] as? String ?? "/", expires: -1, secure: secure,
                httpOnly: record["httponly"] as? Bool ?? false,
                sameSite: sameSite == 2 ? "Strict" : sameSite == 0 ? "None" : "Lax"))
        }
        return result
    }

    // 会话解析改编自 chromium-session 和 chrome-session-viewer，许可见 ThirdPartyNotices/BrowserSessionImport.txt。
    static func chromium(_ file: URL) throws -> BrowserProfileResult<BrowserImportedPage> {
        struct Tab {
            var window = 0
            var position = 0
            var selected = 0
            var entries: [Int: BrowserImportedPage] = [:]
        }
        let data = try boundedData(file)
        guard data.count >= 8, data.prefix(4) == Data("SNSS".utf8), let version = integer(data, 4) else {
            throw ReadError.invalidFile
        }
        guard version == 1 || version == 3 else { throw ReadError.unsupportedVersion }
        var tabs: [Int: Tab] = [:]
        var closedWindows = Set<Int>()
        var offset = 8
        while offset < data.count {
            guard offset + 3 <= data.count else { throw ReadError.invalidFile }
            let length = Int(data[offset]) | (Int(data[offset + 1]) << 8)
            guard length > 0, offset + 2 + length <= data.count else { throw ReadError.invalidFile }
            let type = data[offset + 2]
            let payload = Data(data[(offset + 3)..<(offset + 2 + length)])
            offset += 2 + length
            switch type {
            case 0:
                guard let window = integer(payload, 0), let id = integer(payload, 4) else { throw ReadError.invalidFile }
                tabs[id, default: Tab()].window = window
            case 2:
                guard let id = integer(payload, 0), let position = integer(payload, 4) else { throw ReadError.invalidFile }
                tabs[id, default: Tab()].position = position
            case 5:
                guard let id = integer(payload, 0), let index = signedInteger(payload, 4), index >= 0 else { throw ReadError.invalidFile }
                tabs[id, default: Tab()].entries = tabs[id, default: Tab()].entries.filter { $0.key < index }
            case 11, 24:
                guard let id = integer(payload, 0), let value = signedInteger(payload, 4), value >= 0 else { throw ReadError.invalidFile }
                let index = type == 11 ? 0 : value
                let count = type == 11 ? value : signedInteger(payload, 8) ?? 0
                guard count > 0, index <= Int(Int32.max) - count else { throw ReadError.invalidFile }
                var tab = tabs[id, default: Tab()]
                if tab.selected >= index && tab.selected < index + count { tab.selected = index - 1 }
                else if tab.selected >= index + count { tab.selected -= count }
                var retained: [Int: BrowserImportedPage] = [:]
                for (position, page) in tab.entries where position < index || position >= index + count {
                    retained[position >= index + count ? position - count : position] = page
                }
                tab.entries = retained
                tabs[id] = tab
            case 6:
                guard let id = integer(payload, 4), let index = integer(payload, 8),
                      let (url, next) = string(payload, 12, utf16: false),
                      let (title, _) = string(payload, next, utf16: true) else { throw ReadError.invalidFile }
                tabs[id, default: Tab()].entries[index] = BrowserImportedPage(url: url, title: title, visitedAt: 0)
            case 7:
                guard let id = integer(payload, 0), let index = signedInteger(payload, 4) else { throw ReadError.invalidFile }
                tabs[id, default: Tab()].selected = index
            case 16:
                guard let id = integer(payload, 0) else { throw ReadError.invalidFile }
                tabs.removeValue(forKey: id)
            case 17:
                guard let id = integer(payload, 0) else { throw ReadError.invalidFile }
                closedWindows.insert(id)
            default: break
            }
        }
        var result = BrowserProfileResult<BrowserImportedPage>()
        let openTabs = tabs.values.filter { $0.window != 0 && !closedWindows.contains($0.window) }
            .sorted { $0.window == $1.window ? $0.position < $1.position : $0.window < $1.window }
        for tab in openTabs {
            result.total += 1
            let entries = tab.entries.sorted { $0.key < $1.key }
            let page = tab.entries[tab.selected] ?? entries.first(where: { $0.key >= tab.selected })?.value ?? entries.last?.value
            guard let page, BrowserImportedPage.safeURL(page.url) else { result.skipped += 1; continue }
            result.values.append(page)
        }
        return result
    }

    private static func boundedData(_ file: URL) throws -> Data {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard let size = attributes[.size] as? NSNumber, size.intValue <= maximumBytes else { throw ReadError.tooLarge }
        return try Data(contentsOf: file, options: .mappedIfSafe)
    }

    private static func integer(_ data: Data, _ offset: Int) -> Int? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return data.withUnsafeBytes { Int($0.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian) }
    }

    private static func signedInteger(_ data: Data, _ offset: Int) -> Int? {
        guard let value = integer(data, offset), let bits = UInt32(exactly: value) else { return nil }
        return Int(Int32(bitPattern: bits))
    }

    private static func string(_ data: Data, _ offset: Int, utf16: Bool) -> (String, Int)? {
        guard let count = integer(data, offset), count <= maximumBytes / 2 else { return nil }
        let bytes = count * (utf16 ? 2 : 1)
        let padded = (bytes + 3) & ~3
        guard offset + 4 + padded <= data.count,
              let value = String(data: data[(offset + 4)..<(offset + 4 + bytes)],
                                 encoding: utf16 ? .utf16LittleEndian : .utf8) else { return nil }
        return (value, offset + 4 + padded)
    }
}
