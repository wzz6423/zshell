"""Verify production PR review queries and the mounted AppKit/WebKit diff.

Build Debug first and pass --derived-data. All fixture bundles, binaries,
repositories, preferences and caches are removed when the probe exits.
"""
import argparse
import json
import os
from pathlib import Path
import platform
import plistlib
import subprocess
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--derived-data", type=Path, default=os.environ.get("ZSHELL_TEST_DERIVED_DATA"))
parser.add_argument("--query-only", action="store_true")
options = parser.parse_args()
if not options.derived_data:
    parser.error("--derived-data or ZSHELL_TEST_DERIVED_DATA is required")
build = options.derived_data / "Build"
products = build / "Products/Debug"
library = products / "zshell Debug.app/Contents/MacOS/zshell.debug.dylib"
if not library.is_file():
    raise SystemExit(f"Build the Debug app in {options.derived_data} first")


def git(directory, *arguments):
    return subprocess.check_output(["/usr/bin/git", *arguments], cwd=directory).decode().strip()


with tempfile.TemporaryDirectory(prefix="zshell-pr-review-", dir="/tmp") as directory:
    temporary = Path(directory)
    repo = temporary / "repo"
    repo.mkdir()
    git(repo, "init", "-q", "-b", "main")
    git(repo, "config", "user.name", "Review Fixture")
    git(repo, "config", "user.email", "test@example.invalid")
    before = "".join(f"let line{index} = {index}\n" for index in range(1, 221))
    (repo / "Before.swift").write_text(before)
    git(repo, "add", ".")
    git(repo, "commit", "-qm", "merge base")
    merge_base = git(repo, "rev-parse", "HEAD")
    git(repo, "checkout", "-qb", "feature/review")
    (repo / "Before.swift").rename(repo / "Review.swift")
    after = before.replace("let line10 = 10", "let line10 = 11").replace("let line30 = 30", "let line30 = 31")
    (repo / "Review.swift").write_text(after)
    git(repo, "add", ".")
    git(repo, "commit", "-qm", "reviewed revision")
    previous_head = git(repo, "rev-parse", "HEAD")
    after = after.replace("let line82 = 82", "let line82 = 83")
    (repo / "Review.swift").write_text(after)
    git(repo, "add", ".")
    git(repo, "commit", "-qm", "later revision")
    head = git(repo, "rev-parse", "HEAD")
    git(repo, "checkout", "-q", "main")
    (repo / "Before.swift").write_text(before.replace("let line10 = 10", "let line10 = 999 // base branch"))
    git(repo, "add", ".")
    git(repo, "commit", "-qm", "advance base")
    base = git(repo, "rev-parse", "HEAD")
    git(repo, "checkout", "-q", "feature/review")
    (repo / "Review.swift").write_text(after.replace("let line30 = 31", "let line30 = 999 // working tree"))
    git(repo, "remote", "add", "origin", "git@github.com:example/fork.git")
    git(repo, "remote", "add", "upstream", "https://github.com/example/base.git")
    git(repo, "config", "branch.feature/review.remote", "origin")
    git(repo, "config", "branch.feature/review.merge", "refs/heads/feature/review")

    info = plistlib.loads((library.parents[1] / "Info.plist").read_bytes())
    environment = {key: value for key, value in os.environ.items() if not key.startswith("ZSHELL_")}
    if os.environ.get("ZSHELL_PR_REVIEW_LIVE") == "1":
        # 隔离 HOME 后 gh 无法可靠读取原登录；凭据只传给可选的只读联网检查。
        environment["GH_TOKEN"] = subprocess.check_output(
            ["gh", "auth", "token", "--hostname", "github.com"], cwd=ROOT, text=True).strip()
    home = temporary / "home"
    config = home / ".config/zshell-dev"
    config.mkdir(parents=True)
    (config / "config.toml").write_text("ai.enabled = false\n")
    environment.update(HOME=str(home), CFFIXED_USER_HOME=str(home), ZDOTDIR=str(home),
                       GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL="/dev/null")
    for key in ("ZSHELL_PR_REVIEW_LIVE", "ZSHELL_PR_REVIEW_LIVE_PATH", "ZSHELL_PR_REVIEW_SCREENSHOT"):
        if key in os.environ:
            environment[key] = os.environ[key]

    def compile_probe(name, source):
        contents = temporary / f"{name}.app/Contents"
        binary = contents / "MacOS/probe"
        binary.parent.mkdir(parents=True)
        bundle_info = dict(info, CFBundleIdentifier=f"sh.zshell.test.pr-review.{uuid.uuid4().hex}", CFBundleExecutable="probe")
        (contents / "Info.plist").write_bytes(plistlib.dumps(bundle_info))
        (contents / "Resources").symlink_to(library.parents[1] / "Resources", target_is_directory=True)
        command = ["xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
                   "-target", f"{platform.machine()}-apple-macos15.6", "-module-cache-path", str(temporary / "modules"),
                   "-I", str(products), "-I", str(products / "include"), "-F", str(products)]
        for modulemap in (build / "Intermediates.noindex/GeneratedModuleMaps").glob("*.modulemap"):
            command += ["-Xcc", f"-fmodule-map-file={modulemap}"]
        for include in ("STTextView/Sources/STObjCLandShim/include", "swift-cmark/src/include",
                        "swift-cmark/extensions/include", "swift-markdown/Sources/CAtomic/include"):
            path = ROOT / "mac/Vendor" / include
            command += ["-I", str(path), "-Xcc", f"-fmodule-map-file={path / 'module.modulemap'}"]
        command += ["-I", str(ROOT / "mac/Vendor/alacritty-bridge/include"),
                    "-I", str(ROOT / "mac/Vendor/tree-sitter/lib/include"), str(library),
                    "-Xlinker", "-rpath", "-Xlinker", str(products),
                    "-Xlinker", "-rpath", "-Xlinker", str(library.parent), str(ROOT / "mac/tests" / source), "-o", str(binary)]
        subprocess.run(command, cwd=ROOT, check=True)
        return binary

    query_probe = compile_probe("Query Probe", "ProjectPullRequestReviewTests.swift")
    subprocess.run([str(query_probe), str(repo), base, head, merge_base, previous_head, str(ROOT)],
                   cwd=ROOT, env=environment, check=True, timeout=60)
    if options.query_only:
        raise SystemExit(0)
    environment.pop("GH_TOKEN", None)
    environment.pop("GITHUB_TOKEN", None)

    def comment(identifier, body):
        return {"id": identifier, "author": {"login": "Reviewer"}, "body": body,
                "url": f"https://github.com/example/base/pull/1#discussion_{identifier}",
                "commit": {"oid": previous_head}, "originalCommit": {"oid": merge_base}}

    def connection(nodes, cursor=None):
        return {"nodes": nodes, "pageInfo": {"hasNextPage": cursor is not None, "endCursor": cursor}}

    def thread(identifier, side, line, outdated=False, cursor=None):
        return {"id": identifier, "path": "Review.swift", "line": line, "startLine": None,
                "diffSide": side, "startDiffSide": None, "isResolved": identifier == "left", "isOutdated": outdated,
                "subjectType": "LINE", "comments": connection([comment(identifier,
                    "旧版行号的意见" if side == "LEFT" else "当前行的意见 <script>window.reviewInjected=true</script>")], cursor)}

    pr = {"number": 1, "url": "https://github.com/example/base/pull/1", "headRefName": "feature/review",
          "headRepository": {"nameWithOwner": "example/fork"}, "baseRefOid": base, "headRefOid": head}
    action_pr = dict(pr, id="PR_1", state="OPEN", viewerDidAuthor=False)
    action_thread = dict(thread("right", "RIGHT", 30), pullRequest=action_pr,
                         viewerCanReply=True, viewerCanResolve=True, viewerCanUnresolve=True)
    responses = {
        "status": {"data": {"repository": {"parent": None, "pullRequests": connection([
            dict(pr, state="OPEN", isDraft=True, updatedAt="2026-01-01T00:00:00Z")])}}},
        "review": {"data": {"repository": {"pullRequest": dict(pr, reviewThreads=connection([
            thread("left", "LEFT", 10), thread("right", "RIGHT", 30, cursor="reply"),
            thread("outdated", "RIGHT", 80, outdated=True)]))}}},
        "version": {"data": {"repository": {"pullRequest": pr}}},
        "reply": {"data": {"node": {"id": "right", "pullRequest": pr,
                 "comments": connection([comment("reply", "分页回复：保留原讨论")])}}},
        "action_access": {"data": {"repository": {"pullRequest": action_pr}}},
        "action_thread": {"data": {"node": action_thread}},
    }
    for name, response in responses.items():
        (temporary / f"{name}.json").write_text(json.dumps(response))
    bindir = temporary / "bin"
    bindir.mkdir()
    fake_gh = bindir / "gh"
    fake_gh.write_text("#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$ZSHELL_PR_REVIEW_QUERY_LOG\"\n"
                       "case \"$*\" in\n*--input*) payload=$(cat); case \"$payload\" in\n"
                       "*mutation*) printf '%s' '{\"errors\":[{\"type\":\"FORBIDDEN\"}]}' ;;\n"
                       "*PullRequestReviewThread*) if [ -f \"$ZSHELL_PR_REVIEW_FIXTURES/action-thread-delay\" ]; then\n"
                       "touch \"$ZSHELL_PR_REVIEW_FIXTURES/action-thread-started\"; sleep 0.4; fi\n"
                       "cat \"$ZSHELL_PR_REVIEW_FIXTURES/action_thread.json\" ;;\n"
                       "*) cat \"$ZSHELL_PR_REVIEW_FIXTURES/action_access.json\" ;;\nesac; exit 0 ;;\nesac\n"
                       "case \"$*\" in\n"
                       "*reviewThreads*) cat \"$ZSHELL_PR_REVIEW_FIXTURES/review.json\" ;;\n"
                       "*PullRequestReviewThread*) cat \"$ZSHELL_PR_REVIEW_FIXTURES/reply.json\" ;;\n"
                       "*pullRequest\\(number*) cat \"$ZSHELL_PR_REVIEW_FIXTURES/version.json\" ;;\n"
                       "*) if [ -f \"$ZSHELL_PR_REVIEW_FIXTURES/status-delay\" ]; then sleep 0.3; fi\n"
                       "cat \"$ZSHELL_PR_REVIEW_FIXTURES/status.json\" ;;\nesac\n")
    fake_gh.chmod(0o755)
    environment.update(PATH=f"{bindir}:/usr/bin:/bin:/usr/sbin:/sbin", ZSHELL_PR_REVIEW_FIXTURES=str(temporary),
                       ZSHELL_PR_REVIEW_QUERY_LOG=str(temporary / "queries"))
    ui_probe = compile_probe("Diff Probe", "ProjectPullRequestReviewSurfaceTests.swift")
    subprocess.run([str(ui_probe), str(repo), head, merge_base], cwd=ROOT, env=environment, check=True, timeout=60)

print("PR评论测试临时bundle、binary、Git仓库、preferences、日志与缓存均已清理")
