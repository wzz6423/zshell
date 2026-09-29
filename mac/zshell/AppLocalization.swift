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
    case traditionalChinese = "zh-Hant"
    case japanese = "ja"
    case korean = "ko"
    case french = "fr"
    case german = "de"
    case spanish = "es"
    case brazilianPortuguese = "pt-BR"
    case italian = "it"
    case dutch = "nl"
    case russian = "ru"
    case arabic = "ar"
    case thai = "th"
    case indonesian = "id"
    case vietnamese = "vi"
    case turkish = "tr"

    static let localizationIdentifiers = allCases.filter { $0 != .system }.map(\.rawValue)

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
        case .traditionalChinese:
            "繁體中文"
        case .japanese:
            "日本語"
        case .korean:
            "한국어"
        case .french:
            "Français"
        case .german:
            "Deutsch"
        case .spanish:
            "Español"
        case .brazilianPortuguese:
            "Português (Brasil)"
        case .italian:
            "Italiano"
        case .dutch:
            "Nederlands"
        case .russian:
            "Русский"
        case .arabic:
            "العربية"
        case .thai:
            "ไทย"
        case .indonesian:
            "Bahasa Indonesia"
        case .vietnamese:
            "Tiếng Việt"
        case .turkish:
            "Türkçe"
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

    fileprivate static func from(identifier: String) -> AppLanguage? {
        let components = identifier.replacingOccurrences(of: "_", with: "-")
            .lowercased().split(separator: "-")
        guard let code = components.first else { return nil }
        if code == "zh" {
            // An explicit script takes precedence over the region.
            if components.contains("hant") { return .traditionalChinese }
            if components.contains("hans") { return .simplifiedChinese }
            return components.contains(where: { ["tw", "hk", "mo"].contains($0) })
                ? .traditionalChinese : .simplifiedChinese
        }
        if code == "pt" { return .brazilianPortuguese }
        return allCases.first { $0 != .system && $0.rawValue == code }
    }

    func persist() {
        switch self {
        case .system:
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        default:
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
        // Match supported regional variants before Foundation can fall through
        // from pt-PT to a later preference instead of our pt-BR translation.
        let supportedPreferences = preferences.map {
            AppLanguage.from(identifier: $0)?.rawValue ?? $0
        }
        let identifier = Bundle.preferredLocalizations(
            from: AppLanguage.localizationIdentifiers, forPreferences: supportedPreferences
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
