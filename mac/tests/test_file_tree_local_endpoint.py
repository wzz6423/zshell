"""Exercise the sidebar's production refresh route and real FileTreeModel.

Only SSH transport and terminal/UI dependencies are fixtures. No SSH process or
personal configuration is used; binaries and module caches are removed.
"""
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


def compile_probe(directory, sidebar_source=None):
    sidebar = sidebar_source or (ROOT / "mac/zshell/RightSidebarView.swift").read_text()
    start = sidebar.index("    private func syncModels() {")
    refresh = sidebar[start:sidebar.index("\n    }", start) + len("\n    }")]
    project = (ROOT / "mac/zshell/Project.swift").read_text()
    start = project.index("    var selectedSession: TerminalSession? {")
    selected_session = project[start:project.index("\n    }", start) + len("\n    }")]
    roots = project[project.index("    enum PanelRootSource:"):
                    project.index("    // MARK: - Sessions")]
    remote = (ROOT / "mac/zshell/RemoteSSH.swift").read_text()
    start = remote.index("nonisolated struct SSHEndpoint:")
    endpoint = remote[start:remote.index("\n}", start) + len("\n}")]
    manager = (ROOT / "mac/zshell/TerminalManager.swift").read_text()
    start = manager.index("    func syncFileTree() {")
    tree_sync = manager[start:manager.index("\n    }", start) + len("\n    }")]
    start = manager.index("enum RightPanel:")
    panels = manager[start:manager.index("\n}", start) + len("\n}")]
    support = directory / "ProductionRoute.swift"
    support.write_text("import AppKit\nimport Foundation\n" + endpoint + "\n" + panels
                       + "\nextension Project {\n" + selected_session + "\n" + roots + "}\n"
                       + "extension ManagerFixture {\n" + tree_sync + "\n}\n"
                       + "extension SidebarFixture {\n"
                       + "    func refresh() { syncModels() }\n" + refresh + "\n}\n")
    binary = directory / "file-tree-endpoint-probe"
    subprocess.run([
        "xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
        "-default-isolation", "MainActor",
        "-module-cache-path", str(directory / "ModuleCache"),
        str(ROOT / "mac/zshell/FileTreeModel.swift"), str(support),
        str(ROOT / "mac/tests/FileTreeLocalEndpointTests.swift"), "-o", str(binary),
    ], cwd=ROOT, check=True, timeout=60)
    return binary


class FileTreeLocalEndpointTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="zshell-file-tree-endpoint-", dir="/tmp")
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.directory = Path(cls.temporary.name)
        cls.binary = compile_probe(cls.directory)

    def evaluate(self, scenario):
        result = subprocess.run(
            [str(self.binary), scenario, str(self.directory / scenario)],
            cwd=ROOT, text=True, capture_output=True, timeout=15,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(f"{scenario}: passed", result.stdout)

    def test_remote_to_local_reads_the_local_filesystem(self):
        for scenario in ("local", "same-root", "empty-root"):
            with self.subTest(scenario=scenario):
                self.evaluate(scenario)

    def test_empty_selection_drops_the_previous_remote_tree(self):
        for scenario in ("no-project", "no-session", "unavailable-endpoint"):
            with self.subTest(scenario=scenario):
                self.evaluate(scenario)

    def test_file_and_diff_context_sessions_keep_the_local_tree(self):
        for scenario in ("file-context", "diff-context"):
            with self.subTest(scenario=scenario):
                self.evaluate(scenario)

    def test_info_and_git_tabs_clear_the_remote_endpoint(self):
        self.evaluate("tabs")

    def test_remote_host_switch_with_the_same_root_uses_the_new_endpoint(self):
        self.evaluate("remote-switch")

    def test_unchanged_remote_selection_preserves_expanded_rows(self):
        self.evaluate("remote-stable")

    def test_late_remote_results_cannot_change_local_or_empty_state(self):
        for scenario in ("late-local-success", "late-local-failure",
                         "late-empty-success", "late-empty-failure"):
            with self.subTest(scenario=scenario):
                self.evaluate(scenario)


if __name__ == "__main__":
    unittest.main(verbosity=2)
