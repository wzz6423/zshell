import AppKit
import Combine
import Darwin
import Foundation
#if ZSHELL_FILE_TREE_BUILT_APP
@testable import zshell
#endif

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

@MainActor private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure(description: message) }
}

private func ms(_ start: ContinuousClock.Instant) -> Double {
    let duration = start.duration(to: .now)
    return Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1.0e15
}

@MainActor private func eventually(_ label: String, timeout: Double = 15, _ condition: () -> Bool) async throws {
    let started = ContinuousClock.now
    while !condition() {
        try require(ms(started) < timeout * 1_000, "Timed out: \(label)")
        try await Task.sleep(for: .milliseconds(5))
    }
}

@MainActor private func isRefreshing(_ model: FileTreeModel) -> Bool {
    for child in Mirror(reflecting: model).children where child.label == "localRefreshTask" {
        return !Mirror(reflecting: child.value).children.isEmpty
    }
    fatalError("localRefreshTask not found")
}

@MainActor private func cacheCount(_ model: FileTreeModel) -> Int {
    for child in Mirror(reflecting: model).children where child.label == "localListings" {
        return Mirror(reflecting: child.value).children.count
    }
    fatalError("localListings not found")
}

@MainActor private func draftCreationSafety(in root: URL) async throws {
    let fm = FileManager.default
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    let existingFile = root.appendingPathComponent("existing.txt")
    let existingDirectory = root.appendingPathComponent("existing-folder", isDirectory: true)
    let contents = Data("Keep the existing contents.".utf8)
    try contents.write(to: existingFile)
    try fm.createDirectory(at: existingDirectory, withIntermediateDirectories: false)
    let child = existingDirectory.appendingPathComponent("child.txt")
    try contents.write(to: child)
    let danglingLink = root.appendingPathComponent("dangling-link")
    let missingTarget = root.appendingPathComponent("missing-target")
    let fileLink = root.appendingPathComponent("file-link")
    let directoryLink = root.appendingPathComponent("directory-link")
    for (link, target) in [(danglingLink, missingTarget), (fileLink, existingFile), (directoryLink, existingDirectory)] {
        try fm.createSymbolicLink(at: link, withDestinationURL: target)
    }
    try require(!fm.fileExists(atPath: danglingLink.path), "Dangling symlink bypasses the existence precheck")

    let model = FileTreeModel()
    model.sync(root: root.path)
    try await eventually("creation safety fixture") { model.items.count == 5 && !isRefreshing(model) }
    for path in [existingFile, existingDirectory, danglingLink, fileLink, directoryLink] {
        model.beginNewFile(in: root.path)
        try require(model.items.first?.isDraft == true, "Collision draft visible immediately")
        try require(model.commitDraft(name: path.lastPathComponent) == nil, "Existing path must not count as a created file: \(path.lastPathComponent)")
        try require(model.draft == nil && !model.items.contains(where: \.isDraft), "Rejected creation clears the inline draft")
        try require(model.commitDraft(name: "ignored.txt") == nil, "Blur after submission cannot create another file")
        try await eventually("rejected creation refresh") { !isRefreshing(model) }
        try require(!model.items.contains(where: \.isDraft), "An older refresh cannot restore the rejected draft")
    }
    let savedFileContents = try Data(contentsOf: existingFile)
    let savedChildContents = try Data(contentsOf: child)
    try require(savedFileContents == contents, "Existing file contents preserved")
    try require(savedChildContents == contents, "Existing directory contents preserved")
    for (link, target) in [(danglingLink, missingTarget), (fileLink, existingFile), (directoryLink, existingDirectory)] {
        let destination = try fm.destinationOfSymbolicLink(atPath: link.path)
        try require(destination == target.path, "Existing symbolic link preserved")
    }
    try require(!fm.fileExists(atPath: missingTarget.path), "Creation cannot create a dangling link's target")
    try require(!fm.fileExists(atPath: root.appendingPathComponent("ignored.txt").path), "Repeated draft submission is a no-op")

    model.beginNewFile(in: root.path)
    let created = root.appendingPathComponent("new.txt")
    try require(model.commitDraft(name: " new.txt ") == created.path, "Normal creation returns the trimmed path")
    let createdContents = try Data(contentsOf: created)
    try require(createdContents.isEmpty, "Normal creation produces an empty file")
    try require(model.draft == nil && !model.items.contains(where: \.isDraft), "Normal creation clears the draft immediately")
    try await eventually("successful creation safety refresh") { model.items.contains { $0.path == created.path } && !isRefreshing(model) }
    model.beginNewFolder(in: root.path)
    let createdFolder = root.appendingPathComponent("new-folder")
    try require(model.commitDraft(name: createdFolder.lastPathComponent) == nil, "Folder creation returns no file path")
    try await eventually("normal folder creation") { model.items.contains { $0.path == createdFolder.path && $0.isDirectory } && !isRefreshing(model) }
    print("PASS exclusive file creation: existing file/directory, dangling/live symbolic links, contents preserved, normal file/folder creation, inline draft cleared")
}

@MainActor private final class Heartbeat {
    var maximumGap = 0.0
    var count = 0
    var last = ContinuousClock.now
    func pulse() {
        maximumGap = max(maximumGap, ms(last))
        last = .now
        count += 1
    }
    func reset() {
        maximumGap = 0
        count = 0
        last = .now
    }
}

@main struct FileTreeBackgroundTests {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        setbuf(stderr, nil)
#if ZSHELL_FILE_TREE_BUILT_APP
        NSApplication.shared.setActivationPolicy(.prohibited)
#endif
        let fm = FileManager.default
        try require(CommandLine.arguments.count == 2, "Pass a temporary fixture directory")
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try await draftCreationSafety(in: root.appendingPathComponent("creation-safety", isDirectory: true))
#if ZSHELL_FILE_TREE_BUILT_APP
        print("PASS creation safety against the built zshell module and real AppKit dependencies")
        return
#else
        let large = root.appendingPathComponent("large", isDirectory: true)
        let small = root.appendingPathComponent("small", isDirectory: true)
        let nested = small.appendingPathComponent("folder2", isDirectory: true)
        for dir in [large, small, nested, small.appendingPathComponent("folder10"), small.appendingPathComponent(".git")] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        await Task.detached {
            for index in 0..<10_000 {
                requireFile(fm.createFile(atPath: large.appendingPathComponent("file\(index).txt").path, contents: nil))
            }
        }.value
        for name in ["file10.txt", "file2.txt", ".hidden", "中文\n文件"] {
            try require(fm.createFile(atPath: small.appendingPathComponent(name).path, contents: nil), "Create fixture")
        }
        try require(fm.createFile(atPath: nested.appendingPathComponent("child.txt").path, contents: nil), "Create child")
        let external = root.appendingPathComponent("external")
        try fm.createDirectory(at: external, withIntermediateDirectories: true)
        let target = external.appendingPathComponent("target")
        try require(fm.createFile(atPath: target.path, contents: nil), "Create symlink target")
        try fm.createSymbolicLink(atPath: small.appendingPathComponent("link").path, withDestinationPath: target.path)

        let model = FileTreeModel()
        let heartbeat = Heartbeat()
        let heartbeatTask = Task { @MainActor in
            while !Task.isCancelled {
                heartbeat.pulse()
                do { try await Task.sleep(for: .milliseconds(5)) } catch { break }
            }
        }
        defer { heartbeatTask.cancel() }
        try await Task.sleep(for: .milliseconds(10))
        heartbeat.reset()
        var publications = 0
        let observation = model.$items.dropFirst().sink { _ in publications += 1 }
        defer { observation.cancel() }

        let initialStart = ContinuousClock.now
        let syncStart = ContinuousClock.now
        model.sync(root: large.path)
        let syncDuration = ms(syncStart)
        try require(model.items.isEmpty, "Initial sync must yield before I/O")
        try await eventually("initial large tree") { model.items.count == 10_000 && !isRefreshing(model) }
        heartbeat.pulse()
        let initialDuration = ms(initialStart)
        try require(model.items.first?.name == "file0.txt", "Natural order start")
        try require(model.items[2].name == "file2.txt", "Natural order numbers")
        try require(model.items.last?.name == "file9999.txt", "Natural order end")
        try require(cacheCount(model) == 1, "Only current root cached")
        print(String(format: "10000 files: sync=%.3fms ready=%.3fms heartbeat_max_gap=%.3fms beats=%d", syncDuration, initialDuration, heartbeat.maximumGap, heartbeat.count))
        try require(heartbeat.maximumGap < 250, "Background scan must not stall the main actor")

        let unchangedPublications = publications
        var cachedDurations: [Double] = []
        for _ in 0..<5 {
            let start = ContinuousClock.now
            model.sync(root: large.path)
            try await eventually("unchanged large tree") { !isRefreshing(model) }
            cachedDurations.append(ms(start))
        }
        try require(publications == unchangedPublications, "Unchanged refresh must not republish")
        print("unchanged refresh ms=\(cachedDurations.map { String(format: "%.3f", $0) }.joined(separator: ",")) publications=0")

        let burstStart = ContinuousClock.now
        for _ in 0..<100 { model.sync(root: large.path) }
        try await eventually("coalesced repeated refresh") { !isRefreshing(model) }
        try require(publications == unchangedPublications, "Refresh burst must not republish")
        print(String(format: "100 sync calls coalesced: ready=%.3fms", ms(burstStart)))

        model.sync(root: small.path)
        try await eventually("small root") { model.items.count == 7 && !isRefreshing(model) }
        try require(!model.items.contains { $0.name == ".git" }, ".git stays hidden")
        try require(model.items.contains { $0.name == ".hidden" }, "Hidden files retained")
        try require(model.items.contains { $0.name == "中文\n文件" }, "Unicode and newline names retained")
        try require(model.items.prefix(2).map(\.name) == ["folder2", "folder10"], "Directories before files in natural order")
        let folder = model.items.first { $0.name == "folder2" }!
        model.toggle(folder)
        try await eventually("expand folder") { model.items.contains { $0.name == "child.txt" && $0.depth == 1 } && !isRefreshing(model) }
        try require(cacheCount(model) == 2, "Expanded visible cache")
        try require(fm.createFile(atPath: nested.appendingPathComponent("new-child.txt").path, contents: nil), "Create externally")
        model.sync(root: small.path)
        try await eventually("expanded child refresh") { model.items.contains { $0.name == "new-child.txt" } && !isRefreshing(model) }
        model.toggle(folder)
        try await eventually("collapse folder") { !model.items.contains { $0.depth > 0 } && !isRefreshing(model) }
        try require(cacheCount(model) == 1, "Collapsed listing pruned")
        model.toggle(folder)
        model.toggle(folder)
        try await eventually("expand then immediate collapse") { !isRefreshing(model) }
        try require(!model.items.contains { $0.depth > 0 }, "Older expand cannot publish over collapse")

        model.sync(root: small.path)
        model.beginNewFile(in: nested.path)
        try require(model.items.contains { $0.isDraft && $0.depth == 1 }, "Nested draft visible immediately")
        model.cancelDraft()
        try require(!model.items.contains(where: \.isDraft), "Draft removed immediately")
        try await eventually("cancel nested draft while refresh running") { !isRefreshing(model) }
        try require(!model.items.contains(where: \.isDraft), "Older draft snapshot cannot publish")
        model.beginNewFile(in: small.path)
        try require(model.items.first?.isDraft == true, "Root draft at top immediately")
        let created = model.commitDraft(name: "created.txt")
        try require(created == small.appendingPathComponent("created.txt").path, "Created file return path")
        try require(!model.items.contains(where: \.isDraft), "Committed draft removed immediately")
        try await eventually("created file refresh") { model.items.contains { $0.name == "created.txt" } && !isRefreshing(model) }
        model.beginNewFolder(in: small.path)
        try require(model.commitDraft(name: "created-folder") == nil, "Folder creation returns no file")
        try await eventually("created folder refresh") { model.items.contains { $0.name == "created-folder" && $0.isDirectory } && !isRefreshing(model) }

        let renamedFolder = model.rename(folder, to: "renamed-folder")!
        try await eventually("renamed expanded folder") {
            model.items.contains { $0.path == renamedFolder + "/child.txt" && $0.depth == 1 } && !isRefreshing(model)
        }
        try require(!model.items.contains { $0.path.hasPrefix(nested.path + "/") }, "Rename removes old descendants")
        let createdItem = model.items.first { $0.name == "created.txt" }!
        model.beginRename(createdItem)
        model.sync(root: small.path)
        try await eventually("refresh during inline rename") { !isRefreshing(model) }
        try require(model.renamingPath == createdItem.path, "Periodic refresh preserves inline rename")
        let renamedFile = model.rename(createdItem, to: "renamed.txt")!
        try await eventually("renamed file") { model.items.contains { $0.path == renamedFile } && !isRefreshing(model) }
        try require(!model.items.contains { $0.path == createdItem.path }, "Old filename removed")

        try fm.removeItem(at: target)
        try fm.createDirectory(at: target, withIntermediateDirectories: false)
        model.sync(root: small.path)
        try await eventually("symlink target became directory") { model.items.contains { $0.name == "link" && $0.isDirectory } && !isRefreshing(model) }
        try fm.removeItem(at: target)
        try require(fm.createFile(atPath: target.path, contents: nil), "Replace symlink target with file")
        model.sync(root: small.path)
        try await eventually("symlink target became file") { model.items.contains { $0.name == "link" && !$0.isDirectory } && !isRefreshing(model) }
        let changedFile = small.appendingPathComponent("file2.txt")
        try fm.removeItem(at: changedFile)
        try fm.createDirectory(at: changedFile, withIntermediateDirectories: false)
        model.sync(root: small.path)
        try await eventually("file replaced with directory") { model.items.contains { $0.name == "file2.txt" && $0.isDirectory } && !isRefreshing(model) }

        let savedDirectory = root.appendingPathComponent("saved-directory")
        let renamedDirectoryURL = URL(fileURLWithPath: renamedFolder)
        try fm.moveItem(at: renamedDirectoryURL, to: savedDirectory)
        try fm.createSymbolicLink(at: renamedDirectoryURL, withDestinationURL: savedDirectory)
        model.sync(root: small.path)
        try await eventually("symlink to cached directory") { model.items.contains { $0.path == renamedFolder + "/child.txt" } && !isRefreshing(model) }
        let danglingDirectory = root.appendingPathComponent("unreadable-directory")
        try fm.createDirectory(at: danglingDirectory, withIntermediateDirectories: false)
        if geteuid() != 0 {
            try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: danglingDirectory.path)
        }
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: danglingDirectory.path) }
        try fm.removeItem(at: renamedDirectoryURL)
        try fm.createSymbolicLink(at: renamedDirectoryURL, withDestinationURL: danglingDirectory)
        model.sync(root: small.path)
        try await eventually("unreadable directory clears contents") { !model.items.contains { $0.path.hasPrefix(renamedFolder + "/") } && !isRefreshing(model) }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: danglingDirectory.path)
        try require(fm.createFile(atPath: danglingDirectory.appendingPathComponent("restored.txt").path, contents: nil), "Create after access restored")
        model.sync(root: small.path)
        try await eventually("readable directory recovers") { model.items.contains { $0.name == "restored.txt" } && !isRefreshing(model) }

        let trashName = "zshell-file-tree-trash-\(UUID()).txt"
        let trashURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".Trash/" + trashName)
        defer { try? fm.removeItem(at: trashURL) }
        let trashSource = model.items.first { $0.name == "renamed.txt" }!
        try require(model.rename(trashSource, to: trashName) != nil, "Prepare uniquely named trash fixture")
        try await eventually("unique trash source") { model.items.contains { $0.name == trashName } && !isRefreshing(model) }
        let trashItem = model.items.first { $0.name == trashName }!
        model.moveToTrash(trashItem)
        try await eventually("trash refresh") { !model.items.contains { $0.path == trashItem.path } && !isRefreshing(model) }
        try require(!fm.fileExists(atPath: trashItem.path), "Trash removed backing file")

        var mismatchedRoots = 0
        let rootObservation = model.$items.sink { rows in
            if rows.contains(where: { !$0.path.hasPrefix(model.rootPath + "/") }) { mismatchedRoots += 1 }
        }
        defer { rootObservation.cancel() }
        heartbeat.reset()
        model.sync(root: large.path)
        await Task.yield()
        model.sync(root: small.path)
        try await eventually("root switch after yielding to the worker") { !isRefreshing(model) && model.rootPath == small.path }
        heartbeat.pulse()
        try require(mismatchedRoots == 0, "Running worker cannot publish after root switch")
        print(String(format: "root switch with queued scan: heartbeat_max_gap=%.3fms", heartbeat.maximumGap))
        for _ in 0..<20 {
            model.sync(root: large.path)
            model.sync(root: small.path)
        }
        try await eventually("rapid root switches") { !isRefreshing(model) && model.rootPath == small.path }
        try require(mismatchedRoots == 0, "Old worker never publishes against a new root")
        try require(cacheCount(model) <= 2, "No historical roots retained")
        model.sync(root: large.path)
        model.configureRemote(SSHEndpoint(host: "test.example"))
        model.sync(root: "/remote")
        try await eventually("switch to remote during local scan") { model.items.map(\.name) == ["remote-file.txt"] && !isRefreshing(model) }
        try require(model.isRemote, "Remote source remains selected")
        try require(cacheCount(model) == 0, "Remote transition drops local cache")
        model.configureRemote(nil)
        model.sync(root: small.path)
        try await eventually("return to local") { !model.items.isEmpty && !isRefreshing(model) }
        model.sync(root: large.path)
        model.sync(root: "")
        try await eventually("clear root during local scan") { !isRefreshing(model) }
        try require(model.items.isEmpty && cacheCount(model) == 0, "Empty root stays empty")
        try require(heartbeat.maximumGap < 250, "Background transitions must not stall the main actor")
        print("PASS: background I/O/sort, unchanged no publish, burst coalescing, .git/hidden/unicode/natural ordering, nested refresh/cache pruning, rapid toggle, draft immediate/late cancellation, create/rename/trash, symlink type, file replacement, unreadable recovery, root/remote/empty transitions")
#endif
    }

    private nonisolated static func requireFile(_ created: Bool) {
        precondition(created, "Create large fixture")
    }
}
