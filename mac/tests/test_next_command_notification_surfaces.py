"""Exercise one-shot reminder menus with native AppKit and both real PTY backends."""

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
parser.add_argument("--derived-data", type=Path, default=os.environ.get("ZSHELL_TEST_DERIVED_DATA"))
parser.add_argument("--backend", choices=("ghostty", "alacritty"), action="append")
parser.add_argument("--gui", action="store_true", help="Acquire GUI lease before exercising actual native focus")
options = parser.parse_args()
if not options.derived_data:
    parser.error("--derived-data must point to a completed Debug build")
build = options.derived_data.resolve() / "Build"
products = build / "Products/Debug"
app = products / "zshell Debug.app"
library = app / "Contents/MacOS/zshell.debug.dylib"
if not library.is_file():
    raise SystemExit("Completed Debug app is required")

with tempfile.TemporaryDirectory(prefix="zshell-next-command-surfaces-", dir="/tmp") as directory:
    temporary = Path(directory)
    contents = temporary / "NextCommandProbe.app/Contents"
    binary = contents / "MacOS/NextCommandProbe"
    binary.parent.mkdir(parents=True)
    (contents / "Resources").symlink_to(app / "Contents/Resources", target_is_directory=True)
    domain = "sh.zshell.next-command-test." + uuid.uuid4().hex
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    info.update({"CFBundleIdentifier": domain, "CFBundleExecutable": binary.name, "LSUIElement": True})
    (contents / "Info.plist").write_bytes(plistlib.dumps(info))
    args = ["xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
            "-target", f"{platform.machine()}-apple-macos15.6",
            "-module-cache-path", str(temporary / "ModuleCache"),
            "-I", str(products), "-I", str(products / "include"), "-F", str(products)]
    for modulemap in (build / "Intermediates.noindex/GeneratedModuleMaps").glob("*.modulemap"):
        args += ["-Xcc", f"-fmodule-map-file={modulemap}"]
    for include in ("STTextView/Sources/STObjCLandShim/include", "swift-cmark/src/include",
                    "swift-cmark/extensions/include", "swift-markdown/Sources/CAtomic/include"):
        path = ROOT / "mac/Vendor" / include
        args += ["-I", str(path), "-Xcc", f"-fmodule-map-file={path / 'module.modulemap'}"]
    args += ["-I", str(ROOT / "mac/Vendor/alacritty-bridge/include"), "-I", str(ROOT / "mac/Vendor/tree-sitter/lib/include"),
             str(library), "-Xlinker", "-rpath", "-Xlinker", str(products),
             "-Xlinker", "-rpath", "-Xlinker", str(library.parent),
             str(ROOT / "mac/tests/TerminalNextCommandNotificationSurfaceTests.swift"),
             str(ROOT / "mac/tests/QuickTerminalOffscreen.swift"), "-o", str(binary)]
    subprocess.run(args, cwd=ROOT, check=True)
    for backend in options.backend or ("alacritty", "ghostty"):
        home = temporary / backend
        home.mkdir()
        (home / ".zshenv").write_text('export HOME="$CFFIXED_USER_HOME"\n')
        (home / ".zprofile").write_text("")
        (home / ".zshrc").write_text("PROMPT='NATIVE-NEXT> '; RPROMPT=''; bindkey -e\n")
        (home / ".zlogin").write_text("")
        (home / "tmp").mkdir()
        environment = {key: value for key, value in os.environ.items() if not key.startswith("ZSHELL_")}
        environment.update({"HOME": str(home), "CFFIXED_USER_HOME": str(home), "ZDOTDIR": str(home),
                            "TMPDIR": str(home / "tmp"), "ZSHELL_PTY_MUX_DIRECTORY": str(home / "mux")})
        try:
            subprocess.run([str(binary), str(home), backend] + (["--gui"] if options.gui else []),
                           cwd=ROOT, env=environment, check=True, timeout=120)
        finally:
            subprocess.run(["defaults", "delete", domain], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            preferences = Path.home() / "Library/Preferences" / (domain + ".plist")
            if preferences.exists() and plistlib.loads(preferences.read_bytes()) == {}:
                preferences.unlink()
