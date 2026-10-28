import AppKit
import Darwin
import ImageIO

@main
struct LocalClipboardImageStoreTests {
    nonisolated static func waitForGate(_ gate: DispatchSemaphore) { gate.wait() }

    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        var checks = 0
        func check(_ condition: Bool, _ label: String) {
            precondition(condition, label)
            checks += 1
            print("PASS clipboard: \(label)")
        }
        func contents() throws -> Set<String> { Set(try manager.contentsOfDirectory(atPath: root.path)) }
        func permissions(_ url: URL) throws -> Int {
            (try manager.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber).intValue
        }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 3, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 12, bitsPerPixel: 32)!
        bitmap.bitmapData!.initialize(repeating: 125, count: 24)
        let png = bitmap.representation(using: .png, properties: [:])!
        let tiff = bitmap.tiffRepresentation!
        let pasteboard = NSPasteboard(name: .init("zshell-local-image-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.setData(png, forType: .png)
        if case .image(let captured) = try RemotePasteInput.capture(pasteboard) {
            check(captured == png, "pure PNG capture retains bounded bytes")
        } else { preconditionFailure("PNG capture") }
        pasteboard.clearContents()
        pasteboard.setData(tiff, forType: .tiff)
        if case .image(let captured) = try RemotePasteInput.capture(pasteboard) {
            check(captured == tiff, "pure TIFF capture remains undecoded on the UI thread")
        } else { preconditionFailure("TIFF capture") }
        pasteboard.setString("ordinary text", forType: .string)
        check(try RemotePasteInput.capture(pasteboard) == nil, "text plus image preserves ordinary text paste")
        let original = root.appendingPathComponent("original file.png")
        try png.write(to: original)
        pasteboard.clearContents()
        pasteboard.writeObjects([original as NSURL])
        if case .files(let files) = try RemotePasteInput.capture(pasteboard) {
            check(files == [original], "file URLs remain file paste")
        } else { preconditionFailure("file capture") }

        let saved = try await Task.detached { try LocalClipboardImageStore.save(png, in: root) }.value
        check(try Data(contentsOf: saved) == png, "valid PNG bytes survive private file storage")
        check(try permissions(saved) == 0o600, "PNG file is owner-only 0600")
        check(try permissions(saved.deletingLastPathComponent()) == 0o700, "batch directory is owner-only 0700")
        check(saved.pathExtension == "png", "saved path identifies a PNG")
        var metadata = stat()
        check(lstat(saved.path, &metadata) == 0 && metadata.st_mode & S_IFMT == S_IFREG && metadata.st_nlink == 1,
            "saved image is a new regular file")
        let converted = try await Task.detached { try LocalClipboardImageStore.save(tiff, in: root) }.value
        check(saved != converted && saved.deletingLastPathComponent() != converted.deletingLastPathComponent(),
            "concurrent screenshots use separate random paths")
        let convertedData = try Data(contentsOf: converted)
        let source = CGImageSourceCreateWithData(convertedData as CFData, nil)!
        check(convertedData.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) && CGImageSourceCreateImageAtIndex(source, 0, nil) != nil,
            "TIFF is converted into a readable PNG in the background")
        check((CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [CFString: Any])[kCGImagePropertyPixelWidth] as? Int == 3,
            "conversion retains image dimensions")
        LocalClipboardImageStore.discard(saved)
        LocalClipboardImageStore.discard(converted)
        check(!manager.fileExists(atPath: saved.deletingLastPathComponent().path)
            && !manager.fileExists(atPath: converted.deletingLastPathComponent().path), "discard removes complete private batches")

        let beforeInvalid = try contents()
        let wide = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16_385, pixelsHigh: 1,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 16_385 * 4, bitsPerPixel: 32)!
        wide.bitmapData!.initialize(repeating: 0, count: 16_385 * 4)
        for invalid in [Data(), Data(png.prefix(33)), Data([0, 1, 2, 3]),
                        wide.representation(using: .png, properties: [:])!,
                        Data(repeating: 0, count: RemotePasteUpload.maximumFileBytes + 1)] {
            do {
                _ = try await Task.detached { try LocalClipboardImageStore.save(invalid, in: root) }.value
                preconditionFailure("invalid clipboard image was accepted")
            } catch {}
        }
        check(try contents() == beforeInvalid, "invalid, truncated, oversized and excessive-width images leave no files")

        let gate = DispatchSemaphore(value: 0)
        let cancelled = Task.detached {
            waitForGate(gate)
            return try LocalClipboardImageStore.save(png, in: root)
        }
        cancelled.cancel()
        gate.signal()
        do { _ = try await cancelled.value; preconditionFailure("cancelled image was saved") }
        catch is CancellationError {}
        check(try contents() == beforeInvalid, "cancelled conversion leaves no private batch")

        var originalLimit = rlimit()
        check(getrlimit(RLIMIT_FSIZE, &originalLimit) == 0, "read disposable probe file-size limit")
        var restricted = rlimit(rlim_cur: 1, rlim_max: originalLimit.rlim_max)
        let previousSignal = signal(SIGXFSZ, SIG_IGN)
        check(setrlimit(RLIMIT_FSIZE, &restricted) == 0, "inject a file-write failure after batch creation")
        var failed = false
        do { _ = try LocalClipboardImageStore.save(png, in: root) }
        catch { failed = true }
        let restored = setrlimit(RLIMIT_FSIZE, &originalLimit)
        _ = signal(SIGXFSZ, previousSignal)
        check(restored == 0 && failed, "disk write failure propagates")
        check(try contents() == beforeInvalid, "partial PNG and batch are removed after a write failure")
        print("Local clipboard store: \(checks) checks passed")
    }
}
