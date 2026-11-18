import Darwin
import Foundation

#if !PTY_MUX_STANDALONE
@testable import zshell
#endif

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

private func check(_ condition: @autoclosure () -> Bool, _ label: String) throws {
    guard condition() else { throw TestFailure(description: "FAIL: \(label)") }
    print("PASS: \(label)")
}

private func wait(_ label: String, until condition: () -> Bool) throws {
    let deadline = Date().addingTimeInterval(5)
    while !condition() {
        guard Date() < deadline else { throw TestFailure(description: "Timed out: \(label)") }
        Thread.sleep(forTimeInterval: 0.01)
    }
}

#if TERMINAL_SESSION_TEARDOWN_TEST
private final class LocalPTY {
    let pid: pid_t
    let master: Int32
    private var reaped = false
    private var jobs: [ZshellAgentProcessIdentity] = []

    init(_ script: String) throws {
        var master: Int32 = -1
        var slave: Int32 = -1
        guard openpty(&master, &slave, nil, nil, nil) == 0 else { throw PTYMuxWire.errnoError("openpty") }
        defer { Darwin.close(slave) }
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw PTYMuxWire.errnoError("spawn actions") }
        defer { posix_spawn_file_actions_destroy(&actions) }
        for descriptor in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
            guard posix_spawn_file_actions_adddup2(&actions, slave, descriptor) == 0 else {
                throw PTYMuxWire.errnoError("dup2")
            }
        }
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { throw PTYMuxWire.errnoError("spawn attributes") }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSID)) == 0 else {
            throw PTYMuxWire.errnoError("setsid")
        }
        let command = [CommandLine.arguments[0], PTYMuxCommandLine.childArgument, "/bin/sh", "-c", script]
        let argv = command.map { strdup($0) }
        let env = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") }
        defer { for pointer in argv + env { free(pointer) } }
        var arguments = argv + [nil]
        var variables = env + [nil]
        var pid: pid_t = 0
        guard posix_spawn(&pid, command[0], &actions, &attributes, &arguments, &variables) == 0 else {
            Darwin.close(master)
            throw PTYMuxWire.errnoError("spawn")
        }
        self.pid = pid
        self.master = master
    }

    func observe(_ file: URL) throws -> ZshellAgentProcessIdentity {
        try wait("local job publishes its identity") {
            guard let text = try? String(contentsOf: file, encoding: .utf8),
                  let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
            return ZshellAgentProcessIdentity(pid: pid) != nil
        }
        let pid = pid_t(try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
        let job = ZshellAgentProcessIdentity(pid: pid)!
        jobs.append(job)
        return job
    }

    func reap() {
        guard !reaped else { return }
        var status: Int32 = 0
        var result: pid_t
        repeat { result = waitpid(pid, &status, 0) } while result < 0 && errno == EINTR
        reaped = result == pid || errno == ECHILD
    }

    func cleanup() {
        if !reaped {
            jobs += PTYSessionCleanupCapture.members(root: pid)
            _ = Darwin.kill(pid, SIGKILL)
        } else if jobs.contains(where: { $0.isAlive && getsid($0.pid) == pid }) {
            jobs += PTYSessionCleanupCapture.members(root: pid)
        }
        for job in jobs where job.isAlive && getsid(job.pid) == pid { _ = Darwin.kill(job.pid, SIGKILL) }
        reap()
    }

    deinit {
        // waitpid has not released this owned child's PID, even if it exited
        // before a failing test managed to observe its new background jobs.
        cleanup()
        Darwin.close(master)
    }
}

private enum PTYSessionCleanupCapture {
    static func members(root: pid_t) -> [ZshellAgentProcessIdentity] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let written = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard written > 0 else { return [] }
        return pids.prefix(Int(written)).filter { $0 > 1 && getsid($0) == root }
            .compactMap { ZshellAgentProcessIdentity(pid: $0) }
    }
}

@MainActor private func waitLocal(_ label: String, until condition: () -> Bool) throws {
    let deadline = Date().addingTimeInterval(5)
    while !condition() {
        guard Date() < deadline else { throw TestFailure(description: "Timed out: \(label)") }
        _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
    }
}

@MainActor private func localTeardown(_ root: URL, mode: String) throws {
    let ready = root.appendingPathComponent("local.ready")
    let jobFile = root.appendingPathComponent("local.pid")
    let successorFile = root.appendingPathComponent("local-successor.pid")
    let forkGate = root.appendingPathComponent("local-fork.continue")
    let exitGate = root.appendingPathComponent("local.exit")
    let forks = mode == "local-fork" || mode == "local-fork-exit"
    let handler = """
    trap '' HUP
    (trap '' HUP; exec /bin/sleep 60) &
    echo $! > '\(successorFile.path)'
    while [ ! -f '\(forkGate.path)' ]; do /bin/sleep 0.005; done
    \(mode == "local-fork-exit" ? "exit 0" : "")
    """.replacingOccurrences(of: "'", with: "'\\''")
    let pty = try LocalPTY("""
    set -m
    \(forks ? "trap '\(handler)' HUP" : "trap '' HUP")
    (trap '' HUP; : > '\(ready.path)'; exec /bin/sleep 60) &
    echo $! > '\(jobFile.path)'
    \(mode == "local-exited" ? "while [ ! -f '\(exitGate.path)' ]; do /bin/sleep 0.005; done; exit 7" : "while :; do read -r line || :; done")
    """)
    let job = try pty.observe(jobFile)
    try wait("local HUP-ignoring job starts") { FileManager.default.fileExists(atPath: ready.path) }
    try check(getsid(job.pid) == pty.pid && getpgid(job.pid) != pty.pid,
              "local background job has a separate group in the same PTY session")
    let session = TerminalSession(pid: pty.pid, foreground: pty.pid)
    session.surface.onDetach = { pty.reap() }
    if mode == "local-exited" {
        try Data().write(to: exitGate)
        pty.reap()
        session.beginTeardown(processAlive: false, notifyExit: true)
        try waitLocal("natural local close completes") { session.hasExited }
        try check(job.isAlive, "natural local exit preserves its existing background-job semantics")
        return
    }
    session.beginTeardown(processAlive: true, notifyExit: false)
    if forks {
        let successor = try pty.observe(successorFile)
        try check(getsid(successor.pid) == pty.pid && getpgid(successor.pid) != pty.pid,
                  "local HUP handler creates a new background group after the first scan")
        try Data().write(to: forkGate)
        if mode == "local-fork-exit" { pty.reap() }
        try waitLocal("local successor is terminated") { session.hasExited && !successor.isAlive }
        try check(!successor.isAlive, "delayed local termination discovers the HUP successor without trusting a reused root PID")
    } else {
        try waitLocal("explicit local close terminates its background job") { session.hasExited && !job.isAlive }
    }
    try check(!job.isAlive, "explicit local teardown stops a SIGHUP-ignoring background job")
}

#if PTY_SESSION_PROCESS_TEST
@MainActor private func localIdentity(_ root: URL) throws {
    let ready = root.appendingPathComponent("identity.ready")
    let jobFile = root.appendingPathComponent("identity.pid")
    let pty = try LocalPTY("""
    set -m
    trap '' HUP
    (trap '' HUP; : > '\(ready.path)'; exec /bin/sleep 60) &
    echo $! > '\(jobFile.path)'
    while :; do read -r line || :; done
    """)
    let job = try pty.observe(jobFile)
    try wait("identity job starts") { FileManager.default.fileExists(atPath: ready.path) }
    let processes = PTYSessionProcesses(root: pty.pid)!
    try check(PTYSessionProcesses(root: nil, foreground: job.pid)?.root == pty.pid,
              "a live foreground identity recovers a PTY when its shell PID file is unavailable")
    try check(PTYSessionProcesses(root: job.pid)?.root == pty.pid,
              "a backend launch wrapper can leave the shell PID as a member of another session leader")
    try check(PTYSessionProcesses(root: getpid(), foreground: job.pid) == nil,
              "a foreground identity from another known root cannot change cleanup scope")
    let stale = PTYSessionProcesses(root: pty.pid, processes: [ZshellAgentProcessIdentity(stale: job)])
    stale.signal(SIGKILL)
    try check(job.isAlive, "stale microsecond start time cannot signal a current process or its group")
    let sentinel = try LocalPTY("trap '' HUP; exec /bin/sleep 60")
    defer { sentinel.cleanup() }
    try wait("unrelated sentinel starts") { ZshellAgentProcessIdentity(pid: sentinel.pid) != nil }
    let sentinelIdentity = ZshellAgentProcessIdentity(pid: sentinel.pid)!
    PTYSessionProcesses(root: pty.pid, processes: [sentinelIdentity]).signal(SIGKILL)
    try check(sentinelIdentity.isAlive, "a different PTY session survives a mixed cleanup snapshot")
    _ = Darwin.kill(pty.pid, SIGKILL)
    try wait("root becomes a zombie") { ZshellAgentProcessIdentity(pid: pty.pid) == nil }
    try check(processes.refreshing().processes.contains(where: { $0 == job }),
              "an unreaped root with its original start time remains a safe rescan anchor")
    pty.reap()
    try check(PTYSessionProcesses(root: pty.pid, foreground: job.pid)?.processes.contains(job) == true,
              "an already reaped root can only recover through a verified live member in its original session")
    try check(processes.refreshing().processes.contains(where: { $0 == job }),
              "a captured live background member anchors rescans after the backend reaps the root")
    let staleRoot = PTYSessionProcesses(root: pty.pid, processes: processes.processes.map { ZshellAgentProcessIdentity(stale: $0) })
    try check(staleRoot.refreshing().processes == staleRoot.processes,
              "a reaped root and stale members cannot discover or trust a replacement session")
    staleRoot.refreshing().signal(SIGKILL)
    try check(job.isAlive && sentinelIdentity.isAlive, "stale cleanup leaves both the live old job and unrelated session untouched")
    processes.refreshing().signal(SIGKILL)
    try wait("identity cleanup completes") { !job.isAlive }

    let successorFile = root.appendingPathComponent("zombie-successor.pid")
    let zombieReady = root.appendingPathComponent("zombie.ready")
    let zombieFork = root.appendingPathComponent("zombie.fork")
    let zombie = try LocalPTY("""
    set -m
    trap '' HUP
    : > '\(zombieReady.path)'
    while [ ! -f '\(zombieFork.path)' ]; do /bin/sleep 0.005; done
    (trap '' HUP; exec /bin/sleep 60) &
    echo $! > '\(successorFile.path)'
    exit 7
    """)
    try wait("zombie fixture shell starts") { FileManager.default.fileExists(atPath: zombieReady.path) }
    let beforeFork = PTYSessionProcesses(root: zombie.pid)!
    try Data().write(to: zombieFork)
    let successor = try zombie.observe(successorFile)
    try wait("forking root becomes a zombie") { ZshellAgentProcessIdentity(pid: zombie.pid) == nil }
    let afterFork = beforeFork.refreshing()
    try check(afterFork.processes.contains(successor), "a verified zombie root discovers a new group absent from the original snapshot")
    zombie.reap()
    try check(!beforeFork.refreshing().processes.contains(successor),
              "an already reaped root cannot establish trust in new members from only its former SID")
    beforeFork.refreshing().signal(SIGKILL)
    try check(successor.isAlive && sentinelIdentity.isAlive, "missing anchors never signal uncaptured members or unrelated sessions")
    afterFork.signal(SIGKILL)
    try wait("successor identity cleanup completes") { !successor.isAlive }
}
#endif
#endif

#if PTY_MUX_STANDALONE
private extension ZshellAgentProcessIdentity {
    init(stale process: Self) {
        pid = process.pid
        startedSeconds = process.startedSeconds
        startedMicroseconds = process.startedMicroseconds &+ 1
    }
}
#endif

private final class Fixture {
    let root: URL
    let store = PTYMuxSessionStore()
    private var sessions: [PTYMuxSession] = []
    private var jobs: [(ZshellAgentProcessIdentity, pid_t)] = []

    init(_ root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func create(_ name: String, exits: Bool, ignoresHangup: Bool = false,
                withLaunchDirectory: Bool = false) throws -> (PTYMuxSession, ZshellAgentProcessIdentity) {
        let ready = root.appendingPathComponent("\(name).ready")
        let childFile = root.appendingPathComponent("\(name).pid")
        let exitGate = root.appendingPathComponent("\(name).exit")
        // Job control puts the background process in its own group; a signal
        // to the login shell's group alone cannot end it.
        let script = """
        set -m
        \(ignoresHangup ? "trap '' HUP" : "")
        (trap '' HUP; : > '\(ready.path)'; exec /bin/sleep 60) &
        echo $! > '\(childFile.path)'
        while [ ! -f '\(ready.path)' ]; do /bin/sleep 0.01; done
        \(exits ? "while [ ! -f '\(exitGate.path)' ]; do /bin/sleep 0.01; done; exit 7" : "while IFS= read -r line; do printf 'RECEIVED-%s\\n' \"$line\"; done")
        """
        let id = UUID()
        let directory = withLaunchDirectory ? PersistentCLIConnection.launchDirectory(for: id) : nil
        if let directory {
            try PersistentCLIConnection.prepare(for: id)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        }
        let session = try launch(script, id: id.uuidString, launchDirectoryURL: directory)
        try wait("background job starts") { FileManager.default.fileExists(atPath: ready.path) }
        let job = try observe(childFile, in: session)
        try check(getsid(job.pid) == session.pid && getpgid(job.pid) != session.pid,
                  "background job belongs to the PTY in a separate job-control group")
        if exits { try Data().write(to: exitGate) }
        return (session, job)
    }

    func launch(_ script: String, id: String = UUID().uuidString, launchDirectoryURL: URL? = nil) throws -> PTYMuxSession {
        let session = try store.create(id: id, workingDirectory: root.path, command: ["/bin/sh", "-c", script],
                                       launchDirectoryURL: launchDirectoryURL, theme: ZshellTheme())
        sessions.append(session)
        return session
    }

    func observe(_ childFile: URL, in session: PTYMuxSession) throws -> ZshellAgentProcessIdentity {
        try wait("background PID is published") {
            guard let text = try? String(contentsOf: childFile, encoding: .utf8) else { return false }
            return pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
        }
        guard let pid = pid_t(try String(contentsOf: childFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)),
              let job = ZshellAgentProcessIdentity(pid: pid) else {
            throw TestFailure(description: "Could not observe the background job")
        }
        jobs.append((job, session.pid))
        return job
    }

    func cleanup() {
        for session in sessions { session.terminate() }
        Thread.sleep(forTimeInterval: 0.35)
        for (job, rootPID) in jobs where job.isAlive && getsid(job.pid) == rootPID {
            _ = Darwin.kill(job.pid, SIGKILL)
        }
    }
}

private final class Client {
    let attachment: PTYMuxAttachment
    private let peer: Int32
    private var output = Data()

    init(session: PTYMuxSession) throws {
        var descriptors: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else { throw PTYMuxWire.errnoError("socketpair") }
        attachment = PTYMuxAttachment(descriptor: descriptors[0])
        peer = descriptors[1]
        do {
            try PTYMuxWire.configureSocket(descriptors[0])
            try session.attach(attachment) {}
        } catch {
            Darwin.close(descriptors[0])
            Darwin.close(descriptors[1])
            throw error
        }
    }

    deinit {
        attachment.finish()
        Darwin.close(attachment.descriptor)
        Darwin.close(peer)
    }

    func contains(_ text: String) -> Bool {
        var descriptor = pollfd(fd: peer, events: Int16(POLLIN), revents: 0)
        if Darwin.poll(&descriptor, 1, 0) > 0, descriptor.revents & Int16(POLLIN) != 0 {
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            let count = Darwin.read(peer, &buffer, buffer.count)
            if count > 0 { output.append(contentsOf: buffer.prefix(count)) }
        }
        return String(decoding: output, as: UTF8.self).contains(text)
    }
}

@main
struct PTYMuxSessionLifecycleTests {
    static func main() {
        if PTYMuxCommandLine.shouldRunChild { PTYMuxCommandLine.runChild() }
        setbuf(stdout, nil)
        do { try run() }
        catch {
            fputs("\(error)\n", stderr)
            exit(1)
        }
    }

    private static func run() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        #if TERMINAL_SESSION_TEARDOWN_TEST
        if CommandLine.arguments[1].hasPrefix("local-") {
            try MainActor.assumeIsolated {
                #if PTY_SESSION_PROCESS_TEST
                if CommandLine.arguments[1] == "local-identity" { try localIdentity(root); return }
                #endif
                try localTeardown(root, mode: CommandLine.arguments[1])
            }
            return
        }
        #endif
        let fixture = try Fixture(root)
        defer { fixture.cleanup() }
        switch CommandLine.arguments[1] {
        case "exited": try exited(fixture)
        case "terminate": try terminate(fixture)
        case "detach": try detach(fixture)
        case "fork": try forkDuringHangup(fixture, rootExits: true)
        case "fork-live": try forkDuringHangup(fixture, rootExits: false)
        case "recreate": try recreate(fixture)
        #if PTY_MUX_IDENTITY_TEST
        case "identity": try identity(fixture)
        case "stress": try stress(fixture)
        #endif
        default: throw TestFailure(description: "Unknown lifecycle test")
        }
    }

    private static func exited(_ fixture: Fixture) throws {
        let (session, job) = try fixture.create("exited", exits: true)
        try wait("shell exits") { !session.isRunning }
        let status = session.snapshot(tailBytes: 0).objectValue?["waitStatus"]?.intValue
        try check(status == 7 << 8, "natural shell exit preserves its wait status")
        _ = try fixture.store.create(workingDirectory: fixture.root.path, command: ["/bin/true"], theme: ZshellTheme())
        try check(fixture.store.session(id: session.id) == nil, "an exited session is evicted on the next create")
        try wait("exited shell's background job is stopped") { !job.isAlive }
        try check(!job.isAlive, "session eviction leaves no SIGHUP-ignoring background job")
        session.terminate()
        session.terminate()
        try check(!session.isRunning, "repeated termination of an exited session is harmless")
    }

    private static func terminate(_ fixture: Fixture) throws {
        let (session, job) = try fixture.create("terminate", exits: false, ignoresHangup: true)
        session.terminate()
        session.terminate()
        try wait("explicit termination finishes") { !session.isRunning && !job.isAlive }
        session.terminate()
        try check(!session.isRunning && !job.isAlive, "repeated terminate ends a HUP-ignoring shell and its separate background group")
    }

    private static func detach(_ fixture: Fixture) throws {
        let (session, job) = try fixture.create("detach", exits: false)
        do {
            let client = try Client(session: session)
            session.detach(client.attachment)
        }
        Thread.sleep(forTimeInterval: 0.35)
        try check(session.isRunning && job.isAlive, "normal detach preserves the shell and its background job")
        let client = try Client(session: session)
        defer { session.detach(client.attachment) }
        session.write(Data("reattached\n".utf8), from: client.attachment)
        try wait("reattached shell receives input") { client.contains("RECEIVED-reattached") }
        try check(session.isRunning && job.isAlive, "the same PTY continues accepting input after reattach")
        session.terminate()
        try wait("detached session can still terminate") { !session.isRunning && !job.isAlive }
        try check(!job.isAlive, "explicit termination cleans up a previously detached job")
    }

    private static func forkDuringHangup(_ fixture: Fixture, rootExits: Bool) throws {
        let ready = fixture.root.appendingPathComponent("fork.ready")
        let successorFile = fixture.root.appendingPathComponent("successor.pid")
        let successorGate = fixture.root.appendingPathComponent("successor.continue")
        let successorScript = "trap '' HUP; exec /bin/sleep 60"
        let handler = """
        trap '' HUP
        /bin/sh -c "\(successorScript)" &
        echo $! > '\(successorFile.path)'
        while [ ! -f '\(successorGate.path)' ]; do /bin/sleep 0.01; done
        \(rootExits ? "exit 0" : "")
        """
        let escapedHandler = handler.replacingOccurrences(of: "'", with: "'\\''")
        let session = try fixture.launch("""
        set -m
        trap '\(escapedHandler)' HUP
        : > '\(ready.path)'
        while :; do read -r line || :; done
        """)
        try wait("HUP handler is installed") { FileManager.default.fileExists(atPath: ready.path) }
        session.terminate()
        session.terminate()
        try wait("HUP handler forks a successor") { FileManager.default.fileExists(atPath: successorFile.path) }
        let successor = try fixture.observe(successorFile, in: session)
        try check(getsid(successor.pid) == session.pid, "a HUP handler can fork a new job in the terminating PTY")
        try Data().write(to: successorGate)
        try wait("successor and root terminate") { !session.isRunning && !successor.isAlive }
        try check(!successor.isAlive, rootExits
                  ? "root exit cleans up a job forked after the initial termination scan"
                  : "forced termination rescans a live root and cleans up its new job")
    }

    private static func recreate(_ fixture: Fixture) throws {
        let (old, _) = try fixture.create("recreate", exits: false, withLaunchDirectory: true)
        old.terminate()
        try wait("old root exits") { !old.isRunning }
        let replacement = try fixture.launch("trap '' HUP; exec /bin/sleep 60", id: old.id)
        guard let id = UUID(uuidString: replacement.id) else { throw TestFailure(description: "Invalid replacement ID") }
        try PersistentCLIConnection.save(id: id, bindingToken: "replacement", environment: [:])
        let directory = PersistentCLIConnection.launchDirectory(for: id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let marker = directory.appendingPathComponent("replacement.txt")
        try Data("replacement".utf8).write(to: marker)
        Thread.sleep(forTimeInterval: 0.35)
        try check(replacement.isRunning, "the replacement session survives old termination callbacks")
        try check(FileManager.default.fileExists(atPath: PersistentCLIConnection.connectionURL(for: id).path),
                  "old termination callbacks preserve the replacement session's connection file")
        try check(FileManager.default.fileExists(atPath: marker.path), "old termination callbacks preserve replacement launch files")
        replacement.terminate()
        try wait("replacement stops") { !replacement.isRunning }
    }

    #if PTY_MUX_IDENTITY_TEST
    private static func identity(_ fixture: Fixture) throws {
        let (session, job) = try fixture.create("identity", exits: false)
        try check(PTYMuxSession.isCurrentSessionProcess(job, root: session.pid), "a live process identity in the PTY is accepted")
        #if PTY_MUX_STANDALONE
        try check(!PTYMuxSession.isCurrentSessionProcess(ZshellAgentProcessIdentity(stale: job), root: session.pid),
                  "a stale start time cannot signal a new occupant of the same PID")
        #endif
        try check(!PTYMuxSession.isCurrentSessionProcess(job, root: getpid()), "another session ID is rejected")
        guard let owner = ZshellAgentProcessIdentity(pid: getpid()) else { throw TestFailure(description: "Test process identity is unavailable") }
        try check(!PTYMuxSession.isCurrentSessionProcess(owner, root: getsid(getpid())), "the daemon never signals itself")
        session.terminate()
        try wait("identity fixture stops") { !session.isRunning && !job.isAlive }
        try check(!PTYMuxSession.isCurrentSessionProcess(job, root: session.pid), "an exited process identity is rejected")
    }

    private static func stress(_ fixture: Fixture) throws {
        let sentinel = try fixture.launch("trap '' HUP; exec /bin/sleep 60")
        guard let sentinelIdentity = ZshellAgentProcessIdentity(pid: sentinel.pid) else {
            throw TestFailure(description: "Sentinel did not start")
        }
        for index in 0..<12 {
            let (session, job) = try fixture.create("race-\(index)", exits: index % 2 == 0, ignoresHangup: true)
            DispatchQueue.concurrentPerform(iterations: 8) { _ in session.terminate() }
            try wait("raced termination \(index) finishes") { !session.isRunning && !job.isAlive }
            session.terminate()
            try check(sentinelIdentity.isAlive && sentinel.isRunning, "unrelated sentinel survives termination race \(index + 1)/12")
        }
        Thread.sleep(forTimeInterval: 0.35)
        try check(sentinelIdentity.isAlive && sentinel.isRunning, "delayed SIGKILL callbacks preserve an unrelated session")
        sentinel.terminate()
        try wait("sentinel is stopped explicitly") { !sentinel.isRunning }
    }
    #endif
}
