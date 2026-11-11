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
        do { try run() }
        catch {
            fputs("\(error)\n", stderr)
            exit(1)
        }
    }

    private static func run() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
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
