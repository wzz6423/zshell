"""Check remote FileTab models against a built Debug module, without windows.

Set ZSHELL_TEST_DERIVED_DATA to the isolated Debug build directory. The probe
uses a prohibited activation policy, private preferences, and a fake SSH shell.
"""

import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import uuid

sys.dont_write_bytecode = True
from test_file_tree_background import ROOT, built_app_arguments, compiler_arguments


def main():
    build = Path(os.environ["ZSHELL_TEST_DERIVED_DATA"])
    application = build / "Build/Products/Debug/zshell Debug.app"
    with tempfile.TemporaryDirectory(prefix="zshell-remote-tabs-", dir="/tmp") as directory:
        temporary = Path(directory).resolve()
        bundle = temporary / "Remote File Probe.app"
        binary = bundle / "Contents/MacOS/probe"
        binary.parent.mkdir(parents=True)
        with (bundle / "Contents/Info.plist").open("wb") as info:
            plistlib.dump({"CFBundleIdentifier": f"sh.zshell.test.remote-files.{uuid.uuid4().hex}",
                          "CFBundleExecutable": "probe", "CFBundlePackageType": "APPL"}, info)
        subprocess.run(compiler_arguments(temporary) + built_app_arguments(application) + [
            str(ROOT / "mac/tests/RemoteFileTabTests.swift"), "-o", str(binary),
        ], cwd=ROOT, check=True, timeout=120)
        ssh = temporary / "fixture-ssh"
        ssh.write_text("#!/bin/sh\nfor argument do command=\"$argument\"; done\nexec /bin/sh -c \"$command\"\n")
        ssh.chmod(0o700)
        home = temporary / "home"
        config = home / ".config/zshell-dev"
        config.mkdir(parents=True)
        (config / "config.toml").write_text("ai.enabled = false\n")
        fixture = temporary / "fixture"
        fixture.mkdir()
        environment = {key: value for key, value in os.environ.items() if not key.startswith("ZSHELL_")}
        environment.update(HOME=str(home), CFFIXED_USER_HOME=str(home), ZDOTDIR=str(home), ZSHELL_SSH_AGENT_RESOLVED="1")
        subprocess.run([str(binary), str(fixture), str(ssh)], cwd=ROOT, env=environment, check=True, timeout=60)


if __name__ == "__main__":
    main()
