"""Read actual IOSurface pixels from both production backends in hidden windows.

python3 mac/tests/test_terminal_padding_color.py --derived-data /tmp/derived-data
Fixture homes, preferences and probe binaries are disposable. Screenshots can be
retained with --evidence-directory; no installed app or personal shell is used.
"""

import argparse
import os
from pathlib import Path
import platform
import plistlib
import subprocess
import tempfile
import uuid


ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--derived-data", required=True, type=Path)
parser.add_argument("--evidence-directory", type=Path)
parser.add_argument("--backend", choices=("ghostty", "alacritty"))
parser.add_argument("--quick-terminal", action="store_true", help="Exercise pinned fresh/reusable Quick Terminal splits")
parser.add_argument("--visible", action="store_true", help="Show Quick Terminal only while the isolated GUI slot is available")
parser.add_argument("--hold-seconds", type=float, default=0, help="Hold the first pinned Quick Terminal for manual inspection")
parser.add_argument("--show-settings", action="store_true", help="Open native Appearance settings during a visible hold")
options = parser.parse_args()
if (options.visible or options.hold_seconds) and not options.quick_terminal:
    parser.error("--visible and --hold-seconds require --quick-terminal")
if options.show_settings and (not options.visible or options.hold_seconds <= 0):
    parser.error("--show-settings requires --visible and a positive --hold-seconds")
build = options.derived_data / "Build"
products = build / "Products/Debug"
application = products / "zshell Debug.app"
library = application / "Contents/MacOS/zshell.debug.dylib"
if not library.is_file():
    raise SystemExit(f"Build the Debug app in {options.derived_data} first")

with tempfile.TemporaryDirectory(prefix="zshell-padding-probe-", dir="/tmp") as directory:
    temporary = Path(directory)
    domain = "sh.zshell.padding-tests." + uuid.uuid4().hex
    contents = temporary / "PaddingProbe.app/Contents"
    binary = contents / "MacOS/PaddingProbe"
    binary.parent.mkdir(parents=True)
    (contents / "Resources").symlink_to(application / "Contents/Resources", target_is_directory=True)
    metadata = plistlib.loads((application / "Contents/Info.plist").read_bytes())
    metadata.update({
        "CFBundleIdentifier": domain, "CFBundleExecutable": binary.name,
        "CFBundlePackageType": "APPL", "CFBundleDevelopmentRegion": "en", "LSUIElement": True,
    })
    (contents / "Info.plist").write_bytes(plistlib.dumps(metadata))
    arguments = [
        "xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
        "-target", f"{platform.machine()}-apple-macos15.6",
        "-module-cache-path", str(temporary / "ModuleCache"),
        "-I", str(products), "-I", str(products / "include"), "-F", str(products),
    ]
    for modulemap in (build / "Intermediates.noindex/GeneratedModuleMaps").glob("*.modulemap"):
        arguments += ["-Xcc", f"-fmodule-map-file={modulemap}"]
    for include in (
        "STTextView/Sources/STObjCLandShim/include", "swift-cmark/src/include",
        "swift-cmark/extensions/include", "swift-markdown/Sources/CAtomic/include",
    ):
        path = ROOT / "mac/Vendor" / include
        arguments += ["-I", str(path), "-Xcc", f"-fmodule-map-file={path / 'module.modulemap'}"]
    arguments += [
        "-I", str(ROOT / "mac/Vendor/alacritty-bridge/include"),
        "-I", str(ROOT / "mac/Vendor/tree-sitter/lib/include"), str(library),
        "-Xlinker", "-rpath", "-Xlinker", str(products),
        "-Xlinker", "-rpath", "-Xlinker", str(library.parent),
        str(ROOT / "mac/tests/TerminalPaddingColorSurfaceTests.swift"),
        str(ROOT / "mac/tests/QuickTerminalPaddingColorTests.swift"),
        str(ROOT / "mac/tests/QuickTerminalOffscreen.swift"), "-o", str(binary),
    ]
    subprocess.run(arguments, cwd=ROOT, check=True)
    try:
        for backend in ([options.backend] if options.backend else ("ghostty", "alacritty")):
            home = temporary / backend
            home.mkdir()
            config = home / ".config/zshell-dev/config.toml"
            config.parent.mkdir(parents=True)
            config.write_text("ai.enabled = false\nterminal.preserve-sessions = false\n")
            environment = {key: value for key, value in os.environ.items() if not key.startswith("ZSHELL_")}
            environment.update({"HOME": str(home), "CFFIXED_USER_HOME": str(home),
                                "ZDOTDIR": str(home), "ZSHELL_PTY_MUX_DIRECTORY": str(home / "mux")})
            if options.quick_terminal:
                environment.update({"ZSHELL_PADDING_TEST_VISIBLE": "1" if options.visible else "0",
                                    "ZSHELL_PADDING_TEST_HOLD_SECONDS": str(options.hold_seconds),
                                    "ZSHELL_PADDING_TEST_SHOW_SETTINGS": "1" if options.show_settings else "0"})
            command = [
                str(binary), backend, str(ROOT / "mac/tests/fixtures/terminal_padding_color.py"),
                str(home), str(options.evidence_directory.resolve()) if options.evidence_directory else "",
            ]
            if options.quick_terminal:
                command.append("quick-terminal")
            subprocess.run(command, cwd=ROOT, env=environment, check=True, timeout=120 + max(0, options.hold_seconds))
    finally:
        subprocess.run(["/usr/bin/defaults", "delete", domain],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
