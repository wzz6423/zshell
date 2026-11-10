"""Exercise the built app's power policy and terminal registry without opening UI."""

import os
from pathlib import Path
import platform
import plistlib
import subprocess
import tempfile
import uuid


ROOT = Path(__file__).resolve().parents[2]
BUILD = Path(os.environ["ZSHELL_TEST_DERIVED_DATA"]) / "Build"
PRODUCTS = BUILD / "Products/Debug"
CONTENTS = PRODUCTS / "zshell Debug.app/Contents"
LIBRARY = CONTENTS / "MacOS/zshell.debug.dylib"
if not LIBRARY.is_file():
    raise SystemExit("Build Debug before running the keep-awake production probe.")

with tempfile.TemporaryDirectory(prefix="zshell-keep-awake-probe-", dir="/tmp") as directory:
    temporary = Path(directory)
    contents = temporary / "KeepAwakeTests.app/Contents"
    binary = contents / "MacOS/zshell"
    binary.parent.mkdir(parents=True)
    (contents / "Resources").symlink_to(CONTENTS / "Resources", target_is_directory=True)
    domain = "sh.zshell.keep-awake-tests." + uuid.uuid4().hex
    (contents / "Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": domain, "CFBundleExecutable": "zshell",
        "CFBundlePackageType": "APPL", "LSUIElement": True,
    }))
    arguments = [
        "xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
        "-module-name", "KeepAwakeProductionProbe",
        "-target", f"{platform.machine()}-apple-macos15.6",
        "-module-cache-path", str(temporary / "ModuleCache"),
        "-I", str(PRODUCTS), "-I", str(PRODUCTS / "include"), "-F", str(PRODUCTS),
    ]
    for modulemap in (BUILD / "Intermediates.noindex/GeneratedModuleMaps").glob("*.modulemap"):
        arguments += ["-Xcc", f"-fmodule-map-file={modulemap}"]
    for include in (
        "STTextView/Sources/STObjCLandShim/include", "swift-cmark/src/include",
        "swift-cmark/extensions/include", "swift-markdown/Sources/CAtomic/include",
    ):
        path = ROOT / "mac/Vendor" / include
        arguments += ["-I", str(path), "-Xcc", f"-fmodule-map-file={path / 'module.modulemap'}"]
    arguments += [
        "-I", str(ROOT / "mac/Vendor/alacritty-bridge/include"),
        "-I", str(ROOT / "mac/Vendor/tree-sitter/lib/include"), str(LIBRARY),
        "-Xlinker", "-rpath", "-Xlinker", str(PRODUCTS),
        "-Xlinker", "-rpath", "-Xlinker", str(LIBRARY.parent),
        "-o", str(binary), str(ROOT / "mac/tests/KeepAwakeTests.swift"),
    ]
    subprocess.run(arguments, cwd=ROOT, check=True)
    try:
        for backend in ("alacritty", "ghostty"):
            home = temporary / backend
            home.mkdir()
            environment = {key: value for key, value in os.environ.items() if not key.startswith("ZSHELL_")}
            environment.update({
                "CFFIXED_USER_HOME": str(home),
                "XDG_CONFIG_HOME": str(home / ".config"),
                "XDG_DATA_HOME": str(home / ".local/share"),
                "ZSHELL_PTY_MUX_DIRECTORY": str(home / "pty-mux"),
            })
            subprocess.run([str(binary), backend, str(home)], cwd=ROOT, env=environment, check=True, timeout=45)
    finally:
        subprocess.run(["/usr/bin/defaults", "delete", domain], check=False,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
