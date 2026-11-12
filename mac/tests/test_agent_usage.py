"""Exercise usage policy, cancellation, local fixtures and production AppKit UI.

Every CLI, home, report, resource bundle and compiled binary is disposable.
"""
from pathlib import Path
import json
import os
import plistlib
import subprocess
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "mac/zshell"

HARNESS = r'''
import AppKit
import Combine
import Darwin
import Foundation

@MainActor final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    @Published var aiEnabled = false
    @Published var resumeAgentConversations = true
    @Published var notifyOnAgentAttention = true
    @Published var notifyOnAgentCompletion = true
    @Published var agentUsageEnabled = false
    @Published var claudeUsageEnabled = true
    @Published var codexUsageEnabled = true
    func setAIEnabled(_ value: Bool) throws { aiEnabled = value }
}

@MainActor enum SettingsVisibility {
    struct State { let aiEnabled: Bool }
    static var current: State { State(aiEnabled: AppSettings.shared.aiEnabled) }
}

@MainActor final class TerminalManager { static var activeWindowManager: TerminalManager? }
@MainActor final class AgentConversationHistoryController {
    enum Filter { case all }
    static let shared = AgentConversationHistoryController()
    func show(for manager: TerminalManager, filter: Filter) {}
}

nonisolated final class ControlledLoader: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var values: [Result<AgentUsageSnapshot, AgentUsageIssue>]
    private let firstGate: DispatchSemaphore?
    init(_ values: [Result<AgentUsageSnapshot, AgentUsageIssue>], firstGate: DispatchSemaphore? = nil) {
        self.values = values
        self.firstGate = firstGate
    }
    var calls: Int { lock.withLock { count } }
    func read() -> Result<AgentUsageSnapshot, AgentUsageIssue> {
        let index = lock.withLock { let result = count; count += 1; return result }
        if index == 0 { _ = firstGate?.wait(timeout: .now() + 4) }
        return values[min(index, values.count - 1)]
    }
}

@MainActor enum UsageRouteProbe {
    struct Caller { let session: Bool? }
    static func success(_ request: ZshellAutomationRequest, _ result: ZshellJSONValue) -> ZshellAutomationResponse {
        .success(id: request.id, result: result)
    }
    static func failure(_ request: ZshellAutomationRequest, _ code: String, _ message: String) -> ZshellAutomationResponse {
        .failure(id: request.id, code: code, message: message)
    }
    static func route(_ request: ZshellAutomationRequest, caller: Caller) -> ZshellAutomationResponse {
        switch request.method {
        ROUTE_FRAGMENT
        default: return failure(request, "unknown", "unknown")
        }
    }
}

@main struct UsageProbe {
    @MainActor static func check(_ condition: Bool, _ message: String) {
        precondition(condition, message)
    }
    @MainActor static func wait(_ condition: () -> Bool, _ message: String, timeout: Double = 4) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        check(condition(), message)
    }
    @MainActor static func spin(_ seconds: Double = 0.08) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
    }
    @MainActor static func snapshot(_ percentage: Double) -> AgentUsageSnapshot {
        AgentUsageSnapshot(windows: [AgentUsageWindow(kind: .fiveHour, usedPercent: percentage,
            durationMinutes: nil, resetsAt: Date().addingTimeInterval(900))],
            plan: nil, updatedAt: Date())
    }
    @MainActor static func percentage(_ state: AgentUsageProviderState) -> Double? {
        guard case .available(let value) = state.availability else { return nil }
        return value.windows.first?.usedPercent
    }
    @MainActor static func report(_ percentage: Double) -> ZshellJSONValue {
        .object(["windows": .object(["five_hour": .object([
            "used_percentage": .number(percentage), "resets_at": .number(Date().addingTimeInterval(900).timeIntervalSince1970)
        ])])])
    }
    @MainActor static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
    @MainActor static func hasVisibleAncestor(_ view: NSView) -> Bool {
        !view.isHidden && (view.superview.map(hasVisibleAncestor) ?? true)
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let usageFile = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ZSHELL_CLAUDE_USAGE_FILE"]!)
        let marker = root.appendingPathComponent("cli-starts")
        let settings = AppSettings.shared
        let zero = ControlledLoader([.success(snapshot(10))])
        let none = ControlledLoader([.failure(.noLimits)])
        let disabled = AgentUsageModel(claudeLoader: { zero.read() }, codexLoader: { none.read() })
        disabled.applySettings(settings)
        disabled.refresh()
        disabled.refreshIfNeeded()
        spin()
        check(zero.calls == 0 && none.calls == 0, "disabled usage must not invoke either reader")
        check(!disabled.acceptClaudeStatusLine(report(20)), "disabled reports are rejected")
        check(!FileManager.default.fileExists(atPath: usageFile.path), "disabled reports cannot create files")
        check(disabled.claude.availability == .disabled && disabled.codex.availability == .disabled,
              "master off keeps no visible usage data")

        settings.agentUsageEnabled = true
        settings.codexUsageEnabled = false
        disabled.applySettings(settings)
        wait({ !disabled.claude.isRefreshing }, "Claude-only refresh finishes")
        check(zero.calls == 1 && none.calls == 0 && percentage(disabled.claude) == 10,
              "provider gate reads only enabled Claude")
        disabled.refreshIfNeeded()
        spin()
        check(zero.calls == 1, "freshness prevents redundant reads")
        settings.claudeUsageEnabled = false
        settings.codexUsageEnabled = true
        disabled.applySettings(settings)
        wait({ !disabled.codex.isRefreshing }, "Codex-only refresh finishes")
        check(zero.calls == 1 && none.calls == 1 && disabled.claude.availability == .disabled,
              "provider choices gate reads independently")
        check(disabled.codex.availability == .unavailable(.noLimits), "missing limits stay unavailable")
        settings.agentUsageEnabled = false
        disabled.applySettings(settings)
        check(!settings.claudeUsageEnabled && settings.codexUsageEnabled,
              "master does not overwrite provider selection")

        let first = DispatchSemaphore(value: 0)
        let race = ControlledLoader([.success(snapshot(11)), .success(snapshot(77))], firstGate: first)
        let generation = AgentUsageModel(claudeLoader: { race.read() }, codexLoader: { none.read() })
        settings.agentUsageEnabled = true
        settings.claudeUsageEnabled = true
        settings.codexUsageEnabled = false
        generation.applySettings(settings)
        wait({ race.calls == 1 }, "first slow read begins")
        settings.agentUsageEnabled = false
        generation.applySettings(settings)
        check(!generation.claude.isRefreshing && generation.claude.availability == .disabled,
              "disable immediately removes busy/data")
        settings.agentUsageEnabled = true
        generation.applySettings(settings)
        wait({ percentage(generation.claude) == 77 }, "re-enable loads a fresh generation")
        first.signal()
        spin()
        check(percentage(generation.claude) == 77, "old callback cannot overwrite reopened data")

        let providerGate = DispatchSemaphore(value: 0)
        let providerRead = ControlledLoader([.success(snapshot(5)), .success(snapshot(80))], firstGate: providerGate)
        let otherRead = ControlledLoader([.success(snapshot(25))])
        let providerRace = AgentUsageModel(claudeLoader: { providerRead.read() }, codexLoader: { otherRead.read() })
        settings.codexUsageEnabled = true
        providerRace.applySettings(settings)
        wait({ providerRead.calls == 1 && percentage(providerRace.codex) == 25 }, "independent provider reads begin")
        settings.claudeUsageEnabled = false
        providerRace.applySettings(settings)
        check(providerRace.claude.availability == .disabled && percentage(providerRace.codex) == 25,
              "provider disable preserves unrelated completed usage")
        settings.claudeUsageEnabled = true
        providerRace.applySettings(settings)
        wait({ percentage(providerRace.claude) == 80 }, "provider re-enable starts a new read")
        providerGate.signal()
        spin()
        check(percentage(providerRace.claude) == 80 && otherRead.calls == 1,
              "provider generation rejects old completion without restarting another provider")
        settings.codexUsageEnabled = false
        providerRace.applySettings(settings)

        let liveGate = DispatchSemaphore(value: 0)
        let liveRead = ControlledLoader([.success(snapshot(1))], firstGate: liveGate)
        let live = AgentUsageModel(claudeLoader: { liveRead.read() }, codexLoader: { none.read() })
        live.applySettings(settings)
        wait({ liveRead.calls == 1 }, "old file read begins")
        check(live.acceptClaudeStatusLine(report(54)), "enabled live report is saved")
        liveGate.signal()
        spin()
        check(percentage(live.claude) == 54, "live report invalidates old file read")
        let attributes = try FileManager.default.attributesOfItem(atPath: usageFile.path)
        check((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "saved report is private")
        let saved = try Data(contentsOf: usageFile)
        settings.claudeUsageEnabled = false
        live.applySettings(settings)
        check(!live.acceptClaudeStatusLine(report(99)), "disabled provider rejects reports")
        check(try Data(contentsOf: usageFile) == saved, "disabled provider preserves report bytes")

        let staleLoader = ControlledLoader([.success(snapshot(30)), .failure(.timedOut)])
        let stale = AgentUsageModel(claudeLoader: { staleLoader.read() }, codexLoader: { none.read() })
        settings.claudeUsageEnabled = true
        stale.applySettings(settings)
        wait({ !stale.claude.isRefreshing }, "first stale fixture finishes")
        stale.refresh()
        wait({ !stale.claude.isRefreshing }, "failed refresh finishes")
        if case .stale(let data, .timedOut) = stale.claude.availability {
            check(data.windows.first?.usedPercent == 30, "failed refresh retains last data")
        } else { preconditionFailure("failed refresh must expose stale state") }
        settings.agentUsageEnabled = false
        for model in [disabled, generation, providerRace, live, stale] { model.applySettings(settings) }

        let request = ZshellAutomationRequest(version: 1, id: "test", method: "agent.usage.report",
            token: "fixture", terminalID: UUID().uuidString, params: ["usage": report(60)])
        let masterResponse = UsageRouteProbe.route(request, caller: .init(session: true))
        check(masterResponse.error?.code == "usage_disabled", "router explains master-off refusal")
        check(try Data(contentsOf: usageFile) == saved, "router refuses writes while master off")
        settings.agentUsageEnabled = true
        settings.claudeUsageEnabled = false
        let providerResponse = UsageRouteProbe.route(request, caller: .init(session: true))
        check(providerResponse.error?.code == "provider_usage_disabled", "router explains provider-off refusal")
        settings.agentUsageEnabled = false
        let nonPane = UsageRouteProbe.route(request, caller: .init(session: nil))
        check(nonPane.error?.code == "terminal_required", "pane ownership still gates reports")

        // Production loaders only see disposable paths and our stand-in CLI.
        let real = AgentUsageModel()
        try FileManager.default.removeItem(at: usageFile)
        check(mkfifo(usageFile.path, 0o600) == 0, "fixture FIFO created")
        real.applySettings(settings)
        real.refresh()
        spin()
        check(!FileManager.default.fileExists(atPath: marker.path), "disabled production never launches CLI")
        settings.claudeUsageEnabled = true
        settings.codexUsageEnabled = false
        settings.agentUsageEnabled = true
        real.applySettings(settings)
        wait({ !real.claude.isRefreshing }, "bounded Claude reader rejects FIFO", timeout: 1)
        check(real.claude.availability == .unavailable(.noClaudeSession), "FIFO remains unavailable")
        settings.agentUsageEnabled = false
        real.applySettings(settings)
        try FileManager.default.removeItem(at: usageFile)
        check(real.acceptClaudeStatusLine(report(5)) == false, "disabled production cannot write a report")
        settings.agentUsageEnabled = true
        real.applySettings(settings)
        wait({ !real.claude.isRefreshing }, "missing report finishes")
        check(real.acceptClaudeStatusLine(report(42)), "production report writes isolated fixture")
        real.refresh()
        wait({ !real.claude.isRefreshing }, "production file read completes")
        check(percentage(real.claude) == 42, "production Claude file round trip")

        try "success".write(to: root.appendingPathComponent("cli-mode"), atomically: true, encoding: .utf8)
        settings.claudeUsageEnabled = false
        settings.codexUsageEnabled = true
        real.applySettings(settings)
        wait({ !real.codex.isRefreshing }, "production Codex stand-in finishes")
        check(percentage(real.codex) == 65, "production parser reads stand-in account limit: \(real.codex.availability)")
        try "auth".write(to: root.appendingPathComponent("cli-mode"), atomically: true, encoding: .utf8)
        real.refresh()
        wait({ !real.codex.isRefreshing }, "stand-in auth failure finishes")
        check(real.codex.availability == .stale(snapshotForComparison(real.codex), .notSignedIn),
              "authentication requirement is unavailable without any login flow")
        try "hang".write(to: root.appendingPathComponent("cli-mode"), atomically: true, encoding: .utf8)
        let previousStarts = (try String(contentsOf: marker, encoding: .utf8)).split(separator: "\n").count
        real.refresh()
        wait({ (try? String(contentsOf: marker, encoding: .utf8).split(separator: "\n").count) == previousStarts + 1 },
             "hanging stand-in starts")
        let pid = Int32((try String(contentsOf: marker, encoding: .utf8)).split(separator: "\n").last!)!
        let stopStart = Date()
        settings.codexUsageEnabled = false
        real.applySettings(settings)
        wait({ kill(pid, 0) == -1 && errno == ESRCH }, "provider disable terminates actual child", timeout: 2)
        check(Date().timeIntervalSince(stopStart) < 2 && real.codex.availability == .disabled,
              "actual child cancellation is bounded and data is hidden")
        let startsAfterCancel = try Data(contentsOf: marker)
        real.refresh()
        real.refreshIfNeeded()
        spin()
        check(try Data(contentsOf: marker) == startsAfterCancel, "disabled refresh cannot restart CLI")

        let executable = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PATH"]!.split(separator: ":").first! + "/codex")
        let timeoutStart = Date()
        let timedOut = ProcessRunner.run(executable: executable, arguments: ["app-server", "--listen", "stdio://"],
            initialInput: Data("{\"id\":1}".utf8), initializedInput: Data("{}".utf8),
            secondInput: Data("{\"id\":2}".utf8), waitForResponseID: 1, secondResponseID: 2, timeout: 0.15)
        check(timedOut.timedOut && Date().timeIntervalSince(timeoutStart) < 2, "runner timeout terminates child promptly")
        try "late".write(to: root.appendingPathComponent("cli-mode"), atomically: true, encoding: .utf8)
        let lateStarts = (try String(contentsOf: marker, encoding: .utf8)).split(separator: "\n").count
        let lateTask = Task.detached {
            ProcessRunner.run(executable: executable, arguments: [], initialInput: Data("{\"id\":1}".utf8),
                initializedInput: Data("{}".utf8), secondInput: Data("{\"id\":2}".utf8),
                waitForResponseID: 1, secondResponseID: 2, timeout: 8)
        }
        wait({ (try? String(contentsOf: marker, encoding: .utf8).split(separator: "\n").count) == lateStarts + 1 },
             "late initialize stand-in starts")
        let latePID = Int32((try String(contentsOf: marker, encoding: .utf8)).split(separator: "\n").last!)!
        let lateCancelStart = Date()
        lateTask.cancel()
        let lateResult = await lateTask.value
        check(lateResult.status == -2 && !lateResult.timedOut && Date().timeIntervalSince(lateCancelStart) < 2,
              "cancelled initialize task finishes promptly")
        check(!FileManager.default.fileExists(atPath: root.appendingPathComponent("second-request").path),
              "cancelled initialize cannot issue a later account request")
        wait({ kill(latePID, 0) == -1 && errno == ESRCH }, "cancelled initialize leaves no live child", timeout: 2)

        settings.agentUsageEnabled = false
        settings.claudeUsageEnabled = true
        settings.codexUsageEnabled = true
        AgentUsageModel.shared.applySettings(settings)
        try layout()
        print("Agent usage: provider gates, disabled IO/report refusal, generations, live reports, stale state, FIFO, fake CLI auth/cancel/timeout and 17-language AppKit settings passed")
    }
    @MainActor static func snapshotForComparison(_ state: AgentUsageProviderState) -> AgentUsageSnapshot {
        if case .stale(let data, _) = state.availability { return data }
        preconditionFailure("expected stale snapshot")
    }
    @MainActor static func layout() throws {
        let data = snapshot(75)
        var count = 0
        for language in AppLanguage.allCases where language != .system {
            AppLocalization.apply(language)
            let pane = SettingsAutomationPane()
            pane.setCategory(.automation)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 460),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = pane
            let title = String(localized: "Read account usage")
            let providerTitle = String(localized: "Read Codex usage")
            for width in [660.0, 480, 360, 480] {
                window.setContentSize(NSSize(width: width, height: 460))
                for view in descendants(pane.view) {
                    view.userInterfaceLayoutDirection = language == .arabic ? .rightToLeft : .leftToRight
                }
                pane.view.layoutSubtreeIfNeeded()
                check(pane.revealSearchResult(title, in: String(localized: "Account Usage")), "usage setting search finds actual pane row")
                let switches = descendants(pane.view).compactMap { $0 as? NSSwitch }
                let master = switches.first { $0.accessibilityLabel() == title }!
                let provider = switches.first { $0.accessibilityLabel() == providerTitle }!
                check(hasVisibleAncestor(master) && master.isEnabled && master.state == .off,
                      "master setting remains discoverable with no data")
                check(hasVisibleAncestor(provider) && !provider.isEnabled && provider.state == .on,
                      "provider choice remains visible and retained while master is off")
                for label in descendants(pane.view).compactMap({ $0 as? NSTextField }) where hasVisibleAncestor(label) && !label.stringValue.isEmpty {
                    check(label.frame.height + 1 >= label.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: label.frame.width, height: 10_000)).height,
                          "pane label fits at \(language.rawValue) / \(width): \(label.stringValue)")
                }
                count += 1
            }
            window.close()
            let usage = AgentUsageSettingsView(frame: .zero)
            let host = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 1000))
            usage.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(usage)
            NSLayoutConstraint.activate([
                usage.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                usage.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                usage.topAnchor.constraint(equalTo: host.topAnchor),
            ])
            let cases: [(AgentUsageAvailability, Bool)] = [(.waiting, true), (.unavailable(.noClaudeSession), false),
                (.unavailable(.notSignedIn), false), (.unavailable(.timedOut), false), (.available(data), false),
                (.stale(data, .timedOut), false)]
            for width in [360.0, 240] {
                host.frame.size.width = width
                for (index, entry) in cases.enumerated() {
                    let (availability, busy) = entry
                    usage.apply(claude: AgentUsageProviderState(kind: .claude, availability: availability, isRefreshing: busy),
                        codex: AgentUsageProviderState(kind: .codex, availability: .available(data)))
                    for view in descendants(usage) {
                        view.userInterfaceLayoutDirection = language == .arabic ? .rightToLeft : .leftToRight
                        if index % 2 == 1, let label = view as? NSTextField, let font = label.font {
                            label.font = NSFont(descriptor: font.fontDescriptor, size: font.pointSize * 1.3)
                        }
                    }
                    for _ in 0..<3 { host.layoutSubtreeIfNeeded(); spin(0.005) }
                    check(usage.hasVisibleUsage, "errors and pending data remain visible")
                    for label in descendants(usage).compactMap({ $0 as? NSTextField }) where hasVisibleAncestor(label) && !label.stringValue.isEmpty {
                        check(label.frame.width > 0 && label.frame.height + 1 >= label.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: label.frame.width, height: 10_000)).height,
                              "usage state label fits \(language.rawValue) / \(width): \(label.stringValue)")
                    }
                    let button = descendants(usage).compactMap { $0 as? NSButton }.first!
                    check(!button.isHidden && button.isEnabled == !busy, "refresh remains available for failed reads")
                    count += 1
                }
            }
            usage.apply(claude: .init(kind: .claude), codex: .init(kind: .codex))
            check(!usage.hasVisibleUsage, "disabled state hides usage data")
        }
        print("AppKit usage layout: \(count) locale/width/state samples")
    }
}
'''

FAKE_CLI = r'''#!PYTHON
import json
import os
from pathlib import Path
import signal
import sys
import time
root = Path(os.environ["USAGE_FIXTURE_ROOT"])
mode = (root / "cli-mode").read_text() if (root / "cli-mode").exists() else "success"
with (root / "cli-starts").open("a") as file:
    file.write(str(os.getpid()) + "\n")
if mode == "hang":
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    time.sleep(30)
else:
    for line in sys.stdin:
        message = json.loads(line)
        if message.get("id") == 1:
            if mode == "late":
                time.sleep(1)
            print(json.dumps({"id": 1, "result": {}}), flush=True)
        if message.get("id") == 2:
            if mode == "late":
                (root / "second-request").write_text("unexpected")
            if mode == "auth":
                print(json.dumps({"id": 2, "error": {"code": -32600, "message": "authentication required"}}), flush=True)
            else:
                print(json.dumps({"id": 2, "result": {"rateLimits": {"primary": {"usedPercent": 65, "windowDurationMins": 300}}}}), flush=True)
            break
'''

with tempfile.TemporaryDirectory(prefix="zshell-agent-usage-") as temporary:
    root = Path(temporary)
    home = root / "home"
    home.mkdir()
    fake = root / "bin"
    fake.mkdir()
    cli = fake / "codex"
    cli.write_text(FAKE_CLI.replace("#!PYTHON", "#!" + str(Path(os.sys.executable).resolve()), 1))
    cli.chmod(0o700)
    contents = root / "UsageProbe.app/Contents"
    resources = contents / "Resources"
    resources.mkdir(parents=True)
    binary = contents / "MacOS/UsageProbe"
    binary.parent.mkdir()
    (contents / "Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": "sh.zshell.usage-test." + uuid.uuid4().hex,
        "CFBundleExecutable": binary.name, "CFBundleDevelopmentRegion": "en", "CFBundlePackageType": "APPL",
    }))
    subprocess.run(["xcrun", "xcstringstool", "compile", str(SOURCE / "Localizable.xcstrings"),
                    "--output-directory", str(resources)], check=True, capture_output=True, text=True)
    metadata = root / "Metadata.swift"
    category = (SOURCE / "Settings/SettingsWindowController.swift").read_text()
    category = category[category.index("enum SettingsCategory:"):category.index("    func makePane()")]+"}\n"
    agent = (SOURCE / "AgentAutomation.swift").read_text()
    agent = agent[agent.index("enum ZshellAgentKind:"):agent.index("    var executable:")]+"}\n"
    protocol = (SOURCE / "ZshellAutomationProtocol.swift").read_text()
    protocol = protocol[protocol.index("nonisolated enum ZshellJSONValue:"):protocol.index("enum ZshellAutomationWireError:")]
    metadata.write_text("import AppKit\nimport Foundation\nimport Darwin\n"+category+agent+protocol)
    router = (SOURCE / "ZshellAutomationRouter.swift").read_text()
    fragment = router[router.index('        case "agent.usage.report":'):router.index("\n        default:")]
    harness = root / "Harness.swift"
    harness.write_text(HARNESS.replace("ROUTE_FRAGMENT", fragment))
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-default-isolation", "MainActor", "-D", "DEBUG",
                    "-module-cache-path", str(root / "modules"),
                    str(SOURCE / "AgentUsage.swift"), str(SOURCE / "AgentUsageSettingsView.swift"),
                    str(SOURCE / "AgentCLISupportSettingsView.swift"), str(SOURCE / "AppLocalization.swift"),
                    str(SOURCE / "SettingsConfigFile.swift"), str(SOURCE / "Settings/SettingsRows.swift"),
                    str(SOURCE / "Settings/SettingsPaneKit.swift"), str(SOURCE / "Settings/SettingsPaneViewController.swift"),
                    str(SOURCE / "Settings/SettingsAutomationPane.swift"), str(metadata), str(harness), "-o", str(binary)],
                   cwd=ROOT, check=True)
    environment = {"HOME": str(home), "CFFIXED_USER_HOME": str(home),
                   "PATH": str(fake), "USAGE_FIXTURE_ROOT": str(root), "CODEX_HOME": str(home / "codex"),
                   "ZSHELL_CLAUDE_USAGE_FILE": str(root / "reports/usage.json")}
    (root / "reports").mkdir()
    subprocess.run([str(binary), str(root)], cwd=ROOT, env=environment, check=True, timeout=50)
