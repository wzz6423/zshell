//
//  Updater.swift
//  zshell
//

import Combine
import Foundation
import AppKit
import Sparkle
import SwiftUI

struct UpdateFeedConfiguration {
    let primary: URL
    let fallback: URL

    init?(
        infoDictionary: [String: Any],
        architecture: String = Self.hostArchitecture,
        installedSliceCount: Int = Bundle.main.executableArchitectures?.count ?? 1
    ) {
        guard let publicKey = infoDictionary["SUPublicEDKey"] as? String,
              Data(base64Encoded: publicKey)?.count == 32,
              let primary = Self.feedURL(infoDictionary["SUFeedURL"]),
              let fallback = Self.feedURL(infoDictionary["ZshellReleaseFallbackAppcastURL"]),
              ["arm64", "x86_64"].contains(architecture) else { return nil }

        // Universal installs retain their portability; only thin installs follow a slice feed.
        self.primary = installedSliceCount == 1
            ? primary.deletingLastPathComponent().appendingPathComponent("appcast-\(architecture).xml")
            : primary
        self.fallback = installedSliceCount == 1
            ? fallback.deletingLastPathComponent().appendingPathComponent("appcast-\(architecture).xml")
            : fallback
    }

    private static func feedURL(_ value: Any?) -> URL? {
        guard let value = value as? String,
              let url = URL(string: value),
              url.scheme == "https", url.host != nil else { return nil }
        return url
    }

    static var hostArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        // A thin Intel install running under Rosetta should migrate to native Apple silicon.
        var translated: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let isTranslated = sysctlbyname("sysctl.proc_translated", &translated, &size, nil, 0) == 0
            && translated == 1
        return isTranslated ? "arm64" : "x86_64"
        #endif
    }
}

struct UpdateFeedFallbackState {
    private(set) var isUsingFallback = false
    private var hasLoadedAppcast = false
    private var didFailDownloadingUpdate = false

    var canRetryFallback: Bool {
        !isUsingFallback && (!hasLoadedAppcast || didFailDownloadingUpdate)
    }

    mutating func beginCheck() { self = Self() }
    mutating func didLoadAppcast() { hasLoadedAppcast = true }
    mutating func downloadFailed() { didFailDownloadingUpdate = true }

    mutating func finishCheck(failed: Bool) -> Bool {
        guard (failed || didFailDownloadingUpdate), canRetryFallback else { return false }
        isUsingFallback = true
        hasLoadedAppcast = false
        didFailDownloadingUpdate = false
        return true
    }
}

@MainActor
final class UpdateFeedDelegate: NSObject, SPUUpdaterDelegate {
    var onFallbackRequested: ((SPUUpdateCheck) -> Void)?
    private let configuration: UpdateFeedConfiguration
    private var state = UpdateFeedFallbackState()
    private var fallbackRetryCheck: SPUUpdateCheck?

    var shouldSuppressUpdaterError: Bool { state.canRetryFallback }

    init(configuration: UpdateFeedConfiguration) {
        self.configuration = configuration
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        (state.isUsingFallback ? configuration.fallback : configuration.primary).absoluteString
    }

    func updater(_ updater: SPUUpdater, mayPerformUpdateCheck updateCheck: SPUUpdateCheck,
                 error: NSErrorPointer) -> Bool {
        if fallbackRetryCheck == updateCheck {
            fallbackRetryCheck = nil
        } else {
            state.beginCheck()
        }
        return true
    }

    func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        state.didLoadAppcast()
    }

    func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: Error) {
        state.downloadFailed()
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
                 error: Error?) {
        if state.finishCheck(failed: error != nil) {
            fallbackRetryCheck = updateCheck
            onFallbackRequested?(updateCheck)
        } else {
            state.beginCheck()
            fallbackRetryCheck = nil
        }
    }
}

@MainActor
final class UpdateUserDriver: SPUStandardUserDriver {
    private let shouldSuppressUpdaterError: () -> Bool

    init(shouldSuppressUpdaterError: @escaping () -> Bool) {
        self.shouldSuppressUpdaterError = shouldSuppressUpdaterError
        super.init(hostBundle: .main, delegate: nil)
    }

    override func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        if shouldSuppressUpdaterError() {
            acknowledgement()
        } else {
            super.showUpdaterError(error, acknowledgement: acknowledgement)
        }
    }
}

/// A single Sparkle instance owns updates for both direct and Homebrew installations.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    private let updater: SPUUpdater
    private let feedDelegate: UpdateFeedDelegate
    private let userDriver: UpdateUserDriver

    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var isUpdating = false

    var updateActionTitle: String { String(localized: "Check for Updates…") }

    @Published var automaticallyChecksForUpdates: Bool {
        didSet { updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates }
    }

    private init() {
        guard let configuration = UpdateFeedConfiguration(infoDictionary: Bundle.main.infoDictionary ?? [:]) else {
            preconditionFailure("Missing or invalid Sparkle update configuration")
        }
        let delegate = UpdateFeedDelegate(configuration: configuration)
        feedDelegate = delegate
        let driver = UpdateUserDriver { [weak delegate] in
            delegate?.shouldSuppressUpdaterError == true
        }
        userDriver = driver
        updater = SPUUpdater(hostBundle: .main, applicationBundle: .main,
                             userDriver: driver, delegate: delegate)
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
        updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
        updater.publisher(for: \.sessionInProgress).assign(to: &$isUpdating)

        delegate.onFallbackRequested = { [weak self] check in
            // Sparkle must finish its current cycle before another check may start.
            DispatchQueue.main.async { [weak self] in self?.retryCheck(check) }
        }

        // Debug must not schedule network checks or display update prompts.
        #if !DEBUG
        do {
            try updater.start()
            if automaticallyChecksForUpdates {
                updater.checkForUpdatesInBackground()
            }
        } catch {
            NSLog("Unable to start Sparkle: %@", error.localizedDescription)
        }
        #endif
    }

    func checkForUpdates() { updater.checkForUpdates() }

    private func retryCheck(_ check: SPUUpdateCheck) {
        switch check {
        case .updates: updater.checkForUpdates()
        case .updatesInBackground: updater.checkForUpdatesInBackground()
        case .updateInformation: updater.checkForUpdateInformation()
        @unknown default: updater.checkForUpdatesInBackground()
        }
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
