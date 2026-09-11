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

nonisolated protocol GitCommandRunning: Sendable {
    func run(_ args: [String], in directory: String) async -> GitCommandResult
}

nonisolated struct GitCommandRunner: GitCommandRunning {
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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["LC_ALL"] = "C"
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice

        let cancelledBeforeLaunch = lock.withLock { () -> Bool in
            guard !isCancelled else { return true }
            self.process = process
            return false
        }
        guard !cancelledBeforeLaunch else {
            return GitCommandResult(status: -3, stdout: "", stderr: "")
        }
        defer { lock.withLock { self.process = nil } }

        do {
            try process.run()
        } catch {
            return GitCommandResult(status: -1, stdout: "", stderr: error.localizedDescription)
        }
        if lock.withLock({ isCancelled }) {
            cancel()
        }

        let output = PipeData()
        let errorOutput = PipeData()
        let readers = DispatchGroup()
        readers.enter()
        let stdoutReader = Thread {
            output.value = stdout.fileHandleForReading.readDataToEndOfFile()
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
        return GitCommandResult(
            status: lock.withLock { isCancelled } ? -3 : process.terminationStatus,
            stdout: String(data: output.value, encoding: .utf8) ?? "",
            stderr: String(data: errorOutput.value, encoding: .utf8) ?? ""
        )
    }
}

private nonisolated final class PipeData: @unchecked Sendable {
    var value = Data()
}
