import Darwin
import Foundation

@main
struct SettingsConfigFileTests {
    nonisolated final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var texts: [String] = []

        func append(_ text: String) {
            lock.lock()
            texts.append(text)
            lock.unlock()
        }

        var values: [String] {
            lock.lock()
            defer { lock.unlock() }
            return texts
        }
    }

    nonisolated static func check(_ condition: Bool, _ message: String) {
        guard condition else { fatalError(message) }
    }

    nonisolated static func wait(_ condition: () -> Bool, _ message: String) {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { Thread.sleep(forTimeInterval: 0.025) }
        check(condition(), message)
    }

    nonisolated static func mode(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as! NSNumber).intValue
    }

    @MainActor static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let manager = FileManager.default
        let configDirectory = root.appendingPathComponent("config", isDirectory: true)
        let dotfiles = root.appendingPathComponent("dotfiles", isDirectory: true)
        try manager.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        try manager.createDirectory(at: dotfiles, withIntermediateDirectories: true)
        let config = configDirectory.appendingPathComponent("config.toml")
        let intermediate = dotfiles.appendingPathComponent("current")
        let target = dotfiles.appendingPathComponent("settings.toml")
        try "font-size = 14\n".write(to: target, atomically: true, encoding: .utf8)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        try manager.createSymbolicLink(atPath: intermediate.path, withDestinationPath: "settings.toml")
        try manager.createSymbolicLink(atPath: config.path, withDestinationPath: "../dotfiles/current")
        try SettingsConfigFile.write("font-size = 16\n", at: config)
        check(try manager.destinationOfSymbolicLink(atPath: config.path) == "../dotfiles/current", "relative config link survives save")
        check(try manager.destinationOfSymbolicLink(atPath: intermediate.path) == "settings.toml", "intermediate link survives save")
        check(try SettingsConfigFile.read(at: target) == "font-size = 16\n", "save writes final target")
        check(try mode(target) == 0o600, "private target permissions survive atomic save")
        try manager.setAttributes([.posixPermissions: 0o640], ofItemAtPath: target.path)
        try SettingsConfigFile.write("font-size = 17\n", at: config)
        check(try mode(target) == 0o640, "nondefault mode survives save")
        try SettingsConfigFile.backUp(at: config)
        let backup = configDirectory.appendingPathComponent("config.toml.bak")
        check(try SettingsConfigFile.read(at: backup) == "font-size = 17\n", "backup stores actual contents")
        check(try mode(backup) == 0o600, "new backups are private")
        try manager.removeItem(at: backup)
        try manager.createSymbolicLink(atPath: backup.path, withDestinationPath: "../dotfiles/current")
        try SettingsConfigFile.backUp(at: config)
        var backupAttributes = stat()
        check(lstat(backup.path, &backupAttributes) == 0
            && backupAttributes.st_mode & S_IFMT == S_IFREG, "legacy linked backup becomes independent contents")

        let linkedDirectory = root.appendingPathComponent("linked-directory")
        try manager.createSymbolicLink(atPath: linkedDirectory.path, withDestinationPath: "dotfiles")
        try SettingsConfigFile.write("font-size = 18\n", at: linkedDirectory.appendingPathComponent("settings.toml"))
        check(try SettingsConfigFile.read(at: target) == "font-size = 18\n", "linked directory resolves")
        let dangling = configDirectory.appendingPathComponent("dangling.toml")
        try manager.createSymbolicLink(atPath: dangling.path, withDestinationPath: "../missing/nested/settings.toml")
        try SettingsConfigFile.write("font-size = 19\n", at: dangling)
        check(try manager.destinationOfSymbolicLink(atPath: dangling.path) == "../missing/nested/settings.toml", "dangling link survives")
        check(try SettingsConfigFile.read(at: dangling) == "font-size = 19\n", "dangling target and parents are created")

        let cycle = root.appendingPathComponent("cycle")
        try manager.createSymbolicLink(atPath: cycle.path, withDestinationPath: "cycle")
        do { _ = try SettingsConfigFile.read(at: cycle); fatalError("cyclic link was accepted") }
        catch SettingsConfigFile.Failure.tooManyLinks {}
        let oversized = root.appendingPathComponent("oversized.toml")
        try Data(repeating: 65, count: SettingsConfigFile.maximumBytes + 1).write(to: oversized)
        do { _ = try SettingsConfigFile.read(at: oversized); fatalError("oversized file was accepted") }
        catch SettingsConfigFile.Failure.tooLarge {}
        let pipe = root.appendingPathComponent("pipe.toml")
        check(mkfifo(pipe.path, 0o600) == 0, "create FIFO")
        do { _ = try SettingsConfigFile.read(at: pipe); fatalError("FIFO was accepted") }
        catch SettingsConfigFile.Failure.notRegularFile {}

        let events = Events()
        let monitor = SettingsConfigMonitor(url: config)
        monitor.start { text, _ in events.append(text) }
        wait({ events.values.last == "font-size = 18\n" }, "monitor initial read")
        let noisyWrites = DispatchGroup()
        noisyWrites.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { noisyWrites.leave() }
            let noise = dotfiles.appendingPathComponent("unrelated-editor-cache")
            let deadline = Date().addingTimeInterval(2)
            while Date() < deadline {
                try? Data([1]).write(to: noise, options: .atomic)
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        let changedAt = Date()
        try "font-size = 26\n".write(to: target, atomically: true, encoding: .utf8)
        wait({ events.values.last == "font-size = 26\n" }, "config reload survives unrelated directory writes")
        let reloadDelay = Date().timeIntervalSince(changedAt)
        noisyWrites.wait()
        check(reloadDelay < 1.5, "unrelated directory writes cannot starve config reload: \(reloadDelay)s")

        let direct = try FileHandle(forWritingTo: target)
        try direct.truncate(atOffset: 0)
        try direct.write(contentsOf: Data("font-size = 20\n".utf8))
        try direct.close()
        wait({ events.values.last == "font-size = 20\n" }, "in-place target change reaches monitor")
        let atomic = dotfiles.appendingPathComponent("replacement")
        try "font-size = 21\n".write(to: atomic, atomically: true, encoding: .utf8)
        check(rename(atomic.path, target.path) == 0, "atomic target replacement")
        wait({ events.values.last == "font-size = 21\n" }, "atomic target replacement reaches monitor")
        let other = dotfiles.appendingPathComponent("other.toml")
        try "font-size = 22\n".write(to: other, atomically: true, encoding: .utf8)
        try manager.removeItem(at: intermediate)
        try manager.createSymbolicLink(atPath: intermediate.path, withDestinationPath: "other.toml")
        wait({ events.values.last == "font-size = 22\n" }, "intermediate relink reaches monitor")

        let secondDirectory = root.appendingPathComponent("second-dotfiles", isDirectory: true)
        try manager.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
        let secondTarget = secondDirectory.appendingPathComponent("other.toml")
        try "font-size = 23\n".write(to: secondTarget, atomically: true, encoding: .utf8)
        let watchedDirectory = root.appendingPathComponent("watched-directory")
        try manager.createSymbolicLink(atPath: watchedDirectory.path, withDestinationPath: "dotfiles")
        let directoryEvents = Events()
        let directoryMonitor = SettingsConfigMonitor(url: watchedDirectory.appendingPathComponent("other.toml"))
        directoryMonitor.start { text, _ in directoryEvents.append(text) }
        wait({ directoryEvents.values.last == "font-size = 22\n" }, "directory monitor initial read")
        try manager.removeItem(at: watchedDirectory)
        try manager.createSymbolicLink(atPath: watchedDirectory.path, withDestinationPath: "second-dotfiles")
        wait({ directoryEvents.values.last == "font-size = 23\n" }, "directory relink reaches monitor")

        let countBeforeDeletion = events.values.count
        try manager.removeItem(at: other)
        Thread.sleep(forTimeInterval: 0.6)
        check(events.values.count == countBeforeDeletion, "missing file retains last config")
        try "font-size = 24\n".write(to: other, atomically: true, encoding: .utf8)
        wait({ events.values.last == "font-size = 24\n" }, "recreated target reaches monitor")
        try "".write(to: other, atomically: true, encoding: .utf8)
        Thread.sleep(forTimeInterval: 0.4)
        check(events.values.last == "font-size = 24\n", "transient empty file retains config")
        try "font-size = 25\n".write(to: other, atomically: true, encoding: .utf8)
        wait({ events.values.last == "font-size = 25\n" }, "completed edit after truncation")
        try "".write(to: other, atomically: true, encoding: .utf8)
        wait({ events.values.last == "" }, "stable empty file is valid")

        let beforeSave = events.values.count
        for size in 8...32 { monitor.save("font-size = \(size)\n") }
        monitor.flush()
        check(try SettingsConfigFile.read(at: config) == "font-size = 32\n", "flush persists latest queued UI save")
        Thread.sleep(forTimeInterval: 0.7)
        check(events.values.count == beforeSave, "own saves do not reload")
        check(!monitor.isCurrent(0), "stale read is rejected after save")
        print("SettingsConfigFile: symlinks, permissions, bounded reads, live edits, atomic replacements, deletion, debounce and flush passed")
    }
}
