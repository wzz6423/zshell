"""Exercise native notification UI and both terminal backends in disposable, offscreen fixtures."""
import os
from pathlib import Path
import platform
import plistlib
import shutil
import subprocess
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[2]
build = Path(os.environ["ZSHELL_TEST_DERIVED_DATA"]) / "Build"
products = build / "Products/Debug"
app = products / "zshell Debug.app"
library = app / "Contents/MacOS/zshell.debug.dylib"
if not library.is_file():
    raise SystemExit("An isolated Debug build is required")

with tempfile.TemporaryDirectory(prefix="zshell-notification-surface-", dir="/tmp") as directory:
    temporary = Path(directory)
    probe = temporary / "NotificationProbe"
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
    args += ["-I", str(ROOT / "mac/Vendor/alacritty-bridge/include"),
             "-I", str(ROOT / "mac/Vendor/tree-sitter/lib/include"), str(library),
             "-Xlinker", "-rpath", "-Xlinker", str(products),
             "-Xlinker", "-rpath", "-Xlinker", str(library.parent),
             str(ROOT / "mac/tests/TerminalNotificationSurfaceTests.swift"),
             str(ROOT / "mac/tests/QuickTerminalOffscreen.swift"), "-o", str(probe)]
    subprocess.run(args, cwd=ROOT, check=True)
    requested_backend = os.environ.get("ZSHELL_TEST_BACKEND")
    if requested_backend and requested_backend not in ("alacritty", "ghostty"):
        raise SystemExit("Unknown backend")
    for backend in (requested_backend,) if requested_backend else ("alacritty", "ghostty"):
        bundle = temporary / f"NotificationTests-{backend}.app/Contents"
        binary = bundle / "MacOS/NotificationTests"
        binary.parent.mkdir(parents=True)
        shutil.copy2(probe, binary)
        (bundle / "Resources").symlink_to(app / "Contents/Resources")
        domain = "sh.zshell.notification-test." + uuid.uuid4().hex
        (bundle / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": domain, "CFBundleExecutable": binary.name,
            "CFBundlePackageType": "APPL", "LSUIElement": True,
        }))
        home = temporary / backend
        home.mkdir()
        (home / "tmp").mkdir()
        startup = 'export HOME="$CFFIXED_USER_HOME"\n'
        (home / ".zshenv").write_text(startup)
        (home / ".zshrc").write_text("")
        (home / ".zprofile").write_text("")
        (home / ".zlogin").write_text("")
        environment = {key: value for key, value in os.environ.items() if not key.startswith("ZSHELL_")}
        environment.update({"HOME": str(home), "CFFIXED_USER_HOME": str(home), "ZDOTDIR": str(home),
                            "ZSHELL_PTY_MUX_DIRECTORY": str(home / "mux"), "TMPDIR": str(home / "tmp")})
        try:
            subprocess.run([str(binary), backend, str(home)], cwd=ROOT, env=environment, check=True, timeout=90)
        finally:
            subprocess.run(["defaults", "delete", domain], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            preferences = Path.home() / "Library/Preferences" / (domain + ".plist")
            if preferences.exists() and plistlib.loads(preferences.read_bytes()) == {}:
                preferences.unlink()
        screenshot = home / "panel.png"
        if screenshot.is_file() and os.environ.get("ZSHELL_TEST_SCREENSHOT_DIR"):
            target = Path(os.environ["ZSHELL_TEST_SCREENSHOT_DIR"]) / f"notification-{backend}.png"
            target.write_bytes(screenshot.read_bytes())
