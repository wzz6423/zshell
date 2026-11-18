"""Verify the compiled app's read-only gate with native views and real PTYs.

Set ZSHELL_TEST_DERIVED_DATA to a Debug build and acquire the build/GUI lease
before running. Each backend uses a disposable HOME, preferences domain and
PTY fixture; the launcher removes all probe binaries and files.
"""

import os
import json
from pathlib import Path
import platform
import plistlib
import subprocess
import tempfile
import uuid


root = Path(__file__).resolve().parents[2]
build = Path(os.environ.get("ZSHELL_TEST_DERIVED_DATA", root / "mac/build/debug")).resolve() / "Build"
products = build / "Products/Debug"
bundle = products / "zshell Debug.app"
library = bundle / "Contents/MacOS/zshell.debug.dylib"
if not library.is_file():
    raise SystemExit(f"Build the Debug app in {build.parent} before running read-only checks.")

with tempfile.TemporaryDirectory(prefix="zshell-read-only-tests-", dir="/tmp") as directory:
    temporary = Path(directory)
    arguments = [
        "xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
        "-module-name", "TerminalReadOnlyAcceptance",
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
        path = root / "mac/Vendor" / include
        arguments += ["-I", str(path), "-Xcc", f"-fmodule-map-file={path / 'module.modulemap'}"]
    arguments += [
        "-I", str(root / "mac/Vendor/alacritty-bridge/include"),
        "-I", str(root / "mac/Vendor/tree-sitter/lib/include"), str(library),
        "-Xlinker", "-rpath", "-Xlinker", str(products),
        "-Xlinker", "-rpath", "-Xlinker", str(library.parent),
    ]
    contents = temporary / "ReadOnlyTests.app/Contents"
    binary = contents / "MacOS/zshell"
    binary.parent.mkdir(parents=True)
    (contents / "Resources").symlink_to(bundle / "Contents/Resources", target_is_directory=True)
    domain = "sh.zshell.read-only-tests." + uuid.uuid4().hex
    information = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
    information.update({
        "CFBundleIdentifier": domain, "CFBundleExecutable": "zshell",
        "CFBundlePackageType": "APPL", "CFBundleDevelopmentRegion": "en",
        "LSUIElement": True, "SUEnableAutomaticChecks": False,
    })
    (contents / "Info.plist").write_bytes(plistlib.dumps(information))
    subprocess.run(arguments + [str(root / "mac/tests/TerminalReadOnlySurfaceTests.swift"),
                               "-o", str(binary)], cwd=root, check=True)
    modes = ("alacritty", "ghostty")
    requested = os.environ.get("ZSHELL_TEST_READ_ONLY_BACKEND")
    if requested:
        if requested not in modes:
            raise SystemExit(f"Unknown read-only backend: {requested}")
        modes = (requested,)
    try:
        for mode in modes:
            home = temporary / mode
            home.mkdir()
            (home / "tmp").mkdir()
            fixture = home / "fixture"
            fixture.mkdir()
            keys = ("Read Only", "Unlock Terminal", "This terminal is read only. Unlock it before sending input.")
            strings = json.loads((root / "mac/zshell/Localizable.xcstrings").read_text())["strings"]
            translations = {language: {key: strings[key]["localizations"][language]["stringUnit"]["value"] for key in keys}
                            for language in strings[keys[0]]["localizations"]}
            (fixture / "translations.json").write_text(json.dumps(translations, ensure_ascii=False))
            config = home / ".config/zshell-dev/config.toml"
            config.parent.mkdir(parents=True)
            config.write_text('ai.enabled = false\nquick-terminal.enabled = false\n'
                              'terminal.preserve-sessions = false\nterminal.restore-history = false\n')
            environment = {key: value for key, value in os.environ.items() if not key.startswith("ZSHELL_")}
            environment.update({
                "HOME": str(home), "CFFIXED_USER_HOME": str(home), "ZDOTDIR": str(home),
                "XDG_CONFIG_HOME": str(home / ".config"), "XDG_DATA_HOME": str(home / ".local/share"),
                "TMPDIR": str(home / "tmp") + "/",
                "ZSHELL_PTY_MUX_DIRECTORY": str(home / "pty-mux"),
                "ZSHELL_TEST_EXECUTABLE": str(bundle / "Contents/MacOS/zshell"),
            })
            subprocess.run([str(binary), mode, str(fixture),
                            str(root / "mac/tests/fixtures/terminal_read_only.py")],
                           cwd=root, env=environment, check=True, timeout=150)
    finally:
        subprocess.run(["/usr/bin/defaults", "delete", domain],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
