//
//  RecommendedToolService.swift
//  zshell
//

import Combine
import Foundation

nonisolated struct RecommendedToolState: Equatable, Sendable {
    enum Location: Sendable { case homebrew, external }

    var hasCheckedInstallation = false
    var installedVersion: String?
    var location: Location?
    var latestVersion: String?
    var error: String?
    var isInstalled: Bool { location != nil }
    var hasUpdate: Bool {
        guard let installedVersion, let latestVersion else { return false }
        return RecommendedToolMetadata.isNewer(latestVersion, than: installedVersion)
    }
}

@MainActor
final class RecommendedToolService: ObservableObject {
    typealias CommandRunner = @Sendable (URL, [String], [String: String], TimeInterval) async throws -> BoundedProcessResult
    typealias DataLoader = @Sendable (URL) async throws -> Data

    @Published private(set) var states: [RecommendedTool: RecommendedToolState] = [:]
    @Published private(set) var isRefreshing = false
    @Published private(set) var activeTool: RecommendedTool?
    @Published private(set) var isInstalling = false
    @Published private(set) var homebrewURL: URL?
    @Published private(set) var error: String?

    private let runner: CommandRunner
    private let loader: DataLoader
    private let locateHomebrew: @Sendable () -> URL?
    private let defaults: UserDefaults
    private let environment: [String: String]
    private let homeDirectory: URL
    private let applicationDirectories: [URL]
    private var versionCache: [String: CachedVersion] = [:]
    private var lastRefresh = Date.distantPast

    private static let cacheKey = "zshell.recommendations.versions"
    private static let cacheLifetime: TimeInterval = 30 * 60

    init(
        commandRunner: @escaping CommandRunner = { try await RecommendedToolWorker.run($0, $1, $2, $3) },
        dataLoader: @escaping DataLoader = { try await RecommendedToolWorker.load($0) },
        homebrewLocator: @escaping @Sendable () -> URL? = { RecommendedToolWorker.findHomebrew() },
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        applicationDirectories: [URL]? = nil
    ) {
        runner = commandRunner
        loader = dataLoader
        locateHomebrew = homebrewLocator
        self.defaults = defaults
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.applicationDirectories = applicationDirectories ?? [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            homeDirectory.appendingPathComponent("Applications", isDirectory: true),
        ]
        homebrewURL = homebrewLocator()
        if let data = defaults.data(forKey: Self.cacheKey),
           let cache = try? JSONDecoder().decode([String: CachedVersion].self, from: data) {
            versionCache = cache
        }
        for tool in RecommendedTool.allCases {
            states[tool] = RecommendedToolState(latestVersion: versionCache[tool.rawValue]?.version)
        }
    }

    var isBusy: Bool { isRefreshing || isInstalling }
    var missingTools: [RecommendedTool] {
        RecommendedTool.allCases.filter { states[$0]?.hasCheckedInstallation == true && states[$0]?.isInstalled != true }
    }
    var updatableTools: [RecommendedTool] {
        RecommendedTool.allCases.filter { states[$0]?.location == .homebrew && states[$0]?.hasUpdate == true }
    }

    func refresh(force: Bool = false) async {
        guard !isBusy, force || Date().timeIntervalSince(lastRefresh) >= Self.cacheLifetime else { return }
        isRefreshing = true
        lastRefresh = Date()
        error = nil
        defer { isRefreshing = false }
        homebrewURL = locateHomebrew()
        let tools = RecommendedTool.allCases
        await refreshInstalled(tools)
        await checkLatest(tools, force: force)
    }

    func install(_ tools: [RecommendedTool]) async {
        guard !isBusy, !tools.isEmpty else { return }
        homebrewURL = locateHomebrew()
        guard let homebrewURL else {
            error = String(localized: "Install Homebrew to manage recommended tools.")
            return
        }
        isInstalling = true
        error = nil
        defer { activeTool = nil; isInstalling = false }
        for tool in RecommendedTool.allCases where tools.contains(tool) {
            guard let package = tool.packageName else { continue }
            activeTool = tool
            states[tool]?.error = nil
            do {
                // Recheck ownership immediately before choosing install/upgrade:
                // an executable on PATH need not belong to Homebrew.
                let installed = try await installedVersions(homebrewURL, isCask: tool.isCask)
                let isManaged = installed[package.split(separator: "/").last.map(String.init) ?? package] != nil
                if let tap = tool.requiredTap {
                    _ = try await brew(homebrewURL, ["tap", tap], installing: true)
                }
                var arguments = [isManaged ? "upgrade" : "install", tool.brewFlag]
                if isManaged && tool.isCask { arguments.append("--greedy-auto-updates") }
                arguments.append(package)
                _ = try await brew(homebrewURL, arguments, installing: true)
                let versions = try await installedVersions(homebrewURL, isCask: tool.isCask)
                guard let version = versions[package.split(separator: "/").last.map(String.init) ?? package] else {
                    throw RecommendedToolFailure(String(localized: "Homebrew did not report an installed version. Refresh and try again."))
                }
                states[tool]?.hasCheckedInstallation = true
                states[tool]?.location = .homebrew
                states[tool]?.installedVersion = version
                states[tool]?.error = nil
            } catch {
                states[tool]?.error = error.localizedDescription
            }
        }
    }

    private func refreshInstalled(_ tools: [RecommendedTool]) async {
        var formulae: [String: String] = [:]
        var casks: [String: String] = [:]
        var inventoryAvailable = true
        if let homebrewURL {
            do {
                formulae = try await installedVersions(homebrewURL, isCask: false)
                casks = try await installedVersions(homebrewURL, isCask: true)
            } catch {
                self.error = error.localizedDescription
                inventoryAvailable = false
            }
        }
        let runner = self.runner
        let environment = processEnvironment(installing: false)
        let homeDirectory = self.homeDirectory
        let applicationDirectories = self.applicationDirectories
        for tool in tools {
            states[tool]?.error = nil
            let token = tool.packageName?.split(separator: "/").last.map(String.init) ?? ""
            if let version = (tool.isCask ? casks : formulae)[token] {
                states[tool]?.hasCheckedInstallation = true
                states[tool]?.location = .homebrew
                states[tool]?.installedVersion = tool.applicationName == nil ? version
                    : await Task.detached(priority: .utility) {
                        RecommendedToolWorker.applicationVersion(tool, directories: applicationDirectories) ?? version
                    }.value
            } else {
                let detected = await Task.detached(priority: .utility) {
                    await RecommendedToolWorker.installedVersion(
                        tool, environment: environment, homeDirectory: homeDirectory,
                        applicationDirectories: applicationDirectories, runner: runner
                    )
                }.value
                states[tool]?.hasCheckedInstallation = inventoryAvailable || detected.found
                states[tool]?.location = detected.found ? .external : nil
                states[tool]?.installedVersion = detected.version
            }
        }
    }

    private func checkLatest(_ tools: [RecommendedTool], force: Bool) async {
        let pending = tools.filter { tool in
            guard !force, let cached = versionCache[tool.rawValue] else { return true }
            return Date().timeIntervalSince(cached.checkedAt) >= Self.cacheLifetime
        }
        let loader = self.loader
        // Limit simultaneous requests; switching panes reuses the cached result.
        for start in stride(from: 0, to: pending.count, by: 4) {
            let batch = Array(pending[start..<min(start + 4, pending.count)])
            await withTaskGroup(of: (RecommendedTool, Result<String, RecommendedToolFailure>).self) { group in
                for tool in batch {
                    group.addTask {
                        do {
                            guard let url = tool.metadataURL else { throw RecommendedToolFailure.invalidMetadata }
                            let data = try await loader(url)
                            return (tool, .success(try RecommendedToolMetadata.latestVersion(data, for: tool)))
                        } catch {
                            return (tool, .failure(RecommendedToolFailure(error.localizedDescription)))
                        }
                    }
                }
                for await (tool, result) in group {
                    switch result {
                    case .success(let version):
                        states[tool]?.latestVersion = version
                        states[tool]?.error = nil
                        versionCache[tool.rawValue] = CachedVersion(version: version, checkedAt: Date())
                    case .failure(let failure):
                        states[tool]?.error = String(localized: "Could not check for updates: \(failure.localizedDescription)")
                    }
                }
            }
        }
        if let data = try? JSONEncoder().encode(versionCache) {
            defaults.set(data, forKey: Self.cacheKey)
        }
    }

    private func installedVersions(_ executable: URL, isCask: Bool) async throws -> [String: String] {
        let output = try await brew(executable, ["list", "--versions", isCask ? "--cask" : "--formula"])
        var versions = RecommendedToolMetadata.installedVersions(output.stdout)
        if !isCask, versions["python"] == nil {
            // Homebrew's unversioned Python name is an alias (for example,
            // python@3.14). Resolve it instead of mistaking it for an external copy.
            let prefix = try await brew(executable, ["--prefix", "python"])
            let name = URL(fileURLWithPath: prefix.stdout.trimmingCharacters(in: .whitespacesAndNewlines)).lastPathComponent
            versions["python"] = versions[name]
        }
        return versions
    }

    private func processEnvironment(installing: Bool) -> [String: String] {
        var result = environment
        let paths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        result["PATH"] = ((result["PATH"].map { [$0] } ?? []) + paths).joined(separator: ":")
        result["HOMEBREW_NO_ANALYTICS"] = "1"
        result["HOMEBREW_NO_ENV_HINTS"] = "1"
        result["NONINTERACTIVE"] = "1"
        result["LC_ALL"] = "C"
        if installing {
            result.removeValue(forKey: "HOMEBREW_NO_AUTO_UPDATE")
        } else {
            // Version checks use HTTPS metadata directly; local inventory must
            // not update taps or install anything as a side effect.
            result["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        }
        return result
    }

    private func brew(_ executable: URL, _ arguments: [String], installing: Bool = false) async throws -> BoundedProcessResult {
        let output = try await runner(executable, arguments, processEnvironment(installing: installing), installing ? 1800 : 60)
        guard !output.timedOut else { throw RecommendedToolFailure(String(localized: "Homebrew timed out. Refresh and try again.")) }
        guard output.terminationStatus == 0 else {
            let detail = output.output.stderr.isEmpty ? output.output.stdout : output.output.stderr
            throw RecommendedToolFailure(String(localized: "Homebrew failed: \(detail.trimmingCharacters(in: .whitespacesAndNewlines))"))
        }
        return output
    }

    private struct CachedVersion: Codable {
        let version: String
        let checkedAt: Date
    }
}

private extension BoundedProcessResult {
    var stdout: String { output.stdout }
}

nonisolated struct RecommendedToolFailure: LocalizedError, Sendable {
    let message: String
    init(_ message: String) { self.message = String(message.prefix(600)) }
    var errorDescription: String? { message }
    static var invalidMetadata: Self { Self(String(localized: "The version information could not be read.")) }
}

nonisolated enum RecommendedToolMetadata {
    static func installedVersions(_ output: String) -> [String: String] {
        var versions: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count > 1 else { continue }
            let name = parts[0].split(separator: "/").last.map(String.init) ?? String(parts[0])
            versions[name] = parts.dropFirst().map(String.init).max { isNewer($1, than: $0) }
        }
        return versions
    }

    static func normalizedVersion(_ value: String) -> String? {
        guard let range = value.range(of: #"\d+(?:\.\d+)+(?:_\d+)?"#, options: .regularExpression) else { return nil }
        return String(value[range])
    }

    static func isNewer(_ latest: String, than installed: String) -> Bool {
        guard let lhs = normalizedVersion(latest), let rhs = normalizedVersion(installed) else { return false }
        return lhs.compare(rhs, options: .numeric) == .orderedDescending
    }

    static func latestVersion(_ data: Data, for tool: RecommendedTool) throws -> String {
        if tool.requiredTap != nil || tool == .python {
            let text = String(decoding: data, as: UTF8.self)
            let pattern = tool == .python
                ? #"(?m)^\s*url\s+"https://www\.python\.org/ftp/python/([0-9.]+)/"#
                : #"(?m)^\s*version\s+\"([^\"]+)\""#
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text),
                  let version = normalizedVersion(String(text[range])) else { throw RecommendedToolFailure.invalidMetadata }
            if !tool.isCask,
               let revision = text.range(of: #"(?m)^\s*revision\s+(\d+)"#, options: .regularExpression),
               let value = text[revision].split(whereSeparator: \.isWhitespace).last, value != "0" {
                return "\(version)_\(value)"
            }
            return version
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = tool.isCask ? object["version"] as? String : (object["versions"] as? [String: Any])?["stable"] as? String,
              let version = normalizedVersion(value) else { throw RecommendedToolFailure.invalidMetadata }
        let revision = tool.isCask ? 0 : object["revision"] as? Int ?? 0
        return revision > 0 ? "\(version)_\(revision)" : version
    }
}

nonisolated enum RecommendedToolWorker {
    static func findHomebrew() -> URL? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            .map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func run(_ executable: URL, _ arguments: [String], _ environment: [String: String], _ timeout: TimeInterval) async throws -> BoundedProcessResult {
        try await Task.detached(priority: .utility) {
            try BoundedProcessRunner.run(
                executableURL: executable, arguments: arguments, timeout: timeout,
                outputLimit: 1_048_576, environment: environment
            )
        }.value
    }

    static func load(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadRevalidatingCacheData, timeoutInterval: 20)
        request.setValue("zshell-recommendations", forHTTPHeaderField: "User-Agent")
        if url.host == "api.github.com" {
            request.setValue("application/vnd.github.raw+json", forHTTPHeaderField: "Accept")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw RecommendedToolFailure(String(localized: "The server returned HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)."))
        }
        guard data.count <= 2_097_152 else { throw RecommendedToolFailure.invalidMetadata }
        return data
    }

    static func applicationVersion(_ tool: RecommendedTool, directories: [URL]) -> String? {
        guard let application = tool.applicationName else { return nil }
        for directory in directories {
            let url = directory.appendingPathComponent("\(application).app", isDirectory: true)
            let infoURL = url.appendingPathComponent("Contents/Info.plist")
            if let data = try? Data(contentsOf: infoURL),
               let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
               let version = info["CFBundleShortVersionString"] as? String {
                return version
            }
        }
        return nil
    }

    static func installedVersion(
        _ tool: RecommendedTool, environment: [String: String], homeDirectory: URL,
        applicationDirectories: [URL], runner: RecommendedToolService.CommandRunner
    ) async -> (found: Bool, version: String?) {
        if let version = applicationVersion(tool, directories: applicationDirectories) {
            return (true, version)
        }
        let name = tool.executableName
        var paths = [
            homeDirectory.appendingPathComponent(".local/bin/\(name)").path,
            homeDirectory.appendingPathComponent(".cargo/bin/\(name)").path,
        ]
        if let package = tool.packageName, tool.requiredTap == nil {
            paths += ["/opt/homebrew/opt/\(package)/bin/\(name)", "/usr/local/opt/\(package)/bin/\(name)"]
        }
        paths += (environment["PATH"] ?? "").split(separator: ":").map { "\($0)/\(name)" }
        for path in paths where FileManager.default.isExecutableFile(atPath: path) {
            // Apple's gcc is Clang, and /usr/bin/java is a launcher that may
            // prompt to install a JDK. Neither establishes this recommendation.
            if (tool == .gcc && ["/usr/bin/gcc", "/bin/gcc"].contains(path)) || (tool == .openJDK17 && path == "/usr/bin/java") { continue }
            guard let output = try? await runner(URL(fileURLWithPath: path), tool.versionArguments, environment, 5),
                  output.terminationStatus == 0, !output.timedOut else { continue }
            let text = output.output.stdout + "\n" + output.output.stderr
            let version = RecommendedToolMetadata.normalizedVersion(text)
            if tool == .openJDK17, version?.hasPrefix("17.") != true { continue }
            if tool == .gcc, !text.lowercased().contains("gcc") { continue }
            return (true, version)
        }
        return (false, nil)
    }
}
