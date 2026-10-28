import AppKit
import Darwin
@testable import zshell

@MainActor
private final class PasteTestWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}

@MainActor
private func pumpPaste(_ duration: TimeInterval) {
    let deadline = Date().addingTimeInterval(duration)
    while Date() < deadline { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005)) }
}

@MainActor
private func waitPaste(_ label: String, timeout: TimeInterval = 15, _ condition: () -> Bool) throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return }
        pumpPaste(0.02)
    }
    throw NSError(domain: "RemotePasteTest", code: 1, userInfo: [NSLocalizedDescriptionKey: label])
}

@main
struct RemotePasteSurfaceTests {
    @MainActor static func main() {
        if RemoteSessionRelay.shouldRun { RemoteSessionRelay.run() }
        do {
            try runPathQuoting()
            if CommandLine.arguments.dropFirst().first != "--path-quoting" { try run() }
        }
        catch { fputs("Remote paste failed: \(error)\n", stderr); exit(1) }
    }

    @MainActor private static func runPathQuoting() throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) throws {
            guard condition() else { throw NSError(domain: "RemotePastePathTest", code: 1, userInfo: [NSLocalizedDescriptionKey: label]) }
            checks += 1
            print("PASS \(label)")
        }
        let paths = ["/tmp/it's $(printf injected);image.png",
                     #"/tmp/文件 with\backslash %! *? "`code`".png"#,
                     "/home/me/image:<>|.png"]
        for path in paths {
            try check(RemotePasteUpload.validPath(path), "remote paste accepts an absolute POSIX path")
            let quoted = try RemotePasteUpload.quotePath(path)
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "printf '%s' " + quoted]
            process.standardOutput = output
            try process.run()
            let bytes = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            try check(process.terminationStatus == 0 && String(decoding: bytes, as: UTF8.self) == path,
                      "POSIX shell reads the pasted path as one literal argument")
        }
        for invalid in ["", "relative.png", "~/image.png", #"C:\Users\image.png"#,
                        #"\\server\share\image.png"#, "/tmp/image.png\n", "/tmp/image\u{0}.png", "/tmp/\u{1b}image.png"] {
            try check(!RemotePasteUpload.validPath(invalid), "remote paste rejects an invalid path \(invalid.debugDescription)")
            do {
                _ = try RemotePasteUpload.quotePath(invalid)
                throw NSError(domain: "InvalidPastePathWasQuoted", code: 1)
            } catch is RemoteHostError { checks += 1; print("PASS invalid pasted paths cannot reach the shell") }
        }
        try check(RemotePasteUpload.validPath("/" + String(repeating: "a", count: 16_383)), "remote path accepts the byte limit")
        try check(!RemotePasteUpload.validPath("/" + String(repeating: "a", count: 16_384)), "remote path rejects bytes beyond the limit")
        try check(!RemotePasteUpload.validPath("/" + String(repeating: "图", count: 5_462)), "remote path limits count UTF-8 bytes")
        print("\(checks) remote paste path checks passed")
    }

    @MainActor private static func run() throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        let backend = CommandLine.arguments[1]
        let executable = CommandLine.arguments[2]
        let host = try RemoteHost(name: "Paste fixture", address: CommandLine.arguments[3], serverPath: CommandLine.arguments[5])
        let project = CommandLine.arguments[4]
        let local = FileManager.default.homeDirectoryForCurrentUser
        let sessionID = UUID()
        AppSettings.shared.terminalBackend = backend == "ghostty" ? .libghostty : .alacritty
        AppSettings.shared.terminalStartupProgram = ""
        AppSettings.shared.preserveTerminalSessions = false
        AppSettings.shared.restoreTerminalHistory = false
        let connection = try RemoteSessionConnection(host: host, directory: project, sessionID: sessionID,
            createIfMissing: true, command: ["/bin/sh", "-i"], launchSettings: TerminalLaunchSettings())
        let session = TerminalSession(initialDirectory: local.path,
            commandArguments: [executable, RemoteSessionRelay.argument, connection.configurationURL.path], remoteConnection: connection)
        let surface = session.surface
        surface.frame = NSRect(x: 0, y: 0, width: 760, height: 440)
        let window = PasteTestWindow(contentRect: surface.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = surface
        surface.onBecomeFirstResponder = { [weak session] in session?.terminalDidBecomeFocused() }
        window.makeFirstResponder(surface)
        surface.setSurfaceVisible(true)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("zshell-paste-\(UUID().uuidString)"))
        var uploaded: [String] = []
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) throws {
            guard condition() else { throw NSError(domain: "RemotePasteTest", code: 2, userInfo: [NSLocalizedDescriptionKey: label]) }
            checks += 1
            print("PASS \(backend): \(label)")
        }
        func text() -> String { surface.readVisibleText(maxLines: 256, maxColumns: 1000) ?? "" }
        func paste() throws {
            try check(surface.tryToPerform(#selector(NSText.paste(_:)), with: nil), "backend routes the native user paste action")
        }
        defer {
            session.terminate()
            pumpPaste(0.3)
            window.contentView = nil
            try? RemoteHostClient.terminate(host: host, directory: project, sessionID: sessionID)
            if case .ssh(let endpoint) = try? host.endpoint() {
                for path in uploaded { _ = try? OpenSSHTransport().run(endpoint: endpoint, command: ["/bin/rm", "--", path]) }
                let directDirectories = Set(uploaded.filter { $0.contains("/zshell-paste-") }.map { ($0 as NSString).deletingLastPathComponent })
                for directory in directDirectories {
                    _ = try? OpenSSHTransport().run(endpoint: endpoint, command: ["/bin/rm", "-rf", "--", directory])
                }
            }
            pasteboard.releaseGlobally()
        }
        try waitPaste("remote paste fixture did not connect") { connection.status.state == .connected && connection.isActiveClient }
        let encoded = try JSONEncoder().encode(RemoteFrame(kind: "pasteStart", project: project,
            sessionId: sessionID.uuidString.lowercased(), clientId: connection.clientID.uuidString.lowercased(),
            pasteFiles: [RemotePasteFileInfo(name: "image.png", size: 128)], uploadId: nil, fileIndex: nil, offset: nil))
        let decoded = try JSONDecoder().decode(RemoteFrame.self, from: encoded)
        try check(decoded.pasteFiles?.first?.size == 128 && decoded.pasteFiles?.first?.name == "image.png", "upload metadata survives the production wire model")
        pasteboard.clearContents()
        pasteboard.setString("ordinary text", forType: .string)
        let ordinary = try RemotePasteInput.capture(pasteboard)
        try check(ordinary == nil, "ordinary text bypasses file and image handling")
        try check(!session.terminalHandleUserPaste(pasteboard, paste: { _ in }), "remote session preserves ordinary text paste behavior")

        let first = local.appendingPathComponent("first 相同 'file'.bin")
        let second = local.appendingPathComponent("second/first 相同 'file'.bin")
        try FileManager.default.createDirectory(at: second.deletingLastPathComponent(), withIntermediateDirectories: true)
        let payload = Data((0..<190_000).map { UInt8($0 % 251) })
        try payload.write(to: first)
        try Data([1, 2, 3]).write(to: second)
        pasteboard.clearContents()
        pasteboard.writeObjects([first as NSURL, second as NSURL])
        guard let captured = try RemotePasteInput.capture(pasteboard) else { throw NSError(domain: "MissingPasteFiles", code: 1) }
        var paths: [String]?
        var failure: Error?
        let clientID = connection.clientID
        Task { @MainActor in
            do {
                paths = try await Task.detached { try RemotePasteUpload.upload(captured, host: host, project: project,
                    sessionID: sessionID, clientID: clientID) }.value
            } catch { failure = error }
        }
        try waitPaste("multifile upload did not finish") { paths != nil || failure != nil }
        if let failure { throw failure }
        let remoteFiles = paths!
        uploaded += remoteFiles
        try check(remoteFiles.count == 2 && remoteFiles[0] != remoteFiles[1], "same file names receive distinct remote paths")
        guard case .ssh(let endpoint) = try host.endpoint() else { throw NSError(domain: "ExpectedSSH", code: 1) }
        let content = try OpenSSHTransport().run(endpoint: endpoint, command: ["/bin/sh", "-c", "base64 < \"$1\"", "paste-read", remoteFiles[0]])
        let remoteBytes = Data(base64Encoded: content.stdout, options: .ignoreUnknownCharacters)
        try check(remoteBytes == payload, "multiple chunks preserve every binary byte on the remote host")
        _ = try OpenSSHTransport().run(endpoint: endpoint, command: ["/bin/sh", "-c", "test ! -L \"$1\" && test -f \"$1\"", "paste-check", remoteFiles[0]])
        try check(true, "uploaded path names a regular remote file")

        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 3, pixelsHigh: 2, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 12, bitsPerPixel: 32)!
        let png = bitmap.representation(using: .png, properties: [:])!
        var sshPaths: [String]?
        var sshFailure: Error?
        Task { @MainActor in
            do {
                sshPaths = try await Task.detached {
                    try RemotePasteUpload.uploadSSH(.image(png), endpoint: endpoint, authentication: .agent, credentialID: nil)
                }.value
            } catch { sshFailure = error }
        }
        try waitPaste("direct SSH screenshot upload did not finish") { sshPaths != nil || sshFailure != nil }
        if let sshFailure { throw sshFailure }
        uploaded += sshPaths!
        let sshPNG = try OpenSSHTransport().run(endpoint: endpoint, command: ["/bin/sh", "-c", "base64 < \"$1\"", "paste-read", sshPaths![0]])
        try check(Data(base64Encoded: sshPNG.stdout, options: .ignoreUnknownCharacters) == png, "ordinary SSH connections upload clipboard screenshots")

        let sshSession = TerminalSession(initialDirectory: local.path,
            commandArguments: ["/usr/bin/ssh"] + (try endpoint.terminalArguments(remoteDirectory: project)),
            remotePasteTarget: .ssh(endpoint: endpoint, authentication: .agent, credentialID: nil))
        let sshSurface = sshSession.surface
        sshSurface.frame = surface.frame
        let sshWindow = PasteTestWindow(contentRect: surface.frame, styleMask: [.titled], backing: .buffered, defer: false)
        sshWindow.contentView = sshSurface
        sshWindow.makeFirstResponder(sshSurface)
        sshSurface.setSurfaceVisible(true)
        defer { sshSession.terminate(); pumpPaste(0.3); sshWindow.contentView = nil }
        let startedSSH = awaitSSHStart(sshSession)
        try check(startedSSH, "ordinary SSH terminal launches for the same backend")
        pasteboard.clearContents()
        pasteboard.writeObjects([first as NSURL])
        var sshQuoted: String?
        try check(sshSession.terminalHandleUserPaste(pasteboard, paste: { sshQuoted = $0 }), "ordinary SSH session handles file paste through its saved authentication")
        try waitPaste("ordinary SSH file paste callback did not finish") { sshQuoted != nil }
        try check(sshQuoted!.contains("zshell-paste-") && !sshQuoted!.contains(local.path), "ordinary SSH session returns a remote path")
        sshSurface.sendText("printf 'DIRECT_SSH_PATH=%s\\n' " + sshQuoted! + "\r")
        try waitPaste("ordinary SSH path did not reach the surface") {
            (sshSurface.readVisibleText(maxLines: 256, maxColumns: 1000) ?? "").contains("DIRECT_SSH_PATH=/")
        }
        if let line = (sshSurface.readVisibleText(maxLines: 256, maxColumns: 1000) ?? "").split(separator: "\n")
            .first(where: { $0.hasPrefix("DIRECT_SSH_PATH=/") }) {
            uploaded.append(String(line.dropFirst("DIRECT_SSH_PATH=".count)).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        var quotedImage: String?
        try check(session.terminalHandleUserPaste(pasteboard, paste: { quotedImage = $0 }), "remote image is handled without passing a local clipboard shortcut")
        try waitPaste("image upload callback did not finish") { quotedImage != nil }
        session.sendCommand("printf 'REMOTE_IMAGE_PATH=%s\\n' ")
        surface.sendText(quotedImage!)
        session.sendEnter()
        try waitPaste("remote PNG path was not inserted") { text().contains("REMOTE_IMAGE_PATH=/") && text().contains(".png") }
        let imageLine = text().split(separator: "\n").first { $0.hasPrefix("REMOTE_IMAGE_PATH=/") }
        if let imageLine { uploaded.append(String(imageLine.dropFirst("REMOTE_IMAGE_PATH=".count)).trimmingCharacters(in: .whitespacesAndNewlines)) }
        try check(!quotedImage!.contains(local.path), "pasted screenshot path belongs to the remote filesystem")

        // Exercise the native paste selector on both real surfaces. Save and
        // restore the general pasteboard so the probe leaves user data intact.
        let general = NSPasteboard.general
        let saved = (general.pasteboardItems ?? []).map { item in item.types.compactMap { type in item.data(forType: type).map { (type, $0) } } }
        defer {
            general.clearContents()
            let restored = saved.map { values -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, bytes) in values { item.setData(bytes, forType: type) }
                return item
            }
            general.writeObjects(restored)
        }
        general.clearContents()
        general.writeObjects([first as NSURL])
        session.sendCommand("printf 'NATIVE_REMOTE_PATH=%s\\n' ")
        try paste()
        try waitPaste("native paste path did not reach the terminal surface") { text().contains("first") && text().contains("/pastes/") }
        session.sendEnter()
        try waitPaste("native paste path was not a shell argument") { text().contains("NATIVE_REMOTE_PATH=/") }
        if let line = text().split(separator: "\n").first(where: { $0.hasPrefix("NATIVE_REMOTE_PATH=/") }) {
            uploaded.append(String(line.dropFirst("NATIVE_REMOTE_PATH=".count)).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        try check(true, "native paste inserts a quoted remote path without submitting a command")
        general.clearContents()
        general.setString("printf TEXT_UNCHANGED", forType: .string)
        try paste()
        try waitPaste("ordinary native text paste changed") { text().contains("printf TEXT_UNCHANGED") }
        session.sendEnter()
        try check(true, "ordinary native text paste remains available")

        pasteboard.clearContents()
        pasteboard.writeObjects([first as NSURL])
        var stale = false
        try check(session.terminalHandleUserPaste(pasteboard, paste: { _ in stale = true }), "pending remote upload is accepted")
        connection.detach()
        try waitPaste("detach status did not publish") { connection.status.state == .detached }
        pumpPaste(0.4)
        try check(!stale, "detaching immediately after paste prevents a stale callback")
        print("Remote paste \(backend): \(checks) passed, 0 failed")
    }

    @MainActor private static func awaitSSHStart(_ session: TerminalSession) -> Bool {
        var started: Bool?
        Task { @MainActor in started = await session.waitUntilStarted() }
        let deadline = Date().addingTimeInterval(12)
        while started == nil, Date() < deadline { pumpPaste(0.02) }
        return started == true
    }
}
