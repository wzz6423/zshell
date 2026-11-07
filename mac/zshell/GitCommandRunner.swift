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
        limit: Int = 10 << 20, timeout: TimeInterval? = nil
    ) -> GitCommandDataResult {
        GitProcessState().runData(
            args, in: directory, environment: environment, input: input, limit: limit, timeout: timeout
        )
    }

    /// Every Git process Zshell launches starts from this environment so the
    /// Settings proxy reaches the Git panel, diffs, and worktree actions alike.
    static func processEnvironment() -> [String: String] {
        var environment = GitProxy.processEnvironment(inheriting: ProcessInfo.processInfo.environment)
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        // Fail rather than hanging on a credential prompt behind the app.
        environment["GIT_TERMINAL_PROMPT"] = "0"
        // Git diagnostics are parsed only to distinguish an ordinary folder
        // from a broken repository. Pinning the locale makes that safe and
        // also keeps relative dates stable in the compact history list.
        environment["LC_ALL"] = "C"
        return environment
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
    private var isCancelled = false

    func cancel() {
        lock.withLock { isCancelled = true }
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
        input: Data? = nil, limit: Int = .max, timeout: TimeInterval? = nil
    ) -> GitCommandDataResult {
        guard !lock.withLock({ isCancelled }) else {
            return GitCommandDataResult(status: -3, stdout: Data(), stderr: "", truncated: false)
        }
        let deadline = timeout.map { DispatchTime.now() + max(0, $0) }
        var environment = GitCommandRunner.processEnvironment()
        environment.merge(additionalEnvironment, uniquingKeysWith: { _, value in value })

        do {
            let stdout = try GitPipe()
            let stderr = try GitPipe()
            let stdin = try input.map { _ in try GitPipe() }
            try stdout.makeNonblocking(stdout.readDescriptor)
            try stderr.makeNonblocking(stderr.readDescriptor)
            if let stdin {
                try stdin.makeNonblocking(stdin.writeDescriptor)
                try Self.check(fcntl(stdin.writeDescriptor, F_SETNOSIGPIPE, 1), errnoBased: true)
            }
            guard !lock.withLock({ isCancelled }) else {
                return GitCommandDataResult(status: -3, stdout: Data(), stderr: "", truncated: false)
            }
            let pid = try Self.spawn(args, in: directory, environment: environment,
                                     stdout: stdout, stderr: stderr, stdin: stdin)
            stdout.closeWrite()
            stderr.closeWrite()
            stdin?.closeRead()
            if input?.isEmpty == true { stdin?.closeWrite() }

            var output = Data()
            var errorOutput = Data()
            var truncated = false
            let outputLimit = max(0, limit)
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            var inputOffset = 0
            var exitStatus: Int32?
            var shortExitPolls = 5
            var ownsChild = true
            var interruption: Int32?
            var killDeadline: DispatchTime?
            var reapDeadline: DispatchTime?
            var failure: String?

            // WNOWAIT keeps the child's PID reserved until pipe handling and
            // group signals finish, even when Git exits before its helpers.
            while true {
                let now = DispatchTime.now()
                if exitStatus == nil, ownsChild {
                    var info = siginfo_t()
                    let result = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
                    if result == 0, info.si_pid == pid { exitStatus = info.si_status }
                    else if result < 0 {
                        if errno == ECHILD { ownsChild = false }
                        else if errno != EINTR { failure = Self.error(errno).localizedDescription }
                    }
                }
                let pipesClosed = stdout.readDescriptor < 0 && stderr.readDescriptor < 0
                    && (stdin?.writeDescriptor ?? -1) < 0
                if (exitStatus != nil || !ownsChild), pipesClosed, killDeadline == nil { break }

                if interruption == nil {
                    if lock.withLock({ isCancelled }) { interruption = -3 }
                    else if let deadline, now >= deadline { interruption = -2 }
                    else if failure != nil { interruption = -1 }
                    if interruption != nil {
                        if ownsChild { Self.signalGroup(pid, SIGTERM) }
                        stdin?.closeWrite()
                        killDeadline = now + 0.2
                    }
                }
                if let killAt = killDeadline, now >= killAt {
                    if ownsChild { Self.signalGroup(pid, SIGKILL) }
                    stdout.closeRead()
                    stderr.closeRead()
                    killDeadline = nil
                    reapDeadline = now + 0.2
                }
                if let reapDeadline, now >= reapDeadline { break }
                if (exitStatus != nil || !ownsChild), stdout.readDescriptor < 0,
                   stderr.readDescriptor < 0, (stdin?.writeDescriptor ?? -1) < 0,
                   killDeadline == nil { break }

                let pollingForExit = ownsChild && exitStatus == nil && pipesClosed
                    && interruption == nil && shortExitPolls > 0
                let pollInterval: UInt64 = pollingForExit ? 5_000_000 : 50_000_000
                if pollingForExit { shortExitPolls -= 1 }
                let nextDeadline = interruption == nil ? deadline : (killDeadline ?? reapDeadline)
                let remaining = nextDeadline.map {
                    $0.uptimeNanoseconds > now.uptimeNanoseconds
                        ? min(pollInterval, $0.uptimeNanoseconds - now.uptimeNanoseconds) : 0
                } ?? pollInterval
                var descriptors = [
                    pollfd(fd: stdout.readDescriptor, events: Int16(POLLIN), revents: 0),
                    pollfd(fd: stderr.readDescriptor, events: Int16(POLLIN), revents: 0),
                    pollfd(fd: stdin?.writeDescriptor ?? -1, events: Int16(POLLOUT), revents: 0),
                ]
                let ready = Darwin.poll(&descriptors, nfds_t(descriptors.count),
                                        Int32((remaining + 999_999) / 1_000_000))
                if ready < 0 {
                    if errno != EINTR { failure = Self.error(errno).localizedDescription }
                    continue
                }
                if descriptors[0].revents != 0 {
                    Self.drain(stdout, into: &output, buffer: &buffer,
                               limit: outputLimit, truncated: &truncated)
                }
                if descriptors[1].revents != 0 {
                    Self.drain(stderr, into: &errorOutput, buffer: &buffer,
                               limit: outputLimit, truncated: &truncated)
                }
                if let stdin, let input, descriptors[2].revents != 0 {
                    let written = input.withUnsafeBytes { bytes in
                        Darwin.write(stdin.writeDescriptor,
                                     bytes.baseAddress!.advanced(by: inputOffset),
                                     min(buffer.count, input.count - inputOffset))
                    }
                    if written > 0 {
                        inputOffset += written
                        if inputOffset == input.count { stdin.closeWrite() }
                    } else if written == 0 || (errno != EINTR && errno != EAGAIN) {
                        stdin.closeWrite()
                    }
                }
            }

            if ownsChild {
                // Reap without another unbounded wait. A process delayed by
                // the kernel after SIGKILL needs an exit source, not a worker.
                var status: Int32 = 0
                var result: pid_t
                repeat { result = waitpid(pid, &status, WNOHANG) } while result < 0 && errno == EINTR
                if result == 0 { GitProcessReaper.reapOnExit(pid) }
            }
            return GitCommandDataResult(
                status: lock.withLock { isCancelled } ? -3 : (interruption ?? exitStatus ?? -1),
                stdout: output,
                stderr: failure ?? (String(data: errorOutput, encoding: .utf8) ?? ""),
                truncated: truncated
            )
        } catch {
            return GitCommandDataResult(status: -1, stdout: Data(),
                                        stderr: error.localizedDescription, truncated: false)
        }
    }

    private static func spawn(
        _ args: [String], in directory: String, environment: [String: String],
        stdout: GitPipe, stderr: GitPipe, stdin: GitPipe?
    ) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        try check(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        if let stdin {
            try check(posix_spawn_file_actions_adddup2(&actions, stdin.readDescriptor, STDIN_FILENO))
        } else {
            try check(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0))
        }
        try check(posix_spawn_file_actions_adddup2(&actions, stdout.writeDescriptor, STDOUT_FILENO))
        try check(posix_spawn_file_actions_adddup2(&actions, stderr.writeDescriptor, STDERR_FILENO))
        for pipe in [stdout, stderr] + (stdin.map { [$0] } ?? []) {
            try check(posix_spawn_file_actions_addclose(&actions, pipe.readDescriptor))
            try check(posix_spawn_file_actions_addclose(&actions, pipe.writeDescriptor))
        }
        if #available(macOS 26.0, *) {
            try check(posix_spawn_file_actions_addchdir(&actions, directory))
        } else {
            try check(posix_spawn_file_actions_addchdir_np(&actions, directory))
        }
        var attributes: posix_spawnattr_t?
        try check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        try check(posix_spawnattr_setflags(
            &attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP
                               | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)
        ))
        try check(posix_spawnattr_setpgroup(&attributes, 0))
        var signals = sigset_t()
        sigemptyset(&signals)
        try check(posix_spawnattr_setsigmask(&attributes, &signals))
        sigfillset(&signals)
        try check(posix_spawnattr_setsigdefault(&attributes, &signals))
        let strings = ["/usr/bin/git"] + args + environment.map { "\($0.key)=\($0.value)" }
        guard strings.allSatisfy({ !$0.utf8.contains(0) }), !directory.utf8.contains(0) else {
            throw error(EINVAL)
        }
        let pointers = strings.map { strdup($0) }
        defer { pointers.forEach { free($0) } }
        guard pointers.allSatisfy({ $0 != nil }) else { throw error(ENOMEM) }
        var argv = Array(pointers.prefix(args.count + 1)) + [nil]
        var envp = Array(pointers.dropFirst(args.count + 1)) + [nil]
        var pid: pid_t = 0
        try check(posix_spawn(&pid, "/usr/bin/git", &actions, &attributes, &argv, &envp))
        return pid
    }

    private static func signalGroup(_ pid: pid_t, _ signal: Int32) {
        // POSIX_SPAWN_SETPGROUP created this group atomically. getpgid can
        // fail for an exited leader, whose PID is still reserved by WNOWAIT.
        guard pid > 1, pid != getpid(), pid != getpgrp() else { return }
        _ = Darwin.kill(-pid, signal)
    }

    private static func drain(
        _ pipe: GitPipe, into output: inout Data, buffer: inout [UInt8],
        limit: Int, truncated: inout Bool
    ) {
        // Yield between batches so a helper writing continuously cannot hide
        // cancellation or the deadline behind an always-readable pipe.
        for _ in 0..<4 {
            let count = Darwin.read(pipe.readDescriptor, &buffer, buffer.count)
            if count > 0 {
                let retained = min(count, limit - output.count)
                buffer.withUnsafeBytes { bytes in
                    output.append(bytes.baseAddress!.assumingMemoryBound(to: UInt8.self), count: retained)
                }
                if retained < count { truncated = true }
            } else if count == 0 || (errno != EINTR && errno != EAGAIN) {
                pipe.closeRead()
                return
            } else { return }
        }
    }

    fileprivate static func check(_ result: Int32, errnoBased: Bool = false) throws {
        if errnoBased ? result < 0 : result != 0 { throw error(errnoBased ? errno : result) }
    }

    fileprivate static func error(_ code: Int32) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }
}

private nonisolated final class GitPipe {
    private(set) var readDescriptor: Int32 = -1
    private(set) var writeDescriptor: Int32 = -1

    init() throws {
        var descriptors: [Int32] = [-1, -1]
        try GitProcessState.check(Darwin.pipe(&descriptors), errnoBased: true)
        readDescriptor = descriptors[0]
        writeDescriptor = descriptors[1]
        do {
            // Spawn actions must never overwrite another pipe's source if a
            // caller happened to launch Zshell with a standard FD closed.
            readDescriptor = try descriptorAboveStandard(readDescriptor)
            writeDescriptor = try descriptorAboveStandard(writeDescriptor)
            try GitProcessState.check(fcntl(readDescriptor, F_SETFD, FD_CLOEXEC), errnoBased: true)
            try GitProcessState.check(fcntl(writeDescriptor, F_SETFD, FD_CLOEXEC), errnoBased: true)
        } catch {
            closeRead()
            closeWrite()
            throw error
        }
    }

    deinit { closeRead(); closeWrite() }

    func closeRead() {
        guard readDescriptor >= 0 else { return }
        Darwin.close(readDescriptor)
        readDescriptor = -1
    }

    func closeWrite() {
        guard writeDescriptor >= 0 else { return }
        Darwin.close(writeDescriptor)
        writeDescriptor = -1
    }

    func makeNonblocking(_ descriptor: Int32) throws {
        let flags = fcntl(descriptor, F_GETFL, 0)
        try GitProcessState.check(flags, errnoBased: true)
        try GitProcessState.check(fcntl(descriptor, F_SETFL, flags | O_NONBLOCK), errnoBased: true)
    }

    private func descriptorAboveStandard(_ descriptor: Int32) throws -> Int32 {
        guard descriptor <= STDERR_FILENO else { return descriptor }
        let replacement = fcntl(descriptor, F_DUPFD_CLOEXEC, STDERR_FILENO + 1)
        try GitProcessState.check(replacement, errnoBased: true)
        Darwin.close(descriptor)
        return replacement
    }
}

private nonisolated final class GitProcessReaper: @unchecked Sendable {
    private var source: DispatchSourceProcess?

    static func reapOnExit(_ pid: pid_t) {
        let reaper = GitProcessReaper()
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit,
                                                     queue: .global(qos: .utility))
        reaper.source = source
        source.setEventHandler {
            var status: Int32 = 0
            var result: pid_t
            repeat { result = waitpid(pid, &status, WNOHANG) } while result < 0 && errno == EINTR
            if result != 0 {
                reaper.source?.cancel()
                reaper.source = nil
            }
        }
        source.resume()
    }
}
