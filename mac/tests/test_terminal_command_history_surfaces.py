"""Exercise history through the compiled Debug app, AppKit windows and PTYs.

Set ZSHELL_TEST_DERIVED_DATA to an isolated Debug build and acquire the shared
feature build/GUI lease before running. HOME, preferences, shells and binaries
are disposable; no installed Zshell process or personal shell history is used.
"""
import os
from pathlib import Path
import platform
import plistlib
import subprocess
import tempfile
import uuid


root = Path(__file__).resolve().parents[2]
build = Path(os.environ.get("ZSHELL_TEST_DERIVED_DATA", root / "mac/build/debug")) / "Build"
products = build / "Products/Debug"
bundle = products / "zshell Debug.app"
library = bundle / "Contents/MacOS/zshell.debug.dylib"
if not library.is_file():
    raise SystemExit(f"Build the Debug app in {build.parent} before running history surface tests.")

with tempfile.TemporaryDirectory(prefix="zshell-command-history-tests-", dir="/tmp") as directory:
    temporary = Path(directory)
    arguments = [
        "xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
        "-module-name", "CommandHistoryAcceptance",
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
        "-I", str(root / "mac/Vendor/tree-sitter/lib/include"),
        str(library), "-Xlinker", "-rpath", "-Xlinker", str(products),
        "-Xlinker", "-rpath", "-Xlinker", str(library.parent),
    ]

    suites = [
        ("TerminalCommandHistoryTests", "store"),
        ("TerminalCommandHistoryPanelTests", "panel"),
        ("TerminalCommandHistorySurfaceTests", "alacritty"),
        ("TerminalCommandHistorySurfaceTests", "ghostty"),
    ]
    requested = os.environ.get("ZSHELL_TEST_COMMAND_HISTORY_MODE")
    if requested:
        suites = [suite for suite in suites if suite[1] == requested]
        if not suites:
            raise SystemExit(f"Unknown command history test mode: {requested}")
    for source, mode in suites:
        home = temporary / mode
        home.mkdir()
        contents = temporary / f"CommandHistory-{mode}.app/Contents"
        binary = contents / "MacOS/zshell"
        binary.parent.mkdir(parents=True)
        (contents / "Resources").symlink_to(bundle / "Contents/Resources", target_is_directory=True)
        domain = "sh.zshell.command-history-test." + uuid.uuid4().hex
        (contents / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": domain, "CFBundleExecutable": binary.name,
            "CFBundlePackageType": "APPL", "CFBundleDevelopmentRegion": "en",
            "LSUIElement": True,
        }))
        subprocess.run(arguments + [str(root / "mac/tests" / f"{source}.swift"), "-o", str(binary)],
                       cwd=root, check=True)
        environment = {key: value for key, value in os.environ.items() if not key.startswith("ZSHELL_")}
        environment.update({
            "HOME": str(home), "CFFIXED_USER_HOME": str(home), "ZDOTDIR": str(home),
            "XDG_CONFIG_HOME": str(home / ".config"), "XDG_DATA_HOME": str(home / ".local/share"),
            "ZSHELL_PTY_MUX_DIRECTORY": str(home / "pty-mux"),
        })
        fixture = home / "fixture"
        fixture.mkdir()
        try:
            subprocess.run([str(binary), str(fixture), mode], cwd=root, env=environment,
                           check=True, timeout=120)
        finally:
            subprocess.run(["/usr/bin/defaults", "delete", domain],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
