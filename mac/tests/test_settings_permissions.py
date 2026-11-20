"""Exercise permission actions and app-bundle dragging without contacting macOS privacy prompts."""

from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]

with tempfile.TemporaryDirectory(prefix="zshell-permissions-", dir="/tmp") as directory:
    temporary = Path(directory)
    support = temporary / "Support.swift"
    category = (ROOT / "mac/zshell/Settings/SettingsWindowController.swift").read_text()
    category = category[category.index("enum SettingsCategory:"):category.index("    func makePane()")]
    support.write_text("""
import AppKit
import Combine
@MainActor final class AppSettings: ObservableObject { static let shared = AppSettings() }
nonisolated struct TerminalNotificationAuthorization: Sendable {
    enum Status: Sendable { case allowed, undetermined, denied }
    let status: Status
}
@MainActor final class TerminalNotificationService {
    static let shared = TerminalNotificationService()
    func readAuthorization(_ completion: @escaping @Sendable (TerminalNotificationAuthorization) -> Void) {
        preconditionFailure("The fixture must never read system notification permissions")
    }
    func requestAuthorization(_ completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        preconditionFailure("The fixture must never request system notification permissions")
    }
}
""" + category + "}\n")
    app = temporary / "zshell Debug.app/Contents"
    app.mkdir(parents=True)
    binary = temporary / "permission-probe"
    subprocess.run([
        "xcrun", "swiftc", "-parse-as-library", "-swift-version", "6", "-default-isolation", "MainActor",
        "-module-cache-path", str(temporary / "ModuleCache"), str(support),
        str(ROOT / "mac/zshell/AppLocalization.swift"),
        str(ROOT / "mac/zshell/Settings/SettingsPermission.swift"),
        str(ROOT / "mac/zshell/Settings/SettingsPermissionCoordinator.swift"),
        str(ROOT / "mac/zshell/Settings/SettingsPermissionDragHelper.swift"),
        str(ROOT / "mac/zshell/Settings/SettingsPermissionsPane.swift"),
        str(ROOT / "mac/zshell/Settings/SettingsPaneViewController.swift"),
        str(ROOT / "mac/zshell/Settings/SettingsPaneKit.swift"),
        str(ROOT / "mac/zshell/Settings/SettingsRows.swift"),
        str(ROOT / "mac/tests/SettingsPermissionTests.swift"), "-o", str(binary),
    ], cwd=ROOT, check=True)
    subprocess.run([str(binary), str(app.parent)], cwd=ROOT, check=True, timeout=45)
