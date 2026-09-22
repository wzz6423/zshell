import AppKit
import Foundation
import Sparkle

@main
struct UpdaterPreferencesTests {
    @MainActor static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        Task {
            do {
                try await runTests()
                UserDefaults.standard.synchronize()
                exit(0)
            } catch {
                print("Updater preference tests failed: \(error)")
                exit(1)
            }
        }
        application.run()
    }

    @MainActor static func runTests() async throws {
        let testDomain = Bundle.main.bundleIdentifier!
        precondition(testDomain.hasPrefix("sh.zshell.tests.updater-preferences-"),
                     "tests must have an isolated app identity")
        let phase = CommandLine.arguments[1]
        let defaults = UserDefaults.standard
        let updater = Updater.shared
        let driver = SPUStandardUserDriver(hostBundle: .main, delegate: nil)
        let sparkle = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: nil)
        var passed = 0

        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            passed += 1
        }

        func expectState(checks: Bool, downloads: Bool, allowed: Bool) async throws {
            try await waitUntil {
                updater.automaticallyChecksForUpdates == checks
                    && updater.automaticallyDownloadsUpdates == downloads
                    && updater.allowsAutomaticUpdates == allowed
                    && sparkle.automaticallyChecksForUpdates == checks
                    && sparkle.automaticallyDownloadsUpdates == downloads
                    && sparkle.allowsAutomaticUpdates == allowed
            }
            passed += 1
        }

        switch phase {
        case "fresh":
            try await expectState(checks: true, downloads: false, allowed: true)
            expect(defaults.object(forKey: "SUAutomaticallyUpdate") == nil,
                   "initialization must preserve Sparkle's opt-in default without writing a preference")

            updater.automaticallyDownloadsUpdates = true
            try await expectState(checks: true, downloads: true, allowed: true)
            expect(defaults.bool(forKey: "SUAutomaticallyUpdate"), "user opt-in is stored by Sparkle")
            updater.automaticallyDownloadsUpdates = false
            try await expectState(checks: true, downloads: false, allowed: true)
            expect(!defaults.bool(forKey: "SUAutomaticallyUpdate"), "user opt-out is stored by Sparkle")

            updater.automaticallyDownloadsUpdates = true
            updater.automaticallyChecksForUpdates = false
            try await expectState(checks: false, downloads: false, allowed: false)
            expect(defaults.bool(forKey: "SUAutomaticallyUpdate"),
                   "disabling checks must not erase the persisted opt-in during KVO synchronization")
            updater.automaticallyDownloadsUpdates = true
            try await expectState(checks: false, downloads: false, allowed: false)
            expect(defaults.bool(forKey: "SUAutomaticallyUpdate"),
                   "a rejected download preference follows Sparkle without erasing opt-in")
            updater.automaticallyChecksForUpdates = true
            try await expectState(checks: true, downloads: true, allowed: true)

            sparkle.automaticallyDownloadsUpdates = false
            try await expectState(checks: true, downloads: false, allowed: true)
            sparkle.automaticallyDownloadsUpdates = true
            try await expectState(checks: true, downloads: true, allowed: true)
            sparkle.automaticallyChecksForUpdates = false
            try await expectState(checks: false, downloads: false, allowed: false)
            expect(defaults.bool(forKey: "SUAutomaticallyUpdate"),
                   "external Sparkle changes must retain the stored download choice")
            sparkle.automaticallyChecksForUpdates = true
            try await expectState(checks: true, downloads: true, allowed: true)

            defaults.set(false, forKey: "SUAutomaticallyUpdate")
            try await expectState(checks: true, downloads: false, allowed: true)
            defaults.set(true, forKey: "SUAutomaticallyUpdate")
            try await expectState(checks: true, downloads: true, allowed: true)
            defaults.set(false, forKey: "SUEnableAutomaticChecks")
            try await expectState(checks: false, downloads: false, allowed: false)
            expect(defaults.bool(forKey: "SUAutomaticallyUpdate"), "external defaults changes preserve opt-in")

        case "restore-disabled":
            try await expectState(checks: false, downloads: false, allowed: false)
            expect(defaults.bool(forKey: "SUAutomaticallyUpdate"), "restart retains opt-in while checks are disabled")
            updater.automaticallyChecksForUpdates = true
            try await expectState(checks: true, downloads: true, allowed: true)

        case "restore-enabled":
            try await expectState(checks: true, downloads: true, allowed: true)
            expect(defaults.bool(forKey: "SUAutomaticallyUpdate"), "restart must not overwrite a previous opt-in")
            updater.automaticallyDownloadsUpdates = false
            try await expectState(checks: true, downloads: false, allowed: true)

        case "restore-opted-out":
            try await expectState(checks: true, downloads: false, allowed: true)
            expect(defaults.object(forKey: "SUAutomaticallyUpdate") as? Bool == false,
                   "restart must not overwrite a previous opt-out")
            updater.automaticallyChecksForUpdates = false
            try await expectState(checks: false, downloads: false, allowed: false)
            updater.automaticallyChecksForUpdates = true
            try await expectState(checks: true, downloads: false, allowed: true)

        case "disallowed":
            try await expectState(checks: true, downloads: false, allowed: false)
            updater.automaticallyDownloadsUpdates = true
            try await expectState(checks: true, downloads: false, allowed: false)
            expect(defaults.object(forKey: "SUAutomaticallyUpdate") == nil,
                   "a Sparkle policy that disallows automatic updates cannot be overridden")

        default:
            preconditionFailure("Unknown preference test phase: \(phase)")
        }
        updater.checkForUpdates()
        await Task.yield()
        expect(!updater.canCheckForUpdates && !updater.isUpdating,
               "Debug builds must not start Sparkle after preference changes or a manual check")
        print("Updater preferences (\(phase)): \(passed) passed, 0 failed")
    }

    @MainActor static func waitUntil(_ condition: () -> Bool, line: UInt = #line) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        preconditionFailure("Timed out waiting for Sparkle preference synchronization at line \(line)")
    }
}
