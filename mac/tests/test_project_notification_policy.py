"""Exercise the production project snapshot and bell path without system alerts."""
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]
SUPPORT = r'''
import Foundation
struct EditorState: Codable {}
enum PaneSplitAxis: String, Codable { case horizontal, vertical }
struct TerminalLaunchSettingsOverride: Codable, Equatable {}
struct SessionTabGroup: Codable {}
struct TerminalLaunchSettings: Codable, Equatable {}
struct AgentConversationIdentity: Codable {}
struct SessionWorktree: Codable {}
enum ProjectLocation: Codable { case local }
enum RightPanel: String, Codable { case files }
'''
SNAPSHOT_FIXTURE = r'''
@main struct ProjectNotificationSnapshotTests {
    static func main() throws {
        let decoder = JSONDecoder()
        let legacy = try decoder.decode(SessionSnapshot.ProjectSnapshot.self, from: Data(#"{"tabs":[]}"#.utf8))
        precondition(!legacy.notificationsMuted)
        let unmuted = try JSONEncoder().encode(legacy)
        let object = try JSONSerialization.jsonObject(with: unmuted) as! [String: Any]
        precondition(object["notificationsMuted"] == nil)
        print("PASS legacy project snapshots default to unmuted and omit the default policy")
        var muted = legacy
        let identity = UUID()
        muted.customName = "Same name"
        muted.conversationHistoryProjectID = identity
        muted.notificationsMuted = true
        let data = try JSONEncoder().encode(muted)
        let restored = try decoder.decode(SessionSnapshot.ProjectSnapshot.self, from: data)
        precondition(restored.notificationsMuted && restored.conversationHistoryProjectID == identity)
        print("PASS project mute survives a snapshot round trip with the existing persistent project identity")
        let snapshot = SessionSnapshot(projects: [muted, legacy], selectedProjectIndex: 0)
        let windows = try decoder.decode([SessionSnapshot].self, from: JSONEncoder().encode([snapshot, snapshot]))
        precondition(windows.count == 2 && windows.allSatisfy { $0.projects.map(\.notificationsMuted) == [true, false] })
        print("PASS separate windows retain each project's policy independently of project names")
    }
}
'''
BELL_SUPPORT = r'''
import Foundation
enum NSAccessibility {
    enum Notification { case announcementRequested }
    enum Key { case announcement, priority }
    static var announcements = 0
    static func post(element: Any, notification: Notification, userInfo: [Key: Any]) { announcements += 1 }
}
enum NSAccessibilityPriorityLevel: Int { case low }
enum NSSound {
    static var beeps = 0
    static func beep() { beeps += 1 }
}
final class Application {
    enum Attention { case informationalRequest }
    var isActive = false
    var attentionRequests = 0
    func requestUserAttention(_ attention: Attention) { attentionRequests += 1 }
}
let NSApp = Application()
struct Window { var isMiniaturized = false }
struct Surface { var hasEffectiveTerminalFocus = false; var window: Window? }
struct AppSettings {
    static var shared = AppSettings()
    var terminalBell = true
}
final class TerminalNotificationService {
    enum Kind { case bell }
    static let shared = TerminalNotificationService()
    static var muted = Set<UUID>()
    var history: [UUID] = []
    static func allowsProjectNotifications(for id: UUID) -> Bool { !muted.contains(id) }
    func post(message: String, sessionID: UUID, kind: Kind) { history.append(sessionID) }
}
final class TerminalSession {
    let id = UUID()
    var surface = Surface(window: nil)
'''
BELL_FIXTURE = r'''
@main struct ProjectNotificationBellTests {
    static func main() {
        let muted = TerminalSession(), audible = TerminalSession()
        TerminalNotificationService.muted.insert(muted.id)
        muted.terminalDidRingBell()
        precondition(NSAccessibility.announcements == 1 && NSSound.beeps == 0 && NSApp.attentionRequests == 0)
        precondition(TerminalNotificationService.shared.history == [muted.id])
        print("PASS project mute preserves bell history and accessibility while suppressing local sound and Dock attention")
        audible.terminalDidRingBell()
        precondition(NSSound.beeps == 1 && NSApp.attentionRequests == 1)
        muted.surface.hasEffectiveTerminalFocus = true
        muted.surface.window = Window(isMiniaturized: true)
        muted.terminalDidRingBell()
        precondition(NSSound.beeps == 1 && NSApp.attentionRequests == 1)
        precondition(TerminalNotificationService.shared.history == [muted.id, audible.id, muted.id])
        print("PASS minimized muted panes remain quiet while another project keeps its normal bell behavior")
        muted.surface.window = Window(isMiniaturized: false)
        muted.terminalDidRingBell()
        precondition(NSAccessibility.announcements == 4 && NSSound.beeps == 1)
        precondition(TerminalNotificationService.shared.history.count == 3)
        AppSettings.shared.terminalBell = false
        audible.terminalDidRingBell()
        precondition(NSAccessibility.announcements == 5 && NSSound.beeps == 1)
        precondition(TerminalNotificationService.shared.history.count == 3)
        print("PASS project mute keeps focused-pane and global bell switch behavior intact")
    }
}
'''

with tempfile.TemporaryDirectory(prefix="zshell-project-notification-", dir="/tmp") as directory:
    temporary = Path(directory)
    snapshot_source = temporary / "Snapshot.swift"
    snapshot_source.write_text(SUPPORT + (ROOT / "mac/zshell/SessionStore.swift").read_text() + SNAPSHOT_FIXTURE)
    bell_source = (ROOT / "mac/zshell/TerminalSession.swift").read_text()
    bell = bell_source[bell_source.index("    func terminalDidRingBell()"):
                       bell_source.index("    func terminalDidReportShellIntegration")]
    bell_fixture = temporary / "Bell.swift"
    bell_fixture.write_text(BELL_SUPPORT + bell + "}\n" + BELL_FIXTURE)
    for name, source in (("snapshot", snapshot_source), ("bell", bell_fixture)):
        binary = temporary / name
        subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
                        "-module-cache-path", str(temporary / "ModuleCache"), str(source), "-o", str(binary)],
                       cwd=ROOT, check=True)
        subprocess.run([str(binary)], cwd=ROOT, check=True, timeout=15)
