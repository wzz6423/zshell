//
//  GitCommandRunner.swift
//  zshell
//

import Darwin
import Foundation

nonisolated struct GitCommandResult: Sendable {
    let status: Int32
    let stdout: String
    let stderr: String
}

nonisolated struct GitCommandDataResult: Sendable {
    let status: Int32
    let stdout: Data
    let stderr: String
    let truncated: Bool
}

nonisolated protocol GitCommandRunning: Sendable {
    func run(_ args: [String], in directory: String) async -> GitCommandResult
}

nonisolated struct GitCommandRunner: GitCommandRunning {
    static func runData(
        _ args: [String], in directory: String,
        environment: [String: String] = [:], input: Data? = nil,
        limit: Int = 10 << 20
    ) -> GitCommandDataResult {
        GitProcessState().runData(
            args, in: directory, environment: environment, input: input, limit: limit
        )
    }

    func run(_ args: [String], in directory: String) async -> GitCommandResult {
        let state = GitProcessState()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: state.run(args, in: directory))
                }
            }
        } onCancel: {
            state.cancel()
        }
    }
}

private nonisolated final class GitProcessState: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var isCancelled = false

    func cancel() {
        let process = lock.withLock { () -> Process? in
            isCancelled = true
            return self.process
        }
        guard let process, process.isRunning else { return }
        process.terminate()
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.2) {
            if process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }
    }

    func run(_ args: [String], in directory: String) -> GitCommandResult {
        let result = runData(args, in: directory)
        return GitCommandResult(
            status: result.status,
            stdout: String(data: result.stdout, encoding: .utf8) ?? "",
            stderr: result.stderr
        )
    }

    func runData(
        _ args: [String], in directory: String,
        environment additionalEnvironment: [String: String] = [:],
        input: Data? = nil, limit: Int = .max
    ) -> GitCommandDataResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["LC_ALL"] = "C"
        environment.merge(additionalEnvironment, uniquingKeysWith: { _, value in value })
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let stdin = input == nil ? nil : Pipe()
        process.standardInput = stdin.map { $0 as Any } ?? FileHandle.nullDevice

        let cancelledBeforeLaunch = lock.withLock { () -> Bool in
            guard !isCancelled else { return true }
            self.process = process
            return false
        }
        guard !cancelledBeforeLaunch else {
            return GitCommandDataResult(status: -3, stdout: Data(), stderr: "", truncated: false)
        }
        defer { lock.withLock { self.process = nil } }

        do {
            try process.run()
        } catch {
            return GitCommandDataResult(
                status: -1, stdout: Data(), stderr: error.localizedDescription, truncated: false
            )
        }
        if lock.withLock({ isCancelled }) {
            cancel()
        }

        let output = PipeData()
        let errorOutput = PipeData()
        let readers = DispatchGroup()
        if let stdin, let input {
            readers.enter()
            let writer = Thread {
                try? stdin.fileHandleForWriting.write(contentsOf: input)
                try? stdin.fileHandleForWriting.close()
                readers.leave()
            }
            writer.qualityOfService = Thread.current.qualityOfService
            writer.start()
        }
        readers.enter()
        let stdoutReader = Thread {
            while let chunk = try? stdout.fileHandleForReading.read(upToCount: 64 * 1024),
                  !chunk.isEmpty {
                let remaining = limit - output.value.count
                if remaining > 0 { output.value.append(chunk.prefix(remaining)) }
                if chunk.count > remaining { output.truncated = true }
            }
            readers.leave()
        }
        stdoutReader.qualityOfService = Thread.current.qualityOfService
        stdoutReader.start()
        readers.enter()
        let stderrReader = Thread {
            errorOutput.value = stderr.fileHandleForReading.readDataToEndOfFile()
            readers.leave()
        }
        stderrReader.qualityOfService = Thread.current.qualityOfService
        stderrReader.start()

        process.waitUntilExit()
        readers.wait()
        return GitCommandDataResult(
            status: lock.withLock { isCancelled } ? -3 : process.terminationStatus,
            stdout: output.value,
            stderr: String(data: errorOutput.value, encoding: .utf8) ?? "",
            truncated: output.truncated
        )
    }
}

private nonisolated final class PipeData: @unchecked Sendable {
    var value = Data()
    var truncated = false
}
