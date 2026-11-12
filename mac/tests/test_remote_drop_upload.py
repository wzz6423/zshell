"""Exercise production remote paste and native file drops through disposable SSH.

Build Debug in isolated DerivedData first. Both terminal backends use the real
OpenSSH transport and bundled server. No user SSH files or app windows change.
"""

import argparse
import os
from pathlib import Path
import platform
import shlex
import signal
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
from test_browser_remote_routing import Fixture, ROOT


CANCELLATION_PROBE = r'''
import Foundation
@testable import zshell

@main struct RemotePasteCancellationProbe {
    @MainActor static func main() async throws {
        let local = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let ready = local.appendingPathComponent("ready")
        let remoteTemporary = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let endpoint = try SSHEndpoint(host: "127.0.0.1", port: Int(CommandLine.arguments[3]))
        let first = local.appendingPathComponent("first-completed-\(UUID().uuidString).bin")
        let second = local.appendingPathComponent("second.bin")
        let payload = Data(repeating: 65, count: 64 * 1024)
        try payload.write(to: first)
        try Data(repeating: 66, count: 256 * 1024).write(to: second)
        let task = Task.detached {
            try RemotePasteUpload.uploadSSH(.files([first, second]), endpoint: endpoint,
                                           authentication: .agent, credentialID: nil)
        }
        do {
            let deadline = Date().addingTimeInterval(8)
            while !FileManager.default.fileExists(atPath: ready.path), Date() < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            guard FileManager.default.fileExists(atPath: ready.path) else {
                throw NSError(domain: "RemotePasteCancellation", code: 1)
            }
            let uploadedName = "00-" + first.lastPathComponent
            let directories = try FileManager.default.contentsOfDirectory(at: remoteTemporary,
                includingPropertiesForKeys: nil).filter {
                    $0.lastPathComponent.hasPrefix("zshell-paste-")
                        && FileManager.default.fileExists(atPath: $0.appendingPathComponent(uploadedName).path)
                }
            guard directories.count == 1,
                  try Data(contentsOf: directories[0].appendingPathComponent(uploadedName)) == payload else {
                throw NSError(domain: "RemotePasteCancellation", code: 2)
            }
            print("PASS first file completed before second upload cancellation")
            task.cancel()
            do {
                _ = try await task.value
                throw NSError(domain: "RemotePasteCancellation", code: 3)
            } catch is CancellationError {}
            guard !FileManager.default.fileExists(atPath: directories[0].path) else {
                throw NSError(domain: "RemotePasteCancellation", code: 4)
            }
            print("PASS cancelled SSH upload removes its complete temporary directory")
        } catch {
            task.cancel()
            _ = try? await task.value
            throw error
        }
    }
}
'''


def verify_cancellation(directory, fixture, derived_data):
    temporary = directory / "cancellation"
    temporary.mkdir()
    remote_temporary = subprocess.run(
        ["/usr/bin/ssh", "-F", str(fixture.config), "-p", str(fixture.ssh_port), fixture.host,
         'printf "%s" "${TMPDIR:-/tmp}"'], cwd=ROOT, check=True, capture_output=True, text=True, timeout=5
    ).stdout
    ready = temporary / "ready"
    gate = temporary / "gate.sh"
    gate.write_text("""#!/bin/sh
set -eu
count=0
if [ -f "$1" ]; then count=$(cat "$1"); fi
count=$((count + 1))
printf '%s\\n' "$count" > "$1"
if [ "$count" -eq 3 ]; then
  printf '%s\\n' "$$" > "$2"
  exec /bin/sleep 15
fi
""")
    # Connections create the directory, finish file one, then begin file two.
    local_command = shlex.join(["/bin/sh", str(gate), str(temporary / "count"), str(ready)])
    with fixture.config.open("a") as configuration:
        configuration.write("\n  PermitLocalCommand yes\n  LocalCommand " + local_command + " >/dev/null 2>&1\n")
    products = derived_data / "Build/Products/Debug"
    library = products / "zshell Debug.app/Contents/MacOS/zshell.debug.dylib"
    source = temporary / "CancellationProbe.swift"
    source.write_text(CANCELLATION_PROBE)
    binary = temporary / "cancellation-probe"
    arguments = ["xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
                 "-target", f"{platform.machine()}-apple-macos15.6",
                 "-module-cache-path", str(temporary / "ModuleCache"),
                 "-I", str(products), "-I", str(products / "include"), "-F", str(products)]
    for modulemap in (derived_data / "Build/Intermediates.noindex/GeneratedModuleMaps").glob("*.modulemap"):
        arguments += ["-Xcc", f"-fmodule-map-file={modulemap}"]
    for include in ("STTextView/Sources/STObjCLandShim/include", "swift-cmark/src/include",
                    "swift-cmark/extensions/include", "swift-markdown/Sources/CAtomic/include"):
        path = ROOT / "mac/Vendor" / include
        arguments += ["-I", str(path), "-Xcc", f"-fmodule-map-file={path / 'module.modulemap'}"]
    arguments += ["-I", str(ROOT / "mac/Vendor/alacritty-bridge/include"),
                  "-I", str(ROOT / "mac/Vendor/tree-sitter/lib/include"), str(library),
                  "-Xlinker", "-rpath", "-Xlinker", str(products),
                  "-Xlinker", "-rpath", "-Xlinker", str(library.parent), str(source), "-o", str(binary)]
    environment = {key: value for key, value in os.environ.items() if not key.startswith("ZSHELL_")}
    environment.update({"CFFIXED_USER_HOME": str(temporary), "HOME": str(temporary),
                        "ZSHELL_SSH_CONFIG_FILE": str(fixture.config), "ZSHELL_SSH_AGENT_RESOLVED": "1"})
    try:
        subprocess.run(arguments, cwd=ROOT, check=True)
        subprocess.run([str(binary), str(temporary), remote_temporary, str(fixture.ssh_port)],
                       cwd=ROOT, env=environment, check=True, timeout=20)
        assert (temporary / "count").read_text().strip() == "4", "cleanup opened its own SSH connection"
    finally:
        if ready.is_file():
            try:
                os.kill(int(ready.read_text().strip()), signal.SIGTERM)
            except ProcessLookupError:
                pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--derived-data", type=Path, required=True)
    parser.add_argument("--backend", choices=("alacritty", "ghostty"), action="append")
    parser.add_argument("--cancellation-only", action="store_true", help="Run only cancelled SSH upload cleanup")
    options = parser.parse_args()
    server = options.derived_data.resolve() / "Build/Products/Debug/zshell Debug.app/Contents/Resources/zshell-server"
    if not server.is_file():
        raise SystemExit(f"Build Debug in {options.derived_data} first")
    with tempfile.TemporaryDirectory(prefix="zshell-remote-drop-", dir="/tmp") as temporary:
        directory = Path(temporary)
        ssh = directory / "ssh"
        ssh.mkdir()
        fixture = Fixture(ssh)
        daemon = None
        try:
            fixture.__enter__()
            if options.cancellation_only:
                verify_cancellation(directory, fixture, options.derived_data.resolve())
                return
            home = directory / "remote-home"
            home.mkdir()
            (home / ".zshenv").write_text("HISTFILE=/dev/null\n")
            project = home / "project"
            project.mkdir()
            state = directory / "rs"
            wrapper = directory / "zshell-server"
            wrapper.write_text("#!/bin/sh\nexport HOME=" + shlex.quote(str(home))
                               + " ZDOTDIR=" + shlex.quote(str(home))
                               + "\nexec " + shlex.join([str(server), "--state", str(state)]) + ' "$@"\n')
            wrapper.chmod(0o755)
            environment = {**os.environ, "HOME": str(home), "ZDOTDIR": str(home)}
            with (directory / "server.log").open("wb") as log:
                daemon = subprocess.Popen([str(server), "serve", "--state", str(state)],
                                          cwd=ROOT, env=environment, stdout=log, stderr=log)
            arguments = [sys.executable, str(ROOT / "mac/tests/test_remote_session_surfaces.py"),
                         "--derived-data", str(options.derived_data.resolve()), "--address", fixture.address,
                         "--directory", str(project), "--ssh-config", str(fixture.config),
                         "--server-path", str(wrapper), "--paste-only"]
            for backend in options.backend or ():
                arguments += ["--backend", backend]
            subprocess.run(arguments, cwd=ROOT, check=True, timeout=400)
        finally:
            if daemon is not None:
                subprocess.run([str(server), "stop", "--state", str(directory / "rs")],
                               capture_output=True, timeout=10)
                if daemon.poll() is None:
                    daemon.terminate()
                    try:
                        daemon.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        daemon.kill()
                        daemon.wait()
            fixture.__exit__()


if __name__ == "__main__":
    main()
