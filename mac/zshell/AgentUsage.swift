//
//  AgentUsage.swift
//  zshell
//

import Darwin
import Foundation

nonisolated enum AgentUsagePaths {
    static let applicationSupportDirectory: URL = {
        #if DEBUG
        let directory = "zshell-dev"
        #else
        let directory = "zshell"
        #endif
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent(directory, isDirectory: true)
    }()
}

nonisolated struct ProcessCommandResult {
    let stdout: Data
    let status: Int32
    let timedOut: Bool
}

nonisolated enum ProcessRunner {
    static func resolveExecutable(
        _ name: String, environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        let path = environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        // Empty entries conventionally mean "the current directory"; the app
        // must never execute from an arbitrary working directory, so skip them.
        for directory in path.split(separator: ":", omittingEmptySubsequences: true) {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue,
                  FileManager.default.isExecutableFile(atPath: candidate.path)
            else { continue }
            return candidate
        }
        return nil
    }
    private struct ResponseEnvelope: Decodable {
        let id: Int?
    }

    private final class PipeData: @unchecked Sendable {
        private static let maximumBytes = 1_048_576
        private let lock = NSLock()
        private var storage = Data()
        private var sawResponse = false
        private var sawSecondResponse = false
        private var stopped = false
        private let responseID: Int?
        private let secondResponseID: Int?
        let responseReady = DispatchSemaphore(value: 0)
        let secondResponseReady = DispatchSemaphore(value: 0)

        init(responseID: Int? = nil, secondResponseID: Int? = nil) {
            self.responseID = responseID
            self.secondResponseID = secondResponseID
        }

        func append(_ data: Data) {
            lock.lock()
            let remaining = max(Self.maximumBytes - storage.count, 0)
            if remaining > 0 { storage.append(data.prefix(remaining)) }
            if !sawResponse, let responseID,
               storage.split(separator: 0x0A).contains(where: {
                   (try? JSONDecoder().decode(ResponseEnvelope.self, from: $0))?.id == responseID
               }) {
                sawResponse = true
                responseReady.signal()
            }
            if !sawSecondResponse, let secondResponseID,
               storage.split(separator: 0x0A).contains(where: {
                   (try? JSONDecoder().decode(ResponseEnvelope.self, from: $0))?.id == secondResponseID
               }) {
                sawSecondResponse = true
                secondResponseReady.signal()
            }
            lock.unlock()
        }

        func finish() {
            lock.lock()
            if !sawResponse { responseReady.signal() }
            if !sawSecondResponse { secondResponseReady.signal() }
            lock.unlock()
        }

        var didSeeResponse: Bool {
            lock.withLock { sawResponse }
        }

        var value: Data {
            lock.withLock { storage }
        }

        var isStopped: Bool { lock.withLock { stopped } }

        func stop() { lock.withLock { stopped = true } }
    }

    static func run(
        executable: URL,
        arguments: [String],
        initialInput: Data,
        initializedInput: Data,
        secondInput: Data,
        waitForResponseID: Int,
        secondResponseID: Int,
        timeout: TimeInterval,
        environment: [String: String]? = nil,
        workingDirectory: URL? = nil
    ) -> ProcessCommandResult {
        guard !Task.isCancelled else {
            return ProcessCommandResult(stdout: Data(), status: -2, timedOut: false)
        }
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment ?? ProcessInfo.processInfo.environment
        process.currentDirectoryURL = workingDirectory
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        let completed = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completed.signal() }
        do {
            guard !Task.isCancelled else {
                return ProcessCommandResult(stdout: Data(), status: -2, timedOut: false)
            }
            try process.run()
        } catch {
            return ProcessCommandResult(stdout: Data(), status: -1, timedOut: false)
        }

        let stdoutData = PipeData(
            responseID: waitForResponseID,
            secondResponseID: secondResponseID
        )
        let stderrData = PipeData()
        let readers = DispatchGroup()
        readers.enter()
        let stdoutReader = Thread {
            read(stdout.fileHandleForReading, into: stdoutData)
            stdoutData.finish()
            readers.leave()
        }
        stdoutReader.qualityOfService = .utility
        stdoutReader.start()
        readers.enter()
        let stderrReader = Thread {
            read(stderr.fileHandleForReading, into: stderrData)
            readers.leave()
        }
        stderrReader.qualityOfService = .utility
        stderrReader.start()

        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        do {
            // The CLI can exit while a request is being written.
            guard fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
                throw POSIXError(.EIO)
            }
            try Task.checkCancellation()
            var first = initialInput
            first.append(0x0A)
            try stdin.fileHandleForWriting.write(contentsOf: first)
            if !wait(stdoutData.responseReady, until: deadline) {
                timedOut = !Task.isCancelled
            } else if stdoutData.didSeeResponse {
                try Task.checkCancellation()
                var initialized = initializedInput
                initialized.append(0x0A)
                try stdin.fileHandleForWriting.write(contentsOf: initialized)
                try Task.checkCancellation()
                var second = secondInput
                second.append(0x0A)
                try stdin.fileHandleForWriting.write(contentsOf: second)
                if !wait(stdoutData.secondResponseReady, until: deadline) {
                    timedOut = !Task.isCancelled
                }
            }
            try stdin.fileHandleForWriting.close()
        } catch {
            if process.isRunning { process.terminate() }
        }
        try? stdin.fileHandleForWriting.close()

        if !timedOut, !Task.isCancelled {
            timedOut = !wait(completed, until: deadline)
        }
        if (timedOut || Task.isCancelled), process.isRunning {
            process.terminate()
            if completed.wait(timeout: .now() + 0.25) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = completed.wait(timeout: .now() + 1)
            }
        }
        if readers.wait(timeout: .now() + 1) == .timedOut {
            stdoutData.stop()
            stderrData.stop()
            _ = readers.wait(timeout: .now() + 0.25)
        }
        try? stdout.fileHandleForReading.close()
        try? stderr.fileHandleForReading.close()
        return ProcessCommandResult(
            stdout: stdoutData.value,
            status: timedOut || Task.isCancelled ? -2 : process.terminationStatus,
            timedOut: timedOut
        )
    }

    private static func wait(_ semaphore: DispatchSemaphore, until deadline: Date) -> Bool {
        while !Task.isCancelled {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return false }
            if semaphore.wait(timeout: .now() + min(remaining, 0.05)) == .success {
                return !Task.isCancelled
            }
        }
        return false
    }

    private static func read(_ handle: FileHandle, into data: PipeData) {
        let descriptor = handle.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL, 0)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 8_192)
        while !data.isStopped {
            var ready = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let status = Darwin.poll(&ready, 1, 50)
            if status == 0 || status < 0 && errno == EINTR { continue }
            guard status > 0 else { return }
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 { data.append(Data(buffer.prefix(count))) }
            else if count == 0 { return }
            else if errno != EINTR && errno != EAGAIN { return }
        }
    }
}
