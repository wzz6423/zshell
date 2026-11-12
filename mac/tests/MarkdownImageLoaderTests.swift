import AppKit
import Darwin
import Foundation
#if ZSHELL_MARKDOWN_IMAGE_BUILT_APP
@testable import zshell
#endif

@main
@MainActor
struct MarkdownImageLoaderTests {
    private static var checks = 0

    static func main() async {
        setbuf(stdout, nil)
        let scenario = CommandLine.arguments[2]
        defer { Fixture.controlSession.invalidateAndCancel() }
        do {
            let fixture = Fixture(base: URL(string: CommandLine.arguments[1])!, scenario: scenario)
            switch scenario {
            case "cache": try await cache(fixture)
            case "late-success": try await lateSuccess(fixture)
            case "early-success": try await earlySuccess(fixture)
            case "late-failure": try await lateFailure(fixture)
            case "reset-storm": try await resetStorm(fixture)
            case "oversized": try await rejectedSources(fixture)
            case "streamed": try await streamed(fixture)
            case "large-known", "large-unknown", "large-chunked", "large-compressed":
                try await largeImage(fixture)
            case "limit-known", "limit-unknown", "limit-chunked", "limit-compressed":
                try await boundedImage(fixture)
            case "concurrent": try await concurrentImages(fixture)
            case "large-reset": try await largeReset(fixture)
            case "cancellation": try await cancellation(fixture)
            case "stall": try await stalledImage(fixture)
            case "local-image": try await localImage()
            case "local-fifo": try await localFIFO()
            default: throw failure("Unknown scenario: \(scenario)")
            }
            print("Markdown image loader \(scenario): \(checks) checks passed")
        } catch {
            print("FAIL \(scenario): \(error.localizedDescription)")
            exit(1)
        }
    }

    private static func cache(_ fixture: Fixture) async throws {
        let loader = MarkdownImageLoader()
        var arrivals = 0
        loader.onLoad = { arrivals += 1 }
        try check(loader.image(for: fixture.imageURL) == nil, "a cache miss starts an asynchronous load")
        let initialLoad = try loadTask(for: fixture.imageURL, in: loader)
        try await fixture.waitForRequests(1)
        for _ in 0..<10 { _ = loader.image(for: fixture.imageURL) }
        try check(try await fixture.state().requests == 1, "repeated renders share one in-flight request")
        try await fixture.release(1)
        await initialLoad.value
        let initial = loader.image(for: fixture.imageURL)
        try check(initial?.size.width == 1, "the response becomes a decoded cached image")
        try check(initial === loader.image(for: fixture.imageURL), "a cache hit returns the existing image")

        loader.reset()
        try check(loader.image(for: fixture.imageURL) == nil, "reset invalidates an already cached image")
        let resetLoad = try loadTask(for: fixture.imageURL, in: loader)
        try await fixture.waitForRequests(2)
        try await fixture.release(2)
        await resetLoad.value
        try check(loader.image(for: fixture.imageURL)?.size.width == 2, "the reset document caches fresh bytes")
        try check(try await fixture.state().requests == 2 && arrivals == 2 && loader.inFlight.isEmpty,
                  "cached images notify once per load and do not trigger additional requests")
    }

    private static func lateSuccess(_ fixture: Fixture) async throws {
        let loader = MarkdownImageLoader()
        var arrivals = 0
        loader.onLoad = { arrivals += 1 }
        _ = loader.image(for: fixture.imageURL)
        let oldLoad = try loadTask(for: fixture.imageURL, in: loader)
        try await fixture.waitForRequests(1)
        loader.reset()
        _ = loader.image(for: fixture.imageURL)
        let newLoad = try loadTask(for: fixture.imageURL, in: loader)
        try await fixture.waitForRequests(2)
        try await fixture.release(2)
        await newLoad.value
        let current = loader.image(for: fixture.imageURL)
        try check(current?.size.width == 2, "the new request finishes before the old request")

        try await fixture.release(1)
        await oldLoad.value
        try check(arrivals == 1, "a stale success does not notify the current preview")
        try check(current === loader.image(for: fixture.imageURL), "a stale success cannot overwrite the new cached image")
        try check(loader.image(for: fixture.imageURL)?.size.width == 2, "the preview retains the new image bytes")
    }

    private static func earlySuccess(_ fixture: Fixture) async throws {
        let loader = MarkdownImageLoader()
        var arrivals = 0
        loader.onLoad = { arrivals += 1 }
        _ = loader.image(for: fixture.imageURL)
        let oldLoad = try loadTask(for: fixture.imageURL, in: loader)
        try await fixture.waitForRequests(1)
        loader.reset()
        _ = loader.image(for: fixture.imageURL)
        let newLoad = try loadTask(for: fixture.imageURL, in: loader)
        try await fixture.waitForRequests(2)

        try await fixture.release(1)
        await oldLoad.value
        try check(arrivals == 0, "a stale success does not render while the new request is pending")
        let pendingImages = (0..<10).map { _ in loader.image(for: fixture.imageURL) }
        try check(pendingImages.allSatisfy { $0 == nil }, "the new document never exposes the old image")
        try check(try await fixture.state().requests == 2 && loader.inFlight.count == 1,
                  "the pending new request stays deduplicated after old completion")
        try await fixture.release(2)
        await newLoad.value
        try check(loader.image(for: fixture.imageURL)?.size.width == 2, "the new request remains usable after old completion")
    }

    private static func lateFailure(_ fixture: Fixture) async throws {
        let loader = MarkdownImageLoader()
        var arrivals = 0
        loader.onLoad = { arrivals += 1 }
        _ = loader.image(for: fixture.imageURL)
        let oldLoad = try loadTask(for: fixture.imageURL, in: loader)
        try await fixture.waitForRequests(1)
        loader.reset()
        try await fixture.release(1)
        await oldLoad.value
        try check(arrivals == 0, "a discarded failure does not notify the preview")

        _ = loader.image(for: fixture.imageURL)
        let retryLoad = try loadTask(for: fixture.imageURL, in: loader)
        try await fixture.waitForRequests(2)
        try await fixture.release(2)
        await retryLoad.value
        try check(loader.image(for: fixture.imageURL)?.size.width == 2, "a stale failure cannot mark the reset document's URL as failed")
    }

    private static func resetStorm(_ fixture: Fixture) async throws {
        let loader = MarkdownImageLoader()
        var arrivals = 0
        loader.onLoad = { arrivals += 1 }
        let orders = [[2, 3, 1], [3, 1, 2], [1, 2, 3], [2, 1, 3]]
        for (round, order) in orders.enumerated() {
            let first = round * 3
            var loads: [Task<Void, Never>] = []
            for number in 1...3 {
                loader.reset()
                _ = loader.image(for: fixture.imageURL)
                loads.append(try loadTask(for: fixture.imageURL, in: loader))
                try await fixture.waitForRequests(first + number)
            }
            var currentArrived = false
            for number in order {
                try await fixture.release(first + number)
                await loads[number - 1].value
                if number == 3 { currentArrived = true }
                let images = (0..<64).map { _ in loader.image(for: fixture.imageURL) }
                try check(images.allSatisfy { currentArrived ? $0?.size.width == CGFloat(first + 3) : $0 == nil },
                          "reset storm round \(round + 1) exposes only the current generation")
                try check(arrivals == round + (currentArrived ? 1 : 0),
                          "reset storm round \(round + 1) discards old successes and failures")
                try check(try await fixture.state().requests == first + 3
                          && loader.inFlight.count == (currentArrived ? 0 : 1),
                          "reset storm round \(round + 1) keeps 64 repeated renders deduplicated")
            }
        }
    }

    private static func rejectedSources(_ fixture: Fixture) async throws {
        let loader = MarkdownImageLoader()
        var arrivals = 0
        loader.onLoad = { arrivals += 1 }
        let forbidden = ["data:image/png;base64,aGVsbG8=", "ftp://127.0.0.1/image.png",
                         "mailto:image@example.invalid", "javascript:alert(1)"]
        for source in forbidden {
            let url = URL(string: source)!
            try check(loader.image(for: url) == nil && loader.image(for: url) == nil,
                      "unsupported \(url.scheme!) image sources are rejected")
        }
        try check(try await fixture.state().requests == 0 && arrivals == 0,
                  "unsupported sources do not start HTTP image requests or render callbacks")

        _ = loader.image(for: fixture.imageURL)
        let rejectedLoad = try loadTask(for: fixture.imageURL, in: loader)
        try await fixture.waitForRequests(1)
        try await fixture.release(1)
        await rejectedLoad.value
        let rejected = (0..<10).map { _ in loader.image(for: fixture.imageURL) }
        try check(rejected.allSatisfy { $0 == nil } && arrivals == 0,
                  "an image response larger than 20 MiB is not cached or rendered")
        try check(try await fixture.state().requests == 1, "a rejected oversized image is not fetched on every render")
        loader.reset()
        _ = loader.image(for: fixture.imageURL)
        let retryLoad = try loadTask(for: fixture.imageURL, in: loader)
        try await fixture.waitForRequests(2)
        try await fixture.release(2)
        await retryLoad.value
        try check(loader.image(for: fixture.imageURL)?.size.width == 2,
                  "a reset permits a valid replacement for the oversized response")
    }

    private static func streamed(_ fixture: Fixture) async throws {
        let loader = MarkdownImageLoader()
        var arrivals = 0
        loader.onLoad = { arrivals += 1 }
        try check(loader.image(for: fixture.imageURL) == nil, "an unknown-length image starts asynchronously")
        let initialLoad = try loadTask(for: fixture.imageURL, in: loader)
        try await fixture.waitForRequests(1)
        for _ in 0..<64 { _ = loader.image(for: fixture.imageURL) }
        try check(try await fixture.state().requests == 1, "an unknown-length response shares one pending load")
        try await fixture.release(1)
        await initialLoad.value
        let initial = loader.image(for: fixture.imageURL)
        try check(initial?.size.width == 1, "a complete 64 KiB unknown-length PNG is decoded")
        try check(arrivals == 1 && loader.inFlight.isEmpty, "the streamed task ends after its cache and callback update")
        try check(initial === loader.image(for: fixture.imageURL), "the streamed image stays cached")
        loader.reset()
        try check(loader.image(for: fixture.imageURL) == nil, "reset invalidates the streamed image")
        let resetLoad = try loadTask(for: fixture.imageURL, in: loader)
        try await fixture.waitForRequests(2)
        try await fixture.release(2)
        await resetLoad.value
        try check(loader.image(for: fixture.imageURL)?.size.width == 2 && arrivals == 2,
                  "reset loads fresh unknown-length image bytes")
        try check(try await fixture.state().requests == 2 && loader.inFlight.isEmpty,
                  "the streamed replacement leaves no pending load or duplicate request")
    }

    private static func largeImage(_ fixture: Fixture) async throws {
        let loader = MarkdownImageLoader()
        var arrivals = 0
        loader.onLoad = { arrivals += 1 }
        _ = loader.image(for: fixture.imageURL)
        let load = try loadTask(for: fixture.imageURL, in: loader)
        try await fixture.waitForRequests(1)
        let heartbeat = Heartbeat()
        heartbeat.start()
        let started = Date()
        try await fixture.release(1)
        await load.value
        heartbeat.stop()
        let elapsed = Date().timeIntervalSince(started)
        try check(loader.image(for: fixture.imageURL)?.size.width == 1,
                  "a complete valid 20 MiB \(fixture.scenario) PNG is decoded")
        try check(arrivals == 1 && loader.inFlight.isEmpty,
                  "the actual large-image task completes its cache and callback update")
        try check(elapsed < 30, "a local 20 MiB image completes before the broad regression deadline")
        try heartbeat.check()
        let state = try await fixture.waitForRecord(1, complete: true)
        try check(state.records[0].sent == state.records[0].total,
                  "the successful load consumed the complete fixture response")
        for _ in 0..<64 { _ = loader.image(for: fixture.imageURL) }
        try check(try await fixture.state().requests == 1, "large images remain cached across repeated renders")
        print("Large image \(fixture.scenario): \(elapsed)s, \(heartbeat.ticks) actor ticks, max gap \(heartbeat.maximumGap)s")
    }

    private static func boundedImage(_ fixture: Fixture) async throws {
        let loader = MarkdownImageLoader()
        var arrivals = 0
        loader.onLoad = { arrivals += 1 }
        _ = loader.image(for: fixture.imageURL)
        let load = try loadTask(for: fixture.imageURL, in: loader)
        try await fixture.waitForRequests(1)
        let started = Date()
        try await fixture.release(1)
        await load.value
        try check(loader.inFlight.isEmpty && arrivals == 0,
                  "the real over-limit load ends without caching or notifying")
        let images = (0..<64).map { _ in loader.image(for: fixture.imageURL) }
        let requestCount = try await fixture.state().requests
        try check(images.allSatisfy { $0 == nil } && requestCount == 1,
                  "a rejected large image is not retried on each render")
        let state = try await fixture.waitForRecord(1, complete: false)
        let record = state.records[0]
        try check(!record.complete && record.disconnected && record.sent < record.total,
                  "the server observes cancellation before the oversized body finishes")
        if fixture.scenario == "limit-known" {
            try check(record.sent < 1 << 20, "the Content-Length ceiling rejects before buffering the image")
        } else if fixture.scenario != "limit-compressed" {
            try check(record.sent <= (20 << 20) + (2 << 20),
                      "unknown-length and chunked transfers disconnect near the 20 MiB ceiling")
        }
        print("Oversized \(fixture.scenario): \(Date().timeIntervalSince(started))s, \(record.sent)/\(record.total) wire bytes")
    }

    private static func concurrentImages(_ fixture: Fixture) async throws {
        let loader = MarkdownImageLoader()
        var arrivals = 0
        loader.onLoad = { arrivals += 1 }
        let fixtures = (0..<6).map { Fixture(base: fixture.base, scenario: "concurrent-\($0)") }
        var loads: [Task<Void, Never>] = []
        for image in fixtures {
            _ = loader.image(for: image.imageURL)
            loads.append(try loadTask(for: image.imageURL, in: loader))
        }
        for image in fixtures { try await image.waitForRequests(1) }
        let heartbeat = Heartbeat()
        heartbeat.start()
        let started = Date()
        for image in fixtures { try await image.release(1) }
        for load in loads { await load.value }
        heartbeat.stop()
        try check(fixtures.allSatisfy { loader.image(for: $0.imageURL)?.size.width == 1 },
                  "six concurrent valid 20 MiB PNGs complete and decode")
        try check(arrivals == fixtures.count && loader.inFlight.isEmpty,
                  "concurrent completions each notify once and leave no loader tasks")
        try heartbeat.check()
        try check(Date().timeIntervalSince(started) < 30, "concurrent downloads complete within the broad deadline")
        for image in fixtures {
            let state = try await image.waitForRecord(1, complete: true)
            try check(state.records[0].sent == 20 << 20 && state.requests == 1,
                      "concurrent \(image.scenario) receives all bytes without a duplicate request")
        }
        print("Concurrent large images: \(Date().timeIntervalSince(started))s, \(heartbeat.ticks) actor ticks, max gap \(heartbeat.maximumGap)s")
    }

    private static func largeReset(_ fixture: Fixture) async throws {
        let loader = MarkdownImageLoader()
        var arrivals = 0
        loader.onLoad = { arrivals += 1 }
        var loads: [Task<Void, Never>] = []
        for number in 1...4 {
            loader.reset()
            _ = loader.image(for: fixture.imageURL)
            loads.append(try loadTask(for: fixture.imageURL, in: loader))
            try await fixture.waitForRequests(number)
        }
        for number in [2, 4, 1, 3] {
            try await fixture.release(number)
            await loads[number - 1].value
            let currentHasArrived = number != 2
            try check(loader.image(for: fixture.imageURL)?.size.width == (currentHasArrived ? 4 : nil),
                      "large reset completion \(number) preserves only the newest generation")
            try check(arrivals == (currentHasArrived ? 1 : 0) && loader.inFlight.count == (currentHasArrived ? 0 : 1),
                      "large stale completions cannot remove or notify the current load")
        }
        try check(try await fixture.state().requests == 4, "repeated reset races do not create extra image requests")
    }

    private static func cancellation(_ fixture: Fixture) async throws {
        let loader = MarkdownImageLoader()
        var arrivals = 0
        loader.onLoad = { arrivals += 1 }
        _ = loader.image(for: fixture.imageURL)
        let load = try loadTask(for: fixture.imageURL, in: loader)
        try await fixture.waitForRequests(1)
        try await fixture.release(1)
        try await fixture.waitForBytes(1)
        load.cancel()
        await load.value
        try check(loader.inFlight.isEmpty && arrivals == 0, "cancellation completes the actual loader task without an image")
        let canceled = try await fixture.waitForRecord(1, complete: false).records[0]
        try check(canceled.disconnected && canceled.sent < 1 << 20,
                  "canceling a streaming load stops its network transfer promptly")
        loader.reset()
        _ = loader.image(for: fixture.imageURL)
        let recovery = try loadTask(for: fixture.imageURL, in: loader)
        try await fixture.waitForRequests(2)
        try await fixture.release(2)
        await recovery.value
        try check(loader.image(for: fixture.imageURL)?.size.width == 2 && arrivals == 1,
                  "a reset recovers after a canceled load on the shared session")

        let beforeStart = Fixture(base: fixture.base, scenario: "cancel-before-start")
        _ = loader.image(for: beforeStart.imageURL)
        let canceledBeforeStart = try loadTask(for: beforeStart.imageURL, in: loader)
        canceledBeforeStart.cancel()
        await canceledBeforeStart.value
        try check(loader.inFlight.isEmpty && arrivals == 1,
                  "cancellation before transfer creation completes without notifying")
        try check(try await beforeStart.state().requests == 0,
                  "a pre-canceled load does not start an HTTP request")
    }

    private static func stalledImage(_ fixture: Fixture) async throws {
        let loader = MarkdownImageLoader()
        _ = loader.image(for: fixture.imageURL)
        let load = try loadTask(for: fixture.imageURL, in: loader)
        try await fixture.waitForRequests(1)
        let started = Date()
        try await fixture.release(1)
        await load.value
        let elapsed = Date().timeIntervalSince(started)
        try check(loader.inFlight.isEmpty && loader.image(for: fixture.imageURL) == nil,
                  "a body that stalls completes as a failed image load")
        try check(elapsed >= 10 && elapsed < 30, "the 15-second idle timeout remains in force")
        let state = try await fixture.waitForRecord(1, complete: false)
        try check(state.records[0].disconnected && !state.records[0].complete,
                  "the idle timeout stops the stalled network response")
    }

    private static func localImage() async throws {
        let url = try localFixtureDirectory().appendingPathComponent("tiny.png")
        defer { try? FileManager.default.removeItem(at: url) }
        // Same bytes as the harness png(1) helper, so this is a real 1×1 PNG.
        try Data(tinyPNG).write(to: url)
        let loader = MarkdownImageLoader()
        var arrivals = 0
        loader.onLoad = { arrivals += 1 }
        try check(loader.image(for: url) == nil, "a local file image starts asynchronously")
        let load = try loadTask(for: url, in: loader)
        await load.value
        let image = loader.image(for: url)
        try check(image?.size.width == 1, "a small local PNG is decoded and cached")
        try check(image === loader.image(for: url), "a local PNG stays cached across renders")
        try check(arrivals == 1 && loader.inFlight.isEmpty,
                  "the local file load notifies once and leaves no in-flight task")
    }

    private static func localFIFO() async throws {
        let url = try localFixtureDirectory().appendingPathComponent("fifo")
        defer { try? FileManager.default.removeItem(at: url) }
        let created = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return mkfifo(path, mode_t(0o600))
        }
        guard created == 0 else {
            throw failure("Could not create a FIFO (\(String(cString: strerror(errno))))")
        }
        let loader = MarkdownImageLoader()
        var arrivals = 0
        loader.onLoad = { arrivals += 1 }
        let started = Date()
        try check(loader.image(for: url) == nil, "a FIFO image is not returned synchronously")
        let load = try loadTask(for: url, in: loader)
        await load.value
        let elapsed = Date().timeIntervalSince(started)
        try check(loader.inFlight.isEmpty, "a rejected FIFO clears inFlight")
        try check(loader.image(for: url) == nil && arrivals == 0 && loader.inFlight.isEmpty,
                  "a FIFO is not cached, retried, or rendered")
        try check(elapsed < 5, "a FIFO is rejected within a few seconds")
        print("Local FIFO: \(elapsed)s")
    }

    /// Bytes of a 1×1 RGBA PNG, matching `png(1)` in the Python harness.
    private static let tinyPNG: [UInt8] = [
        0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1f, 0x15, 0xc4,
        0x89, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9c, 0x63, 0xf8, 0xcf, 0xc0, 0xf0,
        0x1f, 0x00, 0x05, 0x00, 0x01, 0xff, 0x89, 0x99, 0x3d, 0x1d, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45,
        0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
    ]

    private static func localFixtureDirectory() throws -> URL {
        guard CommandLine.arguments.count >= 4 else {
            throw failure("Expected a local fixture directory")
        }
        return URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
    }

    @MainActor private final class Heartbeat {
        private var task: Task<Void, Never>?
        private var previous = Date()
        private(set) var ticks = 0
        private(set) var maximumGap: TimeInterval = 0

        func start() {
            previous = Date()
            task = Task {
                while !Task.isCancelled {
                    let now = Date()
                    maximumGap = max(maximumGap, now.timeIntervalSince(previous))
                    previous = now
                    ticks += 1
                    try? await Task.sleep(for: .milliseconds(10))
                }
            }
        }

        func stop() {
            maximumGap = max(maximumGap, Date().timeIntervalSince(previous))
            task?.cancel()
        }

        func check() throws {
            try MarkdownImageLoaderTests.check(ticks > 5 && maximumGap < 2,
                                               "the main actor remains responsive during image downloads")
        }
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw failure(message) }
        checks += 1
        print("PASS images: \(message)")
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "MarkdownImageLoaderTests", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// Await the load itself: network completion alone precedes decoding and cache
    /// updates. The subprocess deadline bounds a load that fails to complete.
    private static func loadTask(for url: URL, in loader: MarkdownImageLoader) throws -> Task<Void, Never> {
        guard let task = loader.inFlight[url] else { throw failure("Expected image load was not started") }
        return task
    }

    /// Each image request waits at the server until its numbered release endpoint
    /// is called, so response order is chosen without timing the production load.
    private struct Fixture {
        // Control requests must not queue behind the image connections whose
        // completion they release, especially at URLSession's per-host limit.
        static let controlSession = URLSession(configuration: .ephemeral)
        let base: URL
        let scenario: String
        var imageURL: URL { base.appendingPathComponent("image/\(scenario).png") }

        struct State: Decodable {
            let requests: Int
            let records: [Record]
        }

        struct Record: Decodable {
            let sent: Int
            let total: Int
            let complete: Bool
            let disconnected: Bool
        }

        func state() async throws -> State {
            let data = try await request("state/\(scenario)")
            return try JSONDecoder().decode(State.self, from: data)
        }

        func release(_ number: Int) async throws {
            _ = try await request("release/\(scenario)/\(number)")
        }

        func waitForRequests(_ expected: Int) async throws {
            let deadline = Date().addingTimeInterval(5)
            while try await state().requests < expected {
                guard Date() < deadline else {
                    throw failure("Expected request \(expected) was not started")
                }
                try await Task.sleep(for: .milliseconds(10))
            }
        }

        func waitForRecord(_ number: Int, complete: Bool) async throws -> State {
            let deadline = Date().addingTimeInterval(5)
            while true {
                let state = try await state()
                if state.records.count >= number {
                    let record = state.records[number - 1]
                    if complete ? record.complete : record.disconnected { return state }
                }
                guard Date() < deadline else { throw failure("Fixture transfer \(number) did not finish as expected") }
                try await Task.sleep(for: .milliseconds(10))
            }
        }

        func waitForBytes(_ number: Int) async throws {
            let deadline = Date().addingTimeInterval(5)
            while true {
                let state = try await state()
                if state.records.count >= number && state.records[number - 1].sent > 0 { return }
                guard Date() < deadline else { throw failure("Fixture transfer \(number) did not send bytes") }
                try await Task.sleep(for: .milliseconds(5))
            }
        }

        private func request(_ path: String) async throws -> Data {
            let (data, response) = try await Self.controlSession.data(from: base.appendingPathComponent(path))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw failure("Fixture request failed: \(path)")
            }
            return data
        }
    }
}
