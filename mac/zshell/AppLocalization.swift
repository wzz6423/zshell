import Foundation
import Synchronization

/// The app-specific language, applied immediately and saved for future launches.
///
/// `AppleLanguages` is stored in Zshell's own defaults domain, matching the
/// per-app language preference managed by System Settings. Removing it returns
/// control to the user's system language order.
nonisolated enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"
    case japanese = "ja"

    var id: String { rawValue }

    /// Language names are autonyms so the picker stays usable even when the
    /// current app language is unfamiliar to the user.
    var title: String {
        switch self {
        case .system:
            String(
                localized: "System Default",
                comment: "Language choice that follows the macOS setting."
            )
        case .english:
            "English"
        case .simplifiedChinese:
            "简体中文"
        case .japanese:
            "日本語"
        }
    }

    static var saved: AppLanguage {
        guard
            let bundleIdentifier = Bundle.main.bundleIdentifier,
            let domain = UserDefaults.standard.persistentDomain(
                forName: bundleIdentifier
            ),
            let identifiers = domain["AppleLanguages"] as? [String],
            let identifier = identifiers.first
        else {
            return .system
        }

        return from(identifier: identifier) ?? .system
    }

    private static func from(identifier: String) -> AppLanguage? {
        let normalized = identifier.replacingOccurrences(of: "_", with: "-")
        if normalized == "zh-Hans"
            || normalized.hasPrefix("zh-Hans-")
            || normalized.hasPrefix("zh-CN")
            || normalized.hasPrefix("zh-SG") {
            return .simplifiedChinese
        }
        if normalized == "ja" || normalized.hasPrefix("ja-") {
            return .japanese
        }
        if normalized == "en" || normalized.hasPrefix("en-") {
            return .english
        }
        return nil
    }

    func persist() {
        switch self {
        case .system:
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        case .english, .simplifiedChinese, .japanese:
            UserDefaults.standard.set([rawValue], forKey: "AppleLanguages")
        }
    }
}

/// Foundation caches the main bundle's language for the process lifetime.
/// Resolve an explicit resource bundle instead, including when returning to
/// the global language order after an app-specific override.
nonisolated enum AppLocalization {
    static let didChange = Notification.Name("zshell.languageDidChange")

    struct Selection {
        let identifier: String
        let bundle: Bundle
        let locale: Locale
    }

    private static let selection = Mutex(resolve(AppLanguage.saved))

    static var current: Selection { selection.withLock { $0 } }

    static func resolve(_ language: AppLanguage, systemLanguages: [String]? = nil,
                        bundle: Bundle = .main) -> Selection {
        let preferences = language == .system
            ? (systemLanguages ?? UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"] as? [String] ?? ["en"])
            : [language.rawValue]
        let identifier = Bundle.preferredLocalizations(
            from: ["en", "zh-Hans", "ja"], forPreferences: preferences
        ).first ?? "en"
        let resourceBundle = bundle.url(forResource: identifier, withExtension: "lproj")
            .flatMap(Bundle.init(url:)) ?? bundle
        return Selection(identifier: identifier, bundle: resourceBundle, locale: Locale(identifier: identifier))
    }

    @MainActor
    static func apply(_ language: AppLanguage) {
        let next = resolve(language)
        selection.withLock { $0 = next }
        // Let popup tracking and @Published's willSet finish before refreshing
        // controls, including the language picker that initiated the change.
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }
}

extension String {
    /// Keep the compiler's String Catalog extraction and interpolation while
    /// making app-owned strings follow the live language selection.
    nonisolated init(localized key: String.LocalizationValue, comment: StaticString? = nil) {
        let selection = AppLocalization.current
        self.init(localized: key, bundle: selection.bundle, locale: selection.locale, comment: comment)
    }
}
