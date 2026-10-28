import AppKit
import CryptoKit
import Darwin
@testable import zshell

@main
struct RemoteServerManagementTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let executable = URL(fileURLWithPath: CommandLine.arguments[1])
        let root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let address = CommandLine.arguments[3]
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
            precondition(condition(), label)
            checks += 1
            print("PASS \(label)")
        }
        let legacy = Data("{\"id\":\"\(UUID())\",\"name\":\"legacy\",\"address\":\"ssh://example.com\",\"serverPath\":\"~/.local/bin/zshell-server\"}".utf8)
        let decoded = try JSONDecoder().decode(RemoteHost.self, from: legacy)
        expect(decoded.serverPath == "~/.local/bin/zshell-server", "old host configurations retain their server path")
        let remote = try RemoteHost(name: "Remote", address: address, serverPath: "/home/dev/server")
        let roundTrip = try JSONDecoder().decode(RemoteHost.self, from: JSONEncoder().encode(remote))
        expect(roundTrip == remote, "host and absolute executable path persist")
        do {
            _ = try RemoteHost(name: "invalid", address: address, serverPath: "relative")
            preconditionFailure("relative executable accepted")
        } catch { checks += 1 }
        let legacyEndpoint = try JSONDecoder().decode(SSHEndpoint.self, from: Data("{\"host\":\"example.com\"}".utf8))
        expect(legacyEndpoint.destination == "example.com", "old SSH projects retain their destination")
        expect(RemoteHostTransport.isTailnetAddress("100.64.0.10") && !RemoteHostTransport.isTailnetAddress("127.0.0.1"), "GUI sharing accepts only Tailscale numeric ranges")

        let installPath = root.appendingPathComponent("remote server 'quoted'/zshell-server").path
        let host = try RemoteHost(name: "Installer fixture", address: address, serverPath: installPath)
        let target = try RemoteServerInstaller.inspect(host: host)
        expect(target.platform == "macos" && target.architecture == "aarch64" && target.installed == nil,
               "SSH platform inspection works before installation")
        let version = try RemoteServerInstaller.install(host: host, target: target, executable: executable)
        expect(version.platform == target.platform && version.architecture == target.architecture,
               "GUI service uploads and validates a production server")
        let before = try Data(contentsOf: URL(fileURLWithPath: installPath))
        let sourceBytes = try Data(contentsOf: executable)
        expect(before == sourceBytes, "atomic installation preserves every executable byte")
        let bad = root.appendingPathComponent("incompatible-server")
        try Data("#!/bin/sh\nprintf '%s\\n' '{\"version\":\"0.1.0\",\"protocolVersion\":1,\"platform\":\"linux\",\"architecture\":\"x86_64\"}'\n".utf8).write(to: bad)
        do {
            _ = try RemoteServerInstaller.install(host: host, target: target, executable: bad)
            preconditionFailure("incompatible server installed")
        } catch { checks += 1 }
        let afterFailure = try Data(contentsOf: URL(fileURLWithPath: installPath))
        expect(afterFailure == before, "incompatible installation leaves the old server intact")
        let corrupt = root.appendingPathComponent("corrupt-server")
        try Data([0, 255, 0, 255]).write(to: corrupt)
        do {
            _ = try RemoteServerInstaller.install(host: host, target: target, executable: corrupt)
            preconditionFailure("corrupt server installed")
        } catch { checks += 1 }
        let afterCorruptUpload = try Data(contentsOf: URL(fileURLWithPath: installPath))
        expect(afterCorruptUpload == before,
               "unexecutable installation leaves the previous server intact")
        let parent = URL(fileURLWithPath: installPath).deletingLastPathComponent()
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: parent.path)
        expect(leftovers == ["zshell-server"], "failed and successful uploads remove their temporary executable")
        let inspected = try RemoteServerInstaller.inspect(host: host)
        expect(inspected.installed == version, "GUI inspection reads the installed server version")
        let second = try RemoteServerInstaller.install(host: host, target: inspected, executable: executable)
        expect(second == version, "existing server updates through the same verified atomic path")
        try Data([0, 255, 0, 255]).write(to: URL(fileURLWithPath: installPath))
        let brokenTarget = try RemoteServerInstaller.inspect(host: host)
        expect(brokenTarget.platform == target.platform && brokenTarget.installed == nil,
               "a corrupt installed server still permits platform inspection")
        let repaired = try RemoteServerInstaller.install(host: host, target: brokenTarget, executable: executable)
        expect(repaired == version, "the installer repairs a corrupt existing server")

        let directoryDestination = root.appendingPathComponent("existing server directory", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryDestination, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: directoryDestination.appendingPathComponent("sentinel"))
        let directoryHost = try RemoteHost(name: "Directory destination", address: address, serverPath: directoryDestination.path)
        var directoryRejected = false
        do { _ = try RemoteServerInstaller.install(host: directoryHost, target: target, executable: executable) }
        catch { directoryRejected = true }
        expect(directoryRejected, "installation rejects an existing directory destination")
        let directoryContents = try FileManager.default.contentsOfDirectory(atPath: directoryDestination.path)
        expect(directoryContents == ["sentinel"], "rejected directory installation leaves no executable inside it")

        let symlinkDestination = root.appendingPathComponent("server symlink")
        try FileManager.default.createSymbolicLink(at: symlinkDestination, withDestinationURL: URL(fileURLWithPath: installPath))
        let symlinkHost = try RemoteHost(name: "Symlink destination", address: address, serverPath: symlinkDestination.path)
        var symlinkRejected = false
        do { _ = try RemoteServerInstaller.install(host: symlinkHost, target: target, executable: executable) }
        catch { symlinkRejected = true }
        expect(symlinkRejected, "installation rejects a symlink destination")
        let symlinkTarget = try FileManager.default.destinationOfSymbolicLink(atPath: symlinkDestination.path)
        expect(symlinkTarget == installPath, "rejected symlink installation preserves the link")
        let afterSymlinkRejection = try Data(contentsOf: URL(fileURLWithPath: installPath))
        expect(afterSymlinkRejection == before, "rejected symlink installation preserves the previous executable")

        let share = LocalRemoteSharing(stateURL: root.appendingPathComponent("sharing-state"))
        expect(share.endpoint == nil && !share.isRunning, "local sharing starts explicitly off")
        do {
            try await share.start(port: 7373, allowedUsers: ["*"], executable: executable)
            preconditionFailure("wildcard sharing allowed")
        } catch { checks += 1 }
        expect(share.endpoint == nil && !share.isRunning, "invalid sharing authorization starts no process")
        share.stop()
        expect(!share.isRunning, "stopping inactive sharing is harmless")
        print("\(checks) host management checks passed")
    }
}
