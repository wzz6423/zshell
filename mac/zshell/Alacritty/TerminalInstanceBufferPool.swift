import Foundation
import Metal

/// CPU uploads own a buffer until the GPU finishes reading that frame.
nonisolated final class TerminalInstanceBufferPool: @unchecked Sendable {
    nonisolated final class Lease: @unchecked Sendable {
        let buffer: MTLBuffer
        private let lock = NSLock()
        private var pool: TerminalInstanceBufferPool?

        fileprivate init(buffer: MTLBuffer, pool: TerminalInstanceBufferPool) {
            self.buffer = buffer
            self.pool = pool
        }

        func releaseWhenCompleted(by commands: MTLCommandBuffer) {
            commands.addCompletedHandler { [self] _ in release() }
        }

        private func release() {
            lock.lock()
            let owner = pool
            pool = nil
            lock.unlock()
            owner?.release(buffer)
        }

        deinit { release() }
    }

    private let device: MTLDevice
    private let maximumBufferCount: Int
    private let condition = NSCondition()
    private var available: [MTLBuffer] = []
    private var allocatedBufferCount = 0
    private var onAvailable: (@Sendable () -> Void)?

    init(device: MTLDevice, maximumBufferCount: Int = 2) {
        precondition(maximumBufferCount > 0)
        self.device = device
        self.maximumBufferCount = maximumBufferCount
    }

    func acquire(
        length: Int,
        waitUntilAvailable: Bool = false,
        onAvailable: (@Sendable () -> Void)? = nil
    ) -> Lease? {
        guard length > 0 else { return nil }
        condition.lock()
        defer { condition.unlock() }

        while available.isEmpty && allocatedBufferCount == maximumBufferCount {
            guard waitUntilAvailable else {
                // Register under the same lock as release so completion cannot
                // race the failed acquisition and lose the redraw wakeup.
                self.onAvailable = onAvailable
                return nil
            }
            condition.wait()
        }

        let buffer: MTLBuffer
        if let index = available.firstIndex(where: { $0.length >= length }) {
            buffer = available.remove(at: index)
        } else if let previous = available.popLast() {
            guard let grown = device.makeBuffer(length: length, options: .storageModeShared) else {
                available.append(previous)
                return nil
            }
            buffer = grown
        } else {
            guard let created = device.makeBuffer(length: length, options: .storageModeShared) else {
                return nil
            }
            allocatedBufferCount += 1
            buffer = created
        }
        return Lease(buffer: buffer, pool: self)
    }

    private func release(_ buffer: MTLBuffer) {
        condition.lock()
        available.append(buffer)
        let notify = onAvailable
        onAvailable = nil
        condition.signal()
        condition.unlock()
        notify?()
    }
}
