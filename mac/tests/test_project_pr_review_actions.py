"""Exercise production review actions against an isolated GraphQL and Git fixture.

No GitHub write or user configuration is touched. All binaries and caches are removed.
"""
import argparse
import os
from pathlib import Path
import platform
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--derived-data", type=Path)
options = parser.parse_args()

with tempfile.TemporaryDirectory(prefix="zshell-pr-actions-", dir="/tmp") as directory:
    temporary = Path(directory)
    repo = temporary / "repo"
    repo.mkdir()
    environment = dict(os.environ, GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL="/dev/null")
    def git(*args):
        subprocess.run(["git", *args], cwd=repo, env=environment, check=True, stdout=subprocess.DEVNULL)
    git("init", "-q", "-b", "feature/review")
    git("config", "user.name", "Review Fixture")
    git("config", "user.email", "test@example.invalid")
    git("commit", "--allow-empty", "-qm", "fixture")
    git("remote", "add", "origin", "git@github.com:example/fork.git")
    git("remote", "add", "upstream", "https://github.com/example/base.git")
    git("config", "branch.feature/review.remote", "origin")
    git("config", "branch.feature/review.merge", "refs/heads/feature/review")
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
    usage = (ROOT / "mac/zshell/AgentUsage.swift").read_text()
    start = usage.index("    static func resolveExecutable(\n")
    resolve = usage[start:usage.index("    private struct ResponseEnvelope:", start)]
    support = temporary / "Support.swift"
    support.write_text("import Foundation\nimport Darwin\nstruct GitStatusModel {\n" + snapshot + helpers
                       + "}\n" + runner + collector + "\nnonisolated enum ProcessRunner {\n" + resolve + "}\n")
    annotations = ROOT / "mac/Vendor/PierreDiffsSwift/Sources/PierreDiffsSwift/Models/DiffAnnotation.swift"
    subprocess.run(["xcrun", "swiftc", "-emit-module", "-emit-library", "-module-name", "PierreDiffsSwift",
                    "-module-cache-path", str(temporary / "modules"), str(annotations),
                    "-emit-module-path", str(temporary / "PierreDiffsSwift.swiftmodule"),
                    "-o", str(temporary / "libPierreDiffsSwift.dylib")], cwd=ROOT, check=True)
    sources = [support, ROOT / "mac/zshell/GitCommandRunner.swift", ROOT / "mac/zshell/GitProxy.swift",
               ROOT / "mac/zshell/ProjectPullRequest.swift", ROOT / "mac/zshell/ProjectPullRequestReview.swift",
               ROOT / "mac/zshell/ProjectPullRequestReviewActions.swift", ROOT / "mac/tests/ProjectPullRequestReviewActionTests.swift"]
    binary = temporary / "actions"
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "5", "-default-isolation", "MainActor",
                    "-module-cache-path", str(temporary / "modules"), "-I", str(temporary), "-L", str(temporary),
                    "-lPierreDiffsSwift", "-Xlinker", "-rpath", "-Xlinker", str(temporary),
                    *map(str, sources), "-o", str(binary)], cwd=ROOT, check=True)
    subprocess.run([str(binary), str(repo)], cwd=ROOT, env=environment, check=True, timeout=45)

print("PR review action fixture binaries, Git repository and module cache cleaned")
