import AppKit
import Metal
import QuartzCore

private nonisolated final class CompletionCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

private nonisolated final class WaitingLease: @unchecked Sendable {
    private let lock = NSLock()
    private var storedLease: TerminalInstanceBufferPool.Lease?

    var lease: TerminalInstanceBufferPool.Lease? {
        lock.lock()
        defer { lock.unlock() }
        return storedLease
    }

    func store(_ lease: TerminalInstanceBufferPool.Lease?) {
        lock.lock()
        storedLease = lease
        lock.unlock()
    }
}

@MainActor
private final class MetalFixture {
    let device: MTLDevice
    let renderer: TerminalMetalRenderer
    let event: MTLSharedEvent

    init() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let renderer = TerminalMetalRenderer(device: device),
              let event = device.makeSharedEvent()
        else { preconditionFailure("A working Metal device is required") }
        self.device = device
        self.renderer = renderer
        self.event = event
    }

    func read(
        _ lease: TerminalInstanceBufferPool.Lease,
        waitingFor value: UInt64
    ) -> (commands: MTLCommandBuffer, result: MTLBuffer) {
        let commands = renderer.testQueue.makeCommandBuffer()!
        let result = device.makeBuffer(length: lease.buffer.length, options: .storageModeShared)!
        commands.encodeWaitForEvent(event, value: value)
        let blit = commands.makeBlitCommandEncoder()!
        blit.copy(from: lease.buffer, sourceOffset: 0, to: result,
                  destinationOffset: 0, size: lease.buffer.length)
        blit.endEncoding()
        lease.releaseWhenCompleted(by: commands)
        commands.commit()
        return (commands, result)
    }

    func wait(_ commands: MTLCommandBuffer) {
        commands.waitUntilCompleted()
        precondition(commands.status == .completed, "GPU command failed: \(String(describing: commands.error))")
    }

    func origin(_ buffer: MTLBuffer, instance: Int = 0) -> Float {
        buffer.contents().load(fromByteOffset: instance * renderer.testInstanceStride, as: Float.self)
    }

    func layer() -> CAMetalLayer {
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = false
        layer.drawableSize = CGSize(width: 64, height: 64)
        layer.maximumDrawableCount = 3
        return layer
    }

    func render(
        _ drawable: CAMetalDrawable,
        cursorColumn: Int?,
        onAvailable: (@Sendable () -> Void)? = nil,
        waitUntilCompleted: Bool = false
    ) -> Bool {
        var cell = ZshellCell()
        cell.bg = 0
        cell.fg = 0xffffff
        var snapshot = ZshellSnapshot()
        snapshot.columns = 1
        snapshot.rows = 1
        snapshot.cursor_line = cursorColumn == nil ? -1 : 0
        snapshot.cursor_column = cursorColumn ?? -1
        snapshot.cursor_color = 0xff0000
        return withUnsafePointer(to: &cell) { cells in
            snapshot.cells = cells
            return renderer.render(
                snapshot: snapshot, markedText: nil, kittyPlacements: [],
                metrics: AlacrittyMetrics(
                    family: "", fallbackFamily: "", size: 13, fontThicken: false,
                    fontThickenStrength: 0, lineHeight: 1
                ),
                padding: CGPoint(x: 4, y: 4), scale: 1, backgroundOpacity: 1,
                dirtyRows: nil, in: drawable, viewportSize: CGSize(width: 64, height: 64),
                onBufferAvailable: onAvailable, waitUntilCompleted: waitUntilCompleted
            )
        }
    }

    func waitForQueue() {
        let commands = renderer.testQueue.makeCommandBuffer()!
        commands.commit()
        wait(commands)
    }

    func pixel(_ texture: MTLTexture, x: Int, y: Int) -> [UInt8] {
        var pixel = [UInt8](repeating: 0, count: 4)
        texture.getBytes(&pixel, bytesPerRow: 4, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
        return pixel
    }
}

@main
struct TerminalMetalBufferTests {
    @MainActor static func main() {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        uploadIsolationAndGrowth()
        abandonedCommandsAndEmptyUploads()
        synchronousAcquisitionAndWakeups()
        renderedFramesKeepTheirInstances()
        synchronousRenderWaitsForInFlightFrames()
        rendererLifetime()
        print("Metal buffer ownership tests passed (real GPU, upload/render/growth/reuse/lifecycle)")
    }

    @MainActor private static func uploadIsolationAndGrowth() {
        let fixture = MetalFixture()
        let first = fixture.renderer.testUploadOrigins([1])!
        let firstRead = fixture.read(first, waitingFor: 1)
        let second = fixture.renderer.testUploadOrigins([2])!
        let secondRead = fixture.read(second, waitingFor: 1)
        precondition(first.buffer !== second.buffer, "In-flight frames shared one buffer")

        let wakeups = CompletionCount()
        for _ in 0..<10 {
            precondition(fixture.renderer.testUploadOrigins([99], onAvailable: { wakeups.increment() }) == nil)
        }
        precondition(wakeups.value == 0)
        fixture.event.signaledValue = 1
        fixture.wait(firstRead.commands)
        fixture.wait(secondRead.commands)
        precondition(fixture.origin(firstRead.result) == 1, "The first GPU read saw the second frame")
        precondition(fixture.origin(secondRead.result) == 2)
        precondition(wakeups.value == 1, "Repeated failures must coalesce one redraw wakeup")

        let reused = fixture.renderer.testUploadOrigins([3])!
        precondition(reused.buffer === first.buffer || reused.buffer === second.buffer)
        let reusedRead = fixture.read(reused, waitingFor: 2)
        let grown = fixture.renderer.testUploadOrigins(Array(repeating: 4, count: 64))!
        precondition(grown.buffer.length >= fixture.renderer.testInstanceStride * 64)
        precondition(grown.buffer !== reused.buffer)
        let grownRead = fixture.read(grown, waitingFor: 2)
        fixture.event.signaledValue = 2
        fixture.wait(reusedRead.commands)
        fixture.wait(grownRead.commands)
        precondition(fixture.origin(reusedRead.result) == 3)
        precondition(fixture.origin(grownRead.result, instance: 63) == 4)

        let finalFirst = fixture.renderer.testUploadOrigins(Array(repeating: 5, count: 64))!
        precondition(finalFirst.buffer === grown.buffer, "A sufficient free buffer must be reused")
        let finalSecond = fixture.renderer.testUploadOrigins([6])!
        precondition(finalSecond.buffer === reused.buffer)
        precondition(fixture.renderer.testUploadOrigins([7]) == nil, "The pool grew beyond its bound")
        print("PASS: delayed GPU reads preserve both frames, including growth and reuse")
    }

    @MainActor private static func abandonedCommandsAndEmptyUploads() {
        let fixture = MetalFixture()
        precondition(fixture.renderer.testUploadOrigins([]) == nil)
        autoreleasepool {
            let first = fixture.renderer.testUploadOrigins([1])!
            let second = fixture.renderer.testUploadOrigins([2])!
            precondition(fixture.renderer.testUploadOrigins([3]) == nil)
            let commands = fixture.renderer.testQueue.makeCommandBuffer()!
            first.releaseWhenCompleted(by: commands)
            _ = second
            // Neither the command nor the second upload is submitted.
        }
        let recoveredFirst = fixture.renderer.testUploadOrigins([4])!
        let recoveredSecond = fixture.renderer.testUploadOrigins([5])!
        precondition(recoveredFirst.buffer !== recoveredSecond.buffer)
        let wakeups = CompletionCount()
        let pool = TerminalInstanceBufferPool(device: fixture.device)
        precondition(pool.acquire(length: 0, onAvailable: { wakeups.increment() }) == nil)
        precondition(pool.acquire(length: -1, onAvailable: { wakeups.increment() }) == nil)
        precondition(wakeups.value == 0)
        print("PASS: empty uploads and discarded commands do not consume slots")
    }

    @MainActor private static func synchronousAcquisitionAndWakeups() {
        let fixture = MetalFixture()
        let pool = TerminalInstanceBufferPool(device: fixture.device, maximumBufferCount: 1)
        var first: TerminalInstanceBufferPool.Lease? = pool.acquire(length: 64)
        let result = WaitingLease()
        let started = DispatchSemaphore(value: 0)
        let completed = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            started.signal()
            result.store(pool.acquire(length: 128, waitUntilAvailable: true))
            completed.signal()
        }
        precondition(started.wait(timeout: .now() + 2) == .success)
        precondition(completed.wait(timeout: .now() + 0.05) == .timedOut)
        first = nil
        precondition(completed.wait(timeout: .now() + 2) == .success)
        precondition(result.lease?.buffer.length ?? 0 >= 128)

        for _ in 0..<100 {
            let racePool = TerminalInstanceBufferPool(device: fixture.device, maximumBufferCount: 1)
            let returned = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            let ready = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                autoreleasepool {
                    let lease = racePool.acquire(length: 64)!
                    ready.signal()
                    _ = release.wait(timeout: .now() + 2)
                    withExtendedLifetime(lease) {}
                }
                returned.signal()
            }
            precondition(ready.wait(timeout: .now() + 2) == .success)
            let wakeups = CompletionCount()
            release.signal()
            let acquired = racePool.acquire(length: 64, onAvailable: { wakeups.increment() })
            precondition(returned.wait(timeout: .now() + 2) == .success)
            precondition(acquired != nil || wakeups.value == 1, "Completion lost the pending redraw")
        }
        withExtendedLifetime(first) {}
        print("PASS: synchronous acquisition waits and completion registration cannot lose wakeups")
    }

    @MainActor private static func renderedFramesKeepTheirInstances() {
        let fixture = MetalFixture()
        let layer = fixture.layer()
        guard let first = layer.nextDrawable(), let second = layer.nextDrawable(),
              let third = layer.nextDrawable()
        else { preconditionFailure("Metal drawables are required") }
        let firstTexture = first.texture
        let secondTexture = second.texture
        let blocker = fixture.renderer.testQueue.makeCommandBuffer()!
        blocker.encodeWaitForEvent(fixture.event, value: 1)
        blocker.commit()
        precondition(fixture.render(first, cursorColumn: 0))
        precondition(fixture.render(second, cursorColumn: 2))
        let wakeups = CompletionCount()
        precondition(!fixture.render(third, cursorColumn: 1, onAvailable: { wakeups.increment() }))
        precondition(wakeups.value == 0)
        fixture.event.signaledValue = 1
        fixture.wait(blocker)
        fixture.waitForQueue()
        precondition(wakeups.value == 1, "render must return its buffer on completion")
        precondition(fixture.pixel(firstTexture, x: 5, y: 5) == [0, 0, 255, 255])
        precondition(fixture.pixel(secondTexture, x: 5, y: 5) == [0, 0, 0, 255])
        precondition(fixture.pixel(secondTexture, x: 21, y: 5) == [0, 0, 255, 255])
        precondition(fixture.render(third, cursorColumn: 1, waitUntilCompleted: true))

        autoreleasepool {
            let renderer = TerminalMetalRenderer(device: fixture.device)!
            let emptyLayer = fixture.layer()
            let firstLease = renderer.testUploadOrigins([1])!
            let secondLease = renderer.testUploadOrigins([2])!
            guard let empty = emptyLayer.nextDrawable() else { preconditionFailure("Missing empty drawable") }
            var snapshot = ZshellSnapshot()
            snapshot.cursor_line = -1
            snapshot.cursor_column = -1
            precondition(renderer.render(
                snapshot: snapshot, markedText: nil, kittyPlacements: [],
                metrics: AlacrittyMetrics(
                    family: "", fallbackFamily: "", size: 13, fontThicken: false,
                    fontThickenStrength: 0, lineHeight: 1
                ), padding: .zero, scale: 1, backgroundOpacity: 1, dirtyRows: nil,
                in: empty, viewportSize: CGSize(width: 64, height: 64), waitUntilCompleted: true
            ), "An empty frame must render even when all buffers are leased")
            withExtendedLifetime((firstLease, secondLease)) {}
        }
        print("PASS: production render keeps separate pixels and synchronous/empty frames work")
    }

    @MainActor private static func rendererLifetime() {
        let device = MTLCreateSystemDefaultDevice()!
        let event = device.makeSharedEvent()!
        weak var weakRenderer: TerminalMetalRenderer?
        var commands: MTLCommandBuffer?
        var result: MTLBuffer?
        let done = DispatchSemaphore(value: 0)
        autoreleasepool {
            let renderer = TerminalMetalRenderer(device: device)!
            weakRenderer = renderer
            let first = renderer.testUploadOrigins([11])!
            let second = renderer.testUploadOrigins([22])!
            let wakeups = CompletionCount()
            precondition(renderer.testUploadOrigins([33], onAvailable: { wakeups.increment() }) == nil)
            let command = renderer.testQueue.makeCommandBuffer()!
            command.encodeWaitForEvent(event, value: 1)
            let readback = device.makeBuffer(length: first.buffer.length, options: .storageModeShared)!
            let blit = command.makeBlitCommandEncoder()!
            blit.copy(from: first.buffer, sourceOffset: 0, to: readback,
                      destinationOffset: 0, size: first.buffer.length)
            blit.endEncoding()
            first.releaseWhenCompleted(by: command)
            command.addCompletedHandler { _ in done.signal() }
            command.commit()
            commands = command
            result = readback
            withExtendedLifetime(second) {}
        }
        precondition(weakRenderer == nil, "A completion retained the renderer")
        event.signaledValue = 1
        precondition(done.wait(timeout: .now() + 5) == .success)
        precondition(commands!.status == .completed)
        precondition(result!.contents().load(as: Float.self) == 11)
        print("PASS: releasing a renderer leaves in-flight GPU reads valid")
    }

    @MainActor private static func synchronousRenderWaitsForInFlightFrames() {
        let fixture = MetalFixture()
        let layer = fixture.layer()
        guard let first = layer.nextDrawable(), let second = layer.nextDrawable(),
              let frozen = layer.nextDrawable()
        else { preconditionFailure("Metal drawables are required") }
        let frozenTexture = frozen.texture
        let blocker = fixture.renderer.testQueue.makeCommandBuffer()!
        blocker.encodeWaitForEvent(fixture.event, value: 1)
        blocker.commit()
        precondition(fixture.render(first, cursorColumn: 0))
        precondition(fixture.render(second, cursorColumn: 2))

        let event = fixture.event
        let released = DispatchSemaphore(value: 0)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            event.signaledValue = 1
            released.signal()
        }
        let rendered = fixture.render(frozen, cursorColumn: 1, waitUntilCompleted: true)
        precondition(released.wait(timeout: .now() + 2) == .success)
        precondition(rendered, "A synchronous freeze must wait for an in-flight buffer")
        precondition(fixture.pixel(frozenTexture, x: 13, y: 5) == [0, 0, 255, 255])
        print("PASS: a synchronous freeze waits for busy buffers and completes its own frame")
    }
}
