"""Run the production host installer against an isolated SSH fixture."""

import argparse
import os
from pathlib import Path
import platform
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--derived-data", type=Path, required=True)
parser.add_argument("--address", required=True)
parser.add_argument("--ssh-config", type=Path, required=True)
options = parser.parse_args()
build = options.derived_data / "Build"
products = build / "Products/Debug"
bundle = products / "zshell Debug.app"
library = bundle / "Contents/MacOS/zshell.debug.dylib"
executable = bundle / "Contents/Resources/zshell-server"

with tempfile.TemporaryDirectory(prefix="zshell-host-management-", dir="/tmp") as directory:
    temporary = Path(directory)
    probe = temporary / "HostManagementProbe"
    arguments = ["xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
                 "-target", f"{platform.machine()}-apple-macos15.6",
                 "-module-cache-path", str(temporary / "ModuleCache"),
                 "-I", str(products), "-I", str(products / "include"), "-F", str(products)]
    for modulemap in (build / "Intermediates.noindex/GeneratedModuleMaps").glob("*.modulemap"):
        arguments += ["-Xcc", f"-fmodule-map-file={modulemap}"]
    for include in ("STTextView/Sources/STObjCLandShim/include", "swift-cmark/src/include",
                    "swift-cmark/extensions/include", "swift-markdown/Sources/CAtomic/include"):
        path = ROOT / "mac/Vendor" / include
        arguments += ["-I", str(path), "-Xcc", f"-fmodule-map-file={path / 'module.modulemap'}"]
    arguments += ["-I", str(ROOT / "mac/Vendor/alacritty-bridge/include"),
                  "-I", str(ROOT / "mac/Vendor/tree-sitter/lib/include"), str(library),
                  "-Xlinker", "-rpath", "-Xlinker", str(products),
                  "-Xlinker", "-rpath", "-Xlinker", str(library.parent),
                  "-o", str(probe), str(ROOT / "mac/tests/RemoteServerManagementTests.swift")]
    subprocess.run(arguments, cwd=ROOT, check=True)
    environment = {**os.environ, "ZSHELL_SSH_CONFIG_FILE": str(options.ssh_config.resolve()),
                   "CFFIXED_USER_HOME": str(temporary / "home")}
    subprocess.run([str(probe), str(executable), str(temporary), options.address], cwd=ROOT,
                   check=True, timeout=180, env=environment)
