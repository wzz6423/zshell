//
//  Updater.swift
//  zshell
//

import Combine
import Foundation
import AppKit
import Sparkle
import SwiftUI

/// App-wide Sparkle updater. A single instance owns the update lifecycle; the
/// "Check for Updates…" menu item and the Settings toggle both drive it.
///
/// The feed URL and the public EdDSA key are read from Info.plist, injected via
/// the `INFOPLIST_KEY_SUFeedURL` and `INFOPLIST_KEY_SUPublicEDKey` build
/// settings. See RELEASING.md for generating the signing keys and publishing
/// updates.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    private let brewExecutable: URL?
    private let controller: SPUStandardUpdaterController

    /// Gates the menu item: Sparkle can't start a check while one is already in
    /// flight, so the command disables itself until it's ready again.
    @Published private(set) var canCheckForUpdates = false

    @Published private(set) var isUpdating = false

    var isHomebrewInstallation: Bool { brewExecutable != nil }

    var updateActionTitle: String {
        isHomebrewInstallation
            ? String(localized: "Update with Homebrew…")
            : String(localized: "Check for Updates…")
    }

    /// Whether Sparkle checks for updates on its own schedule. Sparkle owns the
    /// persisted value (in `UserDefaults`); this mirror lets Settings bind to
    /// it and writes changes straight back through.
    @Published var automaticallyChecksForUpdates: Bool {
        didSet {
            guard brewExecutable == nil else { return }
            controller.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }

    private init() {
        // Don't run the updater in debug builds. Starting it schedules a
        // background check and pops Sparkle's "check for updates
        // automatically?" permission prompt, which is just noise while
        // developing. Release builds start it and behave normally.
        #if DEBUG
        let startImmediately = false
        #else
        let startImmediately = true
        #endif
        brewExecutable = Self.findHomebrewExecutable()
        controller = SPUStandardUpdaterController(
            startingUpdater: startImmediately && brewExecutable == nil,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        // Seed from Sparkle's persisted value; didSet doesn't fire here.
        automaticallyChecksForUpdates = brewExecutable == nil
            ? controller.updater.automaticallyChecksForUpdates
            : false
        if brewExecutable == nil {
            controller.updater.publisher(for: \.canCheckForUpdates)
                .assign(to: &$canCheckForUpdates)
        } else {
            canCheckForUpdates = true
        }

        // Force a silent check on launch when auto-checks are on. Starting the
        // updater only arms Sparkle's *scheduled* checker, which fires once its
        // interval (~a day) has elapsed since the last check — so a normal
        // relaunch checks nothing. Sparkle requires this forced check to run
        // immediately after the updater starts (calling it later interferes
        // with its scheduler), which is why it lives here and is gated on the
        // updater actually having been started.
        if startImmediately && brewExecutable == nil && automaticallyChecksForUpdates {
            controller.updater.checkForUpdatesInBackground()
        }
    }

    /// Runs the updater owned by the installation channel.
    func checkForUpdates() {
        guard let brewExecutable else {
            controller.checkForUpdates(nil)
            return
        }

        isUpdating = true
        canCheckForUpdates = false
        let process = Process()
        process.executableURL = brewExecutable
        process.arguments = ["upgrade", "--cask", "--greedy-auto-updates", "zshell"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.terminationHandler = { [weak self] process in
            let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            Task { @MainActor in
                self?.finishHomebrewUpdate(status: process.terminationStatus, output: text)
            }
        }

        do {
            try process.run()
        } catch {
            finishHomebrewUpdate(status: 1, output: error.localizedDescription)
        }
    }

    private func finishHomebrewUpdate(status: Int32, output: String) {
        isUpdating = false
        canCheckForUpdates = true

        let alert = NSAlert()
        if status == 0 {
            alert.messageText = "Homebrew update finished"
            alert.informativeText = "Quit and reopen Zshell to use the updated version."
        } else {
            alert.messageText = "Homebrew update failed"
            alert.informativeText = output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Run `brew upgrade --cask --greedy-auto-updates zshell` in Terminal to see the error."
                : output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        alert.alertStyle = status == 0 ? .informational : .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private static func findHomebrewExecutable() -> URL? {
        guard Bundle.main.bundleIdentifier == "sh.zshell" else { return nil }

        let fileManager = FileManager.default
        let candidates = [
            "/opt/homebrew/bin/brew",
            "/usr/local/bin/brew",
        ]

        for path in candidates {
            let prefix = URL(fileURLWithPath: path)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .path
            let caskroom = URL(fileURLWithPath: prefix)
                .appendingPathComponent("Caskroom/zshell")
                .path
            if fileManager.fileExists(atPath: caskroom) && fileManager.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }
}

/// The "Check for Updates…" application-menu command.
struct CheckForUpdatesView: View {
    @ObservedObject var updater: Updater

    var body: some View {
        Button(updater.updateActionTitle) {
            updater.checkForUpdates()
        }
        .disabled(!updater.canCheckForUpdates || updater.isUpdating)
    }
}
