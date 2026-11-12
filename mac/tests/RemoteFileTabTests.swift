import AppKit
import Foundation
@testable import zshell

@main struct RemoteFileTabTests {
    @MainActor private static var checks = 0

    @MainActor private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        checks += 1
        guard try condition() else { throw NSError(domain: "RemoteFileTabTests", code: checks, userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    @MainActor private static func eventually(_ message: String, _ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(domain: "RemoteFileTabTests", code: 0, userInfo: [NSLocalizedDescriptionKey: message])
    }

    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let path = root.appendingPathComponent("remote.txt")
        try Data("baseline".utf8).write(to: path)
        let service = RemoteFileService(transport: OpenSSHTransport(executableURL: URL(fileURLWithPath: CommandLine.arguments[2])))
        let remote = RemoteFileSource(endpoint: try SSHEndpoint(host: "fixture.invalid"), root: root.path)
        let settings = AppSettings.shared
        settings.remoteFileWritesEnabled = true
        let localDraftID = UUID()
        let localRecord = EditorDraftRecord(id: localDraftID, source: .file(path: path.path), text: "local backup must survive",
                                           baseline: try FileSaveCoordinator.read(path: path.path))
        try EditorDraftStore.shared.archive.flush([localRecord])
        let file = FileTab(path: path.path, source: .remote(remote), remoteFiles: service, draftID: localDraftID, recoveringDraft: true)
        try await eventually("Remote file did not load") { if case .text = file.content { return file.allowsEditing }; return false }
        try require(file.text == "baseline" && file.displayPath == "fixture.invalid:" + path.path,
                    "Remote reads keep the host attached and ignore local recovery records")
        file.text = "draft"
        file.refreshDirtyState()
        try require(file.draftSnapshot() == nil && PaneContent.file(file).draftID == nil,
                    "Remote drafts do not enter the local-only archive or session draft IDs")
        file.discardDraftBackup()
        let retained = try await EditorDraftStore.shared.archive.load(localDraftID)
        try require(retained?.text == localRecord.text, "Remote discard cannot remove an unrelated local backup")
        let saved = await PaneContent.file(file).saveAndWait()
        try require(saved && !file.isDirty && file.saveError == nil, "Async pane save waits for SSH completion")
        try require(try String(contentsOf: path, encoding: .utf8) == "draft", "Async save writes the draft bytes")
        try Data("agent edit".utf8).write(to: path)
        file.text = "unsaved draft"
        file.refreshDirtyState()
        var conflicts = 0
        file.save { _, _ in conflicts += 1; return .keepDraft }
        try await eventually("Remote conflict did not settle") { !file.isSaving }
        try require(conflicts == 1 && file.isDirty && file.text == "unsaved draft", "Conflict retains dirty text without opening a dialog")
        try require(try String(contentsOf: path, encoding: .utf8) == "agent edit", "Conflict preserves the external writer")
        file.save { _, _ in .reload }
        try await eventually("Remote reload did not settle") { !file.isDirty && file.text == "agent edit" }
        try require(!file.isDirty, "Reload can discard exactly the compared draft")
        file.text = "disabled draft"
        file.refreshDirtyState()
        settings.remoteFileWritesEnabled = false
        try await eventually("Remote write setting did not apply") { !file.allowsEditing }
        let disabledSave = await file.saveAndWait()
        try require(!disabledSave && file.isDirty, "Disabling writes preserves unsaved drafts and rejects saving")
        settings.remoteFileWritesEnabled = true
        try await eventually("Remote write setting did not recover") { file.allowsEditing }
        file.save { _, _ in .overwrite }
        file.close()
        try await eventually("Cancelled save did not settle") { !file.isSaving }
        try require(try String(contentsOf: path, encoding: .utf8) == "agent edit", "Closing cancels a save before its SSH operation starts")
        let unavailable = FileTab(path: path.path, source: .unavailableRemote, remoteFiles: service)
        try require({ if case .unavailable = unavailable.content { return true }; return false }(),
                    "An unavailable remote source never loads a matching local path")
        try require(!FileSource.local.sharesFilesystem(with: .remote(remote)), "Remote renames cannot propagate into local projects")
        let other = RemoteFileSource(endpoint: try SSHEndpoint(host: "other.invalid"), root: root.path)
        try require(!FileSource.remote(remote).sharesFilesystem(with: .remote(other)), "Remote renames cannot cross hosts with matching paths")
        unavailable.close()
        try require(NSApp.windows.allSatisfy { !$0.isVisible }, "The model probe never creates visible windows")
        print("Remote FileTab: \(checks) checks passed; prohibited activation, no windows or input events")
    }
}
