"""Render production icon buttons and check their visible pixel centers."""

from pathlib import Path
import subprocess
import sys
import tempfile

MAC = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="zshell-icon-button-tests-") as directory:
    temporary = Path(directory)
    binary = temporary / "icon-tests"
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
                    "-default-isolation", "MainActor", "-module-cache-path", str(temporary / "modules"),
                    str(MAC / "zshell/CenteredIconButtonCell.swift"),
                    str(MAC / "tests/CenteredIconButtonTests.swift"), "-o", str(binary)], check=True)
    subprocess.run([str(binary), *sys.argv[1:]], check=True, timeout=20)
