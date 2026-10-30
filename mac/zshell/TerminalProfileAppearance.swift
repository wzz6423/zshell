import AppKit
import GhosttyTheme

extension TerminalProfileAppearance {
    var effectiveFontFamily: String { fontFamily ?? AppSettings.shared.fontFamily }
    var effectiveFontSize: Double { fontSize ?? AppSettings.shared.fontSize }
    var effectiveCursorShape: TerminalCursorShape {
        cursorShape.flatMap(TerminalCursorShape.init(rawValue:)) ?? AppSettings.shared.cursorShape
    }
    var effectiveCursorBlinking: Bool { cursorBlinking ?? AppSettings.shared.cursorBlinking }

    func theme(dark: Bool) -> GhosttyThemeDefinition {
        (dark ? themeDark : themeLight).flatMap(Theme.definition(named:)) ?? Theme.terminal(dark: dark)
    }
}
