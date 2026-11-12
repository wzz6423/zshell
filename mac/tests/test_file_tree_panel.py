"""Replay production file-tree interactions in disposable offscreen Debug apps."""

import argparse
import os
from pathlib import Path
import platform
import plistlib
import shutil
import signal
import subprocess
import tempfile
import uuid


ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--derived-data", type=Path, required=True)
    parser.add_argument("--backend", choices=("libghostty", "alacritty"))
    options = parser.parse_args()
    build = options.derived_data.resolve() / "Build"
    products = build / "Products/Debug"
    library = products / "zshell Debug.app/Contents/MacOS/zshell.debug.dylib"
    if not library.is_file():
        parser.error(f"Missing completed Debug build: {library}")
    with tempfile.TemporaryDirectory(prefix="zshell-file-tree-panel-") as directory:
        temporary = Path(directory).resolve()
        binary = temporary / "file-tree-panel-tests"
        arguments = ["xcrun", "swiftc", "-parse-as-library", "-swift-version", "5", "-warnings-as-errors",
                     "-target", f"{platform.machine()}-apple-macos15.6",
                     "-module-cache-path", str(temporary / "modules"), "-I", str(products),
                     "-I", str(products / "include"), "-F", str(products)]
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
                      str(ROOT / "mac/tests/FileTreePanelTests.swift"),
                      str(ROOT / "mac/tests/QuickTerminalOffscreen.swift"), "-o", str(binary)]
        subprocess.run(arguments, cwd=ROOT, check=True, timeout=120)
        for backend in (options.backend,) if options.backend else ("libghostty", "alacritty"):
            contents = temporary / f"FileTreeTests-{backend}.app/Contents"
            executable = contents / "MacOS/FileTreeTests"
            executable.parent.mkdir(parents=True)
            shutil.copy2(binary, executable)
            domain = "sh.zshell.file-tree-test." + uuid.uuid4().hex
            info = plistlib.loads((library.parents[1] / "Info.plist").read_bytes())
            info.update(CFBundleIdentifier=domain, CFBundleExecutable=executable.name,
                        CFBundleName="Zshell File Tree Test", CFBundleDisplayName="Zshell File Tree Test",
                        LSBackgroundOnly=True, SUEnableAutomaticChecks=False)
            (contents / "Info.plist").write_bytes(plistlib.dumps(info))
            (contents / "Resources").symlink_to(library.parents[1] / "Resources", target_is_directory=True)
            fixture = temporary / backend
            fixture.mkdir()
            (fixture / "tmp").mkdir()
            configuration = fixture / ".config/zshell-dev/config.toml"
            configuration.parent.mkdir(parents=True)
            configuration.write_text(f'ai.enabled = false\nterminal.backend = "{backend}"\n'
                                     'terminal.preserve-sessions = false\nterminal.restore-history = false\n'
                                     'terminal.startup-program = "/bin/sleep 60"\nquick-terminal.enabled = false\n')
            for name in (".zshenv", ".zshrc", ".zprofile", ".zlogin"):
                (fixture / name).write_text("")
            environment = {key: value for key, value in os.environ.items() if not key.startswith("ZSHELL_")}
            environment.update(CFFIXED_USER_HOME=str(fixture), ZDOTDIR=str(fixture), TMPDIR=str(fixture / "tmp"),
                               ZSHELL_PTY_MUX_DIRECTORY=str(fixture / "mux"), ZSHELL_SSH_AGENT_RESOLVED="1")
            process = subprocess.Popen([str(executable), backend, str(fixture)], cwd=temporary,
                                       env=environment, start_new_session=True)
            try:
                result = process.wait(timeout=30)
                if result:
                    raise subprocess.CalledProcessError(result, process.args)
            finally:
                # Scope cleanup to this fixture's process group and mux executables.
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                process.wait()
                commands = subprocess.run(["ps", "-axo", "pid=,command="], capture_output=True,
                                          text=True, check=True).stdout.splitlines()
                for line in commands:
                    fields = line.strip().split(maxsplit=1)
                    if len(fields) == 2 and fields[1].startswith(str(executable) + " --pty-mux-"):
                        try:
                            os.kill(int(fields[0]), signal.SIGTERM)
                        except ProcessLookupError:
                            pass
                subprocess.run(["defaults", "delete", domain], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                preference = Path.home() / "Library/Preferences" / (domain + ".plist")
                if preference.exists() and plistlib.loads(preference.read_bytes()) == {}:
                    preference.unlink()


if __name__ == "__main__":
    main()
