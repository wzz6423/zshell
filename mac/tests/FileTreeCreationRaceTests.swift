import Darwin
import Foundation

nonisolated final class CreationRaceFixture: @unchecked Sendable {
    static let shared = CreationRaceFixture()
    let contents = Data("Externally created contents must survive.".utf8)
    private let condition = NSCondition()
    private var destination: String?
    private var finished = false
    private var failure: Error?

    func pauseBeforeCreation(_ path: String) {
        condition.lock()
        defer { condition.unlock() }
        destination = path
        condition.broadcast()
        let deadline = Date().addingTimeInterval(5)
        while !finished {
            precondition(condition.wait(until: deadline), "External writer did not complete")
        }
        if let failure { preconditionFailure("External writer failed: \(failure)") }
    }

    func writeAfterPrecheck() {
        condition.lock()
        let deadline = Date().addingTimeInterval(5)
        while destination == nil {
            precondition(condition.wait(until: deadline), "Production existence precheck did not reach the barrier")
        }
        let path = destination!
        condition.unlock()
        let result = Result { try contents.write(to: URL(fileURLWithPath: path), options: .withoutOverwriting) }
        condition.lock()
        if case .failure(let error) = result { failure = error }
        finished = true
        condition.broadcast()
        condition.unlock()
    }
}

@main struct FileTreeCreationRaceTests {
    @MainActor static func main() {
        setbuf(stdout, nil)
        setbuf(stderr, nil)
        do {
            try run()
        } catch {
            fputs("FAIL creation race: \(error)\n", stderr)
            exit(1)
        }
    }

    @MainActor private static func run() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let destination = root.appendingPathComponent("race.txt")
        let model = FileTreeModel()
        model.sync(root: root.path)
        model.beginNewFile(in: root.path)
        Thread { CreationRaceFixture.shared.writeAfterPrecheck() }.start()
        let created = model.commitDraft(name: destination.lastPathComponent)
        let saved = try Data(contentsOf: destination)
        let preserved = saved == CreationRaceFixture.shared.contents
        let draftCleared = model.draft == nil && !model.items.contains(where: \.isDraft)
        print("Writer completed after the production existence check: savedBytes=\(saved.count) preserved=\(preserved) returnedNewFile=\(created != nil) draftCleared=\(draftCleared)")
        guard created == nil, preserved, draftCleared else {
            throw NSError(domain: "FileTreeCreationRaceTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Creation must reject the race and preserve the external writer's contents."])
        }
        print("PASS production file creation rejects a concurrent writer and preserves all \(saved.count) bytes")
    }
}
