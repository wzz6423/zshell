//
//  AppSettings.swift
//  zshell
//

import AppKit
import Combine
import Foundation

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

    /// Compensates for the light card reading larger than the dark default
    /// against Dock glass while retaining the system's icon geometry.
    private var dockVisualScale: CGFloat {
        switch self {
        case .light: 0.9
        case .defaultIcon, .dark: 1
        }
    }

    /// Loads an icon resource whether Xcode copied it at the bundle root or
    /// preserved the source `Icons` directory in the resource bundle.
    func bundledImage() -> NSImage? {
        guard let resourceName else { return nil }
        guard let image = Self.image(named: resourceName) else { return nil }
        if let compiledIconSize = Self.compiledIconSize {
            image.size = compiledIconSize
        }
        guard #available(macOS 26.0, *) else { return image }

        // macOS insets bundled app icons into an 824-point shape on a
        // 1024-point canvas. Runtime overrides bypass that normalization.
        let contentScale = CGFloat(824.0 / 1024.0) * dockVisualScale
        return NSImage(size: image.size, flipped: false) { rect in
            let inset = (1 - contentScale) / 2
            let content = rect.insetBy(dx: rect.width * inset, dy: rect.height * inset)
            image.draw(in: content, from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
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

    private let configMonitor = SettingsConfigMonitor(url: AppSettings.configURL)
    private var isApplyingConfig = false
    private var configTerminationObserver: NSObjectProtocol?

    /// The minimum runtimes, in seconds, that Settings offers for
    /// `terminal.notify-finish-seconds`. A hand-edited config value outside
    /// this set reads as off — the alternative is a popup displaying a number
    /// the pane's shell integration would not have been built with.
    static let notifyFinishSecondChoices = [0, 5, 10, 30, 60]

    @Published var language: AppLanguage {
        didSet {
            guard language != oldValue else { return }
            language.persist()
            AppLocalization.apply(language)
        }
    }

    /// Icon shown for the running app; `defaultIcon` restores the icon compiled
    /// for this build configuration.
    @Published var applicationIcon: ApplicationIcon {
        didSet {
            guard applicationIcon != oldValue else { return }
            guard !isApplyingConfig else { return }
            applyApplicationIcon()
            save()
        }
    }

    /// Light/dark appearance override; `system` follows macOS.
    @Published var theme: AppTheme {
        didSet {
            guard theme != oldValue else { return }
            guard !isApplyingConfig else { return }
            applyAppearance()
            save()
        }
    }

    /// Color theme names, one per appearance. `Theme` keeps the resolved
    /// definitions (Zshell built-ins plus the Ghostty catalog).
    @Published var themeDark: String {
        didSet {
            guard themeDark != oldValue else { return }
            guard !isApplyingConfig else { return }
            reloadThemeSelection()
            save()
        }
    }

    @Published var themeLight: String {
        didSet {
            guard themeLight != oldValue else { return }
            guard !isApplyingConfig else { return }
            reloadThemeSelection()
            save()
        }
    }

    /// Keep the selected palettes on terminal surfaces while the rest of the
    /// app uses Zshell's built-in light and dark palettes.
    @Published var terminalThemeOnly: Bool {
        didSet {
            guard terminalThemeOnly != oldValue else { return }
            guard !isApplyingConfig else { return }
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

    @Published var applicationPresence: ApplicationPresence {
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

    @Published var vimCommandHints: Bool {
        didSet { save() }
    }

    @Published var shellCompletions: Bool {
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
    /// when the app relaunches, above the freshly started shell. Captured
    /// output is written to disk while enabled.
    @Published var restoreTerminalHistory: Bool {
        didSet { save() }
    }

    @Published var preserveTerminalSessions: Bool {
        didSet { save() }
    }

    /// Copy terminal text to the clipboard after a pointer selection ends.
    /// Enabled by default to preserve Zshell's existing selection behavior.
    @Published var copyOnSelect: Bool {
        didSet { save() }
    }

    @Published var focusFollowsMouse: Bool {
        didSet { save() }
    }

    /// Alpha of each main workspace window. With blur, the same value blends
    /// the terminal's theme background over the native behind-window material.
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
    /// Persisted as `terminal.notify-on-error`; shares the shim plumbing and
    /// the new-terminals-only caveat with ``notifyFinishSeconds``.
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

    @Published var quickTerminalMode: QuickTerminalMode {
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

    @Published var resumeAgentConversations: Bool {
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

    @Published var browserContentBlocking: Bool {
        didSet { save() }
    }

    @Published var browserFilterLists: String {
        didSet { save() }
    }

    @Published var terminalProfiles: [TerminalProfile] {
        didSet { save() }
    }

    private init() {
        let savedLanguage = AppLanguage.saved
        language = savedLanguage

        let existing = TOML.parse(at: Self.configURL)
        let toml = existing ?? Self.legacyDefaults()
        applicationIcon = ApplicationIcon(
            rawValue: toml["app-icon"]?.string ?? ""
        ) ?? .defaultIcon
        applicationPresence = ApplicationPresence(
            rawValue: toml["app-presence"]?.string ?? ""
        ) ?? .dockOnly
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
        ) ?? .bar
        cursorBlinking = toml["terminal.cursor-blinking"]?.bool ?? true
        macosOptionAsAlt = toml["terminal.macos-option-as-alt"]?.bool ?? false
        // Older configs omitted these preferences when disabled, so only a
        // new config adopts their enabled defaults.
        vimCommandHints = toml["terminal.vim-command-hints"]?.bool ?? (existing == nil)
        shellCompletions = toml["terminal.shell-completions"]?.bool ?? true
        terminalBell = toml["terminal.bell"]?.bool ?? true
        shiftEnterNewline = toml["terminal.shift-enter-newline"]?.bool ?? true
        wrapLines = toml["editor.wrap-lines"]?.bool ?? true
        externalEditor = ExternalEditor.persisted(
            toml["editor.external-editor"]?.string
        )
        restoreTerminalHistory = toml["terminal.restore-history"]?.bool ?? (existing == nil)
        preserveTerminalSessions = toml["terminal.preserve-sessions"]?.bool ?? false
        copyOnSelect = toml["terminal.copy-on-select"]?.bool ?? true
        focusFollowsMouse = toml["terminal.focus-follows-mouse"]?.bool ?? false
        let terminalBackgroundOpacity = toml["terminal.background-opacity"]?.double
            ?? Self.defaultTerminalBackgroundOpacity
        self.terminalBackgroundOpacity = Self.terminalBackgroundOpacityRange.contains(
            terminalBackgroundOpacity
        ) ? terminalBackgroundOpacity : Self.defaultTerminalBackgroundOpacity
        terminalBackgroundBlur = toml["terminal.background-blur"]?.bool
            ?? Self.defaultTerminalBackgroundBlur
        let notifySeconds = toml["terminal.notify-finish-seconds"]?.double ?? 0
        let notifyChoice = Self.notifyFinishChoice(notifySeconds)
        notifyFinishSeconds = Self.notifyFinishSecondChoices.contains(notifyChoice)
            ? notifyChoice : 0
        notifyOnError = toml["terminal.notify-on-error"]?.bool ?? (existing == nil)
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
        quickTerminalMode = QuickTerminalMode(rawValue: toml["quick-terminal.mode"]?.string ?? "") ?? .reuse
        commandShortcuts = Self.parseCommandShortcuts(toml)
        showPaneFocusRing = toml["panes.show-focus-ring"]?.bool ?? true
        let paneFocusRingOpacity = toml["panes.focus-ring-opacity"]?.double
            ?? Self.defaultPaneFocusRingOpacity
        self.paneFocusRingOpacity = Self.paneFocusRingOpacityRange.contains(
            paneFocusRingOpacity
        ) ? paneFocusRingOpacity : Self.defaultPaneFocusRingOpacity
        aiEnabled = toml["ai.enabled"]?.bool ?? true
        resumeAgentConversations = toml["ai.resume-conversations"]?.bool ?? true
        terminalBackend = TerminalBackend(persisted: toml["terminal.backend"]?.string)
        terminalStartupProgram = toml["terminal.startup-program"]?.string ?? ""
        terminalStartupArguments = toml["terminal.startup-arguments"]?.string ?? ""
        browserContentBlocking = toml["browser.content-blocking"]?.bool ?? true
        browserFilterLists = toml["browser.filter-lists"]?.string ?? BrowserFilterSource.defaults
        terminalProfiles = TerminalProfile.read(toml)
        applyAppearance()
        applyApplicationIcon()
        reloadThemeSelection()
        if existing == nil { save() }
        configMonitor.start { [weak self] text, revision in
            let parsed = TOML.parseStrictly(text: text)
            guard parsed.malformed == nil else { return }
            Task { @MainActor [weak self] in
                guard let self, self.configMonitor.isCurrent(revision) else { return }
                self.applyConfig(parsed.values)
            }
        }
        configTerminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [configMonitor] _ in
            configMonitor.flush()
        }
    }

    static func paneFocusRingOpacityMatchesDefault(_ value: Double) -> Bool {
        Int((value * 100).rounded())
            == Int((defaultPaneFocusRingOpacity * 100).rounded())
    }

    private static func notifyFinishChoice(_ seconds: Double) -> Int {
        guard seconds.isFinite, seconds >= 0, seconds < 61 else { return 0 }
        let choice = Int(seconds)
        return notifyFinishSecondChoices.contains(choice) ? choice : 0
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
            && applicationPresence == .dockOnly
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
            && cursorShape == .bar
            && cursorBlinking
            && !macosOptionAsAlt
            && terminalBell
            && vimCommandHints
            && shiftEnterNewline
            && wrapLines
            && externalEditor == .systemDefault
            && restoreTerminalHistory
            && !preserveTerminalSessions
            && copyOnSelect
            && !focusFollowsMouse
            && terminalBackgroundOpacity == Self.defaultTerminalBackgroundOpacity
            && terminalBackgroundBlur == Self.defaultTerminalBackgroundBlur
            && notifyFinishSeconds == 0
            && notifyOnError
            && quickTerminalSize == Self.defaultQuickTerminalSize
            && quickTerminalOpacity == Self.defaultQuickTerminalOpacity
            && quickTerminalShortcut == Self.defaultQuickTerminalShortcut
            && quickTerminalMode == .reuse
            && showPaneFocusRing
            && Self.paneFocusRingOpacityMatchesDefault(paneFocusRingOpacity)
            && aiEnabled
            && resumeAgentConversations
            && terminalBackend == .fallback
            && terminalStartupProgram.isEmpty
            && terminalStartupArguments.isEmpty
            && browserContentBlocking
            && browserFilterLists == BrowserFilterSource.defaults
            && terminalProfiles.isEmpty
    }

    func resetToDefaults() {
        applicationIcon = .defaultIcon
        applicationPresence = .dockOnly
        resetFont()
        language = .system
        theme = .system
        themeDark = Theme.defaultDarkThemeName
        themeLight = Theme.defaultLightThemeName
        terminalThemeOnly = false
        toolbarVisibility = Self.defaultToolbarVisibility
        cursorShape = .bar
        cursorBlinking = true
        macosOptionAsAlt = false
        terminalBell = true
        vimCommandHints = true
        shellCompletions = true
        shiftEnterNewline = true
        wrapLines = true
        externalEditor = .systemDefault
        restoreTerminalHistory = true
        preserveTerminalSessions = false
        copyOnSelect = true
        focusFollowsMouse = false
        terminalBackgroundOpacity = Self.defaultTerminalBackgroundOpacity
        terminalBackgroundBlur = Self.defaultTerminalBackgroundBlur
        notifyFinishSeconds = 0
        notifyOnError = true
        quickTerminalSize = Self.defaultQuickTerminalSize
        quickTerminalOpacity = Self.defaultQuickTerminalOpacity
        quickTerminalShortcut = Self.defaultQuickTerminalShortcut
        quickTerminalMode = .reuse
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
        terminalProfiles = []
        browserContentBlocking = true
        browserFilterLists = BrowserFilterSource.defaults
        resumeAgentConversations = true
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

    /// Import and external edits use existing-file defaults. Language remains in
    /// UserDefaults, outside config.toml. Import persists once; a file reload
    /// never writes back while an editor may still be changing the file.
    func applyImported(_ toml: [String: TOML.Value]) {
        applyConfig(toml, defaultAIEnabled: aiEnabled)
        save()
    }

    private func assign<Value: Equatable>(
        _ keyPath: ReferenceWritableKeyPath<AppSettings, Value>, _ value: Value
    ) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    private func applyConfig(_ toml: [String: TOML.Value], defaultAIEnabled: Bool = true) {
        let oldIcon = applicationIcon
        let oldTheme = theme
        let oldThemeDark = themeDark
        let oldThemeLight = themeLight
        let oldTerminalThemeOnly = terminalThemeOnly
        let oldShortcut = quickTerminalShortcut
        isApplyingConfig = true
        defer { isApplyingConfig = false }

        assign(\.applicationIcon, ApplicationIcon(
            rawValue: toml["app-icon"]?.string ?? ""
        ) ?? .defaultIcon)
        assign(\.applicationPresence, ApplicationPresence(
            rawValue: toml["app-presence"]?.string ?? ""
        ) ?? .dockOnly)
        assign(\.theme, toml["theme"]?.string.flatMap(AppTheme.init(rawValue:)) ?? .system)
        assign(\.themeDark, Self.knownTheme(
            toml["theme-dark"]?.string,
            dark: true,
            fallback: Theme.defaultDarkThemeName
        ))
        assign(\.themeLight, Self.knownTheme(
            toml["theme-light"]?.string,
            dark: false,
            fallback: Theme.defaultLightThemeName
        ))
        assign(\.terminalThemeOnly, toml["terminal.theme-only"]?.bool ?? false)
        assign(\.fontFamily, toml["font-family"]?.string ?? "")
        assign(\.fontFallbackFamily, toml["terminal.font-fallback-family"]?.string ?? "")
        let size = toml["font-size"]?.double ?? Self.defaultFontSize
        assign(\.fontSize, Self.fontSizeRange.contains(size) ? size : Self.defaultFontSize)
        let sidebarSize = toml["sidebar.font-size"]?.double
            ?? Self.defaultSidebarFontSize
        assign(\.sidebarFontSize, Self.sidebarFontSizeRange.contains(sidebarSize)
            ? sidebarSize
            : Self.defaultSidebarFontSize)
        let scale = toml["interface.scale"]?.double ?? Self.defaultInterfaceScale
        assign(\.interfaceScale, Self.interfaceScaleRange.contains(scale)
            ? scale : Self.defaultInterfaceScale)
        assign(\.toolbarVisibility, ToolbarVisibility(
            rawValue: toml["toolbar.visibility"]?.string ?? ""
        ) ?? Self.defaultToolbarVisibility)
        assign(\.fontThicken, toml["terminal.font-thicken"]?.bool
            ?? toml["font-thicken"]?.bool
            ?? false)
        let thickenStrength = toml["terminal.font-thicken-strength"]?.double
            ?? Double(Self.defaultFontThickenStrength)
        assign(\.fontThickenStrength, Self.fontThickenStrengthRange.contains(thickenStrength)
            ? Int(thickenStrength.rounded()) : Self.defaultFontThickenStrength)
        let lineHeight = toml["terminal.line-height"]?.double ?? Self.defaultTerminalLineHeight
        assign(\.terminalLineHeight, Self.terminalLineHeightRange.contains(lineHeight)
            ? lineHeight : Self.defaultTerminalLineHeight)
        let cursorShape = TerminalCursorShape(
            rawValue: toml["terminal.cursor-shape"]?.string ?? ""
        ) ?? .bar
        assign(\.cursorShape, cursorShape)
        assign(\.cursorBlinking, toml["terminal.cursor-blinking"]?.bool ?? true)
        assign(\.macosOptionAsAlt, toml["terminal.macos-option-as-alt"]?.bool ?? false)
        assign(\.terminalBell, toml["terminal.bell"]?.bool ?? true)
        assign(\.vimCommandHints, toml["terminal.vim-command-hints"]?.bool ?? false)
        assign(\.shellCompletions, toml["terminal.shell-completions"]?.bool ?? true)
        assign(\.shiftEnterNewline, toml["terminal.shift-enter-newline"]?.bool ?? true)
        assign(\.wrapLines, toml["editor.wrap-lines"]?.bool ?? true)
        assign(\.externalEditor, ExternalEditor.persisted(toml["editor.external-editor"]?.string))
        assign(\.restoreTerminalHistory, toml["terminal.restore-history"]?.bool ?? false)
        assign(\.preserveTerminalSessions, toml["terminal.preserve-sessions"]?.bool ?? false)
        assign(\.copyOnSelect, toml["terminal.copy-on-select"]?.bool ?? true)
        assign(\.focusFollowsMouse, toml["terminal.focus-follows-mouse"]?.bool ?? false)
        let opacity = toml["terminal.background-opacity"]?.double
            ?? Self.defaultTerminalBackgroundOpacity
        assign(\.terminalBackgroundOpacity, Self.terminalBackgroundOpacityRange.contains(opacity)
            ? opacity : Self.defaultTerminalBackgroundOpacity)
        assign(\.terminalBackgroundBlur, toml["terminal.background-blur"]?.bool
            ?? Self.defaultTerminalBackgroundBlur)
        let notifySeconds = toml["terminal.notify-finish-seconds"]?.double ?? 0
        assign(\.notifyFinishSeconds, Self.notifyFinishChoice(notifySeconds))
        assign(\.notifyOnError, toml["terminal.notify-on-error"]?.bool ?? false)
        let quickTerminalSize = toml["quick-terminal.size"]?.double
            ?? Self.defaultQuickTerminalSize
        assign(\.quickTerminalSize, Self.quickTerminalSizeRange.contains(quickTerminalSize)
            ? quickTerminalSize
            : Self.defaultQuickTerminalSize)
        let quickTerminalOpacity = toml["quick-terminal.opacity"]?.double
            ?? Self.defaultQuickTerminalOpacity
        assign(\.quickTerminalOpacity, Self.quickTerminalOpacityRange.contains(quickTerminalOpacity)
            ? quickTerminalOpacity
            : Self.defaultQuickTerminalOpacity)
        assign(\.quickTerminalShortcut, QuickTerminalShortcut(
            persistedValue: toml["quick-terminal.shortcut"]?.string
        ) ?? Self.defaultQuickTerminalShortcut)
        assign(\.quickTerminalMode, QuickTerminalMode(
            rawValue: toml["quick-terminal.mode"]?.string ?? ""
        ) ?? .reuse)
        assign(\.commandShortcuts, Self.parseCommandShortcuts(toml))
        assign(\.showPaneFocusRing, toml["panes.show-focus-ring"]?.bool ?? true)
        let focusOpacity = toml["panes.focus-ring-opacity"]?.double
            ?? Self.defaultPaneFocusRingOpacity
        assign(\.paneFocusRingOpacity, Self.paneFocusRingOpacityRange.contains(focusOpacity)
            ? focusOpacity : Self.defaultPaneFocusRingOpacity)
        let enabled = toml["ai.enabled"]?.bool ?? defaultAIEnabled
        if enabled != aiEnabled {
            do {
                try setAIEnabled(enabled)
            } catch {
                // Match resetToDefaults: the install steps are best effort,
                // and the rest of the imported settings still apply.
                NSLog("zshell: failed to apply AI support setting: \(error)")
            }
        }
        assign(\.resumeAgentConversations, toml["ai.resume-conversations"]?.bool ?? true)
        assign(\.terminalBackend, TerminalBackend(persisted: toml["terminal.backend"]?.string))
        assign(\.terminalStartupProgram, toml["terminal.startup-program"]?.string ?? "")
        assign(\.terminalStartupArguments, toml["terminal.startup-arguments"]?.string ?? "")
        assign(\.browserContentBlocking, toml["browser.content-blocking"]?.bool ?? true)
        assign(\.browserFilterLists, toml["browser.filter-lists"]?.string ?? BrowserFilterSource.defaults)
        assign(\.terminalProfiles, TerminalProfile.read(toml))

        if applicationIcon != oldIcon { applyApplicationIcon() }
        if theme != oldTheme { applyAppearance() }
        if themeDark != oldThemeDark || themeLight != oldThemeLight
            || terminalThemeOnly != oldTerminalThemeOnly {
            reloadThemeSelection()
        }
        if quickTerminalShortcut != oldShortcut { GlobalTerminalOverlay.shared.reloadHotkey() }
    }

    /// Persist the setting only after every requested destination operation
    /// returns successfully.
    func setAIEnabled(_ enabled: Bool) throws {
        if enabled {
            try ZshellAgentIntegrations.preflightInstallAvailable()
            try ZshellAgentLifecycleHooks.preflightInstallAvailable()
            _ = try ZshellAutomationSkill.install(
                destinations: ZshellAutomationSkill.Destination.allCases,
                force: false
            )
            try ZshellAgentIntegrations.installAvailable()
            try ZshellAgentLifecycleHooks.installAvailable()
        } else {
            try ZshellAgentIntegrations.preflightUninstallManaged()
            try ZshellAgentLifecycleHooks.preflightUninstallManaged()
            _ = try ZshellAutomationSkill.uninstall(
                destinations: ZshellAutomationSkill.Destination.allCases,
                force: false
            )
            try ZshellAgentIntegrations.uninstallManaged()
            try ZshellAgentLifecycleHooks.uninstallManaged()
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
        } catch {
            NSLog("zshell: failed to refresh AI automation skill: \(error)")
        }
        // A local skill edit must not prevent independent provider session hooks.
        do {
            try ZshellAgentIntegrations.installAvailable()
            try ZshellAgentLifecycleHooks.installAvailable()
        } catch {
            NSLog("zshell: failed to refresh AI support: \(error)")
        }
    }

    private func save() {
        guard !isApplyingConfig else { return }
        configMonitor.save(serializedConfig())
    }

    func backUpConfig() {
        configMonitor.backUp()
    }

    /// The config.toml representation of the current settings, from the same
    /// writer that persists `config.toml`, so an exported file is byte for
    /// byte what the app would have saved. Preferences whose defaults changed
    /// are always emitted so older files retain their meaning; other values
    /// are omitted when they match their default.
    func serializedConfig() -> String {
        var lines: [String] = []
        // Top-level like `theme`: the icon covers the whole app.
        if applicationIcon != .defaultIcon {
            lines.append("app-icon = \(TOML.quote(applicationIcon.rawValue))")
        }
        if applicationPresence != .dockOnly {
            lines.append("app-presence = \(TOML.quote(applicationPresence.rawValue))")
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
        if cursorShape != .bar {
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
        lines.append("terminal.vim-command-hints = \(vimCommandHints)")
        lines.append("terminal.shell-completions = \(shellCompletions)")
        if !shiftEnterNewline {
            lines.append("terminal.shift-enter-newline = false")
        }
        if !wrapLines {
            lines.append("editor.wrap-lines = false")
        }
        if externalEditor != .systemDefault {
            lines.append("editor.external-editor = \(TOML.quote(externalEditor.rawValue))")
        }
        lines.append("terminal.restore-history = \(restoreTerminalHistory)")
        if preserveTerminalSessions {
            lines.append("terminal.preserve-sessions = true")
        }
        if !copyOnSelect {
            lines.append("terminal.copy-on-select = false")
        }
        if focusFollowsMouse {
            lines.append("terminal.focus-follows-mouse = true")
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
        lines.append("terminal.notify-on-error = \(notifyOnError)")
        if quickTerminalSize != Self.defaultQuickTerminalSize {
            lines.append("quick-terminal.size = \(TOML.number(quickTerminalSize))")
        }
        if quickTerminalOpacity != Self.defaultQuickTerminalOpacity {
            lines.append("quick-terminal.opacity = \(TOML.number(quickTerminalOpacity))")
        }
        if quickTerminalShortcut != Self.defaultQuickTerminalShortcut {
            lines.append("quick-terminal.shortcut = \(TOML.quote(quickTerminalShortcut.persistedValue))")
        }
        if quickTerminalMode != .reuse {
            lines.append("quick-terminal.mode = \(TOML.quote(quickTerminalMode.rawValue))")
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
        if !resumeAgentConversations {
            lines.append("ai.resume-conversations = false")
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
        if !browserContentBlocking {
            lines.append("browser.content-blocking = false")
        }
        if browserFilterLists != BrowserFilterSource.defaults {
            lines.append("browser.filter-lists = \(TOML.quote(browserFilterLists))")
        }
        lines.append(contentsOf: TerminalProfile.configLines(terminalProfiles))
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
nonisolated enum TOML {
    enum Value: Equatable, Sendable {
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
    struct MalformedLine: Sendable {
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

    static func parseStrictly(
        text: String
    ) -> (values: [String: Value], malformed: MalformedLine?) {
        read(text: text, reportingMalformed: true)
    }

    /// Both entry points share one grammar so import validation accepts
    /// exactly what the launch-time reader accepts. Empty lines are kept in
    /// the split so line numbers stay true to the file.
    private static func read(
        at url: URL, reportingMalformed: Bool
    ) -> (values: [String: Value], malformed: MalformedLine?)? {
        guard let text = try? SettingsConfigFile.read(at: url) else {
            return nil
        }
        return read(text: text, reportingMalformed: reportingMalformed)
    }

    private static func read(
        text: String, reportingMalformed: Bool
    ) -> (values: [String: Value], malformed: MalformedLine?) {
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
                if table.isEmpty || table.contains("[") || table.contains("]") {
                    if reportingMalformed {
                        return (result, MalformedLine(number: index + 1, text: line))
                    }
                }
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
            guard !key.isEmpty, let value = parseValue(rawValue, strictly: reportingMalformed) else {
                if reportingMalformed {
                    return (result, MalformedLine(number: index + 1, text: line))
                }
                continue
            }
            result[table.isEmpty ? key : "\(table).\(key)"] = value
        }
        return (result, nil)
    }

    private static func parseValue(_ raw: String, strictly: Bool) -> Value? {
        if raw.hasPrefix("\"") {
            var out = ""
            var escaped = false
            for index in raw.indices.dropFirst() {
                let ch = raw[index]
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
                    let trailing = raw[raw.index(after: index)...]
                        .trimmingCharacters(in: .whitespaces)
                    guard !strictly || trailing.isEmpty || trailing.hasPrefix("#") else {
                        return nil
                    }
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
        default:
            guard let number = Double(bare), number.isFinite else { return nil }
            return .number(number)
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
