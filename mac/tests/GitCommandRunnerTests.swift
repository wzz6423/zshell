import Darwin
import Foundation

private nonisolated func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

private nonisolated func elapsed(since start: DispatchTime) -> TimeInterval {
    Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
}

private nonisolated final class Fixture {
    let directory: URL
    let script: URL
    let pids: URL

    init(_ root: URL, name: String, body: String) throws {
        directory = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        script = directory.appendingPathComponent("helper.sh")
        pids = directory.appendingPathComponent("pids")
        try body.replacingOccurrences(of: "$PID_FILE", with: "'\(pids.path)'")
            .write(to: script, atomically: true, encoding: .utf8)
    }

    var arguments: [String] {
        ["-c", "alias.auditwait=!/bin/sh '\(script.path)'", "auditwait"]
    }

    func ownedPIDs() -> [pid_t] {
        (try? String(contentsOf: pids, encoding: .utf8))?
            .split(whereSeparator: \.isWhitespace).compactMap { pid_t($0) } ?? []
    }

    func requireStopped() {
        let start = DispatchTime.now()
        while elapsed(since: start) < 1 {
            if ownedPIDs().allSatisfy({ Darwin.kill($0, 0) < 0 && errno == ESRCH }) { return }
            usleep(10_000)
        }
        for pid in ownedPIDs() {
            var info = proc_bsdinfo()
            let bytes = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
            print("Pending helper: pid \(pid), ppid \(info.pbi_ppid), pgid \(getpgid(pid)), state \(info.pbi_status), info bytes \(bytes)")
        }
        require(false, "Fixture still has live helper processes: \(ownedPIDs())")
    }
}

private nonisolated let sleepingHelper = """
trap '' TERM
printf '%s\\n' "$$" > $PID_FILE
/bin/sleep 3 &
printf '%s\\n' "$!" >> $PID_FILE
wait
printf finished
"""

private nonisolated func originalAlias(_ root: URL) {
    let args = ["-c", "alias.auditwait=!trap '' TERM; /bin/sleep 3; printf finished", "auditwait"]
    let start = DispatchTime.now()
    let runner = GitCommandRunner.runData(args, in: root.path, timeout: 0.1)
    let duration = elapsed(since: start)
    require(runner.status == -2 && runner.stdout.isEmpty && duration < 0.8,
            "Original hanging alias did not finish by its deadline")
    let modelStart = DispatchTime.now()
    let model = GitStatusModel.runGit(args, in: root.path, timeout: 0.1)
    let modelDuration = elapsed(since: modelStart)
    require(model.status == -2 && model.stdout.isEmpty && modelDuration < 0.8,
            "Model still waits for the original alias's pipe EOF")
    print("Original TERM-ignoring alias: runner \(String(format: "%.3f", duration))s / model \(String(format: "%.3f", modelDuration))s")
}

private nonisolated func boundedTimeout(_ root: URL, model: Bool) throws {
    let fixture = try Fixture(root, name: model ? "model-timeout" : "runner-timeout", body: sleepingHelper)
    let start = DispatchTime.now()
    let status: Int32
    if model {
        let result = GitStatusModel.runGit(fixture.arguments, in: root.path, timeout: 0.1)
        status = result.status
        require(result.stderr.hasSuffix("Git did not respond in time."), "Model lost its timeout diagnostic")
    } else {
        let result = GitCommandRunner.runData(fixture.arguments, in: root.path, timeout: 0.1)
        status = result.status
        require(!result.stdout.contains(Data("finished".utf8)), "Timed-out helper was allowed to finish")
    }
    let duration = elapsed(since: start)
    require(status == -2 && duration < 0.8, "Timeout did not bound the entire Git command")
    require(!fixture.ownedPIDs().isEmpty, "Timeout fixture never started")
    fixture.requireStopped()
    print("\(model ? "GitStatusModel" : "GitCommandRunner") helper timeout: \(String(format: "%.3f", duration))s, status \(status)")
}

private nonisolated func exitedParent(_ root: URL) throws {
    let fixture = try Fixture(root, name: "exited-parent", body: """
    (
        trap '' TERM
        /bin/sleep 3 &
        printf '%s\\n' "$!" >> $PID_FILE
        wait
        printf finished
    ) &
    printf '%s\\n' "$!" >> $PID_FILE
    exit 0
    """)
    let start = DispatchTime.now()
    let result = GitCommandRunner.runData(fixture.arguments, in: root.path, timeout: 0.1)
    let duration = elapsed(since: start)
    require(result.status == -2 && duration < 0.8, "Exited Git parent bypassed the pipe deadline")
    require(!fixture.ownedPIDs().isEmpty, "Background fixture never started")
    fixture.requireStopped()
    print("Exited parent with inherited pipes: \(String(format: "%.3f", duration))s, status \(result.status)")
}

private nonisolated func successfulBackgroundHelper(_ root: URL) throws {
    let fixture = try Fixture(root, name: "successful-background", body: """
    /bin/sleep 2 </dev/null >/dev/null 2>&1 &
    printf '%s\\n' "$!" > $PID_FILE
    printf success
    """)
    let result = GitCommandRunner.runData(fixture.arguments, in: root.path, timeout: 1)
    require(result.status == 0 && String(decoding: result.stdout, as: UTF8.self) == "success",
            "Command with detached stdio did not succeed")
    let pids = fixture.ownedPIDs()
    require(pids.count == 1 && Darwin.kill(pids[0], 0) == 0, "Success killed an unrelated-to-output helper")
    Darwin.kill(pids[0], SIGKILL)
    fixture.requireStopped()
    print("Successful command left its helper with detached stdio running: passed")
}

private nonisolated func inheritedDescriptors(_ root: URL) throws {
    let descriptor = Darwin.open(root.appendingPathComponent("inheritable-fd").path, O_RDWR | O_CREAT, 0o600)
    require(descriptor > STDERR_FILENO, "Could not create inherited descriptor fixture")
    defer { Darwin.close(descriptor) }
    require(fcntl(descriptor, F_SETFD, 0) == 0, "Could not make descriptor inheritable")
    let fixture = try Fixture(root, name: "inherited-fds", body: """
    if (printf leak >&\(descriptor)) 2>/dev/null; then exit 91; fi
    printf isolated
    """)
    let result = GitCommandRunner.runData(fixture.arguments, in: root.path, timeout: 1)
    require(result.status == 0 && String(decoding: result.stdout, as: UTF8.self) == "isolated",
            "Git inherited a nonstandard parent descriptor")
    print("Git inherited only configured standard descriptors: passed")
}

private nonisolated func continuousOutput(_ root: URL) throws {
    let fixture = try Fixture(root, name: "continuous-output", body: """
    trap '' TERM
    printf '%s\\n' "$$" > $PID_FILE
    /usr/bin/perl -e 'alarm 3; while (1) { print "continuous-output" x 8192; print STDERR "continuous-error" x 8192; }' &
    printf '%s\\n' "$!" >> $PID_FILE
    wait
    """)
    let start = DispatchTime.now()
    let result = GitCommandRunner.runData(fixture.arguments, in: root.path, limit: 128, timeout: 0.1)
    let duration = elapsed(since: start)
    require(result.status == -2 && duration < 0.8, "Continuous output hid the deadline")
    require(result.stdout.count == 128 && result.truncated, "Output limit was not preserved")
    fixture.requireStopped()
    print("Continuous truncated output: \(String(format: "%.3f", duration))s, retained \(result.stdout.count) bytes")
}

private nonisolated func blockedInput(_ root: URL) throws {
    let fixture = try Fixture(root, name: "blocked-input", body: sleepingHelper)
    let start = DispatchTime.now()
    let result = GitCommandRunner.runData(fixture.arguments, in: root.path,
                                          input: Data(repeating: 42, count: 8 << 20), timeout: 0.1)
    let duration = elapsed(since: start)
    require(result.status == -2 && duration < 0.8, "Blocked stdin hid the deadline")
    fixture.requireStopped()
    print("Blocked 8 MiB stdin: \(String(format: "%.3f", duration))s, status \(result.status)")
}

private nonisolated func outputs(_ root: URL) throws {
    let fixture = try Fixture(root, name: "large-output", body: """
    /usr/bin/perl -e 'for (1..768) { print STDOUT "a" x 16384; print STDERR "b" x 8192; }'
    """)
    let result = GitCommandRunner.runData(fixture.arguments, in: root.path, limit: .max, timeout: 10)
    require(result.status == 0 && !result.truncated, "Normal output was reported as incomplete")
    require(result.stdout == Data(repeating: 97, count: 12 << 20), "Normal stdout lost bytes")
    require(result.stderr == String(repeating: "b", count: 6 << 20), "Normal stderr lost bytes")
    let model = GitStatusModel.runGit(fixture.arguments, in: root.path, timeout: 10)
    require(model.status == 0 && model.stdout == String(repeating: "a", count: 12 << 20)
            && model.stderr == result.stderr, "Model's unlimited output was capped")
    let limited = GitCommandRunner.runData(fixture.arguments, in: root.path, limit: 128, timeout: 10)
    require(limited.status == 0 && limited.truncated && limited.stdout == Data(repeating: 97, count: 128)
            && limited.stderr == String(repeating: "b", count: 128), "Limited output was not drained to completion")
    let zero = GitCommandRunner.runData(fixture.arguments, in: root.path, limit: 0, timeout: 10)
    require(zero.status == 0 && zero.truncated && zero.stdout.isEmpty && zero.stderr.isEmpty,
            "Zero output limit failed to drain the pipes")

    let unicode = try Fixture(root, name: "unicode", body: """
    /usr/bin/perl -e 'print pack("C*", 0xe7, 0x95, 0x8c, 0xf0, 0x9f, 0x99, 0x82) x 20000;'
    """)
    let unicodeResult = GitStatusModel.runGit(unicode.arguments, in: root.path, timeout: 2)
    require(unicodeResult.status == 0 && unicodeResult.stdout == String(repeating: "界🙂", count: 20000),
            "UTF-8 split across read batches was damaged")
    print("Large stdout/stderr, truncation/zero limit, and Unicode: passed")
}

private nonisolated func inputAndEnvironment(_ root: URL) throws {
    let echo = try Fixture(root, name: "stdin-echo", body: "/bin/cat")
    let input = Data(repeating: 53, count: 8 << 20)
    let result = GitCommandRunner.runData(echo.arguments, in: root.path, input: input, limit: .max, timeout: 10)
    require(result.status == 0 && result.stdout == input && !result.truncated, "Stdin round trip lost bytes")
    for input in [Data?.none, Data()] {
        let result = GitCommandRunner.runData(echo.arguments, in: root.path, input: input, timeout: 1)
        require(result.status == 0 && result.stdout.isEmpty, "Nil or empty stdin did not reach EOF")
    }
    let earlyClose = try Fixture(root, name: "stdin-close", body: "exec 0<&-\nprintf closed")
    let closed = GitCommandRunner.runData(earlyClose.arguments, in: root.path, input: input, timeout: 1)
    require(closed.status == 0 && String(decoding: closed.stdout, as: UTF8.self) == "closed",
            "Closing stdin triggered SIGPIPE or prevented completion")

    GitProxy.update(enabled: true, address: "http://127.0.0.1:45678")
    defer { GitProxy.update(enabled: false, address: "") }
    let environment = try Fixture(root, name: "environment", body: """
    printf '%s|%s|%s|%s|%s|' "$GIT_OPTIONAL_LOCKS" "$GIT_TERMINAL_PROMPT" "$LC_ALL" "$AUDIT_MARKER" "$https_proxy"
    /usr/bin/git config --get http.proxy
    """)
    let value = GitCommandRunner.runData(environment.arguments, in: root.path,
                                        environment: ["AUDIT_MARKER": "自定义"], timeout: 1)
    require(value.status == 0 && String(decoding: value.stdout, as: UTF8.self)
            == "0|0|C|自定义|http://127.0.0.1:45678|http://127.0.0.1:45678\n",
            "Git environment or proxy was lost")
    print("Stdin round trip/nil/empty/early close and proxy/environment: passed")
}

private nonisolated func errorsAndExitCodes(_ root: URL) throws {
    let fixture = try Fixture(root, name: "exit-code", body: "printf diagnostic >&2\nexit 37")
    let result = GitCommandRunner.runData(fixture.arguments, in: root.path, timeout: 1)
    require(result.status == 37 && result.stderr == "diagnostic", "Ordinary nonzero exit changed")
    let signalled = try Fixture(root, name: "signal-exit", body: "kill -KILL $$")
    require(GitCommandRunner.runData(signalled.arguments, in: root.path, timeout: 1).status != 0,
            "Signal termination was reported as successful")
    let invalid = GitCommandRunner.runData(["--version"], in: root.appendingPathComponent("missing").path, timeout: 1)
    require(invalid.status == -1 && !invalid.stderr.isEmpty, "Invalid cwd did not return launch failure")
    let malformed = GitCommandRunner.runData(["bad\0argument"], in: root.path, timeout: 1)
    require(malformed.status == -1, "Malformed argv was accepted")
    print("Exit code, signal exit, invalid cwd/argv: passed")
}

private nonisolated func cancellation(_ root: URL, index: Int) async throws {
    let fixture = try Fixture(root, name: "cancel-\(index)", body: sleepingHelper)
    let arguments = fixture.arguments
    let directory = root.path
    let task = Task.detached { await GitCommandRunner().run(arguments, in: directory) }
    let launchStart = DispatchTime.now()
    while fixture.ownedPIDs().isEmpty, elapsed(since: launchStart) < 1 {
        try await Task.sleep(for: .milliseconds(10))
    }
    require(!fixture.ownedPIDs().isEmpty, "Cancellation fixture never started")
    let start = DispatchTime.now()
    task.cancel()
    let result = await task.value
    let duration = elapsed(since: start)
    require(result.status == -3 && duration < 0.8, "Cancellation left the Git worker blocked")
    fixture.requireStopped()
    print("Running cancellation \(index): \(String(format: "%.3f", duration))s, status \(result.status)")
}

private nonisolated func cancellationAfterParentExit(_ root: URL) async throws {
    let fixture = try Fixture(root, name: "cancel-exited-parent", body: """
    (
        trap '' TERM
        /bin/sleep 3 &
        printf '%s\\n' "$!" >> $PID_FILE
        wait
        printf finished
    ) &
    printf '%s\\n' "$!" >> $PID_FILE
    exit 0
    """)
    let arguments = fixture.arguments
    let directory = root.path
    let task = Task.detached { await GitCommandRunner().run(arguments, in: directory) }
    let launchStart = DispatchTime.now()
    while fixture.ownedPIDs().isEmpty, elapsed(since: launchStart) < 1 {
        try await Task.sleep(for: .milliseconds(10))
    }
    try await Task.sleep(for: .milliseconds(100))
    let start = DispatchTime.now()
    task.cancel()
    let result = await task.value
    let duration = elapsed(since: start)
    require(result.status == -3 && duration < 0.8, "Cancelling an exited parent left pipe readers stuck")
    fixture.requireStopped()
    print("Cancellation after parent exit: \(String(format: "%.3f", duration))s, status \(result.status)")
}

private nonisolated func cancelledBeforeLaunch(_ root: URL) async throws {
    let fixture = try Fixture(root, name: "cancel-before-launch", body: "printf launched > $PID_FILE")
    let arguments = fixture.arguments
    let directory = root.path
    let task = Task.detached {
        withUnsafeCurrentTask { $0?.cancel() }
        return await GitCommandRunner().run(arguments, in: directory)
    }
    let result = await task.value
    require(result.status == -3 && !FileManager.default.fileExists(atPath: fixture.pids.path),
            "Already-cancelled task launched Git")
    print("Cancellation before launch: status \(result.status), no helper launched")
}

private nonisolated func threadCount() -> Int32 {
    var info = proc_taskinfo()
    let bytes = proc_pidinfo(getpid(), PROC_PIDTASKINFO, 0, &info, Int32(MemoryLayout<proc_taskinfo>.size))
    require(bytes > 0, "Could not measure test threads")
    return info.pti_threadnum
}

private nonisolated func descriptorCount() -> Int32 {
    let bytes = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, nil, 0)
    require(bytes > 0, "Could not measure test file descriptors")
    return bytes
}

@main
struct GitCommandRunnerTests {
    static func main() async throws {
        setbuf(Darwin.stdout, nil)
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        originalAlias(root)
        try boundedTimeout(root, model: false)
        try boundedTimeout(root, model: true)
        try exitedParent(root)
        try successfulBackgroundHelper(root)
        try inheritedDescriptors(root)
        try continuousOutput(root)
        try blockedInput(root)
        try outputs(root)
        try inputAndEnvironment(root)
        try errorsAndExitCodes(root)
        try await cancelledBeforeLaunch(root)
        try await cancellationAfterParentExit(root)
        try await cancellation(root, index: 0)
        try await Task.sleep(for: .milliseconds(100))
        let baselineThreads = threadCount()
        let baselineDescriptors = descriptorCount()
        for index in 1...6 { try await cancellation(root, index: index) }
        try await Task.sleep(for: .milliseconds(100))
        let finalThreads = threadCount()
        let finalDescriptors = descriptorCount()
        require(finalThreads <= baselineThreads + 2, "Repeated cancellation left growing reader/worker threads")
        require(finalDescriptors == baselineDescriptors, "Repeated cancellation leaked pipe descriptors")
        print("Repeated cancellation resources: threads \(baselineThreads) -> \(finalThreads), FD bytes \(baselineDescriptors) -> \(finalDescriptors)")
        print("Git process timeout/cancellation regression: passed")
    }
}
