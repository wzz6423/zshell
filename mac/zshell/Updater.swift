//
//  Updater.swift
//  zshell
//

import Combine
import Foundation
import AppKit
import Sparkle
import SwiftUI

enum UpdateFeedPreference {
    case giteeFirst
    case githubFirst

    init(countryCode: String?, systemRegionCode: String?) {
        let region = Self.normalizedCountryCode(countryCode) ?? Self.normalizedCountryCode(systemRegionCode)
        self = region == nil || region == "CN" ? .giteeFirst : .githubFirst
    }

    static func normalizedCountryCode(_ value: String?) -> String? {
        guard let code = value?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
              code.count == 2, Locale.Region.isoRegions.contains(where: { $0.identifier == code }) else { return nil }
        return code
    }
}

@MainActor
final class UpdateFeedResolver {
    static let cacheLifetime: TimeInterval = 30 * 60
    static let requestTimeout: TimeInterval = 5

    private let loadCountryCode: () async -> String?
    private let systemRegionCode: () -> String?
    private let now: () -> Date
    private var cachedPreference: (value: UpdateFeedPreference, expires: Date)?
    private var task: Task<Void, Never>?
    private var automaticCheck: ((UpdateFeedPreference) -> Void)?
    private var manualCheck: ((UpdateFeedPreference) -> Void)?

    var preference: UpdateFeedPreference? {
        guard let cachedPreference, now() < cachedPreference.expires else { return nil }
        return cachedPreference.value
    }

    init(
        loadCountryCode: @escaping () async -> String? = { await countryCodeForCurrentIP() },
        systemRegionCode: @escaping () -> String? = { Locale.current.region?.identifier },
        now: @escaping () -> Date = Date.init
    ) {
        self.loadCountryCode = loadCountryCode
        self.systemRegionCode = systemRegionCode
        self.now = now
    }

    @discardableResult
    func resolve(manual: Bool, apply: @escaping (UpdateFeedPreference) -> Void) -> Task<Void, Never>? {
        if let preference {
            apply(preference)
            return nil
        }
        if manual {
            manualCheck = apply
        } else {
            automaticCheck = apply
        }
        if let task { return task }

        let task = Task { [weak self, loadCountryCode] in
            let countryCode = await loadCountryCode()
            guard !Task.isCancelled, let self else { return }
            let preference = UpdateFeedPreference(countryCode: countryCode, systemRegionCode: self.systemRegionCode())
            self.cachedPreference = (preference, self.now().addingTimeInterval(Self.cacheLifetime))
            self.task = nil
            // A user request supersedes a scheduled check sharing the same lookup.
            let check = self.manualCheck ?? self.automaticCheck
            self.manualCheck = nil
            self.automaticCheck = nil
            check?(preference)
        }
        self.task = task
        return task
    }

    func cancelAutomaticCheck() {
        automaticCheck = nil
        if manualCheck == nil {
            task?.cancel()
            task = nil
        }
    }

    static func countryCodeForCurrentIP() async -> String? {
        #if DEBUG
        return nil
        #else
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "https://ipinfo.io/country")!)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = requestTimeout
        do {
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return UpdateFeedPreference.normalizedCountryCode(String(data: data, encoding: .utf8))
        } catch {
            return nil
        }
        #endif
    }
}

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

    func url(preference: UpdateFeedPreference, isUsingFallback: Bool) -> URL {
        let useGitee = (preference == .giteeFirst) != isUsingFallback
        return useGitee ? primary : fallback
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
    var onCheckRequested: ((SPUUpdateCheck) -> Void)?
    private let configuration: UpdateFeedConfiguration
    private let resolver: UpdateFeedResolver
    private var checkPreference = UpdateFeedPreference(countryCode: nil, systemRegionCode: Locale.current.region?.identifier)
    private var state = UpdateFeedFallbackState()
    private var fallbackRetryCheck: SPUUpdateCheck?
    private var isDeferringCheck = false
    private var deferredCheck: SPUUpdateCheck?

    var shouldSuppressUpdaterError: Bool { state.canRetryFallback }

    init(configuration: UpdateFeedConfiguration, resolver: UpdateFeedResolver? = nil) {
        self.configuration = configuration
        self.resolver = resolver ?? UpdateFeedResolver()
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        configuration.url(preference: checkPreference, isUsingFallback: state.isUsingFallback).absoluteString
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard updateCheck == .updates || updater.automaticallyChecksForUpdates else {
            isDeferringCheck = true
            deferredCheck = nil
            throw NSError(domain: SUSparkleErrorDomain, code: Int(SUError.installationCanceledError.rawValue))
        }
        if fallbackRetryCheck == updateCheck {
            fallbackRetryCheck = nil
        } else {
            fallbackRetryCheck = nil
            state.beginCheck()
            guard let preference = resolver.preference else {
                isDeferringCheck = true
                deferredCheck = updateCheck
                throw NSError(domain: SUSparkleErrorDomain, code: Int(SUError.installationCanceledError.rawValue))
            }
            checkPreference = preference
        }
    }

    func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        state.didLoadAppcast()
    }

    func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: Error) {
        state.downloadFailed()
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
                 error: Error?) {
        if isDeferringCheck {
            isDeferringCheck = false
            let check = deferredCheck
            deferredCheck = nil
            guard let check, check == .updates || updater.automaticallyChecksForUpdates else { return }
            // Sparkle treats cancellation as a silent deferral, without an error dialog.
            resolver.resolve(manual: check == .updates) { [weak self, weak updater] _ in
                guard let updater, check == .updates || updater.automaticallyChecksForUpdates else { return }
                self?.onCheckRequested?(check)
            }
            return
        }
        guard updateCheck == .updates || updater.automaticallyChecksForUpdates else {
            state.beginCheck()
            fallbackRetryCheck = nil
            return
        }
        if state.finishCheck(failed: error != nil) {
            fallbackRetryCheck = updateCheck
            onCheckRequested?(updateCheck)
        } else {
            state.beginCheck()
            fallbackRetryCheck = nil
        }
    }

    func cancelAutomaticCheck() {
        resolver.cancelAutomaticCheck()
        if let fallbackRetryCheck, fallbackRetryCheck != .updates {
            self.fallbackRetryCheck = nil
            state.beginCheck()
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
    private var pendingCheck: SPUUpdateCheck?
    private var sessionObservation: AnyCancellable?
    private var preferenceObservations: Set<AnyCancellable> = []

    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var isUpdating = false
    @Published private(set) var allowsAutomaticUpdates = false

    var updateActionTitle: String { String(localized: "Check for Updates…") }

    @Published var automaticallyChecksForUpdates: Bool {
        didSet {
            if updater.automaticallyChecksForUpdates != automaticallyChecksForUpdates {
                updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
            }
            if !automaticallyChecksForUpdates {
                feedDelegate.cancelAutomaticCheck()
                if pendingCheck != .updates { pendingCheck = nil }
            }
        }
    }

    @Published var automaticallyDownloadsUpdates: Bool {
        didSet {
            // Sparkle reports false while checks are disabled without clearing the user's opt-in.
            if updater.automaticallyDownloadsUpdates != automaticallyDownloadsUpdates {
                updater.automaticallyDownloadsUpdates = automaticallyDownloadsUpdates
                automaticallyDownloadsUpdates = updater.automaticallyDownloadsUpdates
            }
        }
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
        automaticallyDownloadsUpdates = updater.automaticallyDownloadsUpdates
        updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
        updater.publisher(for: \.sessionInProgress).assign(to: &$isUpdating)
        updater.publisher(for: \.allowsAutomaticUpdates).assign(to: &$allowsAutomaticUpdates)
        updater.publisher(for: \.automaticallyChecksForUpdates)
            .sink { [weak self] value in
                guard let self, self.automaticallyChecksForUpdates != value else { return }
                self.automaticallyChecksForUpdates = value
            }
            .store(in: &preferenceObservations)
        updater.publisher(for: \.automaticallyDownloadsUpdates)
            .sink { [weak self] value in
                guard let self, self.automaticallyDownloadsUpdates != value else { return }
                self.automaticallyDownloadsUpdates = value
            }
            .store(in: &preferenceObservations)

        delegate.onCheckRequested = { [weak self] check in
            guard let self else { return }
            if self.pendingCheck != .updates { self.pendingCheck = check }
            self.schedulePendingCheck()
        }
        sessionObservation = updater.publisher(for: \.sessionInProgress).sink { [weak self] in
            if !$0 { self?.schedulePendingCheck() }
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

    func checkForUpdates() {
        #if !DEBUG
        pendingCheck = .updates
        schedulePendingCheck()
        #endif
    }

    private func schedulePendingCheck() {
        // Sparkle also opens a short session while rescheduling its timer after a cycle.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.updater.sessionInProgress, self.updater.canCheckForUpdates,
                  let check = self.pendingCheck else { return }
            self.pendingCheck = nil
            guard check == .updates || self.automaticallyChecksForUpdates else { return }
            self.retryCheck(check)
        }
    }

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
