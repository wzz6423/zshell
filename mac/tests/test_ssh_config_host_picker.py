"""Exercise the built AppKit SSH config picker and saved project form offscreen."""

import argparse
import os
from pathlib import Path
import platform
import plistlib
import shutil
import subprocess
import tempfile
import uuid


ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--derived-data", type=Path, required=True)
    parser.add_argument("--visible", action="store_true", help="Requires a GUI lease and screen recording permission")
    parser.add_argument("--screenshots", type=Path, help="Copy visible fixture screenshots to this directory")
    options = parser.parse_args()
    build = options.derived_data.resolve() / "Build"
    products = build / "Products/Debug"
    bundle = products / "zshell Debug.app"
    library = bundle / "Contents/MacOS/zshell.debug.dylib"
    if not library.is_file():
        parser.error("Build the Debug app in the specified DerivedData first")
    with tempfile.TemporaryDirectory(prefix="zshell-ssh-picker-tests-", dir="/tmp") as directory:
        temporary = Path(directory)
        contents = temporary / "SSHPickerTests.app/Contents"
        binary = contents / "MacOS/ssh-picker-tests"
        binary.parent.mkdir(parents=True)
        (contents / "Resources").symlink_to(bundle / "Contents/Resources", target_is_directory=True)
        domain = "sh.zshell.ssh-picker-test." + uuid.uuid4().hex
        (contents / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": domain, "CFBundleExecutable": binary.name,
            "CFBundlePackageType": "APPL", "CFBundleDevelopmentRegion": "en", "LSUIElement": True,
        }))
        arguments = [
            "xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
            "-module-name", "SSHConfigHostPickerAcceptance",
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
            str(ROOT / "mac/tests/SSHConfigHostPickerTests.swift"),
            str(ROOT / "mac/tests/QuickTerminalOffscreen.swift"), "-o", str(binary),
        ]
        subprocess.run(arguments, cwd=ROOT, check=True, timeout=120)
        home = temporary / "home"
        home.mkdir()
        (home / ".ssh").mkdir()
        config = home / "form-config"
        config.write_text("Host form-host other-host\n    HostName 127.0.0.1\n")
        settings = home / ".config/zshell-dev"
        settings.mkdir(parents=True)
        (settings / "config.toml").write_text("[ai]\nenabled = false\n[terminal]\npreserve-sessions = false\n")
        environment = {key: value for key, value in os.environ.items() if not key.startswith("ZSHELL_")}
        environment.update({
            "HOME": str(home), "CFFIXED_USER_HOME": str(home), "ZDOTDIR": str(home),
            "XDG_CONFIG_HOME": str(home / ".config"), "XDG_DATA_HOME": str(home / ".local/share"),
            "ZSHELL_PTY_MUX_DIRECTORY": str(home / "pty-mux"), "ZSHELL_SSH_CONFIG_FILE": str(config),
        })
        try:
            subprocess.run([str(binary), str(home)] + (["--visible"] if options.visible else []),
                           cwd=ROOT, env=environment, check=True, timeout=60)
            if options.screenshots:
                options.screenshots.mkdir(parents=True, exist_ok=True)
                for screenshot in home.glob("ssh-*.png"):
                    shutil.copy2(screenshot, options.screenshots / screenshot.name)
        finally:
            subprocess.run(["/usr/bin/defaults", "delete", domain], stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL, check=False)


if __name__ == "__main__":
    main()
