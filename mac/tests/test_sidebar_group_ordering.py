"""Exercise mixed project/group sidebar ordering and its production wiring.

Run: python3 mac/tests/test_sidebar_group_ordering.py
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
GROUP_SOURCE = ROOT / "mac/zshell/ProjectGroup.swift"
SIDEBAR_SOURCE = ROOT / "mac/zshell/AppKitProjectSidebarView.swift"
MANAGER_SOURCE = ROOT / "mac/zshell/TerminalManager.swift"
SESSION_SOURCE = ROOT / "mac/zshell/SessionStore.swift"
CONTENT_SOURCE = ROOT / "mac/zshell/ContentView.swift"

fixture = r'''
struct AppSettings {
    static let configURL = URL(fileURLWithPath: NSTemporaryDirectory())
}

struct ProjectTabMarkerColor: Equatable {
    static let defaultColor = ProjectTabMarkerColor(hex: "#000000")!
    let hex: String
    init?(hex: String) { self.hex = hex }
}

@main
struct SidebarGroupOrderingRegression {
    static func main() {
        var failures = 0
        var checks = 0
        func check(_ condition: Bool, _ name: String) {
            checks += 1
            print("\(condition ? "PASS" : "FAIL") \(name)")
            if !condition { failures += 1 }
        }

        let projectA = UUID(), projectB = UUID(), projectC = UUID()
        let groupA = UUID(), groupB = UUID(), stale = UUID()
        let legacy = ProjectSidebarOrder.normalized(
            [], projectIDs: [projectA, projectB], groupIDs: [groupA, groupB]
        )
        check(
            legacy == [.project(projectA), .project(projectB), .group(groupA), .group(groupB)],
            "legacy data keeps projects before groups"
        )

        let mixed = ProjectSidebarOrder.normalized(
            [.group(groupA), .project(projectA), .group(stale), .group(groupA)],
            projectIDs: [projectA, projectB], groupIDs: [groupA, groupB]
        )
        check(
            mixed == [.group(groupA), .project(projectA), .project(projectB), .group(groupB)],
            "saved mixed order survives while stale and duplicate rows are removed"
        )

        let groupMovedAcrossProject = ProjectSidebarOrder.moving(
            .group(groupB), to: .project(projectA), in: mixed
        )
        check(
            groupMovedAcrossProject == [.group(groupA), .group(groupB), .project(projectA), .project(projectB)],
            "a group can move upward across an ungrouped project"
        )

        let groupMovedDownAcrossProjects = ProjectSidebarOrder.moving(
            .group(groupA), to: .project(projectB), in: mixed
        )
        check(
            groupMovedDownAcrossProjects == [.project(projectA), .project(projectB), .group(groupA), .group(groupB)],
            "a group can move downward across ungrouped projects"
        )

        let projectMovedAcrossGroup = ProjectSidebarOrder.moving(
            .project(projectA), to: .group(groupA), in: mixed
        )
        check(
            projectMovedAcrossGroup == [.project(projectA), .group(groupA), .project(projectB), .group(groupB)],
            "an ungrouped project can move across a group"
        )

        let appended = ProjectSidebarOrder.moving(
            .group(groupA), to: nil, in: mixed
        )
        check(
            appended == [.project(projectA), .project(projectB), .group(groupB), .group(groupA)],
            "dropping a group on sidebar whitespace moves it to the end"
        )

        let withNewProject = ProjectSidebarOrder.normalized(
            mixed, projectIDs: [projectA, projectB, projectC], groupIDs: [groupA, groupB]
        )
        check(withNewProject.last == .project(projectC), "new top-level rows append without disturbing saved order")

        print("Sidebar group ordering regression: \(checks - failures) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
'''

with tempfile.TemporaryDirectory(prefix="zshell-sidebar-order-tests-") as directory:
    helper = Path(directory) / "SidebarGroupOrderingRegression.swift"
    helper.write_text(GROUP_SOURCE.read_text() + fixture)
    executable = Path(directory) / "sidebar-order-tests"
    subprocess.run(
        ["xcrun", "swiftc", "-parse-as-library", str(helper), "-o", str(executable)],
        check=True,
    )
    subprocess.run([str(executable)], check=True)

    session_helper = Path(directory) / "SessionSnapshotRegression.swift"
    session_helper.write_text(
        r'''
import Foundation

struct EditorState: Codable {}
enum PaneSplitAxis: String, Codable { case horizontal, vertical }
struct TerminalLaunchSettingsOverride: Codable, Equatable {}
struct SessionTabGroup: Codable {}
struct TerminalLaunchSettings: Codable, Equatable {}
enum ProjectLocation: Codable { case local }
enum RightPanel: String, Codable { case files }
'''
        + SESSION_SOURCE.read_text()
        + r'''

@main
struct SessionSnapshotRegression {
    static func main() throws {
        let legacy = try JSONDecoder().decode(
            SessionSnapshot.self,
            from: Data(#"{"projects":[]}"#.utf8)
        )
        guard legacy.sidebarOrder == nil else { exit(1) }

        let groupID = UUID()
        let current = SessionSnapshot(
            projects: [],
            selectedProjectIndex: nil,
            sidebarOrder: [.group(groupID)],
            isLeftSidebarVisible: nil,
            isRightPanelVisible: nil,
            rightPanelTab: nil
        )
        let restored = try JSONDecoder().decode(
            SessionSnapshot.self,
            from: JSONEncoder().encode(current)
        )
        guard restored.sidebarOrder == [.group(groupID)] else { exit(1) }
        print("PASS legacy and current sidebar order snapshots decode")
    }
}
'''
    )
    session_executable = Path(directory) / "session-snapshot-tests"
    subprocess.run(
        ["xcrun", "swiftc", "-parse-as-library", str(session_helper), "-o", str(session_executable)],
        check=True,
    )
    subprocess.run([str(session_executable)], check=True)

sidebar = SIDEBAR_SOURCE.read_text()
manager = MANAGER_SOURCE.read_text()
session = SESSION_SOURCE.read_text()
content = CONTENT_SOURCE.read_text()
assert "for item in manager.sidebarTopLevelItems" in sidebar
assert "items += manager.projects.filter { $0.groupID == id }" in sidebar
assert "manager.moveSidebarItem(item, to: target)" in sidebar
assert "tabDrag.updateGroupDrag(" in sidebar
assert "tabDrag.commitGroupDrag()" in sidebar
assert "func commitGroupDrag()" in content
assert "manager.moveGroupTabs(" in content
assert "var sidebarTopLevelItems: [ProjectSidebarItem]" in manager
assert "sidebarOrder: sidebarTopLevelItems.compactMap" in manager
assert "var sidebarOrder: [SidebarItemSnapshot]? = nil" in session
