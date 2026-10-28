import Combine
import CryptoKit
import Foundation
import WebKit

nonisolated struct BrowserFilterSource: Equatable, Sendable {
    let name: String
    let url: URL

    static let catalog = [
        BrowserFilterSource(name: "EasyList", url: URL(string: "https://easylist.to/easylist/easylist.txt")!),
        BrowserFilterSource(name: "EasyPrivacy", url: URL(string: "https://easylist.to/easylist/easyprivacy.txt")!),
    ]
    static let defaults = catalog.map { $0.url.absoluteString }.joined(separator: "\n")
    static let maximumSources = 8
    static let maximumBytes = 8 * 1_024 * 1_024

    static func parse(_ text: String) throws -> [BrowserFilterSource] {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard lines.count <= maximumSources else { throw SourceError.invalid }
        var seen: Set<URL> = []
        return try lines.compactMap { line in
            guard line.utf8.count <= 2_048, let url = URL(string: line),
                  ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
                  let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
                  url.fragment == nil else { throw SourceError.invalid }
            guard seen.insert(url).inserted else { return nil }
            return catalog.first { $0.url == url } ?? BrowserFilterSource(name: host, url: url)
        }
    }

    enum SourceError: Error { case invalid, response, size, format }
}

/// One serialized pipeline owns downloads and compilation for every pane.
/// Canceled compilation may finish inside WebKit, but cannot publish its result.
@MainActor
final class BrowserContentBlocker: ObservableObject {
    static let shared = BrowserContentBlocker()

    enum Status: Equatable {
        case disabled, idle, updating, empty
        case active(converted: Int, skipped: Int, cached: Bool)
        case failed(usingPreviousRules: Bool)

        var text: String {
            switch self {
            case .disabled: String(localized: "Content blocking is off.")
            case .idle: String(localized: "Content blocking starts when a browser opens.")
            case .updating: String(localized: "Updating content blocking rules…")
            case .empty: String(localized: "No filter lists selected.")
            case let .active(converted, skipped, cached):
                if cached {
                    String(localized: "Using cached rules: \(converted) filters converted; \(skipped) unsupported filters skipped. The update failed.")
                } else {
                    String(localized: "Content blocking is active: \(converted) filters converted; \(skipped) unsupported filters skipped.")
                }
            case let .failed(usingPreviousRules):
                if usingPreviousRules {
                    String(localized: "The update failed. Previously active rules are still in use.")
                } else {
                    String(localized: "Content blocking failed. Check the list URLs and try updating again.")
                }
            }
        }
    }

    @Published private(set) var ruleLists: [WKContentRuleList] = []
    @Published private(set) var status: Status = .idle
    private(set) var lastError: String?
    private var observation: AnyCancellable?
    private var worker: Task<Void, Never>?
    private var revision: UInt = 0
    private var configuration: Configuration?
    private var refreshRequested = false
    private let store: WKContentRuleListStore
    private let cacheDirectory: URL

    private struct Configuration: Equatable {
        let enabled: Bool
        let sources: String
    }

    init(settings: AppSettings? = nil, cacheDirectory: URL? = nil, store: WKContentRuleListStore? = nil) {
        let settings = settings ?? .shared
        self.cacheDirectory = cacheDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "zshell")
            .appendingPathComponent("BrowserContentBlocking", isDirectory: true)
        self.store = store ?? .default()
        observation = Publishers.CombineLatest(settings.$browserContentBlocking, settings.$browserFilterLists)
            .map { Configuration(enabled: $0, sources: $1) }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] configuration in self?.configure(configuration) }
    }

    func refresh() {
        refreshRequested = true
        revision &+= 1
        worker?.cancel()
        startIfNeeded()
    }

    private func configure(_ value: Configuration) {
        guard value != configuration else { return }
        configuration = value
        revision &+= 1
        worker?.cancel()
        ruleLists = []
        if !value.enabled { status = .disabled }
        startIfNeeded()
    }

    private func startIfNeeded() {
        guard worker == nil, let configuration, configuration.enabled else { return }
        let current = revision
        let refresh = refreshRequested
        refreshRequested = false
        status = .updating
        worker = Task { [weak self] in
            guard let self else { return }
            do {
                let sources = try BrowserFilterSource.parse(configuration.sources)
                if sources.isEmpty {
                    if current == self.revision { self.ruleLists = []; self.status = .empty }
                } else {
                    let directory = self.cacheDirectory
                    let loaded = try await Task.detached(priority: .utility) {
                        try await BrowserFilterDownload.load(sources, directory: directory, refresh: refresh)
                    }.valueWithCancellation()
                    try Task.checkCancellation()
                    let prepared = try await Task.detached(priority: .utility) {
                        let result = try BrowserContentRules.convert(loaded.texts)
                        return (result, result.lists.map { "zshell-content-v1-" + BrowserFilterDownload.digest($0) })
                    }.valueWithCancellation()
                    let converted = prepared.0
                    try Task.checkCancellation()
                    var compiled: [WKContentRuleList] = []
                    for (json, identifier) in zip(converted.lists, prepared.1) {
                        if let cached = try? await self.store.contentRuleList(forIdentifier: identifier) {
                            compiled.append(cached)
                        } else {
                            guard let rule = try await self.store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) else { throw BrowserFilterSource.SourceError.format }
                            compiled.append(rule)
                        }
                        try Task.checkCancellation()
                    }
                    guard current == self.revision else { throw CancellationError() }
                    self.ruleLists = compiled
                    self.status = .active(converted: converted.converted, skipped: converted.skipped, cached: loaded.usedStaleCache)
                }
            } catch is CancellationError {
                // A newer revision owns both the rules and the displayed state.
            } catch {
                if current == self.revision { self.lastError = String(describing: error); self.status = .failed(usingPreviousRules: !self.ruleLists.isEmpty) }
            }
            await self.removeUnusedCompiledRules(keeping: Set(self.ruleLists.map(\.identifier)))
            self.worker = nil
            if current != self.revision { self.startIfNeeded() }
        }
    }

    private func removeUnusedCompiledRules(keeping identifiers: Set<String>) async {
        let available = await store.availableIdentifiers() ?? []
        for identifier in available where identifier.hasPrefix("zshell-content-v1-") && !identifiers.contains(identifier) {
            try? await store.removeContentRuleList(forIdentifier: identifier)
        }
    }
}

nonisolated private enum BrowserFilterDownload {
    struct Loaded: Sendable {
        let texts: [String]
        let usedStaleCache: Bool
    }

    static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func load(_ sources: [BrowserFilterSource], directory: URL, refresh: Bool) async throws -> Loaded {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var texts: [String] = []
        var stale = false
        let paths = sources.map { directory.appendingPathComponent(digest($0.url.absoluteString) + ".txt") }
        // Prune before downloading, including pipelines that later fail.
        let selected = Set(paths.map(\.lastPathComponent))
        for file in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
            if file.pathExtension == "txt", !selected.contains(file.lastPathComponent) { try? FileManager.default.removeItem(at: file) }
        }
        for (source, path) in zip(sources, paths) {
            try Task.checkCancellation()
            let attributes = try? FileManager.default.attributesOfItem(atPath: path.path)
            let date = attributes?[.modificationDate] as? Date ?? .distantPast
            let size = attributes?[.size] as? Int ?? 0
            let cached: String? = size <= BrowserFilterSource.maximumBytes ? (try? String(contentsOf: path, encoding: .utf8)) : nil
            if !refresh, Date().timeIntervalSince(date) < 4 * 24 * 60 * 60, let cached {
                texts.append(cached)
                continue
            }
            do {
                let text = try await download(source.url)
                try Task.checkCancellation()
                try text.write(to: path, atomically: true, encoding: .utf8)
                texts.append(text)
            } catch is CancellationError { throw CancellationError() }
            catch {
                guard let cached else { throw error }
                stale = true
                texts.append(cached)
            }
        }
        return Loaded(texts: texts, usedStaleCache: stale)
    }

    private static func download(_ url: URL) async throws -> String {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: Redirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(from: url)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else { throw BrowserFilterSource.SourceError.response }
        guard response.expectedContentLength <= BrowserFilterSource.maximumBytes else { throw BrowserFilterSource.SourceError.size }
        var data = Data()
        for try await byte in bytes {
            guard data.count < BrowserFilterSource.maximumBytes else { throw BrowserFilterSource.SourceError.size }
            data.append(byte)
            if data.count % 65_536 == 0 { try Task.checkCancellation() }
        }
        guard let text = String(data: data, encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !text.prefix(512).lowercased().contains("<html"), !text.prefix(512).lowercased().contains("<!doctype") else { throw BrowserFilterSource.SourceError.format }
        return text
    }

    private final class Redirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private var remaining = 5
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            remaining -= 1
            guard remaining >= 0,
                  let url = request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  url.user == nil, url.password == nil else { completionHandler(nil); return }
            completionHandler(request)
        }
    }
}

nonisolated private extension Task where Failure == Error {
    func valueWithCancellation() async throws -> Success {
        try await withTaskCancellationHandler { try await value } onCancel: { cancel() }
    }
}
