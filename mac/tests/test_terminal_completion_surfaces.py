"""Exercise completion in both real terminal views using an isolated Debug build."""

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
app = products / "zshell Debug.app/Contents"
library = app / "MacOS/zshell.debug.dylib"
if not library.is_file():
    raise SystemExit(f"Build the Debug app in {build.parent} before running surface tests.")

with tempfile.TemporaryDirectory(prefix="zshell-completion-surfaces-", dir="/tmp") as directory:
    temporary = Path(directory)
    contents = temporary / "CompletionTests.app/Contents"
    binary = contents / "MacOS/zshell"
    binary.parent.mkdir(parents=True)
    (contents / "Resources").symlink_to(app / "Resources", target_is_directory=True)
    (contents / "Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": "sh.zshell.completion-tests." + uuid.uuid4().hex,
        "CFBundleExecutable": "zshell", "CFBundlePackageType": "APPL", "LSUIElement": True,
    }))
    arguments = [
        "xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
        "-module-name", "TerminalCompletionSurfaceProbe",
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
        "-o", str(binary), str(root / "mac/tests/TerminalCompletionSurfaceTests.swift"),
    ]
    subprocess.run(arguments, cwd=root, check=True)
    for backend in ("alacritty", "ghostty"):
        home = temporary / backend
        home.mkdir()
        environment = {key: value for key, value in os.environ.items() if not key.startswith("ZSHELL_")}
        environment.update({"HOME": str(home), "CFFIXED_USER_HOME": str(home)})
        subprocess.run([str(binary), backend], cwd=root, env=environment, check=True, timeout=60)
