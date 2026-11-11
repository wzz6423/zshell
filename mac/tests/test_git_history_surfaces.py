"""Exercise Git history refresh, pagination, and native rows from a Debug build.

Run: python3 -B mac/tests/test_git_history_surfaces.py --built-app '/path/to/zshell Debug.app'
The existing compiled module is reused; no full app rebuild is performed.
Repositories, signing keys, preferences, probe bundles, and caches are temporary.
"""

import argparse
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import uuid

from test_file_tree_background import built_app_arguments, compiler_arguments


ROOT = Path(__file__).resolve().parents[2]


def repository_fixture(repo, signing_key, environment):
    repo.mkdir()

    def git(*args):
        return subprocess.run(["/usr/bin/git", *args], cwd=repo, env=environment,
                              check=True, capture_output=True).stdout

    git("init", "-q", "-b", "main")
    author = "Compiled\x1eAuthor\x1fName"
    git("config", "user.name", author)
    git("config", "user.email", "compiled@example.invalid")
    git("config", "core.hooksPath", "/dev/null")
    expected = []
    parent = None

    def commit(subject, files, signed=False):
        nonlocal parent
        git("add", ".")
        git("commit", "-q", "--allow-empty", "--cleanup=verbatim", "-m", subject,
            *(["-S"] if signed else []))
        commit_hash = git("rev-parse", "HEAD").decode().strip()
        expected.insert(0, {
            "hash": commit_hash,
            "shortHash": git("rev-parse", "--short", "HEAD").decode().strip(),
            "subject": subject, "author": author, "parent": parent, "files": files,
        })
        parent = commit_hash

    original = "before\x1eafter.txt"
    renamed = "R100\x1frenamed\n.txt"
    copied = "\nC100\x1ecopied.txt"
    content = "copy baseline\n" * 20
    (repo / original).write_text(content)
    commit("root\x1e\x1f", [{"status": "A", "path": original}])
    git("mv", "--", original, renamed)
    commit("rename\x1e\x1f", [{"status": "R", "path": renamed, "original": original}])
    git("config", "diff.renames", "copies")
    (repo / copied).write_text(content)
    (repo / renamed).write_text("changed original\n" * 20)
    commit("copy\x1e\x1f", [{"status": "C", "path": copied, "original": renamed},
                              {"status": "M", "path": renamed}])
    for index in range(3, 34):
        (repo / "tick.txt").write_text(f"tick {index}\n")
        commit(f"page\x1e{index}\x1f", [{"status": "A" if index == 3 else "M", "path": "tick.txt"}])

    subprocess.run(["/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(signing_key)],
                   env=environment, check=True, capture_output=True)
    git("config", "gpg.format", "ssh")
    git("config", "user.signingKey", str(signing_key))
    git("config", "log.showSignature", "true")
    git("config", "log.showNotes", "true")
    commit("signed empty\x1e\x1f", [], signed=True)
    git("notes", "add", "-m", "fixture note")
    return expected


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--built-app", required=True, type=Path)
    application = parser.parse_args().built_app.resolve()
    with tempfile.TemporaryDirectory(prefix="zshell-history-surfaces-", dir="/tmp") as directory:
        temporary = Path(directory)
        home = temporary / "home"
        config = home / ".config/zshell-dev/config.toml"
        config.parent.mkdir(parents=True)
        config.write_text("ai.enabled = false\nterminal.preserve-sessions = false\n")
        environment = {key: value for key, value in os.environ.items() if not key.startswith("ZSHELL_")}
        environment.update(HOME=str(home), CFFIXED_USER_HOME=str(home), ZDOTDIR=str(home),
                           GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL="/dev/null")

        repo = temporary / "repo"
        expected = repository_fixture(repo, temporary / "signing", environment)
        fixture = temporary / "expected.json"
        fixture.write_text(json.dumps(expected))
        contents = temporary / "Git History Probe.app/Contents"
        binary = contents / "MacOS/history-probe"
        binary.parent.mkdir(parents=True)
        (contents / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "sh.zshell.tests.git-history." + uuid.uuid4().hex,
            "CFBundleExecutable": binary.name, "CFBundlePackageType": "APPL", "LSUIElement": True,
        }))
        (contents / "Resources").symlink_to(application / "Contents/Resources", target_is_directory=True)
        arguments = compiler_arguments(temporary) + built_app_arguments(application)
        arguments += [str(ROOT / "mac/tests/GitHistorySurfaceTests.swift"), "-o", str(binary)]
        subprocess.run(arguments, cwd=ROOT, check=True, timeout=120)
        subprocess.run([str(binary), str(repo), str(fixture)], cwd=ROOT,
                       env=environment, check=True, timeout=90)
    print("Git history probe bundle, signing key, repository, preferences, cache, and binary cleaned")


if __name__ == "__main__":
    main()
