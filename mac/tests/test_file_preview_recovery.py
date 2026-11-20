"""Exercise production file tabs, Markdown views and missing-file recovery.

Use --built-app with a signed Debug build. --model-source compiles the current
FileTab against an unchanged baseline's dependencies without rebuilding the app.
All homes, bundles, files, preferences, module caches and binaries are disposable;
AppKit windows remain offscreen and never receive keyboard or mouse input.
"""
import argparse
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
import uuid

sys.dont_write_bytecode = True
from test_file_tree_background import built_app_arguments, compiler_arguments

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--built-app", required=True, type=Path)
    parser.add_argument("--model-source", action="store_true")
    parser.add_argument("--case", choices=("baseline", "missing-action", "recovery"), default="recovery")
    options = parser.parse_args()
    if options.model_source and options.case != "recovery":
        parser.error("--model-source runs recovery model checks only")
    app = options.built_app.resolve()
    with tempfile.TemporaryDirectory(prefix="zshell-file-preview-recovery-", dir="/tmp") as directory:
        temporary = Path(directory)
        contents = temporary / "File Preview Probe.app/Contents"
        binary = contents / "MacOS/probe"
        binary.parent.mkdir(parents=True)
        domain = f"sh.zshell.test.file-preview.{uuid.uuid4().hex}"
        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        info.update(CFBundleIdentifier=domain, CFBundleExecutable="probe", CFBundleDevelopmentRegion="en",
                    CFBundleName="File Preview Probe", LSBackgroundOnly=True, SUEnableAutomaticChecks=False)
        (contents / "Info.plist").write_bytes(plistlib.dumps(info))
        (contents / "Resources").symlink_to(app / "Contents/Resources")
        arguments = built_app_arguments(app)
        # Generated module maps remember the original checkout. Relocate their
        # equivalent vendored headers only inside this disposable test bundle.
        maps = temporary / "ModuleMaps"
        maps.mkdir()
        for index, argument in enumerate(arguments):
            prefix = "-fmodule-map-file="
            if not argument.startswith(prefix):
                continue
            original = Path(argument[len(prefix):])
            if original.parent.name != "GeneratedModuleMaps":
                continue
            copied = maps / original.name
            copied.write_text(re.sub(r'"[^"\n]+/mac/Vendor/([^"\n]+)"',
                                     lambda match: '"' + str(ROOT / "mac/Vendor" / match[1]) + '"',
                                     original.read_text()))
            arguments[index] = prefix + str(copied)
        command = compiler_arguments(temporary) + arguments
        if options.case != "recovery":
            command += ["-D", "FILE_PREVIEW_BASELINE"]
        if options.model_source:
            source = (ROOT / "mac/zshell/FileViewerView.swift").read_text()
            model = source[:source.index("/// Content of a file tab, hosted in AppKit:")]
            current = temporary / "FileTab.swift"
            current.write_text("@testable import zshell\n" + model)
            command += ["-D", "FILE_PREVIEW_SOURCE_MODEL", str(current)]
        command += [str(ROOT / "mac/tests/FilePreviewRecoveryTests.swift"),
                    str(ROOT / "mac/tests/QuickTerminalOffscreen.swift"), "-o", str(binary)]
        compiled = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, timeout=120)
        if compiled.returncode:
            raise SystemExit(compiled.stderr or compiled.stdout)
        environments = []
        try:
            backends = ("libghostty", "alacritty") if not options.model_source else ("libghostty",)
            for backend in backends:
                home = temporary / backend / "home"
                config = home / ".config/zshell-dev"
                config.mkdir(parents=True)
                (home / "tmp").mkdir()
                (config / "config.toml").write_text(
                    f'ai.enabled = false\nterminal.backend = "{backend}"\n'
                    'terminal.restore-history = false\nterminal.preserve-sessions = false\n'
                    'quick-terminal.enabled = false\n'
                )
                fixture = temporary / backend / "fixture"
                fixture.mkdir()
                env = {key: value for key, value in os.environ.items()
                       if not key.startswith("ZSHELL_") and key != "DYLD_INSERT_LIBRARIES"}
                env.update(HOME=str(home), CFFIXED_USER_HOME=str(home), ZDOTDIR=str(home),
                           TMPDIR=str(home / "tmp"), XDG_CONFIG_HOME=str(home / ".config"),
                           ZSHELL_PTY_MUX_DIRECTORY=str(home / "mux"), ZSHELL_SSH_AGENT_RESOLVED="1",
                           GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL="/dev/null")
                environments.append(env)
                run = subprocess.run([str(binary), options.case, str(fixture), backend],
                                     cwd=ROOT, env=env, capture_output=True, text=True, timeout=45)
                print(run.stdout, end="", flush=True)
                if run.stderr:
                    print(run.stderr, end="", file=sys.stderr, flush=True)
                if run.returncode or f"FILE_PREVIEW_SUCCESS case={options.case} backend={backend}" not in run.stdout:
                    raise SystemExit(f"The {backend} {options.case} fixture did not finish (exit {run.returncode})")
        finally:
            # A restored file-only workspace starts no terminals. If a future
            # regression starts one, cleanup stays inside this fixture's mux.
            mux = [str(app / "Contents/MacOS/zshell"), "+pty-mux"]
            for env in environments:
                subprocess.run(mux + ["shutdown"], env=env, capture_output=True, timeout=10)
                subprocess.run(["defaults", "delete", domain], env=env,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)


if __name__ == "__main__":
    main()
