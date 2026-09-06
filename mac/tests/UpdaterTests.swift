import Foundation
import Sparkle

@main
struct UpdaterTests {
    @MainActor static func main() throws {
        var passed = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
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
        expect(!state.isUsingFallback, "next check starts on Gitee")
        state.didLoadAppcast()
        expect(!state.finishCheck(failed: true), "post-appcast non-download errors do not retry")
        state.downloadFailed()
        expect(state.finishCheck(failed: false), "download failure retries even if cycle error is nil")
        expect(!state.canRetryFallback, "download fallback is bounded")
        state.beginCheck()
        state.didLoadAppcast()
        expect(!state.finishCheck(failed: false), "no update found does not retry")

        let configuration = UpdateFeedConfiguration(infoDictionary: info, architecture: "arm64", installedSliceCount: 1)!
        let delegate = UpdateFeedDelegate(configuration: configuration)
        let driver = UpdateUserDriver { delegate.shouldSuppressUpdaterError }
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: delegate)
        let failure = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        var fallbackChecks: [SPUUpdateCheck] = []
        delegate.onFallbackRequested = { fallbackChecks.append($0) }
        for kind in [SPUUpdateCheck.updates, .updatesInBackground, .updateInformation] {
            expect(delegate.updater(updater, mayPerformUpdateCheck: kind, error: nil), "allows initial check")
            expect(delegate.feedURLString(for: updater) == configuration.primary.absoluteString, "initial check Gitee")
            var acknowledged = false
            driver.showUpdaterError(failure) { acknowledged = true }
            expect(acknowledged, "primary error acknowledged to allow fallback")
            delegate.updater(updater, didFinishUpdateCycleFor: kind, error: failure)
            expect(fallbackChecks.last == kind, "preserves check type")
            expect(delegate.updater(updater, mayPerformUpdateCheck: kind, error: nil), "allows fallback check")
            expect(delegate.feedURLString(for: updater) == configuration.fallback.absoluteString, "retry GitHub")
            expect(!delegate.shouldSuppressUpdaterError, "GitHub error remains visible")
            let count = fallbackChecks.count
            delegate.updater(updater, didFinishUpdateCycleFor: kind, error: failure)
            expect(fallbackChecks.count == count, "does not loop after GitHub failure")
            expect(delegate.feedURLString(for: updater) == configuration.primary.absoluteString, "resets Gitee next cycle")
        }
        print("Updater tests: \(passed) passed, 0 failed")
    }
}
