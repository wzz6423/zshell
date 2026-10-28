"""Run the Debug app's production relay, real surfaces and SSH against a test host.

Build the Debug app in isolated DerivedData, install zshell-server on a dedicated
macOS/Linux SSH host, and provide a private OpenSSH configuration with a trusted
host key and test identity. No user SSH files or live app windows are changed.

python3 mac/tests/test_remote_session_surfaces.py --derived-data /tmp/derived \
    --address ssh://test-host --directory /home/test/project --ssh-config /tmp/ssh_config
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
parser.add_argument("--derived-data", type=Path, default=Path(os.environ.get("ZSHELL_TEST_DERIVED_DATA", ROOT / "mac/build/debug")))
parser.add_argument("--address", required=True)
parser.add_argument("--directory", required=True)
parser.add_argument("--ssh-config", type=Path, required=True)
parser.add_argument("--backend", choices=("alacritty", "ghostty"), action="append")
options = parser.parse_args()
build = options.derived_data / "Build"
products = build / "Products/Debug"
executable = products / "zshell Debug.app/Contents/MacOS/zshell"
library = executable.parent / "zshell.debug.dylib"
if not library.is_file():
    raise SystemExit(f"Build the Debug app in {options.derived_data} first")

with tempfile.TemporaryDirectory(prefix="zshell-remote-surfaces-", dir="/tmp") as directory:
    temporary = Path(directory)
    binary = temporary / ("zshellRemoteProbe_" + uuid.uuid4().hex)
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
                  "-Xlinker", "-rpath", "-Xlinker", str(library.parent), "-o", str(binary)]
    ssh_source = temporary / "RemoteSSHTests.swift"
    ssh_source.write_text("@testable import zshell\n" + (ROOT / "mac/tests/RemoteSSHTests.swift").read_text().replace("static func main()", "@MainActor static func main()"))
    subprocess.run(arguments + [str(ssh_source)], cwd=ROOT, check=True)
    subprocess.run([str(binary)], cwd=ROOT, check=True, timeout=30,
                   env={**os.environ, "CFFIXED_USER_HOME": directory})
    subprocess.run(arguments + [str(ROOT / "mac/tests/RemoteSessionSurfaceTests.swift")], cwd=ROOT, check=True)
    for backend in options.backend or ("alacritty", "ghostty"):
        home = temporary / backend
        home.mkdir()
        environment = {key: value for key, value in os.environ.items() if key not in ("ZSHELL_CLI_STATE", "ZSHELL_CLI_TOKEN")}
        environment.update({"CFFIXED_USER_HOME": str(home), "HOME": str(home),
                            "ZSHELL_SSH_CONFIG_FILE": str(options.ssh_config.resolve()),
                            "ZSHELL_PTY_MUX_DIRECTORY": str(home / "mux")})
        subprocess.run([str(binary), backend, str(executable), options.address, options.directory],
                       cwd=ROOT, check=True, timeout=120, env=environment)
