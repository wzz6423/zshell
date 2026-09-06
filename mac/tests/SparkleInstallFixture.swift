// A disposable installer host, not Zshell: no production updater or user state is loaded.
import AppKit
import CryptoKit
import Foundation
import Sparkle

@MainActor
private final class InstallDriver: SPUStandardUserDriver {
    let root: URL

    init(root: URL) {
        self.root = root
        super.init(hostBundle: .main, delegate: nil)
    }

    func record(_ stage: String, details: String = "") {
        let event = ["stage": stage, "details": details, "pid": String(getpid())]
        let data = try! JSONSerialization.data(withJSONObject: event)
        let file = root.appendingPathComponent("events.jsonl")
        if !FileManager.default.fileExists(atPath: file.path) {
            FileManager.default.createFile(atPath: file.path, contents: nil)
        }
        let handle = try! FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try! handle.seekToEnd()
        try! handle.write(contentsOf: data + Data([10]))
    }

    override func show(_ request: SPUUpdatePermissionRequest,
                       reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
    }
    override func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {}
    override func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
                                  reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard appcastItem.signingValidationStatus == .succeeded else {
            record("error", details: "Appcast did not pass its signature check")
            reply(.dismiss)
            NSApp.terminate(nil)
            return
        }
        record("signedFeedAccepted", details: appcastItem.versionString)
        reply(.install)
    }
    override func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    override func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}
    override func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        record("error", details: "No update: \(error)")
        acknowledgement()
        NSApp.terminate(nil)
    }
    override func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        record("error", details: String(describing: error))
        acknowledgement()
        NSApp.terminate(nil)
    }
    override func showDownloadInitiated(cancellation: @escaping () -> Void) { record("download") }
    override func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}
    override func showDownloadDidReceiveData(ofLength length: UInt64) {}
    override func showDownloadDidStartExtractingUpdate() { record("extracting") }
    override func showExtractionReceivedProgress(_ progress: Double) {}
    override func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        record("ready")
        reply(.install)
    }
    override func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                                       retryTerminatingApplication: @escaping () -> Void) {
        record("installing", details: String(applicationTerminated))
    }
    override func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        record("installed", details: String(relaunched))
        acknowledgement()
    }
    override func dismissUpdateInstallation() {}
}

@main
@MainActor
struct SparkleInstallFixture {
    static func main() throws {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--generate-test-key" {
            let key = Curve25519.Signing.PrivateKey()
            try key.rawRepresentation.base64EncodedString()
                .write(toFile: CommandLine.arguments[2], atomically: true, encoding: .utf8)
            print(key.publicKey.rawRepresentation.base64EncodedString())
            return
        }
        let root = URL(fileURLWithPath: Bundle.main.object(forInfoDictionaryKey: "ZshellTestRoot") as! String)
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let driver = InstallDriver(root: root)
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as! String
        driver.record("launch", details: build)
        if build == "2" {
            #if arch(arm64)
            let architecture = "arm64"
            #else
            let architecture = "x86_64"
            #endif
            let marker: [String: Any] = ["build": build, "pid": getpid(), "architecture": architecture,
                                          "bundle": Bundle.main.bundleURL.path]
            try JSONSerialization.data(withJSONObject: marker)
                .write(to: root.appendingPathComponent("relaunched.json"), options: .atomic)
            return
        }
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main,
                                 userDriver: driver, delegate: nil)
        try updater.start()
        DispatchQueue.main.async { updater.checkForUpdates() }
        withExtendedLifetime((driver, updater)) { app.run() }
    }
}
