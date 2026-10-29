"""Compile production profile matching/config and inspect real kernel metadata."""

from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix="zshell-profiles-model-") as directory:
    temporary = Path(directory)
    source = (ROOT / "mac/zshell/AppSettings.swift").read_text()
    toml = temporary / "TOML.swift"
    toml.write_text("import Foundation\n" + source[source.index("nonisolated enum TOML {"):])
    binary = temporary / "profile-tests"
    subprocess.run([
        "xcrun", "swiftc", "-parse-as-library", "-default-isolation", "MainActor",
        "-module-cache-path", str(temporary / "modules"),
        str(ROOT / "mac/zshell/TerminalProfiles.swift"),
        str(ROOT / "mac/zshell/TerminalEnvironmentSettings.swift"),
        str(ROOT / "mac/zshell/TerminalStartupCommand.swift"),
        str(ROOT / "mac/zshell/ProcessWorkingDirectory.swift"),
        str(ROOT / "mac/zshell/SettingsConfigFile.swift"),
        str(toml), str(ROOT / "mac/tests/TerminalProfilesTests.swift"),
        "-o", str(binary),
    ], check=True, cwd=ROOT)
    subprocess.run([str(binary)], check=True, cwd=ROOT, timeout=30)
