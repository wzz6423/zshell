//
//  AppSettings.swift
//  zshell
//

import AppKit
import Combine
import Foundation

/// The app-specific language macOS should use when Zshell next launches.
///
/// `AppleLanguages` is stored in Zshell's own defaults domain, matching the
/// per-app language preference managed by System Settings. Removing it returns
/// control to the user's system language order.
enum AppLanguage: String, CaseIterable, Identifiable {
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

/// Whether the toolbar follows project context, always shows, or stays hidden.
enum ToolbarVisibility: String, CaseIterable, Identifiable {
    case auto
    case always
    case hide

    var id: String { rawValue }
}

/// The icon shown for the running app in the Dock and app switcher.
enum ApplicationIcon: String, CaseIterable, Identifiable {
    case defaultIcon = "default"
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .defaultIcon:
            String(localized: "Default", comment: "Use the app's bundled icon.")
        case .light:
            String(localized: "Light", comment: "Light application icon.")
        case .dark:
            String(localized: "Dark", comment: "Dark application icon.")
        }
    }

    /// Name of the bundled `.icns` resource for this choice. `nil` restores
    /// the icon compiled for this build configuration.
    var resourceName: String? {
        switch self {
        case .defaultIcon: nil
        case .light: "AppIconLight"
        case .dark: "AppIconDark"
        }
    }

    /// Loads an icon resource whether Xcode copied it at the bundle root or
    /// preserved the source `Icons` directory in the resource bundle.
    func bundledImage() -> NSImage? {
        guard let resourceName else { return nil }
        guard let image = Self.image(named: resourceName) else { return nil }
        if let compiledIconSize = Self.compiledIconSize {
            // Runtime overrides use an NSImage's point size to size the Dock tile.
            image.size = compiledIconSize
        }
        return image
    }

    private static var compiledIconSize: NSSize? {
        #if DEBUG
        image(named: "AppIconDebug")?.size
        #else
        image(named: "AppIcon")?.size
        #endif
    }

    private static func image(named resourceName: String) -> NSImage? {
        let urls = [
            Bundle.main.url(forResource: resourceName, withExtension: "icns"),
            Bundle.main.url(
                forResource: resourceName,
                withExtension: "icns",
                subdirectory: "Icons"
            ),
        ]
        return urls.compactMap { $0 }.compactMap(NSImage.init(contentsOf:)).first
    }
}

/// User-configurable settings, persisted to `$HOME/.config/zshell/config.toml`.
/// Views observe this directly; `TerminalManager` re-themes live sessions on
/// any change.
@MainActor
final class AppSettings: nonisolated ObservableObject {
    static let shared = AppSettings()

    /// Development (Debug) builds store their config under `~/.config/zshell-dev`
    /// instead of `~/.config/zshell`, so running a dev build alongside an
    /// installed production build doesn't clobber its settings. This mirrors
    /// the separate `sh.zshell.dev` bundle identifier that keeps the two apps'
    /// `UserDefaults` (session snapshot, sidebar widths, Sparkle) apart.
    static let configURL: URL = {
        #if DEBUG
        let directory = "zshell-dev"
        #else
        let directory = "zshell"
        #endif
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/\(directory)/config.toml")
    }()

    static let defaultFontSize: Double = 13
    static let fontSizeRange: ClosedRange<Double> = 8...32
    static let defaultFontThickenStrength = 255
    static let fontThickenStrengthRange: ClosedRange<Double> = 0...255
    static let defaultTerminalLineHeight: Double = 1
    static let terminalLineHeightRange: ClosedRange<Double> = 0.75...2
    static let defaultSidebarFontSize: Double = 14
    static let sidebarFontSizeRange: ClosedRange<Double> = 9...24
    static let defaultInterfaceScale: Double = 1
    static let interfaceScaleRange: ClosedRange<Double> = 0.9...1.5
    static let defaultToolbarVisibility: ToolbarVisibility = .hide
    static let defaultTerminalBackgroundOpacity: Double = 1
    static let terminalBackgroundOpacityRange: ClosedRange<Double> = 0.2...1
    static let defaultTerminalBackgroundBlur = false
    static let defaultQuickTerminalSize: Double = 0.75
    static let quickTerminalSizeRange: ClosedRange<Double> = 0.35...0.95
    static let defaultQuickTerminalOpacity: Double = 0.5
    static let quickTerminalOpacityRange: ClosedRange<Double> = 0.05...1
    static let defaultQuickTerminalShortcut = QuickTerminalShortcut.defaultValue
    static let defaultPaneFocusRingOpacity: Double = 0.85
    static let paneFocusRingOpacityRange: ClosedRange<Double> = 0.05...1

    /// The minimum runtimes, in seconds, that Settings offers for
    /// `terminal.notify-finish-seconds`. A hand-edited config value outside
    /// this set reads as off — the alternative is a popup displaying a number
    /// the pane's shell integration would not have been built with.
    static let notifyFinishSecondChoices = [0, 5, 10, 30, 60]

    /// The language this process launched with, kept separate from the pending
    /// selection so Settings can explain when a relaunch is required.
    let activeLanguage: AppLanguage

    @Published var language: AppLanguage {
        didSet { language.persist() }
    }

    var languageRequiresRelaunch: Bool {
        language != activeLanguage
    }

    /// Icon shown for the running app; `defaultIcon` restores the icon compiled
    /// for this build configuration.
    @Published var applicationIcon: ApplicationIcon {
        didSet {
            applyApplicationIcon()
            save()
        }
    }

    /// Light/dark appearance override; `system` follows macOS.
    @Published var theme: AppTheme {
        didSet {
            applyAppearance()
            save()
        }
    }

    /// Color theme names, one per appearance. `Theme` keeps the resolved
    /// definitions (Zshell built-ins plus the Ghostty catalog).
    @Published var themeDark: String {
        didSet {
            reloadThemeSelection()
            save()
        }
    }

    @Published var themeLight: String {
        didSet {
            reloadThemeSelection()
            save()
        }
    }

    /// Keep the selected palettes on terminal surfaces while the rest of the
    /// app uses Zshell's built-in light and dark palettes.
    @Published var terminalThemeOnly: Bool {
        didSet {
            reloadThemeSelection()
            save()
        }
    }

    /// Terminal font family name; empty string means the bundled default
    /// (JetBrains Mono).
    @Published var fontFamily: String {
        didSet { save() }
    }

    /// Ordered CJK fallback family for terminal glyphs the primary face lacks.
    /// Empty string leaves fallback selection to each backend and macOS.
    @Published var fontFallbackFamily: String {
        didSet { save() }
    }

    @Published var fontSize: Double {
        didSet { save() }
    }

    /// Base text size for both sidebars. Each panel preserves its relative
    /// hierarchy for section labels, content, metadata, and controls.
    @Published var sidebarFontSize: Double {
        didSet { save() }
    }

    /// Scale applied to application chrome while terminal and editor content
    /// keep their separately configured font size.
    @Published var interfaceScale: Double {
        didSet { save() }
    }

    /// `auto` shows the toolbar only for Git projects; `always` keeps its Git
    /// panel entry point visible in every project; `hide` suppresses it.
    @Published var toolbarVisibility: ToolbarVisibility {
        didSet { save() }
    }

    /// Render terminal glyphs with slightly heavier strokes, like classic
    /// macOS font smoothing. Each backend maps this to its own rasterizer.
    /// Persisted as `terminal.font-thicken`; off by default so Zshell's text
    /// matches a stock Ghostty install.
    @Published var fontThicken: Bool {
        didSet { save() }
    }

    /// Backend-specific thickening intensity normalized to Ghostty's 0...255
    /// range. It is ignored while `fontThicken` is off.
    @Published var fontThickenStrength: Int {
        didSet { save() }
    }

    /// Terminal cell height multiplier. One uses each font's native metrics.
    @Published var terminalLineHeight: Double {
        didSet { save() }
    }

    @Published var cursorShape: TerminalCursorShape {
        didSet { save() }
    }

    @Published var cursorBlinking: Bool {
        didSet { save() }
    }

    /// Send Option-key chords to terminal programs as Alt/Meta instead of
    /// letting the active macOS input source produce text. Off by default so
    /// layouts such as Polish Pro can type their Option-composed characters.
    @Published var macosOptionAsAlt: Bool {
        didSet { save() }
    }

    /// Whether a terminal bell may make sound or request visual attention.
    /// Accessibility announcements remain semantic output, not an alert style.
    @Published var terminalBell: Bool {
        didSet { save() }
    }

    /// Send Shift-Return as LF so coding agents can insert a line without
    /// changing plain Return's submit behavior.
    @Published var shiftEnterNewline: Bool {
        didSet { save() }
    }

    /// Soft-wrap file editor lines to the viewport width. Off by default so
    /// long lines scroll horizontally.
    @Published var wrapLines: Bool {
        didSet { save() }
    }

    @Published var externalEditor: ExternalEditor {
        didSet { save() }
    }

    /// Restore each terminal's previous scrollback (as static, styled text)
    /// when the app relaunches, above the freshly started shell. Off by
    /// default: opt-in, and it writes captured output to disk.
    @Published var restoreTerminalHistory: Bool {
        didSet { save() }
    }

    /// Copy terminal text to the clipboard after a pointer selection ends.
    /// Enabled by default to preserve Zshell's existing selection behavior.
    @Published var copyOnSelect: Bool {
        didSet { save() }
    }

    /// Alpha of each main workspace window. The terminal's default background
    /// is clear only while the shared behind-window material is active.
    @Published var terminalBackgroundOpacity: Double {
        didSet { save() }
    }

    @Published var terminalBackgroundBlur: Bool {
        didSet { save() }
    }

    var effectiveTerminalBackgroundOpacity: Double {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            ? Self.defaultTerminalBackgroundOpacity
            : terminalBackgroundOpacity
    }

    var isTerminalBackgroundTranslucent: Bool {
        effectiveTerminalBackgroundOpacity < Self.defaultTerminalBackgroundOpacity
    }

    var isTerminalBackgroundBlurActive: Bool {
        isTerminalBackgroundTranslucent && terminalBackgroundBlur
    }

    /// Minimum runtime, in seconds, a command must reach before its pane's zsh
    /// shell integration asks Zshell to post a completion notification. Zero
    /// disables it. Persisted as `terminal.notify-finish-seconds`; the shell
    /// integration shim is written when a pane is created, so changes reach
    /// terminals opened afterwards.
    @Published var notifyFinishSeconds: Int {
        didSet { save() }
    }

    /// Notify when a command exits with a failure, regardless of runtime.
    /// Persisted as `terminal.notify-on-error`; off by default so a stream of
    /// expected failures cannot surprise the user with banners. Shares the
    /// shim plumbing and the new-terminals-only caveat with
    /// ``notifyFinishSeconds``.
    @Published var notifyOnError: Bool {
        didSet { save() }
    }


    /// Initial area and translucency for the global quick terminal. Per-use
    /// adjustments stay with the overlay rather than changing these defaults.
    @Published var quickTerminalSize: Double {
        didSet { save() }
    }

    @Published var quickTerminalOpacity: Double {
        didSet { save() }
    }

    @Published var quickTerminalShortcut: QuickTerminalShortcut {
        didSet { save() }
    }

    /// Remapped menu shortcuts for the core commands in ``AppCommand``. Only
    /// bindings that differ from the command's default are stored, so the
    /// dictionary doubles as the "not at defaults" signal; menus read the
    /// effective binding through ``commandShortcut(for:)``.
    @Published var commandShortcuts: [AppCommand: CommandShortcut] {
        didSet { save() }
    }

    /// Keep the active pane visible in split and zoomed layouts without changing
    /// any terminal surface's own focus or rendering behavior.
    @Published var showPaneFocusRing: Bool {
        didSet { save() }
    }

    @Published var paneFocusRingOpacity: Double {
        didSet { save() }
    }

    /// Link Zshell's shared coordination skill plus the native lifecycle
    /// integrations whose provider APIs provide semantic turn events. Other
    /// agents retain process recognition without inferred progress state.
    @Published private(set) var aiEnabled: Bool {
        didSet { save() }
    }

    /// Which emulator drives terminal panes. Only ever holds a backend this
    /// build ships a surface for — see `TerminalBackend` — and a session binds
    /// its backend at creation, so a change here reaches terminals opened
    /// afterwards rather than live ones.
    @Published var terminalBackend: TerminalBackend {
        didSet { save() }
    }

    /// Full executable path and argument text used by terminals opened after a
    /// settings change. An empty program keeps the account login shell.
    @Published var terminalStartupProgram: String {
        didSet { save() }
    }

    @Published var terminalStartupArguments: String {
        didSet { save() }
    }

    private init() {
        let savedLanguage = AppLanguage.saved
        activeLanguage = savedLanguage
        language = savedLanguage

        let existing = TOML.parse(at: Self.configURL)
        let toml = existing ?? Self.legacyDefaults()
        applicationIcon = ApplicationIcon(
            rawValue: toml["app-icon"]?.string ?? ""
        ) ?? .defaultIcon
        theme = toml["theme"]?.string.flatMap(AppTheme.init(rawValue:)) ?? .system
        themeDark = Self.knownTheme(
            toml["theme-dark"]?.string,
            dark: true,
            fallback: Theme.defaultDarkThemeName
        )
        themeLight = Self.knownTheme(
            toml["theme-light"]?.string,
            dark: false,
            fallback: Theme.defaultLightThemeName
        )
        terminalThemeOnly = toml["terminal.theme-only"]?.bool ?? false
        fontFamily = toml["font-family"]?.string ?? ""
        fontFallbackFamily = toml["terminal.font-fallback-family"]?.string ?? ""
        let size = toml["font-size"]?.double ?? Self.defaultFontSize
        fontSize = Self.fontSizeRange.contains(size) ? size : Self.defaultFontSize
        let sidebarSize = toml["sidebar.font-size"]?.double
            ?? Self.defaultSidebarFontSize
        sidebarFontSize = Self.sidebarFontSizeRange.contains(sidebarSize)
            ? sidebarSize
            : Self.defaultSidebarFontSize
        let interfaceScale = toml["interface.scale"]?.double
            ?? Self.defaultInterfaceScale
        self.interfaceScale = Self.interfaceScaleRange.contains(interfaceScale)
            ? interfaceScale
            : Self.defaultInterfaceScale
        toolbarVisibility = ToolbarVisibility(
            rawValue: toml["toolbar.visibility"]?.string ?? ""
        ) ?? Self.defaultToolbarVisibility
        fontThicken = toml["terminal.font-thicken"]?.bool
            ?? toml["font-thicken"]?.bool
            ?? false
        let thickenStrength = toml["terminal.font-thicken-strength"]?.double
            ?? Double(Self.defaultFontThickenStrength)
        fontThickenStrength = Self.fontThickenStrengthRange.contains(thickenStrength)
            ? Int(thickenStrength.rounded())
            : Self.defaultFontThickenStrength
        let lineHeight = toml["terminal.line-height"]?.double
            ?? Self.defaultTerminalLineHeight
        terminalLineHeight = Self.terminalLineHeightRange.contains(lineHeight)
            ? lineHeight
            : Self.defaultTerminalLineHeight
        cursorShape = TerminalCursorShape(
            rawValue: toml["terminal.cursor-shape"]?.string ?? ""
        ) ?? .block
        cursorBlinking = toml["terminal.cursor-blinking"]?.bool ?? true
        macosOptionAsAlt = toml["terminal.macos-option-as-alt"]?.bool ?? false
        terminalBell = toml["terminal.bell"]?.bool ?? true
        shiftEnterNewline = toml["terminal.shift-enter-newline"]?.bool ?? true
        wrapLines = toml["editor.wrap-lines"]?.bool ?? true
        externalEditor = ExternalEditor.persisted(
            toml["editor.external-editor"]?.string
        )
        restoreTerminalHistory = toml["terminal.restore-history"]?.bool ?? false
        copyOnSelect = toml["terminal.copy-on-select"]?.bool ?? true
        let terminalBackgroundOpacity = toml["terminal.background-opacity"]?.double
            ?? Self.defaultTerminalBackgroundOpacity
        self.terminalBackgroundOpacity = Self.terminalBackgroundOpacityRange.contains(
            terminalBackgroundOpacity
        ) ? terminalBackgroundOpacity : Self.defaultTerminalBackgroundOpacity
        terminalBackgroundBlur = toml["terminal.background-blur"]?.bool
            ?? Self.defaultTerminalBackgroundBlur
        let notifySeconds = toml["terminal.notify-finish-seconds"]?.double ?? 0
        let notifyChoice = notifySeconds.isFinite ? Int(notifySeconds) : 0
        notifyFinishSeconds = Self.notifyFinishSecondChoices.contains(notifyChoice)
            ? notifyChoice : 0
        notifyOnError = toml["terminal.notify-on-error"]?.bool ?? false
        let quickTerminalSize = toml["quick-terminal.size"]?.double
            ?? Self.defaultQuickTerminalSize
        self.quickTerminalSize = Self.quickTerminalSizeRange.contains(quickTerminalSize)
            ? quickTerminalSize
            : Self.defaultQuickTerminalSize
        let quickTerminalOpacity = toml["quick-terminal.opacity"]?.double
            ?? Self.defaultQuickTerminalOpacity
        self.quickTerminalOpacity = Self.quickTerminalOpacityRange.contains(quickTerminalOpacity)
            ? quickTerminalOpacity
            : Self.defaultQuickTerminalOpacity
        quickTerminalShortcut = QuickTerminalShortcut(
            persistedValue: toml["quick-terminal.shortcut"]?.string
        ) ?? Self.defaultQuickTerminalShortcut
        commandShortcuts = Self.parseCommandShortcuts(toml)
        showPaneFocusRing = toml["panes.show-focus-ring"]?.bool ?? true
        let paneFocusRingOpacity = toml["panes.focus-ring-opacity"]?.double
            ?? Self.defaultPaneFocusRingOpacity
        self.paneFocusRingOpacity = Self.paneFocusRingOpacityRange.contains(
            paneFocusRingOpacity
        ) ? paneFocusRingOpacity : Self.defaultPaneFocusRingOpacity
        aiEnabled = toml["ai.enabled"]?.bool ?? true
        terminalBackend = TerminalBackend(persisted: toml["terminal.backend"]?.string)
        terminalStartupProgram = toml["terminal.startup-program"]?.string ?? ""
        terminalStartupArguments = toml["terminal.startup-arguments"]?.string ?? ""
        applyAppearance()
        applyApplicationIcon()
        reloadThemeSelection()
        if existing == nil { save() }
    }

    static func paneFocusRingOpacityMatchesDefault(_ value: Double) -> Bool {
        Int((value * 100).rounded())
            == Int((defaultPaneFocusRingOpacity * 100).rounded())
    }

    /// Pushes the current names into `Theme`, which resolves and caches the
    /// definitions. Called from `init` because `didSet` doesn't run there.
    private func reloadThemeSelection() {
        Theme.reloadSelection(
            light: themeLight,
            dark: themeDark,
            terminalOnly: terminalThemeOnly
        )
    }

    /// A saved shared-theme name, or `fallback` when it is absent or no longer
    /// part of the cross-backend catalog, so Settings never shows an empty
    /// selection after upgrading from the larger Ghostty-only list.
    private static func knownTheme(
        _ name: String?, dark: Bool, fallback: String
    ) -> String {
        guard let name, Theme.isCommonTheme(named: name, dark: dark) else {
            return fallback
        }
        return name
    }

    /// Overrides the app-wide appearance so every window — and the terminal
    /// theme, which reads `NSApp.effectiveAppearance` — follows the choice.
    /// Called from `init` because `didSet` doesn't run during initialization.
    func applyAppearance() {
        NSApp?.appearance = theme.nsAppearance
    }

    /// Applies only to the running process. Assigning nil restores the app
    /// icon compiled for this build, preserving the separate Debug identity.
    func applyApplicationIcon() {
        guard let application = NSApp else { return }
        guard let resourceName = applicationIcon.resourceName else {
            application.applicationIconImage = nil
            return
        }
        guard let image = applicationIcon.bundledImage() else {
            NSLog("zshell: missing application icon resource \(resourceName).icns")
            return
        }
        application.applicationIconImage = image
    }

    func resetFont() {
        fontFamily = ""
        fontFallbackFamily = ""
        fontSize = Self.defaultFontSize
        sidebarFontSize = Self.defaultSidebarFontSize
        interfaceScale = Self.defaultInterfaceScale
        fontThicken = false
        fontThickenStrength = Self.defaultFontThickenStrength
        terminalLineHeight = Self.defaultTerminalLineHeight
    }

    /// Whether every setting ``resetToDefaults()`` touches already holds its
    /// default, so Settings can disable the reset button.
    var isAtDefaults: Bool {
        applicationIcon == .defaultIcon
            && fontFamily.isEmpty
            && fontFallbackFamily.isEmpty
            && fontSize == Self.defaultFontSize
            && sidebarFontSize == Self.defaultSidebarFontSize
            && interfaceScale == Self.defaultInterfaceScale
            && !fontThicken
            && fontThickenStrength == Self.defaultFontThickenStrength
            && terminalLineHeight == Self.defaultTerminalLineHeight
            && language == .system
            && theme == .system
            && themeDark == Theme.defaultDarkThemeName
            && themeLight == Theme.defaultLightThemeName
            && !terminalThemeOnly
            && toolbarVisibility == Self.defaultToolbarVisibility
            && cursorShape == .block
            && cursorBlinking
            && !macosOptionAsAlt
            && terminalBell
            && shiftEnterNewline
            && wrapLines
            && externalEditor == .systemDefault
            && !restoreTerminalHistory
            && copyOnSelect
            && terminalBackgroundOpacity == Self.defaultTerminalBackgroundOpacity
            && terminalBackgroundBlur == Self.defaultTerminalBackgroundBlur
            && notifyFinishSeconds == 0
            && !notifyOnError
            && quickTerminalSize == Self.defaultQuickTerminalSize
            && quickTerminalOpacity == Self.defaultQuickTerminalOpacity
            && quickTerminalShortcut == Self.defaultQuickTerminalShortcut
            && showPaneFocusRing
            && Self.paneFocusRingOpacityMatchesDefault(paneFocusRingOpacity)
            && aiEnabled
            && terminalBackend == .fallback
            && terminalStartupProgram.isEmpty
            && terminalStartupArguments.isEmpty
    }

    func resetToDefaults() {
        applicationIcon = .defaultIcon
        resetFont()
        language = .system
        theme = .system
        themeDark = Theme.defaultDarkThemeName
        themeLight = Theme.defaultLightThemeName
        terminalThemeOnly = false
        toolbarVisibility = Self.defaultToolbarVisibility
        cursorShape = .block
        cursorBlinking = true
        macosOptionAsAlt = false
        terminalBell = true
        shiftEnterNewline = true
        wrapLines = true
        externalEditor = .systemDefault
        restoreTerminalHistory = false
        copyOnSelect = true
        terminalBackgroundOpacity = Self.defaultTerminalBackgroundOpacity
        terminalBackgroundBlur = Self.defaultTerminalBackgroundBlur
        notifyFinishSeconds = 0
        notifyOnError = false
        quickTerminalSize = Self.defaultQuickTerminalSize
        quickTerminalOpacity = Self.defaultQuickTerminalOpacity
        quickTerminalShortcut = Self.defaultQuickTerminalShortcut
        resetCommandShortcuts()
        showPaneFocusRing = true
        paneFocusRingOpacity = Self.defaultPaneFocusRingOpacity
        GlobalTerminalOverlay.shared.reloadHotkey()
        if !aiEnabled {
            do {
                try setAIEnabled(true)
            } catch {
                NSLog("zshell: failed to enable AI support: \(error)")
            }
        }
        terminalBackend = .fallback
        terminalStartupProgram = ""
        terminalStartupArguments = ""
    }

    /// The effective shortcut for a command: its recorded binding, or the
    /// shipped default when the user hasn't remapped it.
    func commandShortcut(for command: AppCommand) -> CommandShortcut {
        commandShortcuts[command] ?? command.defaultShortcut
    }

    /// Why a recorded shortcut can't be applied. A chord bound to another core
    /// command is refused, and so is one matching the Quick Terminal's global
    /// hotkey — that hotkey is registered system-wide and would swallow the
    /// menu chord before Zshell ever saw it.
    enum CommandShortcutConflict: Equatable {
        case command(AppCommand)
        case quickTerminal
    }

    /// Applies a recorded shortcut to a command, returning the conflict when
    /// the chord is already taken (the caller keeps the old binding).
    /// Restoring a command's default simply removes its override.
    @discardableResult
    func setCommandShortcut(
        _ shortcut: CommandShortcut, for command: AppCommand
    ) -> CommandShortcutConflict? {
        // The Quick Terminal's hotkey is registered system-wide, so a menu
        // chord matching it would never reach the menu bar. Key codes are
        // only comparable when the chord's character maps to one.
        if let keyCode = shortcut.ansiKeyCode,
           keyCode == quickTerminalShortcut.keyCode,
           shortcut.carbonModifiers == quickTerminalShortcut.modifiers {
            return .quickTerminal
        }
        if let other = AppCommand.allCases.first(where: {
            $0 != command && commandShortcut(for: $0) == shortcut
        }) {
            return .command(other)
        }
        if shortcut == command.defaultShortcut {
            commandShortcuts[command] = nil
        } else {
            commandShortcuts[command] = shortcut
        }
        return nil
    }

    /// Clears every override, restoring all menu shortcuts to their shipped
    /// bindings.
    func resetCommandShortcuts() {
        commandShortcuts = [:]
    }

    /// Overrides from the `shortcuts.<command>` keys; unrecognized commands or
    /// values (a hand-edited config) fall back to the shipped default.
    private static func parseCommandShortcuts(
        _ toml: [String: TOML.Value]
    ) -> [AppCommand: CommandShortcut] {
        var result: [AppCommand: CommandShortcut] = [:]
        for (key, value) in toml {
            guard key.hasPrefix("shortcuts.") else { continue }
            guard let command = AppCommand(rawValue: String(key.dropFirst("shortcuts.".count))),
                  let shortcut = CommandShortcut(persistedValue: value.string)
            else { continue }
            result[command] = shortcut
        }
        return result
    }

    /// Replaces the settings with values parsed from an imported config,
    /// reading the same keys with the same fallbacks `init` does, then
    /// persists them through the published properties' `didSet` saves.
    /// Assigning the published properties also refreshes the settings window
    /// through the panes' existing `objectWillChange` observation, so no
    /// separate notification is needed. Keys the file omits fall back to
    /// their defaults, and `language` is deliberately untouched: it lives in
    /// `UserDefaults` (`AppleLanguages`), not config.toml, so it is neither
    /// exported nor imported.
    func applyImported(_ toml: [String: TOML.Value]) {
        theme = toml["theme"]?.string.flatMap(AppTheme.init(rawValue:)) ?? .system
        themeDark = Self.knownTheme(
            toml["theme-dark"]?.string,
            dark: true,
            fallback: Theme.defaultDarkThemeName
        )
        themeLight = Self.knownTheme(
            toml["theme-light"]?.string,
            dark: false,
            fallback: Theme.defaultLightThemeName
        )
        fontFamily = toml["font-family"]?.string ?? ""
        let size = toml["font-size"]?.double ?? Self.defaultFontSize
        fontSize = Self.fontSizeRange.contains(size) ? size : Self.defaultFontSize
        let sidebarSize = toml["sidebar.font-size"]?.double
            ?? Self.defaultSidebarFontSize
        sidebarFontSize = Self.sidebarFontSizeRange.contains(sidebarSize)
            ? sidebarSize
            : Self.defaultSidebarFontSize
        toolbarVisibility = ToolbarVisibility(
            rawValue: toml["toolbar.visibility"]?.string ?? ""
        ) ?? Self.defaultToolbarVisibility
        fontThicken = toml["terminal.font-thicken"]?.bool
            ?? toml["font-thicken"]?.bool
            ?? false
        cursorShape = TerminalCursorShape(
            rawValue: toml["terminal.cursor-shape"]?.string ?? ""
        ) ?? .block
        cursorBlinking = toml["terminal.cursor-blinking"]?.bool ?? true
        macosOptionAsAlt = toml["terminal.macos-option-as-alt"]?.bool ?? false
        wrapLines = toml["editor.wrap-lines"]?.bool ?? true
        restoreTerminalHistory = toml["terminal.restore-history"]?.bool ?? false
        copyOnSelect = toml["terminal.copy-on-select"]?.bool ?? true
        let quickTerminalSize = toml["quick-terminal.size"]?.double
            ?? Self.defaultQuickTerminalSize
        self.quickTerminalSize = Self.quickTerminalSizeRange.contains(quickTerminalSize)
            ? quickTerminalSize
            : Self.defaultQuickTerminalSize
        let quickTerminalOpacity = toml["quick-terminal.opacity"]?.double
            ?? Self.defaultQuickTerminalOpacity
        self.quickTerminalOpacity = Self.quickTerminalOpacityRange.contains(quickTerminalOpacity)
            ? quickTerminalOpacity
            : Self.defaultQuickTerminalOpacity
        quickTerminalShortcut = QuickTerminalShortcut(
            persistedValue: toml["quick-terminal.shortcut"]?.string
        ) ?? Self.defaultQuickTerminalShortcut
        if let enabled = toml["ai.enabled"]?.bool, enabled != aiEnabled {
            do {
                try setAIEnabled(enabled)
            } catch {
                // Match resetToDefaults: the install steps are best effort,
                // and the rest of the imported settings still apply.
                NSLog("zshell: failed to apply imported AI support setting: \(error)")
            }
        }
        terminalBackend = TerminalBackend(persisted: toml["terminal.backend"]?.string)
        // The shortcut applies to the registered hotkey only through this
        // reload, the same as resetToDefaults.
        GlobalTerminalOverlay.shared.reloadHotkey()
    }

    /// Persist the setting only after every requested destination operation
    /// returns successfully.
    func setAIEnabled(_ enabled: Bool) throws {
        if enabled {
            try ZshellAgentIntegrations.preflightInstallAvailable()
            _ = try ZshellAutomationSkill.install(
                destinations: ZshellAutomationSkill.Destination.allCases,
                force: false
            )
            try ZshellAgentIntegrations.installAvailable()
        } else {
            try ZshellAgentIntegrations.preflightUninstallManaged()
            _ = try ZshellAutomationSkill.uninstall(
                destinations: ZshellAutomationSkill.Destination.allCases,
                force: false
            )
            try ZshellAgentIntegrations.uninstallManaged()
        }
        aiEnabled = enabled
    }

    /// App updates normally preserve the bundle path targeted by the links.
    /// Reconcile at launch as well so moving the app or changing Debug build
    /// products repairs only installations the user explicitly enabled.
    func reconcileAIEnabled() {
        guard aiEnabled else { return }
        do {
            _ = try ZshellAutomationSkill.install(
                destinations: ZshellAutomationSkill.Destination.allCases,
                force: false
            )
            try ZshellAgentIntegrations.installAvailable()
        } catch {
            NSLog("zshell: failed to refresh AI support: \(error)")
        }
    }

    private func save() {
        let dir = Self.configURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true)
            try serializedConfig().write(
                to: Self.configURL, atomically: true, encoding: .utf8)
        } catch {
            NSLog("zshell: failed to write \(Self.configURL.path): \(error)")
        }
    }

    /// The config.toml representation of the current settings, from the same
    /// writer that persists `config.toml`, so an exported file is byte for
    /// byte what the app would have saved. Like `save()`, only values that
    /// differ from their default are emitted — an absent key means "keep the
    /// default", which is the contract the reader applies at launch.
    func serializedConfig() -> String {
        var lines: [String] = []
        // Top-level like `theme`: the icon covers the whole app.
        if applicationIcon != .defaultIcon {
            lines.append("app-icon = \(TOML.quote(applicationIcon.rawValue))")
        }
        if theme != .system {
            lines.append("theme = \(TOML.quote(theme.rawValue))")
        }
        if themeDark != Theme.defaultDarkThemeName {
            lines.append("theme-dark = \(TOML.quote(themeDark))")
        }
        if themeLight != Theme.defaultLightThemeName {
            lines.append("theme-light = \(TOML.quote(themeLight))")
        }
        if terminalThemeOnly {
            lines.append("terminal.theme-only = true")
        }
        if !fontFamily.isEmpty {
            lines.append("font-family = \(TOML.quote(fontFamily))")
        }
        if !fontFallbackFamily.isEmpty {
            lines.append("terminal.font-fallback-family = \(TOML.quote(fontFallbackFamily))")
        }
        lines.append("font-size = \(TOML.number(fontSize))")
        if sidebarFontSize != Self.defaultSidebarFontSize {
            lines.append("sidebar.font-size = \(TOML.number(sidebarFontSize))")
        }
        if interfaceScale != Self.defaultInterfaceScale {
            lines.append("interface.scale = \(TOML.number(interfaceScale))")
        }
        if toolbarVisibility != Self.defaultToolbarVisibility {
            lines.append("toolbar.visibility = \(TOML.quote(toolbarVisibility.rawValue))")
        }
        if fontThicken {
            lines.append("terminal.font-thicken = true")
        }
        if fontThickenStrength != Self.defaultFontThickenStrength {
            lines.append("terminal.font-thicken-strength = \(fontThickenStrength)")
        }
        if terminalLineHeight != Self.defaultTerminalLineHeight {
            lines.append("terminal.line-height = \(TOML.number(terminalLineHeight))")
        }
        if cursorShape != .block {
            lines.append("terminal.cursor-shape = \(TOML.quote(cursorShape.rawValue))")
        }
        if !cursorBlinking {
            lines.append("terminal.cursor-blinking = false")
        }
        if macosOptionAsAlt {
            lines.append("terminal.macos-option-as-alt = true")
        }
        if !terminalBell {
            lines.append("terminal.bell = false")
        }
        if !shiftEnterNewline {
            lines.append("terminal.shift-enter-newline = false")
        }
        if !wrapLines {
            lines.append("editor.wrap-lines = false")
        }
        if externalEditor != .systemDefault {
            lines.append("editor.external-editor = \(TOML.quote(externalEditor.rawValue))")
        }
        if restoreTerminalHistory {
            lines.append("terminal.restore-history = true")
        }
        if !copyOnSelect {
            lines.append("terminal.copy-on-select = false")
        }
        if terminalBackgroundOpacity != Self.defaultTerminalBackgroundOpacity {
            lines.append(
                "terminal.background-opacity = \(TOML.number(terminalBackgroundOpacity))"
            )
        }
        if terminalBackgroundBlur != Self.defaultTerminalBackgroundBlur {
            lines.append("terminal.background-blur = true")
        }
        if notifyFinishSeconds > 0 {
            lines.append("terminal.notify-finish-seconds = \(TOML.number(Double(notifyFinishSeconds)))")
        }
        if notifyOnError {
            lines.append("terminal.notify-on-error = true")
        }
        if quickTerminalSize != Self.defaultQuickTerminalSize {
            lines.append("quick-terminal.size = \(TOML.number(quickTerminalSize))")
        }
        if quickTerminalOpacity != Self.defaultQuickTerminalOpacity {
            lines.append("quick-terminal.opacity = \(TOML.number(quickTerminalOpacity))")
        }
        if quickTerminalShortcut != Self.defaultQuickTerminalShortcut {
            lines.append("quick-terminal.shortcut = \(TOML.quote(quickTerminalShortcut.persistedValue))")
        }
        for command in AppCommand.allCases.sorted(by: { $0.rawValue < $1.rawValue }) {
            if let shortcut = commandShortcuts[command] {
                lines.append("shortcuts.\(command.rawValue) = \(TOML.quote(shortcut.persistedValue))")
            }
        }
        if !showPaneFocusRing {
            lines.append("panes.show-focus-ring = false")
        }
        if !Self.paneFocusRingOpacityMatchesDefault(paneFocusRingOpacity) {
            lines.append("panes.focus-ring-opacity = \(TOML.number(paneFocusRingOpacity))")
        }
        if !aiEnabled {
            lines.append("ai.enabled = false")
        }
        if terminalBackend != .fallback {
            lines.append("terminal.backend = \(TOML.quote(terminalBackend.rawValue))")
        }
        if !terminalStartupProgram.isEmpty {
            lines.append("terminal.startup-program = \(TOML.quote(terminalStartupProgram))")
        }
        if !terminalStartupArguments.isEmpty {
            lines.append("terminal.startup-arguments = \(TOML.quote(terminalStartupArguments))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Settings from releases that stored config in UserDefaults.
    private static func legacyDefaults() -> [String: TOML.Value] {
        var toml: [String: TOML.Value] = [:]
        let defaults = UserDefaults.standard
        if let family = defaults.string(forKey: "terminalFontFamily") {
            toml["font-family"] = .string(family)
        }
        if defaults.object(forKey: "terminalFontSize") != nil {
            toml["font-size"] = .number(defaults.double(forKey: "terminalFontSize"))
        }
        return toml
    }
}

/// Minimal TOML support covering what the config file uses: flat and dotted
/// keys (`font-size = 15`, `terminal.restore-history = true`), string/number/
/// bool values, and `#` comments. `[table]` headers are also accepted and
/// flattened to `table.key`, matching the dotted form.
enum TOML {
    enum Value {
        case string(String)
        case number(Double)
        case bool(Bool)

        var string: String? {
            if case .string(let s) = self { return s }
            return nil
        }

        var double: Double? {
            if case .number(let n) = self { return n }
            return nil
        }

        var bool: Bool? {
            if case .bool(let b) = self { return b }
            return nil
        }
    }

    /// A line the reader could not turn into a key/value pair.
    struct MalformedLine {
        /// 1-based position of the line in the file.
        let number: Int
        /// The line as written, for surfacing in an error message.
        let text: String
    }

    static func parse(at url: URL) -> [String: Value]? {
        read(at: url, reportingMalformed: false)?.values
    }

    /// Parses like `parse(at:)` but, instead of silently skipping a line that
    /// yields no key or no value, reports the first such line. The lenient
    /// reader keeps a hand-edited config from ever blocking launch; importing
    /// a file is explicit, so a mistake there should be surfaced rather than
    /// quietly dropped. Values are only meaningful when `malformed` is nil.
    static func parseStrictly(
        at url: URL
    ) -> (values: [String: Value], malformed: MalformedLine?)? {
        read(at: url, reportingMalformed: true)
    }

    /// Both entry points share one grammar so import validation accepts
    /// exactly what the launch-time reader accepts. Empty lines are kept in
    /// the split so line numbers stay true to the file.
    private static func read(
        at url: URL, reportingMalformed: Bool
    ) -> (values: [String: Value], malformed: MalformedLine?)? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        var table = ""
        var result: [String: Value] = [:]
        for (index, rawLine) in text.split(
            separator: "\n", omittingEmptySubsequences: false
        ).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                table = String(line.dropFirst().dropLast())
                    .trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let eq = line.firstIndex(of: "=") else {
                if reportingMalformed {
                    return (result, MalformedLine(number: index + 1, text: line))
                }
                continue
            }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let rawValue = line[line.index(after: eq)...]
                .trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, let value = parseValue(rawValue) else {
                if reportingMalformed {
                    return (result, MalformedLine(number: index + 1, text: line))
                }
                continue
            }
            result[table.isEmpty ? key : "\(table).\(key)"] = value
        }
        return (result, nil)
    }

    private static func parseValue(_ raw: String) -> Value? {
        if raw.hasPrefix("\"") {
            var out = ""
            var escaped = false
            for ch in raw.dropFirst() {
                if escaped {
                    switch ch {
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    default: out.append(ch)
                    }
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == "\"" {
                    return .string(out)
                } else {
                    out.append(ch)
                }
            }
            return nil
        }
        // Unquoted: strip a trailing comment, then try bool/number.
        // `omittingEmptySubsequences: false` keeps index 0 alive for an empty
        // value ("key =") — with it omitted, the subscript below crashed on
        // such a line, taking the launch-time reader down with it.
        let bare = raw.split(
            separator: "#", maxSplits: 1, omittingEmptySubsequences: false
        )[0]
            .trimmingCharacters(in: .whitespaces)
        switch bare {
        case "true": return .bool(true)
        case "false": return .bool(false)
        default: return Double(bare).map(Value.number)
        }
    }

    static func quote(_ s: String) -> String {
        var out = "\""
        for ch in s {
            switch ch {
            case "\"", "\\": out.append("\\\(ch)")
            case "\n": out.append("\\n")
            case "\t": out.append("\\t")
            default: out.append(ch)
            }
        }
        return out + "\""
    }

    static func number(_ n: Double) -> String {
        n == n.rounded() && abs(n) < 1e15
            ? String(Int(n)) : String(n)
    }
}
