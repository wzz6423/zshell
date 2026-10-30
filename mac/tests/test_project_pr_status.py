"""Exercise the production PR lookup against temporary Git repositories.

All binaries, module caches and repositories are removed after the test.
"""
import argparse
import json
import os
from pathlib import Path
import platform
import plistlib
import shutil
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--derived-data", type=Path)
options = parser.parse_args()


def git(directory, *args):
    subprocess.run(["/usr/bin/git", *args], cwd=directory, check=True, stdout=subprocess.DEVNULL)


with tempfile.TemporaryDirectory(prefix="zshell-pr-status-") as directory:
    temporary = Path(directory)
    repo = temporary / "repo"
    repo.mkdir()
    git(repo, "init", "-q", "-b", "feature/one")
    git(repo, "config", "user.name", "Test")
    git(repo, "config", "user.email", "test@example.invalid")
    git(repo, "commit", "--allow-empty", "-qm", "fixture")
    git(repo, "remote", "add", "origin", "git@github.com:example/fork.git")
    git(repo, "remote", "add", "upstream", "https://github.com/example/base.git")
    git(repo, "config", "branch.feature/one.remote", "origin")
    git(repo, "config", "branch.feature/one.merge", "refs/heads/feature/one")
    worktree = temporary / "worktree"
    git(repo, "worktree", "add", "-q", "-b", "feature/two", str(worktree))
    git(worktree, "config", "branch.feature/two.remote", "origin")
    git(worktree, "config", "branch.feature/two.merge", "refs/heads/feature/two")

    source = (ROOT / "mac/zshell/GitStatusModel.swift").read_text()
    start = source.index("    nonisolated struct BranchSnapshot:")
    snapshot = source[start:source.index("\n}\n", start)]
    helpers = source[source.index("    private nonisolated static func containsGitMetadata"):
                     source.index("    private nonisolated static func gitFailureMessage")]
    remote = (ROOT / "mac/zshell/RemoteSSH.swift").read_text()
    runner = remote[remote.index("nonisolated struct BoundedProcessOutput:"):
                    remote.index("nonisolated struct OpenSSHTransport")]
    collector = remote[remote.index("private nonisolated final class BoundedOutputCollector:"):]
    collector = collector[:collector.index("\n}\n") + 3]
    agent = (ROOT / "mac/zshell/AgentUsage.swift").read_text()
    start = agent.index("    static func resolveExecutable(\n")
    resolve = agent[start:agent.index("    private struct ResponseEnvelope:", start)]
    support = temporary / "Support.swift"
    support.write_text("import Foundation\nimport Darwin\nstruct GitStatusModel {\n" + snapshot + helpers
                       + "}\n" + runner + collector + "\nnonisolated enum ProcessRunner {\n" + resolve + "}\n")
    binary = temporary / "pr-status-tests"
    subprocess.run([
        "xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
        "-default-isolation", "MainActor", "-module-cache-path", str(temporary / "modules"),
        str(support), str(ROOT / "mac/zshell/GitCommandRunner.swift"), str(ROOT / "mac/zshell/GitProxy.swift"),
        str(ROOT / "mac/zshell/ProjectPullRequest.swift"),
        str(ROOT / "mac/tests/ProjectPullRequestTests.swift"), "-o", str(binary),
    ], cwd=ROOT, check=True)
    subprocess.run([str(binary), str(repo), str(worktree), str(temporary)], cwd=ROOT, check=True, timeout=45)

    if options.derived_data:
        build = options.derived_data / "Build"
        products = build / "Products/Debug"
        library = products / "zshell Debug.app/Contents/MacOS/zshell.debug.dylib"
        if not library.is_file():
            raise SystemExit(f"Build the Debug app in {options.derived_data} first")
        contents = temporary / "PRFixture.app/Contents"
        executable_dir = contents / "MacOS"
        executable_dir.mkdir(parents=True)
        binary = executable_dir / "pr-surface-tests"
        info = plistlib.loads((library.parents[1] / "Info.plist").read_bytes())
        info.update({"CFBundleIdentifier": "sh.zshell.pr-fixture", "CFBundleExecutable": binary.name})
        (contents / "Info.plist").write_bytes(plistlib.dumps(info))
        (contents / "Resources").symlink_to(library.parents[1] / "Resources", target_is_directory=True)
        arguments = ["xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
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
                      str(ROOT / "mac/tests/ProjectPullRequestSurfaceTests.swift"), "-o", str(binary)]
        subprocess.run(arguments, cwd=ROOT, check=True)

        def response(branch, number):
            return json.dumps({"data": {"repository": {"parent": None, "pullRequests": {
                "pageInfo": {"hasNextPage": False}, "nodes": [{"number": number,
                "url": f"https://github.com/example/base/pull/{number}", "state": "OPEN",
                "isDraft": False, "headRefName": branch, "headRepository": {"nameWithOwner": "example/fork"},
                "updatedAt": "2026-01-01T00:00:00Z"}]}}}})

        bindir = temporary / "bin"
        bindir.mkdir()
        fake_gh = bindir / "gh"
        fake_gh.write_text("#!/bin/sh\nprintf . >> \"$ZSHELL_PR_COUNT_FILE\"\n"
                           + "printf '%s\\n' \"${HTTPS_PROXY:-none}\" >> \"$ZSHELL_PR_PROXY_FILE\"\ncase \"$*\" in\n"
                           + "*branch=feature/other*) printf '%s\\n' '" + response("feature/other", 2) + "' ;;\n"
                           + "*) printf '%s\\n' '" + response("feature/one", 1) + "' ;;\nesac\n")
        fake_gh.chmod(0o755)
        for backend in ("ghostty", "alacritty"):
            fixture = temporary / backend
            fixture.mkdir()
            checkout = fixture / "repo"
            git(temporary, "clone", "-q", str(repo), str(checkout))
            git(checkout, "remote", "set-url", "origin", "git@github.com:example/fork.git")
            git(checkout, "remote", "add", "upstream", "https://github.com/example/base.git")
            # An inherited proxy would hide whether the Settings proxy is applied.
            env = {key: value for key, value in os.environ.items()
                   if not key.startswith(("ZSHELL_", "GH_", "GIT_CONFIG_"))
                   and key.lower() not in ("http_proxy", "https_proxy", "all_proxy")}
            env.update({"HOME": str(fixture), "CFFIXED_USER_HOME": str(fixture), "ZDOTDIR": str(fixture),
                        "PATH": f"{bindir}:/usr/bin:/bin:/usr/sbin:/sbin",
                        "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
                        "ZSHELL_PTY_MUX_DIRECTORY": str(fixture / "mux"),
                        "ZSHELL_PR_COUNT_FILE": str(fixture / "queries"),
                        "ZSHELL_PR_PROXY_FILE": str(fixture / "proxies"),
                        "ZSHELL_PR_TERMINAL_DIRECTORY": str(fixture)})
            if backend == "ghostty" and "ZSHELL_PR_TEST_SCREENSHOT" in os.environ:
                env["ZSHELL_PR_TEST_SCREENSHOT"] = os.environ["ZSHELL_PR_TEST_SCREENSHOT"]
            subprocess.run([str(binary), backend, str(checkout)], cwd=ROOT, env=env, check=True, timeout=45)
            # Hung-up shells may still write their history just after the app exits.
            for attempt in range(50):
                try:
                    shutil.rmtree(fixture)
                    break
                except OSError:
                    if attempt == 49:
                        raise
                    time.sleep(0.1)
