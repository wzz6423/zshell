"""Exercise the Info panel's process list on both real terminal backends.

Build Debug first. Local panes always run. Pass an SSH fixture prepared like
test_remote_session_surfaces.py to also check a shared remote session's
processes through zshell-server's `processes` request.

python3 mac/tests/test_session_process_surfaces.py --derived-data /tmp/derived \
    [--address ssh://test-host --directory /home/test/project --ssh-config /tmp/ssh_config]
"""

import argparse
import os
from pathlib import Path
import platform
import subprocess
import tempfile
import uuid


ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--derived-data", type=Path,
    default=Path(os.environ.get("ZSHELL_TEST_DERIVED_DATA", ROOT / "mac/build/debug")))
parser.add_argument("--backend", choices=("alacritty", "ghostty"), action="append")
parser.add_argument("--address")
parser.add_argument("--directory")
parser.add_argument("--ssh-config", type=Path)
parser.add_argument("--server-path", default="~/.local/bin/zshell-server")
options = parser.parse_args()
if options.address and not (options.directory and options.ssh_config):
    raise SystemExit("--address needs --directory and --ssh-config")
build = options.derived_data.resolve() / "Build"
products = build / "Products/Debug"
executable = products / "zshell Debug.app/Contents/MacOS/zshell"
library = executable.parent / "zshell.debug.dylib"
if not library.is_file():
    raise SystemExit(f"Build the Debug app in {options.derived_data} before running process surface tests")

with tempfile.TemporaryDirectory(prefix="zshell-process-surfaces-", dir="/tmp") as directory:
    temporary = Path(directory)
    binary = temporary / ("zshellProcessProbe_" + uuid.uuid4().hex)
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
        "-Xlinker", "-rpath", "-Xlinker", str(library.parent), "-o", str(binary),
        str(ROOT / "mac/tests/SessionProcessSurfaceTests.swift")]
    subprocess.run(arguments, cwd=ROOT, check=True)
    for backend in options.backend or ("alacritty", "ghostty"):
        home = temporary / backend
        home.mkdir()
        environment = {key: value for key, value in os.environ.items()
            if key not in ("ZSHELL_CLI_STATE", "ZSHELL_CLI_TOKEN")}
        environment.update({"CFFIXED_USER_HOME": str(home), "HOME": str(home),
            "ZSHELL_PTY_MUX_DIRECTORY": str(home / "mux")})
        command = [str(binary), backend, str(executable)]
        if options.address:
            environment["ZSHELL_SSH_CONFIG_FILE"] = str(options.ssh_config.resolve())
            command += [options.address, options.directory, options.server_path]
        subprocess.run(command, cwd=ROOT, check=True, timeout=150, env=environment)
