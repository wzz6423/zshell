"""Compile production config IO/monitor and exercise disposable file fixtures."""

from pathlib import Path
import os
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]

with tempfile.TemporaryDirectory(prefix="zshell-settings-config-") as temporary:
    directory = Path(temporary)
    binary = directory / "config-tests"
    subprocess.run([
        "xcrun", "swiftc", "-parse-as-library", "-default-isolation", "MainActor",
        "-module-cache-path", str(directory / "modules"),
        str(ROOT / "mac/zshell/SettingsConfigFile.swift"),
        str(ROOT / "mac/tests/SettingsConfigFileTests.swift"),
        "-o", str(binary),
    ], check=True, cwd=ROOT)
    subprocess.run([str(binary), str(directory)], check=True, timeout=35)

    # Keep launch-capable dependencies out of the probe while compiling the
    # complete production settings class and its file monitor.
    dependency_sources = {
        "AppTheme": ("Theme.swift", "enum AppTheme:", "/// Publishes when"),
        "QuickTerminalShortcut": ("GlobalTerminalOverlay.swift", "struct QuickTerminalShortcut:", "/// The independent quick terminal"),
        "QuickTerminalMode": ("QuickTerminalWorkspaceView.swift", "enum QuickTerminalMode:", "@MainActor\nenum QuickTerminalWorkspaceSnapshot"),
        "ApplicationPresence": ("ApplicationPresenceController.swift", "enum ApplicationPresence:", "@MainActor\nfinal class ApplicationPresenceController"),
        "BrowserFilterSource": ("BrowserContentBlocker.swift", "nonisolated struct BrowserFilterSource:", "/// One serialized pipeline"),
        "TerminalBackend": ("TerminalBackend.swift", "enum TerminalBackend:", "    /// Builds this backend's surface"),
    }
    dependencies = "import AppKit\nimport Foundation\nimport Carbon.HIToolbox\n"
    for name, (filename, start, end) in dependency_sources.items():
        source = (ROOT / "mac/zshell" / filename).read_text()
        fragment = source[source.index(start):source.index(end)]
        if name == "TerminalBackend":
            fragment += "}\nstruct TerminalBackendHighlight { let title: String; let isPositive: Bool }\n"
        dependencies += fragment + "\n"
    cursor = (ROOT / "mac/zshell/TerminalCursorSettings.swift").read_text()
    dependencies += cursor[cursor.index("enum TerminalCursorShape:"):cursor.index("    var ghosttyValue:")] + "}\n"
    source_path = directory / "SettingsDependencies.swift"
    source_path.write_text(dependencies)
    reload_binary = directory / "settings-reload-tests"
    subprocess.run([
        "xcrun", "swiftc", "-parse-as-library", "-default-isolation", "MainActor",
        "-D", "DEBUG", "-module-cache-path", str(directory / "modules"),
        str(ROOT / "mac/zshell/AppSettings.swift"),
        str(ROOT / "mac/zshell/TerminalProfiles.swift"),
        str(ROOT / "mac/zshell/TerminalEnvironmentSettings.swift"),
        str(ROOT / "mac/zshell/SettingsConfigFile.swift"),
        str(ROOT / "mac/zshell/ExternalEditor.swift"),
        str(ROOT / "mac/zshell/CommandShortcuts.swift"),
        str(ROOT / "mac/zshell/AppLocalization.swift"),
        str(ROOT / "mac/zshell/GitProxy.swift"),
        str(source_path), str(ROOT / "mac/tests/SettingsReloadTests.swift"),
        "-o", str(reload_binary),
    ], check=True, cwd=ROOT)
    home = directory / "home"
    home.mkdir()
    environment = dict(os.environ, HOME=str(home), CFFIXED_USER_HOME=str(home))
    subprocess.run([str(reload_binary), str(home)], env=environment, check=True, timeout=35)
