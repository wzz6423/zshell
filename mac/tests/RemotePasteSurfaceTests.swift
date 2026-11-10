import AppKit
import Darwin
import ImageIO
import UniformTypeIdentifiers
@testable import zshell

@MainActor
private final class PasteTestWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}

@MainActor
private final class FileDropInfo: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingDestinationWindow: NSWindow?
    let draggingSourceOperationMask: NSDragOperation = .copy
    let draggingLocation = NSPoint.zero
    let draggedImageLocation = NSPoint.zero
    let draggedImage: NSImage? = nil
    let draggingSource: Any? = nil
    let draggingSequenceNumber = 1
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    let springLoadingHighlight: NSSpringLoadingHighlight = .none

    init(pasteboard: NSPasteboard, window: NSWindow) {
        draggingPasteboard = pasteboard
        draggingDestinationWindow = window
    }

    func slideDraggedImage(to screenPoint: NSPoint) {}
    override func namesOfPromisedFilesDropped(atDestination destination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions, for view: NSView?, classes: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
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
            if CommandLine.arguments.dropFirst().first == "--capture-drop" {
                try captureDrop()
                return
            }
            try runPathQuoting()
            try runImageCapture()
            if CommandLine.arguments.dropFirst().first != "--path-quoting" { try run() }
        }
        catch { fputs("Remote paste failed: \(error)\n", stderr); exit(1) }
    }

    private static func captureDrop() throws {
        var original = termios()
        guard tcgetattr(STDIN_FILENO, &original) == 0 else { throw PTYMuxWire.errnoError("tcgetattr") }
        var raw = original
        cfmakeraw(&raw)
        guard tcsetattr(STDIN_FILENO, TCSANOW, &raw) == 0 else { throw PTYMuxWire.errnoError("tcsetattr") }
        defer { _ = tcsetattr(STDIN_FILENO, TCSANOW, &original) }
        try PTYMuxWire.writeAll(Data("\u{1b}[?2004hDROP_READY\r\n".utf8), to: STDOUT_FILENO)
        var received = Data()
        let end = Data("\u{1b}[201~".utf8)
        while received.count < 16_384 {
            var byte: UInt8 = 0
            let count = Darwin.read(STDIN_FILENO, &byte, 1)
            if count < 0 && errno == EINTR { continue }
            guard count == 1 else { throw PTYMuxWire.errnoError("read") }
            received.append(byte)
            if received.suffix(end.count) == end { break }
        }
        try received.write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .atomic)
        try PTYMuxWire.writeAll(Data("\u{1b}[?2004lDROP_DONE\r\n".utf8), to: STDOUT_FILENO)
    }

    @MainActor private static func imageFixtures() throws -> [(NSPasteboard.PasteboardType, Data, String)] {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 3, pixelsHigh: 2, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 12, bitsPerPixel: 32)!
        for pixel in 0..<6 { bitmap.bitmapData!.advanced(by: pixel * 4).update(from: [255, 0, 0, 255], count: 4) }
        let png = bitmap.representation(using: .png, properties: [:])!
        let tiff = bitmap.tiffRepresentation!
        let jpeg = bitmap.representation(using: .jpeg, properties: [:])!
        let firstImage = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(png as CFData, nil)!, 0, nil)!
        let gif = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(gif, UTType.gif.identifier as CFString, 2, nil) else {
            throw NSError(domain: "GIFDestination", code: 1)
        }
        let gifProperties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary
        CGImageDestinationAddImage(destination, firstImage, gifProperties)
        for pixel in 0..<6 { bitmap.bitmapData!.advanced(by: pixel * 4).update(from: [0, 0, 255, 255], count: 4) }
        let secondPNG = bitmap.representation(using: .png, properties: [:])!
        let secondImage = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(secondPNG as CFData, nil)!, 0, nil)!
        CGImageDestinationAddImage(destination, secondImage, gifProperties)
        guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "GIFEncoding", code: 1) }
        let webP = Data(base64Encoded: "UklGRh4AAABXRUJQVlA4TBEAAAAvAkAAAAdQo1oWpf+BiOh/AAA=")!
        let apng = NSMutableData()
        guard let apngDestination = CGImageDestinationCreateWithData(apng, UTType.png.identifier as CFString, 2, nil) else {
            throw NSError(domain: "APNGDestination", code: 1)
        }
        let frameProperties = [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: 0.1]] as CFDictionary
        CGImageDestinationAddImage(apngDestination, firstImage, frameProperties)
        CGImageDestinationAddImage(apngDestination, secondImage, frameProperties)
        guard CGImageDestinationFinalize(apngDestination) else { throw NSError(domain: "APNGEncoding", code: 1) }
        return [(.png, png, "PNG"),
                (.png, apng as Data, "APNG"),
                (.tiff, tiff, "TIFF"),
                (.init(UTType.jpeg.identifier), jpeg, "JPEG"),
                (.init(UTType.gif.identifier), gif as Data, "GIF"),
                (.init(UTType.webP.identifier), webP, "WebP"),
                (.init("public.webp"), webP, "WebP alias")]
    }

    private static func rgbaPixels(_ image: CGImage) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard rendered else { throw NSError(domain: "ImagePixels", code: 1) }
        return pixels
    }

    private static func checkNormalizedImage(_ png: Data, original: Data, label: String) throws {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              CGImageSourceGetType(source) == UTType.png.identifier as CFString,
              CGImageSourceGetCount(source) == 1,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil), image.width == 3, image.height == 2 else {
            throw NSError(domain: "ImageConversion", code: 1, userInfo: [NSLocalizedDescriptionKey: label])
        }
        if label == "PNG", png != original { throw NSError(domain: "PNGBytesChanged", code: 1) }
        if label == "GIF" || label == "APNG" {
            guard let animation = CGImageSourceCreateWithData(original as CFData, nil), CGImageSourceGetCount(animation) == 2,
                  let first = CGImageSourceCreateImageAtIndex(animation, 0, nil),
                  let second = CGImageSourceCreateImageAtIndex(animation, 1, nil) else {
                throw NSError(domain: "AnimationFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: label])
            }
            let firstPixels = try rgbaPixels(first)
            guard try rgbaPixels(image) == firstPixels, try rgbaPixels(second) != firstPixels else {
                throw NSError(domain: "AnimationFirstFrame", code: 1, userInfo: [NSLocalizedDescriptionKey: label])
            }
        }
    }

    @MainActor private static func runImageCapture() throws {
        let pasteboard = NSPasteboard(name: .init("zshell-image-capture-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        for (type, bytes, label) in try imageFixtures() {
            pasteboard.clearContents()
            pasteboard.setData(bytes, forType: type)
            guard case .image(let captured) = try RemotePasteInput.capture(pasteboard) else {
                print("IMAGE_CAPTURE types=\(pasteboard.types?.map(\.rawValue) ?? []) format=\(label) bytes=\(bytes.count)")
                throw NSError(domain: "ImageCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: label])
            }
            let png = try RemotePasteInput.pngData(from: captured)
            try checkNormalizedImage(png, original: bytes, label: label)
            pasteboard.setString("ordinary text", forType: .string)
            guard try RemotePasteInput.capture(pasteboard) == nil else { throw NSError(domain: "ImageTextPriority", code: 1) }
            print("PASS \(label) captures, decodes to a single PNG frame, and preserves text priority")
        }
        pasteboard.clearContents()
        pasteboard.setData(Data([1, 2, 3]), forType: .init(UTType.bmp.identifier))
        do {
            if case .image(let bytes) = try RemotePasteInput.capture(pasteboard) {
                _ = try RemotePasteInput.pngData(from: bytes)
            } else {
                throw RemoteHostError.message("Unsupported clipboard image")
            }
            throw NSError(domain: "UnsupportedImageAccepted", code: 1)
        } catch is RemoteHostError { print("PASS unsupported clipboard image reports an error") }
        for bytes in [Data(), Data([1, 2, 3]), Data(repeating: 0, count: RemotePasteUpload.maximumFileBytes + 1)] {
            do {
                _ = try RemotePasteInput.pngData(from: bytes)
                throw NSError(domain: "InvalidImageAccepted", code: 1)
            } catch is RemoteHostError { print("PASS unreadable and oversized images are rejected") }
        }
        pasteboard.declareTypes([.init(UTType.jpeg.identifier)], owner: nil)
        do {
            if case .image(let bytes) = try RemotePasteInput.capture(pasteboard) {
                _ = try RemotePasteInput.pngData(from: bytes)
            } else {
                throw RemoteHostError.message("Unreadable clipboard image")
            }
            throw NSError(domain: "UnreadableImageAccepted", code: 1)
        } catch is RemoteHostError { print("PASS a declared image without readable clipboard data reports an error") }
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
        AppSettings.shared.remotePasteUpload = true
        AppSettings.shared.remoteDropUpload = true
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
        func remotePath(_ quoted: String) throws -> String {
            let output = try BoundedProcessRunner.run(executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "printf '%s' " + quoted], timeout: 2, outputLimit: 16_384)
            try check(output.terminationStatus == 0 && !output.output.wasTruncated, "uploaded paths remain literal shell arguments")
            uploaded.append(output.output.stdout)
            return output.output.stdout
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

        let unsafeDirectory = local.appendingPathComponent("upload-folder", isDirectory: true)
        try FileManager.default.createDirectory(at: unsafeDirectory, withIntermediateDirectories: true)
        let symlink = local.appendingPathComponent("upload-link")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: first)
        func sparse(_ name: String, bytes: UInt64) throws -> URL {
            let url = local.appendingPathComponent(name)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.truncate(atOffset: bytes)
            return url
        }
        let tooLarge = try sparse("too-large", bytes: UInt64(RemotePasteUpload.maximumFileBytes + 1))
        let batchFiles = try (0..<3).map { try sparse("batch-\($0)", bytes: UInt64(RemotePasteUpload.maximumFileBytes)) }
        for urls in [[unsafeDirectory], [symlink], [tooLarge], batchFiles, Array(repeating: first, count: 33),
                     [URL(string: "https://example.invalid/file")!], [URL(fileURLWithPath: first.path + "\u{0}suffix")]] {
            do {
                _ = try RemotePasteUpload.upload(.files(urls), host: host, project: project, sessionID: sessionID, clientID: clientID)
                try check(false, "invalid upload must be rejected")
            } catch {
                if (error as NSError).domain == "RemotePasteTest" { throw error }
                try check(true, "invalid file kind, path, count or size is rejected before upload")
            }
        }

        let drop = FileDropInfo(pasteboard: pasteboard, window: window)
        AppSettings.shared.remotePasteUpload = false
        AppSettings.shared.remoteDropUpload = false
        var disabledPaste = false
        try check(session.terminalHandleUserPaste(pasteboard, paste: { _ in disabledPaste = true }), "disabled remote paste consumes file URLs")
        try check(!surface.draggingEntered(drop).contains(.copy), "disabled remote drag rejects the native drop affordance")
        try check(session.terminalHandleFileDrop([first], paste: { _ in disabledPaste = true }), "disabled remote drop never falls back to local paths")
        pumpPaste(0.1)
        try check(!disabledPaste, "disabled automatic uploads insert no local paths")
        guard let uploadItem = TerminalContextMenu.make(for: surface, linkTarget: nil).items.first(where: {
            $0.action.map(NSStringFromSelector) == "uploadFiles:"
        }) else { throw NSError(domain: "MissingUploadMenu", code: 1) }
        try check(uploadItem.target === session && session.validateMenuItem(uploadItem), "remote context menu keeps explicit upload available with both switches off")
        var explicitlyUploaded: String?
        try check(session.uploadSelectedFiles([first], paste: { explicitlyUploaded = $0 }), "explicitly selected files upload with automatic uploads disabled")
        try waitPaste("explicit upload did not finish") { explicitlyUploaded != nil }
        let explicitPath = try remotePath(explicitlyUploaded!)
        let explicitContent = try OpenSSHTransport().run(endpoint: endpoint,
            command: ["/bin/sh", "-c", "base64 < \"$1\"", "paste-read", explicitPath])
        try check(Data(base64Encoded: explicitContent.stdout, options: .ignoreUnknownCharacters) == payload,
                  "explicit upload writes every selected byte on the real host")
        AppSettings.shared.remoteDropUpload = true
        try check(surface.draggingEntered(drop).contains(.copy), "remote file drop is available while clipboard upload stays off")
        let droppedPathFile = project + "/dropped-\(UUID().uuidString).txt"
        session.sendCommand("printf '%s\\n' > " + SSHEndpoint.shellWord(droppedPathFile) + " ")
        try check(surface.performDragOperation(drop), "real backend routes a native file drop to upload")
        try waitPaste("native drop did not upload paths") { session.validateMenuItem(uploadItem) }
        let beforeEnter = try OpenSSHTransport().run(endpoint: endpoint,
            command: ["/bin/sh", "-c", "test ! -e \"$1\" && printf UNEXECUTED", "paste-check", droppedPathFile])
        try check(beforeEnter.stdout == "UNEXECUTED", "native drop inserts paths without executing the pending command")
        session.sendEnter()
        var droppedPaths = ""
        try waitPaste("native drop paths did not reach the remote shell") {
            droppedPaths = (try? OpenSSHTransport().run(endpoint: endpoint, command: ["/bin/cat", "--", droppedPathFile]).stdout) ?? ""
            return droppedPaths.contains("/pastes/")
        }
        let dropped = droppedPaths.split(separator: "\n").map(String.init)
        uploaded += dropped
        try check(!droppedPaths.contains(local.path) && dropped.count == 2 && dropped[0] != dropped[1], "multiple native drops insert distinct remote paths")
        _ = try OpenSSHTransport().run(endpoint: endpoint, command: ["/bin/rm", "--", droppedPathFile])
        AppSettings.shared.remotePasteUpload = true

        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 3, pixelsHigh: 2, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 12, bitsPerPixel: 32)!
        let png = bitmap.representation(using: .png, properties: [:])!
        for (type, bytes, label) in try imageFixtures() {
            pasteboard.clearContents()
            pasteboard.setData(bytes, forType: type)
            var converted: String?
            try check(session.terminalHandleUserPaste(pasteboard, paste: { converted = $0 }), "\(label) clipboard starts a real shared upload")
            try waitPaste("\(label) upload did not finish") { converted != nil }
            let imagePath = try remotePath(converted!)
            let received = try OpenSSHTransport().run(endpoint: endpoint,
                command: ["/bin/sh", "-c", "base64 < \"$1\"", "paste-read", imagePath])
            let normalized = try RemotePasteInput.pngData(from: bytes)
            let receivedPNG = Data(base64Encoded: received.stdout, options: .ignoreUnknownCharacters)
            try check(receivedPNG == normalized && imagePath.hasSuffix(".png"),
                "\(label) upload preserves the converted PNG on the host")
            try checkNormalizedImage(receivedPNG!, original: bytes, label: label)
            try check(true, "\(label) upload retains dimensions, original PNG bytes, and animation first-frame pixels as applicable")
        }
        for (_, bytes, label) in try imageFixtures() where label == "PNG" || label == "APNG" {
            var sshPaths: [String]?
            var sshFailure: Error?
            Task { @MainActor in
                do {
                    sshPaths = try await Task.detached {
                        try RemotePasteUpload.uploadSSH(.image(bytes), endpoint: endpoint, authentication: .agent, credentialID: nil)
                    }.value
                } catch { sshFailure = error }
            }
            try waitPaste("direct SSH \(label) upload did not finish") { sshPaths != nil || sshFailure != nil }
            if let sshFailure { throw sshFailure }
            uploaded += sshPaths!
            let received = try OpenSSHTransport().run(endpoint: endpoint,
                command: ["/bin/sh", "-c", "base64 < \"$1\"", "paste-read", sshPaths![0]])
            guard let sshPNG = Data(base64Encoded: received.stdout, options: .ignoreUnknownCharacters) else {
                throw NSError(domain: "SSHImageBytes", code: 1)
            }
            try checkNormalizedImage(sshPNG, original: bytes, label: label)
            try check(true, "ordinary SSH \(label) upload preserves original static bytes or first-frame pixels")
        }

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
        let sshDrop = FileDropInfo(pasteboard: pasteboard, window: sshWindow)
        let sshDropFile = project + "/ssh-drop-\(UUID().uuidString).txt"
        sshSurface.sendText("printf '%s' > " + SSHEndpoint.shellWord(sshDropFile) + " ")
        try check(sshSurface.performDragOperation(sshDrop), "ordinary SSH backend routes native file drops")
        try waitPaste("ordinary SSH drop did not finish") {
            sshSession.terminalFileUploadMenuItem.map { sshSession.validateMenuItem($0) } == true
        }
        sshSession.sendEnter()
        var sshDropPath = ""
        try waitPaste("ordinary SSH drop path did not reach the remote shell") {
            sshDropPath = (try? OpenSSHTransport().run(endpoint: endpoint, command: ["/bin/cat", "--", sshDropFile]).stdout) ?? ""
            return sshDropPath.contains("zshell-paste-")
        }
        uploaded.append(sshDropPath)
        let sshDropContent = try OpenSSHTransport().run(endpoint: endpoint,
            command: ["/bin/sh", "-c", "base64 < \"$1\"", "paste-read", sshDropPath])
        try check(Data(base64Encoded: sshDropContent.stdout, options: .ignoreUnknownCharacters) == payload,
                  "ordinary SSH native drop writes the original file on the real host")
        _ = try OpenSSHTransport().run(endpoint: endpoint, command: ["/bin/rm", "--", sshDropFile])
        pasteboard.clearContents()
        pasteboard.writeObjects([first as NSURL])
        var sshQuoted: String?
        try check(sshSession.terminalHandleUserPaste(pasteboard, paste: { sshQuoted = $0 }), "ordinary SSH session handles file paste through its saved authentication")
        try waitPaste("ordinary SSH file paste callback did not finish") { sshQuoted != nil }
        try check(sshQuoted!.contains("zshell-paste-") && !sshQuoted!.contains(local.path), "ordinary SSH session returns a remote path")
        let sshPasteFile = project + "/ssh-paste-\(UUID().uuidString).txt"
        sshSurface.sendText("printf '%s' > " + SSHEndpoint.shellWord(sshPasteFile) + " " + sshQuoted!)
        sshSession.sendEnter()
        var sshPastePath = ""
        try waitPaste("ordinary SSH pasted path did not reach the remote shell") {
            sshPastePath = (try? OpenSSHTransport().run(endpoint: endpoint, command: ["/bin/cat", "--", sshPasteFile]).stdout) ?? ""
            return sshPastePath.contains("zshell-paste-")
        }
        uploaded.append(sshPastePath)
        _ = try OpenSSHTransport().run(endpoint: endpoint, command: ["/bin/rm", "--", sshPasteFile])
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
        var ownedPasteboardChangeCount = general.changeCount
        defer {
            if general.changeCount == ownedPasteboardChangeCount {
                general.clearContents()
                let restored = saved.map { values -> NSPasteboardItem in
                    let item = NSPasteboardItem()
                    for (type, bytes) in values { item.setData(bytes, forType: type) }
                    return item
                }
                general.writeObjects(restored)
            }
        }
        general.clearContents()
        general.writeObjects([first as NSURL])
        ownedPasteboardChangeCount = general.changeCount
        let nativePathFile = project + "/native-\(UUID().uuidString).txt"
        session.sendCommand("printf '%s' > " + SSHEndpoint.shellWord(nativePathFile) + " ")
        try paste()
        try waitPaste("native paste upload did not complete") { session.validateMenuItem(uploadItem) }
        session.sendEnter()
        var nativePath = ""
        try waitPaste("native paste path was not a shell argument") {
            nativePath = (try? OpenSSHTransport().run(endpoint: endpoint, command: ["/bin/cat", "--", nativePathFile]).stdout) ?? ""
            return nativePath.contains("/pastes/")
        }
        uploaded.append(nativePath)
        _ = try OpenSSHTransport().run(endpoint: endpoint, command: ["/bin/rm", "--", nativePathFile])
        try check(true, "native paste inserts a quoted remote path without submitting a command")
        general.clearContents()
        general.setString("printf TEXT_UNCHANGED", forType: .string)
        ownedPasteboardChangeCount = general.changeCount
        try paste()
        try waitPaste("ordinary native text paste changed") { text().contains("printf TEXT_UNCHANGED") }
        session.sendEnter()
        try check(true, "ordinary native text paste remains available")

        let viewerConnection = try RemoteSessionConnection(host: host, directory: project, sessionID: sessionID,
            createIfMissing: false, command: nil, launchSettings: TerminalLaunchSettings())
        let viewer = TerminalSession(initialDirectory: local.path,
            commandArguments: [executable, RemoteSessionRelay.argument, viewerConnection.configurationURL.path], remoteConnection: viewerConnection)
        viewer.surface.frame = surface.frame
        let viewerWindow = PasteTestWindow(contentRect: surface.frame, styleMask: [.titled], backing: .buffered, defer: false)
        viewerWindow.contentView = viewer.surface
        viewer.surface.setSurfaceVisible(true)
        defer { viewer.terminate(); viewerWindow.contentView = nil }
        try waitPaste("second shared client did not attach") { viewerConnection.status.state == .connected }
        viewerConnection.takeControl()
        try waitPaste("shared control did not move") { viewerConnection.isActiveClient && !connection.isActiveClient }
        try check(!session.terminalAllowsFileDrop && !session.validateMenuItem(uploadItem), "a shared-session viewer cannot upload through drag or menu")
        connection.takeControl()
        try waitPaste("shared control did not return") { connection.isActiveClient }
        try check(session.terminalAllowsFileDrop && session.validateMenuItem(uploadItem), "upload is restored after taking shared-session control")

        pasteboard.clearContents()
        pasteboard.writeObjects([first as NSURL])
        var unfocusedDrop = false
        try check(session.terminalHandleFileDrop([first], paste: { _ in unfocusedDrop = true }), "pending remote drop is accepted")
        window.makeFirstResponder(nil)
        pumpPaste(0.4)
        try check(!unfocusedDrop, "focus loss cancels a pending remote drop")
        window.makeFirstResponder(surface)

        var transferredDrop = false
        try check(session.terminalHandleFileDrop([first], paste: { _ in transferredDrop = true }), "pending remote drop starts before a window transfer")
        let manager = TerminalManager()
        defer { for project in manager.projects { project.terminateAll() } }
        session.transferHost(to: manager)
        pumpPaste(0.4)
        try check(!transferredDrop, "transferring a terminal to another manager discards late upload insertion")

        var terminatedDrop = false
        try check(sshSession.terminalHandleFileDrop([first], paste: { _ in terminatedDrop = true }), "pending ordinary SSH drop is accepted")
        sshSession.terminate()
        pumpPaste(0.4)
        try check(!terminatedDrop, "terminating an ordinary SSH terminal discards a late upload result")

        pasteboard.clearContents()
        pasteboard.writeObjects([first as NSURL])
        var stale = false
        try check(session.terminalHandleFileDrop([first], paste: { _ in stale = true }), "pending remote drop is accepted before detach")
        connection.detach()
        try waitPaste("detach status did not publish") { connection.status.state == .detached }
        pumpPaste(0.4)
        try check(!stale, "detaching immediately after drop prevents a stale callback")
        try check(!session.terminalAllowsFileDrop && !session.validateMenuItem(uploadItem), "detached remote terminals reject new drops and explicit uploads")

        let localCapture = local.appendingPathComponent("local-drop-input")
        let localSession = TerminalSession(initialDirectory: local.path,
            commandArguments: [CommandLine.arguments[0], "--capture-drop", localCapture.path], allowsPersistence: false)
        let localSurface = localSession.surface
        localSurface.frame = surface.frame
        let localWindow = PasteTestWindow(contentRect: surface.frame, styleMask: [.titled], backing: .buffered, defer: false)
        localWindow.contentView = localSurface
        localSurface.setSurfaceVisible(true)
        localWindow.makeFirstResponder(localSurface)
        defer { localSession.terminate(); localWindow.contentView = nil }
        try waitPaste("local drop PTY did not enable bracketed paste") {
            (localSurface.readVisibleText(maxLines: 64, maxColumns: 1000) ?? "").contains("DROP_READY")
        }
        let localDrop = FileDropInfo(pasteboard: pasteboard, window: localWindow)
        AppSettings.shared.remoteDropUpload = false
        try check(localSession.terminalFileUploadMenuItem == nil && localSurface.draggingEntered(localDrop).contains(.copy),
                  "local drops remain available and have no remote upload menu")
        try check(localSurface.performDragOperation(localDrop), "local backend accepts a native file drop")
        try waitPaste("local drop did not reach the raw PTY") { FileManager.default.fileExists(atPath: localCapture.path) }
        let rawDrop = try String(contentsOf: localCapture, encoding: .utf8)
        try check(rawDrop.hasPrefix("\u{1b}[200~") && rawDrop.hasSuffix("\u{1b}[201~") && rawDrop.contains(local.path),
                  "local native drops keep one bracketed paste payload containing the local path")
        let localPayload = String(rawDrop.dropFirst(6).dropLast(6))
        let resolvedDrop = try BoundedProcessRunner.run(executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf '%s' " + localPayload], timeout: 2, outputLimit: 16_384)
        try check(resolvedDrop.output.stdout == first.path, "local native drop quotes spaces and apostrophes as one shell argument")
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
