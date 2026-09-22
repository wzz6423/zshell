import AppKit
import Foundation
import Sparkle

@main
struct UpdaterTests {
    @MainActor static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        Task {
            do {
                try await runTests()
                exit(0)
            } catch {
                print("Updater tests failed: \(error)")
                exit(1)
            }
        }
        application.run()
    }

    @MainActor static func runTests() async throws {
        let testDomain = Bundle.main.bundleIdentifier!
        precondition(testDomain.hasPrefix("sh.zshell.tests."), "tests must have an isolated app identity")
        defer { UserDefaults.standard.removePersistentDomain(forName: testDomain) }
        var passed = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else {
                print("Updater test failed: \(message)")
                exit(1)
            }
            passed += 1
        }
        let infoData = try Data(contentsOf: URL(fileURLWithPath: "mac/zshell/Info.plist"))
        let info = try PropertyListSerialization.propertyList(from: infoData, format: nil) as! [String: Any]
        expect(info["SUPublicEDKey"] as? String == "94CIcriCuNHELX8l1CQPW2XUsrBcqp0mr++vw9tXB0Q=", "release public key must not rotate")
        expect(info["SURequireSignedFeed"] as? Bool == true, "signed feeds required")
        expect(info["SUVerifyUpdateBeforeExtraction"] as? Bool == true, "verify ZIP before extracting")
        for architecture in ["arm64", "x86_64"] {
            for slices in [1, 2] {
                let config = UpdateFeedConfiguration(infoDictionary: info, architecture: architecture, installedSliceCount: slices)!
                let file = slices == 1 ? "appcast-\(architecture).xml" : "appcast.xml"
                expect(config.primary.absoluteString == "https://gitee.com/wzz6423/zshell/releases/download/update-release/\(file)", "Gitee feed architecture")
                expect(config.fallback.absoluteString == "https://github.com/wzz6423/zshell/releases/latest/download/\(file)", "GitHub feed architecture")
            }
        }
        for key in ["SUPublicEDKey", "SUFeedURL", "ZshellReleaseFallbackAppcastURL"] {
            var invalid = info
            invalid.removeValue(forKey: key)
            expect(UpdateFeedConfiguration(infoDictionary: invalid) == nil, "reject missing \(key)")
            invalid[key] = key == "SUPublicEDKey" ? "invalid" : "http://example.com/appcast.xml"
            expect(UpdateFeedConfiguration(infoDictionary: invalid) == nil, "reject invalid \(key)")
        }
        expect(UpdateFeedConfiguration(infoDictionary: info, architecture: "unknown") == nil, "reject unknown architecture")
        expect(["arm64", "x86_64"].contains(UpdateFeedConfiguration.hostArchitecture), "supported host architecture")
        var state = UpdateFeedFallbackState()
        expect(!state.finishCheck(failed: false), "success does not retry")
        expect(state.finishCheck(failed: true), "feed load failure retries")
        expect(state.isUsingFallback, "retry selects fallback")
        expect(!state.finishCheck(failed: true), "fallback failure cannot retry twice")
        state.beginCheck()
        expect(!state.isUsingFallback, "next check starts on its primary mirror")
        state.didLoadAppcast()
        expect(!state.finishCheck(failed: true), "post-appcast non-download errors do not retry")
        state.downloadFailed()
        expect(state.finishCheck(failed: false), "download failure retries even if cycle error is nil")
        expect(!state.canRetryFallback, "download fallback is bounded")
        state.beginCheck()
        state.didLoadAppcast()
        expect(!state.finishCheck(failed: false), "no update found does not retry")

        for (country, region, expected) in [
            ("CN", "US", UpdateFeedPreference.giteeFirst),
            (" us\n", "CN", .githubFirst),
            (nil, "CN", .giteeFirst),
            (nil, "JP", .githubFirst),
            ("unknown", "GB", .githubFirst),
            ("<html>failure</html>", "CN", .giteeFirst),
            ("ZZ", "US", .githubFirst),
            (nil, nil, .giteeFirst),
        ] {
            expect(UpdateFeedPreference(countryCode: country, systemRegionCode: region) == expected,
                   "IP country wins and invalid results fall back to the system region")
        }

        var clock = Date()
        var lookups = 0
        var nextCountry: String? = "US"
        let resolver = UpdateFeedResolver(loadCountryCode: { lookups += 1; return nextCountry },
                                          systemRegionCode: { "CN" }, now: { clock })
        expect(lookups == 0, "constructing resolver does not query the network")
        var resolved: UpdateFeedPreference?
        await resolver.resolve(manual: false) { resolved = $0 }?.value
        expect(resolved == .githubFirst && lookups == 1, "resolves IP country asynchronously")
        clock += UpdateFeedResolver.cacheLifetime - 1
        expect(resolver.resolve(manual: true) { resolved = $0 } == nil && lookups == 1,
               "manual check shares unexpired background lookup")
        clock += 1
        nextCountry = nil
        expect(resolver.preference == nil, "country cache expires after thirty minutes")
        await resolver.resolve(manual: true) { resolved = $0 }?.value
        expect(resolved == .giteeFirst && lookups == 2, "expired lookup failure uses system region")
        clock += UpdateFeedResolver.cacheLifetime - 1
        expect(resolver.preference == .giteeFirst, "failed lookup is also cached to avoid repeated requests")

        let pendingLookup = PendingCountryLookup()
        let pendingResolver = UpdateFeedResolver(loadCountryCode: { await pendingLookup.load() }, systemRegionCode: { "CN" })
        var automaticCalls = 0
        var manualCalls = 0
        let automaticTask = pendingResolver.resolve(manual: false) { _ in automaticCalls += 1 }
        try await waitUntil { pendingLookup.continuations.count == 1 }
        let manualTask = pendingResolver.resolve(manual: true) { _ in manualCalls += 1 }
        pendingResolver.cancelAutomaticCheck()
        pendingLookup.continuations.removeFirst().resume(returning: "US")
        await automaticTask?.value
        await manualTask?.value
        expect(automaticCalls == 0 && manualCalls == 1, "disabling automatic checks preserves pending manual check")

        let canceledLookup = PendingCountryLookup()
        let canceledResolver = UpdateFeedResolver(loadCountryCode: { await canceledLookup.load() }, systemRegionCode: { "US" })
        let canceledTask = canceledResolver.resolve(manual: false) { _ in automaticCalls += 1 }
        try await waitUntil { canceledLookup.continuations.count == 1 }
        canceledResolver.cancelAutomaticCheck()
        expect(canceledResolver.preference == nil, "canceling background lookup leaves no cached country")
        let restartedTask = canceledResolver.resolve(manual: true) { resolved = $0 }
        try await waitUntil { canceledLookup.continuations.count == 2 }
        canceledLookup.continuations.removeLast().resume(returning: "US")
        await restartedTask?.value
        expect(resolved == .githubFirst, "manual lookup can restart before canceled request finishes")
        canceledLookup.continuations.removeFirst().resume(returning: "CN")
        await canceledTask?.value
        expect(automaticCalls == 0 && canceledResolver.preference == .githubFirst,
               "late canceled background result cannot replace newer manual country or resume a check")

        let configuration = UpdateFeedConfiguration(infoDictionary: info, architecture: "arm64", installedSliceCount: 1)!
        let failure = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        for country in ["CN", "US"] {
            var checkClock = Date()
            var checkCountry = country
            let checkResolver = UpdateFeedResolver(loadCountryCode: { checkCountry }, systemRegionCode: { "CN" }, now: { checkClock })
            await checkResolver.resolve(manual: true) { _ in }?.value
            let delegate = UpdateFeedDelegate(configuration: configuration, resolver: checkResolver)
            let driver = UpdateUserDriver { delegate.shouldSuppressUpdaterError }
            let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: delegate)
            updater.automaticallyChecksForUpdates = true
            var fallbackChecks: [SPUUpdateCheck] = []
            delegate.onCheckRequested = { fallbackChecks.append($0) }
            let preference = UpdateFeedPreference(countryCode: country, systemRegionCode: nil)
            for kind in [SPUUpdateCheck.updates, .updatesInBackground, .updateInformation] {
                expect(allowsCheck(delegate, updater, kind), "allows initial check")
                expect(delegate.feedURLString(for: updater) == configuration.url(preference: preference, isUsingFallback: false).absoluteString, "country selects primary mirror")
                var acknowledged = false
                driver.showUpdaterError(failure) { acknowledged = true }
                expect(acknowledged, "primary error acknowledged to allow fallback")
                delegate.updater(updater, didFinishUpdateCycleFor: kind, error: failure)
                expect(fallbackChecks.last == kind, "preserves check type")
                // Expiry and a changed exit country cannot reorder an already-started fallback.
                checkClock += UpdateFeedResolver.cacheLifetime
                checkCountry = country == "CN" ? "US" : "CN"
                await checkResolver.resolve(manual: true) { _ in }?.value
                expect(allowsCheck(delegate, updater, kind), "allows fallback check")
                expect(delegate.feedURLString(for: updater) == configuration.url(preference: preference, isUsingFallback: true).absoluteString, "fallback keeps original cycle order")
                expect(!delegate.shouldSuppressUpdaterError, "fallback error remains visible")
                let count = fallbackChecks.count
                delegate.updater(updater, didFinishUpdateCycleFor: kind, error: failure)
                expect(fallbackChecks.count == count, "does not loop after fallback failure")
                checkClock += UpdateFeedResolver.cacheLifetime
                checkCountry = country
                await checkResolver.resolve(manual: true) { _ in }?.value
            }
        }

        let supersededLookup = PendingCountryLookup()
        var supersededClock = Date()
        let supersededResolver = UpdateFeedResolver(loadCountryCode: { await supersededLookup.load() },
                                                   systemRegionCode: { "CN" }, now: { supersededClock })
        let initialLookup = supersededResolver.resolve(manual: false) { _ in }
        try await waitUntil { supersededLookup.continuations.count == 1 }
        supersededLookup.continuations.removeFirst().resume(returning: "US")
        await initialLookup?.value
        let supersededDelegate = UpdateFeedDelegate(configuration: configuration, resolver: supersededResolver)
        let supersededDriver = UpdateUserDriver { supersededDelegate.shouldSuppressUpdaterError }
        let supersededUpdater = SPUUpdater(hostBundle: .main, applicationBundle: .main,
                                          userDriver: supersededDriver, delegate: supersededDelegate)
        supersededUpdater.automaticallyChecksForUpdates = true
        var supersededChecks: [SPUUpdateCheck] = []
        supersededDelegate.onCheckRequested = { supersededChecks.append($0) }
        expect(allowsCheck(supersededDelegate, supersededUpdater, .updatesInBackground), "allows background check before manual request")
        supersededDelegate.updater(supersededUpdater, didFinishUpdateCycleFor: .updatesInBackground, error: failure)
        expect(supersededChecks == [.updatesInBackground], "background failure queues one fallback")
        supersededChecks.removeAll()
        supersededClock += UpdateFeedResolver.cacheLifetime
        expect(!allowsCheck(supersededDelegate, supersededUpdater, .updates), "new manual check waits for expired country lookup")
        supersededDelegate.updater(supersededUpdater, didFinishUpdateCycleFor: .updates, error: nil)
        try await waitUntil { supersededLookup.continuations.count == 1 }
        expect(!allowsCheck(supersededDelegate, supersededUpdater, .updatesInBackground),
               "superseded background fallback cannot bypass a pending manual country lookup")
        supersededDelegate.updater(supersededUpdater, didFinishUpdateCycleFor: .updatesInBackground, error: nil)
        supersededLookup.continuations.removeFirst().resume(returning: "US")
        try await waitUntil { supersededChecks.count == 1 }
        expect(supersededChecks == [.updates], "manual check supersedes the old background fallback")
        expect(allowsCheck(supersededDelegate, supersededUpdater, .updates), "superseding manual check can resume")
        supersededDelegate.updater(supersededUpdater, didFinishUpdateCycleFor: .updates, error: nil)
        supersededChecks.removeAll()
        expect(allowsCheck(supersededDelegate, supersededUpdater, .updatesInBackground), "allows next scheduled check")
        supersededDelegate.updater(supersededUpdater, didFinishUpdateCycleFor: .updatesInBackground, error: failure)
        expect(supersededChecks == [.updatesInBackground], "scheduled failure requests fallback before checks are disabled")
        supersededUpdater.automaticallyChecksForUpdates = false
        supersededDelegate.cancelAutomaticCheck()
        expect(supersededDelegate.feedURLString(for: supersededUpdater) == configuration.fallback.absoluteString,
               "disabling automatic checks clears the queued fallback mirror")
        expect(!allowsCheck(supersededDelegate, supersededUpdater, .updatesInBackground), "canceled background fallback cannot start")
        supersededDelegate.updater(supersededUpdater, didFinishUpdateCycleFor: .updatesInBackground, error: nil)
        expect(supersededChecks.count == 1, "canceled background fallback cannot schedule another check")
        supersededChecks.removeAll()
        expect(allowsCheck(supersededDelegate, supersededUpdater, .updates), "manual check still works with scheduled checks disabled")
        supersededDelegate.updater(supersededUpdater, didFinishUpdateCycleFor: .updates, error: failure)
        supersededDelegate.cancelAutomaticCheck()
        expect(supersededChecks == [.updates] && allowsCheck(supersededDelegate, supersededUpdater, .updates),
               "disabling scheduled checks preserves a requested manual fallback")
        expect(supersededDelegate.feedURLString(for: supersededUpdater) == configuration.primary.absoluteString,
               "manual fallback keeps the second mirror while automatic checks are disabled")
        supersededDelegate.updater(supersededUpdater, didFinishUpdateCycleFor: .updates, error: failure)
        expect(supersededChecks.count == 1, "manual fallback remains bounded when automatic checks are disabled")

        let deferredLookup = PendingCountryLookup()
        let deferredResolver = UpdateFeedResolver(loadCountryCode: { await deferredLookup.load() }, systemRegionCode: { "CN" })
        let deferredDelegate = UpdateFeedDelegate(configuration: configuration, resolver: deferredResolver)
        let deferredDriver = UpdateUserDriver { deferredDelegate.shouldSuppressUpdaterError }
        let deferredUpdater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: deferredDriver, delegate: deferredDelegate)
        deferredUpdater.automaticallyChecksForUpdates = false
        var requestedChecks: [SPUUpdateCheck] = []
        deferredDelegate.onCheckRequested = { requestedChecks.append($0) }
        expect(!allowsCheck(deferredDelegate, deferredUpdater, .updatesInBackground),
               "disabled scheduled checks are rejected before region lookup")
        deferredDelegate.updater(deferredUpdater, didFinishUpdateCycleFor: .updatesInBackground, error: nil)
        await Task.yield()
        expect(deferredLookup.continuations.isEmpty, "disabled automatic checking makes no country request")
        do {
            try deferredDelegate.updater(deferredUpdater, mayPerform: .updates)
            preconditionFailure("manual check must wait for region when automatic checks are off")
        } catch {
            let deferredError = error as NSError
            expect(deferredError.domain == SUSparkleErrorDomain
                   && deferredError.code == Int(SUError.installationCanceledError.rawValue),
                   "region deferral uses Sparkle's silent cancellation error")
            deferredDelegate.updater(deferredUpdater, didFinishUpdateCycleFor: .updates, error: deferredError)
        }
        try await waitUntil { deferredLookup.continuations.count == 1 }
        deferredLookup.continuations.removeFirst().resume(returning: "US")
        try await waitUntil { requestedChecks.count == 1 }
        expect(requestedChecks == [.updates], "region resolution resumes exactly one manual check")
        expect(allowsCheck(deferredDelegate, deferredUpdater, .updates), "resolved manual check proceeds")
        expect(deferredDelegate.feedURLString(for: deferredUpdater) == configuration.fallback.absoluteString, "resolved overseas check uses GitHub first")

        let integrationLookup = PendingCountryLookup()
        var integrationClock = Date()
        let integrationResolver = UpdateFeedResolver(loadCountryCode: { await integrationLookup.load() },
                                                    systemRegionCode: { "US" }, now: { integrationClock })
        let integrationDelegate = UpdateFeedDelegate(configuration: configuration, resolver: integrationResolver)
        for selector in ["updater:mayPerformUpdateCheck:error:", "feedURLStringForUpdater:",
                         "updater:didFinishLoadingAppcast:", "updater:failedToDownloadUpdate:error:",
                         "updater:didFinishUpdateCycleForUpdateCheck:error:"] {
            expect(integrationDelegate.responds(to: NSSelectorFromString(selector)),
                   "Swift delegate implements Sparkle's Objective-C callback \(selector)")
        }
        let integrationDriver = RecordingUserDriver(hostBundle: .main, delegate: nil)
        let integrationUpdater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: integrationDriver, delegate: integrationDelegate)
        integrationUpdater.automaticallyChecksForUpdates = false
        var integrationChecks: [SPUUpdateCheck] = []
        integrationDelegate.onCheckRequested = { integrationChecks.append($0) }
        try integrationUpdater.start()
        try await waitUntil { integrationUpdater.canCheckForUpdates && !integrationUpdater.sessionInProgress }
        integrationUpdater.checkForUpdates()
        try await waitUntil { integrationLookup.continuations.count == 1 }
        expect(integrationDriver.errors.isEmpty, "real Sparkle silently defers for region lookup")
        try await waitUntil { !integrationUpdater.sessionInProgress }
        integrationLookup.continuations.removeFirst().resume(returning: "US")
        try await waitUntil { integrationChecks.count == 1 }
        expect(integrationChecks == [.updates] && integrationUpdater.canCheckForUpdates,
               "real Sparkle completes deferral and requests exactly one resumable manual check")
        integrationClock += UpdateFeedResolver.cacheLifetime
        integrationChecks.removeAll()
        integrationUpdater.automaticallyChecksForUpdates = true
        integrationUpdater.checkForUpdatesInBackground()
        try await waitUntil { integrationLookup.continuations.count == 1 }
        try await waitUntil { !integrationUpdater.sessionInProgress }
        integrationLookup.continuations.removeFirst().resume(returning: "CN")
        try await waitUntil { integrationChecks.count == 1 }
        expect(integrationChecks == [.updatesInBackground] && integrationUpdater.canCheckForUpdates,
               "real Sparkle reschedules its timer and requests one background continuation")
        integrationClock += UpdateFeedResolver.cacheLifetime
        integrationChecks.removeAll()
        integrationUpdater.checkForUpdatesInBackground()
        try await waitUntil { integrationLookup.continuations.count == 1 }
        try await waitUntil { !integrationUpdater.sessionInProgress }
        integrationUpdater.checkForUpdates()
        try await waitUntil { !integrationUpdater.sessionInProgress }
        expect(integrationLookup.continuations.count == 1, "real manual and scheduled checks share one pending country request")
        integrationLookup.continuations.removeFirst().resume(returning: "US")
        try await waitUntil { integrationChecks.count == 1 }
        expect(integrationChecks == [.updates], "real manual request supersedes a deferred scheduled check")
        expect(integrationDriver.errors.isEmpty, "real manual and scheduled deferrals show no errors")
        integrationUpdater.automaticallyChecksForUpdates = false

        #if DEBUG
        let debugCountry = await UpdateFeedResolver.countryCodeForCurrentIP()
        expect(debugCountry == nil, "Debug country lookup is disabled")
        #endif
        print("Updater tests: \(passed) passed, 0 failed")
    }

    @MainActor static func waitUntil(_ condition: () -> Bool, line: UInt = #line) async throws {
        for _ in 0..<1200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        preconditionFailure("Timed out waiting for asynchronous updater behavior at line \(line)")
    }

    @MainActor static func allowsCheck(_ delegate: UpdateFeedDelegate, _ updater: SPUUpdater,
                                      _ check: SPUUpdateCheck) -> Bool {
        do {
            try delegate.updater(updater, mayPerform: check)
            return true
        } catch {
            return false
        }
    }
}

@MainActor
private final class PendingCountryLookup {
    var continuations: [CheckedContinuation<String?, Never>] = []

    func load() async -> String? {
        await withCheckedContinuation { continuations.append($0) }
    }
}

@MainActor
private final class RecordingUserDriver: SPUStandardUserDriver {
    var errors: [Error] = []

    override func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        errors.append(error)
        acknowledgement()
    }
}
