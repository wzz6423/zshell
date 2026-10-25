"""Exercise production review code against disposable Git repositories."""
from pathlib import Path
import subprocess
import tempfile
import unittest


class AgentTurnReviewTests(unittest.TestCase):
    def test_snapshot_and_revert_safety(self):
        mac = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory(prefix="zshell-turn-review-build-") as temporary:
            binary = Path(temporary) / "review-tests"
            subprocess.run([
                "swiftc", "-parse-as-library", "-swift-version", "6",
                str(mac / "zshell/GitCommandRunner.swift"),
                str(mac / "zshell/AgentTurnReview.swift"),
                str(mac / "tests/AgentTurnReviewTests.swift"),
                "-o", str(binary),
            ], check=True)
            result = subprocess.run([str(binary)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("guards passed", result.stdout)
            print(result.stdout.strip())


if __name__ == "__main__":
    unittest.main(verbosity=2)
