import Foundation

private actor ToolFixture {
    var formulae = ["fzf": "0.60.0", "python@3.14": "3.14.0"]
    var casks = ["kero": "0.1.47"]
    var commands: [[String]] = []
    var metadataRequests: [URL] = []
    var failFzfUpgrade = false
    var failMetadata = false

    func setFailures(upgrade: Bool = false, metadata: Bool = false) {
        failFzfUpgrade = upgrade
        failMetadata = metadata
    }

    func setZislaInstalledVersion(_ version: String?) {
        casks["zisla"] = version
    }

    func run(_ executable: URL, _ arguments: [String], _ environment: [String: String]) -> BoundedProcessResult {
        guard executable.lastPathComponent == "brew" else { return result(status: 1) }
        commands.append(arguments)
        if arguments.first == "list" {
            precondition(environment["HOMEBREW_NO_AUTO_UPDATE"] == "1", "inventory must not update Homebrew")
            precondition(arguments.count == 3, "inventory must also succeed for missing packages")
            let versions = arguments.contains("--cask") ? casks : formulae
            return result(versions.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: "\n"))
        }
        if arguments == ["--prefix", "python"] { return result("/opt/homebrew/opt/python@3.14\n") }
        if arguments.first == "tap" { return result() }
        guard let action = arguments.first, ["install", "upgrade"].contains(action), let package = arguments.last else {
            return result(status: 1)
        }
        precondition(environment["HOMEBREW_NO_AUTO_UPDATE"] == nil, "installation must allow fresh Homebrew metadata")
        if package == "fzf", failFzfUpgrade { return result(status: 1, error: "fixture download failed") }
        let token = String(package.split(separator: "/").last!)
        if arguments.contains("--cask") {
            casks[token] = token == "zisla" ? "0.1.11" : "0.1.48"
        } else {
            formulae[token == "python" ? "python@3.14" : token] = token == "python" ? "3.14.2" : "0.61.0"
        }
        return result()
    }

    func load(_ url: URL) throws -> Data {
        metadataRequests.append(url)
        if failMetadata { throw URLError(.notConnectedToInternet) }
        if url.lastPathComponent == "python" {
            return Data("class PythonAT314 < Formula\n  url \"https://www.python.org/ftp/python/3.14.2/Python-3.14.2.tgz\"\nend\n".utf8)
        }
        if url.lastPathComponent == "zisla.rb" {
            return Data("""
            cask "zisla" do
              arch arm: "arm64", intel: "x86_64"
              version "0.1.11"
              auto_updates true
              app "zisla.app"
            end
            """.utf8)
        }
        if url.pathExtension == "rb" { return Data("cask \"fixture\" do\n  version \"0.1.48\"\nend\n".utf8) }
        if url.path.contains("/cask/") { return Data(#"{"version":"0.1.48"}"#.utf8) }
        let version = url.lastPathComponent == "python.json" ? "3.14.2" : "0.61.0"
        return try JSONSerialization.data(withJSONObject: ["versions": ["stable": version], "revision": 0])
    }

    private func result(_ output: String = "", status: Int32 = 0, error: String = "") -> BoundedProcessResult {
        BoundedProcessResult(
            terminationStatus: status, timedOut: false,
            output: BoundedProcessOutput(stdout: output, stderr: error, wasTruncated: false)
        )
    }
}

@main
struct RecommendedToolTests {
    @MainActor static func main() async throws {
        var passed = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            passed += 1
        }
        let suite = "zshell-recommendations-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let fixture = ToolFixture()
        let brewURL = URL(fileURLWithPath: "/fixture/brew")
        let service = RecommendedToolService(
            commandRunner: { executable, arguments, environment, _ in
                await fixture.run(executable, arguments, environment)
            },
            dataLoader: { try await fixture.load($0) },
            homebrewLocator: { brewURL }, defaults: defaults,
            environment: ["PATH": "", "HOMEBREW_NO_AUTO_UPDATE": "1"],
            homeDirectory: URL(fileURLWithPath: "/nonexistent-zshell-test-home"),
            applicationDirectories: []
        )
        expect(RecommendedTool.allCases.count == 46, "46 recommendations remain available")
        expect(RecommendedToolGroup.allCases.map { group in RecommendedTool.allCases.filter { $0.group == group }.count } == [11, 7, 21, 3, 4], "preserve the five recommendation groups")
        expect(RecommendedTool(rawValue: "zshell") == nil, "the running app is not recommended to itself")
        expect(service.missingTools.isEmpty, "unchecked inventory must not enable install-all")
        await service.refresh(force: true)
        expect(service.states[.fzf]?.installedVersion == "0.60.0", "detect Homebrew formula")
        expect(service.states[.fzf]?.hasUpdate == true, "compare fresh metadata with installed version")
        expect(service.states[.python]?.location == .homebrew, "Python alias remains Homebrew-managed")
        expect(service.states[.python]?.installedVersion == "3.14.0", "read canonical Python receipt")
        expect(service.missingTools.contains(.tree), "missing tool enables installation")
        expect(service.missingTools.contains(.zisla), "missing Zisla participates in install-all")
        expect(service.states[.zisla]?.latestVersion == "0.1.11", "Zisla version comes from its cask recipe")
        let afterRefresh = await fixture.commands
        expect(!afterRefresh.contains { ["install", "upgrade", "tap"].contains($0.first ?? "") }, "automatic checks never mutate packages or taps")
        let requests = await fixture.metadataRequests
        expect(requests.count == 46, "check every recommended tool")
        expect(requests.contains(URL(string: "https://api.github.com/repos/wzz6423/homebrew-tap/contents/Casks/zisla.rb?ref=main")!), "Zisla metadata uses the installable tap recipe")
        await service.refresh()
        let cachedRequests = await fixture.metadataRequests
        expect(cachedRequests == requests, "reopening within cache lifetime does not repeat network requests")

        await service.install([.tree])
        expect(service.states[.tree]?.location == .homebrew, "new installation becomes managed")
        let afterInstall = await fixture.commands
        expect(afterInstall.contains(["install", "--formula", "tree"]), "missing tool uses install")

        await service.install([.zisla])
        expect(service.states[.zisla]?.location == .homebrew, "single Zisla install becomes managed")
        expect(service.states[.zisla]?.installedVersion == "0.1.11", "single Zisla install refreshes the receipt")
        let afterZislaInstall = await fixture.commands
        expect(afterZislaInstall.contains(["tap", "wzz6423/tap"]), "Zisla installation enables its verified tap")
        expect(afterZislaInstall.contains(["install", "--cask", "wzz6423/tap/zisla"]), "single Zisla install uses the fully qualified cask")

        await fixture.setZislaInstalledVersion(nil)
        await service.refresh(force: true)
        let beforeInstallAll = await fixture.commands.count
        await service.install(service.missingTools)
        let afterInstallAll = await fixture.commands
        expect(afterInstallAll.dropFirst(beforeInstallAll).contains(["install", "--cask", "wzz6423/tap/zisla"]), "install-all includes missing Zisla")
        expect(service.missingTools.isEmpty, "install-all refreshes every installed tool")

        await fixture.setZislaInstalledVersion("0.1.10")
        await service.refresh(force: true)
        expect(service.updatableTools.contains(.zisla), "managed older Zisla participates in update-all")
        await fixture.setFailures(upgrade: true)
        await service.install(service.updatableTools)
        expect(service.states[.fzf]?.error?.contains("fixture download failed") == true, "failed download remains visible")
        expect(service.states[.python]?.installedVersion == "3.14.2", "batch continues after a failure and resolves Python alias")
        expect(service.states[.kero]?.installedVersion == "0.1.48", "batch updates cask after earlier failure")
        expect(service.states[.zisla]?.installedVersion == "0.1.11", "batch updates Zisla after earlier failure")
        let afterBatch = await fixture.commands
        expect(afterBatch.contains(["upgrade", "--formula", "python"]), "managed Python uses upgrade")
        expect(afterBatch.contains(["upgrade", "--cask", "--greedy-auto-updates", "egoist/tap/kero"]), "explicit cask upgrade includes apps with automatic updates")
        expect(afterBatch.contains(["upgrade", "--cask", "--greedy-auto-updates", "wzz6423/tap/zisla"]), "update-all upgrades Zisla through its cask")
        expect(!service.isBusy && service.activeTool == nil, "batch always releases busy state")

        await fixture.setFailures(metadata: true)
        await service.refresh(force: true)
        expect(service.states[.fzf]?.error != nil, "offline check reports failure")
        expect(service.states[.fzf]?.installedVersion == "0.60.0", "offline metadata does not lose installed inventory")
        await fixture.setFailures()
        await service.refresh(force: true)
        expect(service.states[.fzf]?.error == nil, "manual retry bypasses cache and clears recovered error")

        let applicationDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: applicationDirectory) }
        let contents = applicationDirectory.appendingPathComponent("zisla.app/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info = try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": "0.1.12"], format: .xml, options: 0)
        try info.write(to: contents.appendingPathComponent("Info.plist"))
        await fixture.setZislaInstalledVersion(nil)
        let applicationService = RecommendedToolService(
            commandRunner: { executable, arguments, environment, _ in
                await fixture.run(executable, arguments, environment)
            },
            dataLoader: { try await fixture.load($0) },
            homebrewLocator: { brewURL }, defaults: defaults, environment: ["PATH": ""],
            homeDirectory: applicationDirectory, applicationDirectories: [applicationDirectory]
        )
        await applicationService.refresh(force: true)
        expect(applicationService.states[.zisla]?.location == .external, "detect manually installed lowercase zisla.app")
        expect(applicationService.states[.zisla]?.installedVersion == "0.1.12", "read Zisla bundle version")
        expect(!applicationService.missingTools.contains(.zisla), "external Zisla is not missing")
        await fixture.setZislaInstalledVersion("0.1.10")
        await applicationService.refresh(force: true)
        expect(applicationService.states[.zisla]?.location == .homebrew, "recognize the installed Zisla cask")
        expect(applicationService.states[.zisla]?.installedVersion == "0.1.12", "prefer self-updated Zisla bundle over its stale receipt")
        expect(!applicationService.updatableTools.contains(.zisla), "update-all does not downgrade a newer Zisla bundle")

        let unavailable = RecommendedToolService(homebrewLocator: { nil }, defaults: defaults)
        await unavailable.install([.tree])
        expect(unavailable.error != nil && !unavailable.isBusy, "missing Homebrew reports actionable failure")
        expect(RecommendedToolMetadata.isNewer("1.10.0", than: "1.9.9"), "numeric version ordering")
        expect(RecommendedToolMetadata.isNewer("1.2.3_1", than: "1.2.3"), "Homebrew revisions count as updates")
        expect(!RecommendedToolMetadata.isNewer("1.2.3", than: "1.2.3_1"), "never advertise a downgrade")
        expect(RecommendedToolMetadata.installedVersions("tree 1.9.0 1.10.0\n")["tree"] == "1.10.0", "multiple installed receipts select newest")
        print("Recommended tools tests: \(passed) passed, 0 failed")
    }
}
