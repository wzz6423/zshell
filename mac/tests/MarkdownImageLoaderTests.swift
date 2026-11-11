import AppKit
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
        do {
            let fixture = Fixture(base: URL(string: CommandLine.arguments[1])!, scenario: scenario)
            switch scenario {
            case "cache": try await cache(fixture)
            case "late-success": try await lateSuccess(fixture)
            case "early-success": try await earlySuccess(fixture)
            case "late-failure": try await lateFailure(fixture)
            case "reset-storm": try await resetStorm(fixture)
            case "oversized", "streamed-oversized": try await rejectedSources(fixture)
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
        try await fixture.waitForRequests(1)
        for _ in 0..<10 { _ = loader.image(for: fixture.imageURL) }
        try check(try await fixture.state().requests == 1, "repeated renders share one in-flight request")
        try await fixture.release(1)
        try await wait("the initial image did not load") { arrivals == 1 }
        let initial = loader.image(for: fixture.imageURL)
        try check(initial?.size.width == 1, "the response becomes a decoded cached image")
        try check(initial === loader.image(for: fixture.imageURL), "a cache hit returns the existing image")

        loader.reset()
        try check(loader.image(for: fixture.imageURL) == nil, "reset invalidates an already cached image")
        try await fixture.waitForRequests(2)
        try await fixture.release(2)
        try await wait("the reset image did not load") { arrivals == 2 }
        try check(loader.image(for: fixture.imageURL)?.size.width == 2, "the reset document caches fresh bytes")
        try check(try await fixture.state().requests == 2, "cached images do not trigger additional requests")
    }

    private static func lateSuccess(_ fixture: Fixture) async throws {
        let loader = MarkdownImageLoader()
        var arrivals = 0
        loader.onLoad = { arrivals += 1 }
        _ = loader.image(for: fixture.imageURL)
        try await fixture.waitForRequests(1)
        loader.reset()
        _ = loader.image(for: fixture.imageURL)
        try await fixture.waitForRequests(2)
        try await fixture.release(2)
        try await wait("the new document's image did not load") { arrivals == 1 }
        let current = loader.image(for: fixture.imageURL)
        try check(current?.size.width == 2, "the new request finishes before the old request")

        try await fixture.release(1)
        try await settle(fixture.imageURL, pendingRequests: 0)
        try check(arrivals == 1, "a stale success does not notify the current preview")
        try check(current === loader.image(for: fixture.imageURL), "a stale success cannot overwrite the new cached image")
        try check(loader.image(for: fixture.imageURL)?.size.width == 2, "the preview retains the new image bytes")
    }

    private static func earlySuccess(_ fixture: Fixture) async throws {
        let loader = MarkdownImageLoader()
        var arrivals = 0
        loader.onLoad = { arrivals += 1 }
        _ = loader.image(for: fixture.imageURL)
        try await fixture.waitForRequests(1)
        loader.reset()
        _ = loader.image(for: fixture.imageURL)
        try await fixture.waitForRequests(2)

        try await fixture.release(1)
        try await settle(fixture.imageURL, pendingRequests: 1)
        try check(arrivals == 0, "a stale success does not render while the new request is pending")
        let pendingImages = (0..<10).map { _ in loader.image(for: fixture.imageURL) }
        try check(pendingImages.allSatisfy { $0 == nil }, "the new document never exposes the old image")
        try await settle(fixture.imageURL, pendingRequests: 1)
        try check(try await fixture.state().requests == 2, "the pending new request stays deduplicated after old completion")
        try await fixture.release(2)
        try await wait("the pending new image did not load") { arrivals == 1 }
        try check(loader.image(for: fixture.imageURL)?.size.width == 2, "the new request remains usable after old completion")
    }

    private static func lateFailure(_ fixture: Fixture) async throws {
        let loader = MarkdownImageLoader()
        var arrivals = 0
        loader.onLoad = { arrivals += 1 }
        _ = loader.image(for: fixture.imageURL)
        try await fixture.waitForRequests(1)
        loader.reset()
        try await fixture.release(1)
        try await settle(fixture.imageURL, pendingRequests: 0)
        try check(arrivals == 0, "a discarded failure does not notify the preview")

        _ = loader.image(for: fixture.imageURL)
        try await fixture.waitForRequests(2)
        try await fixture.release(2)
        try await wait("a stale failure blocked the reset document's retry") { arrivals == 1 }
        try check(loader.image(for: fixture.imageURL)?.size.width == 2, "a stale failure cannot mark the reset document's URL as failed")
    }

    private static func resetStorm(_ fixture: Fixture) async throws {
        let loader = MarkdownImageLoader()
        var arrivals = 0
        loader.onLoad = { arrivals += 1 }
        let orders = [[2, 3, 1], [3, 1, 2], [1, 2, 3], [2, 1, 3]]
        for (round, order) in orders.enumerated() {
            let first = round * 3
            for number in 1...3 {
                loader.reset()
                _ = loader.image(for: fixture.imageURL)
                try await fixture.waitForRequests(first + number)
            }
            var completed = 0
            var currentArrived = false
            for number in order {
                try await fixture.release(first + number)
                completed += 1
                if number == 3 {
                    currentArrived = true
                    try await wait("reset storm lost the current image") { arrivals == round + 1 }
                }
                try await settle(fixture.imageURL, pendingRequests: 3 - completed)
                let images = (0..<64).map { _ in loader.image(for: fixture.imageURL) }
                try check(images.allSatisfy { currentArrived ? $0?.size.width == CGFloat(first + 3) : $0 == nil },
                          "reset storm round \(round + 1) exposes only the current generation")
                try check(arrivals == round + (currentArrived ? 1 : 0),
                          "reset storm round \(round + 1) discards old successes and failures")
                try await settle(fixture.imageURL, pendingRequests: 3 - completed)
                try check(try await fixture.state().requests == first + 3,
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
        try await fixture.waitForRequests(1)
        try await fixture.release(1)
        try await settle(fixture.imageURL, pendingRequests: 0,
                         timeout: fixture.scenario == "streamed-oversized" ? 30 : 5)
        let rejected = (0..<10).map { _ in loader.image(for: fixture.imageURL) }
        try check(rejected.allSatisfy { $0 == nil } && arrivals == 0,
                  "an image response larger than 20 MiB is not cached or rendered")
        try check(try await fixture.state().requests == 1, "a rejected oversized image is not fetched on every render")
        loader.reset()
        _ = loader.image(for: fixture.imageURL)
        try await fixture.waitForRequests(2)
        try await fixture.release(2)
        try await wait("reset did not retry the rejected image") { arrivals == 1 }
        try check(loader.image(for: fixture.imageURL)?.size.width == 2,
                  "a reset permits a valid replacement for the oversized response")
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

    private static func wait(_ message: String, until complete: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !complete() {
            guard Date() < deadline else { throw failure(message) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Network completion precedes the loader's actor continuation. Require a stable
    /// task count before asserting that a discarded response left no visible effects.
    private static func settle(_ url: URL, pendingRequests: Int, timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        var settled = 0
        while settled < 20 {
            let tasks = await withCheckedContinuation { continuation in
                URLSession.shared.getAllTasks { continuation.resume(returning: $0) }
            }
            let pending = tasks.filter { $0.originalRequest?.url == url }.count
            settled = pending == pendingRequests ? settled + 1 : 0
            guard Date() < deadline else { throw failure("Released image requests did not finish") }
            // Let the loader's main-actor continuation consume the completed network read.
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Each image request waits at the server until its numbered release endpoint
    /// is called, so response order is chosen without timing the production load.
    private struct Fixture {
        let base: URL
        let scenario: String
        var imageURL: URL { base.appendingPathComponent("image/\(scenario).png") }

        struct State: Decodable {
            let requests: Int
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

        private func request(_ path: String) async throws -> Data {
            let (data, response) = try await URLSession.shared.data(from: base.appendingPathComponent(path))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw failure("Fixture request failed: \(path)")
            }
            return data
        }
    }
}
