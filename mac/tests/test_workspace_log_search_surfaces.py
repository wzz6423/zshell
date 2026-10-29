"""Test workspace log search against real PTYs and both terminal backends."""
import os
from pathlib import Path
import platform
import plistlib
import subprocess
import tempfile
import uuid

root = Path(__file__).resolve().parents[2]
build = Path(os.environ["ZSHELL_TEST_DERIVED_DATA"]) / "Build"
products = build / "Products/Debug"
bundle = products / "zshell Debug.app"
library = bundle / "Contents/MacOS/zshell.debug.dylib"
if not library.is_file():
    raise SystemExit(f"Build the Debug app in {build.parent} first.")

with tempfile.TemporaryDirectory(prefix="zshell-log-surfaces-", dir="/tmp") as temporary:
    directory = Path(temporary)
    contents = directory / "LogTests.app/Contents"
    binary = contents / "MacOS/zshell"
    binary.parent.mkdir(parents=True)
    (contents / "Resources").symlink_to(bundle / "Contents/Resources", target_is_directory=True)
    (contents / "Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": "sh.zshell.log-tests." + uuid.uuid4().hex,
        "CFBundleExecutable": binary.name, "CFBundlePackageType": "APPL",
        "CFBundleDevelopmentRegion": "en", "LSUIElement": True,
    }))
    arguments = [
        "xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
        "-module-name", "ZshellWorkspaceLogSearchTests",
        "-target", f"{platform.machine()}-apple-macos15.6",
        "-module-cache-path", str(directory / "ModuleCache"),
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
        str(root / "mac/tests/WorkspaceLogSearchSurfaceTests.swift"), "-o", str(binary),
    ]
    subprocess.run(arguments, cwd=root, check=True)
    for backend in ("alacritty", "ghostty"):
        home = directory / backend
        home.mkdir()
        subprocess.run([
            str(binary), backend, str(root / "mac/tests/fixtures/workspace-log-output.py"),
        ], cwd=root, check=True, timeout=90, env={**os.environ, "HOME": str(home),
                                                    "CFFIXED_USER_HOME": str(home)})
