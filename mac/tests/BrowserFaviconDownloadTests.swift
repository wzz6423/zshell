import Foundation
#if ZSHELL_FAVICON_BUILT_APP
@testable import zshell
#endif

@main
struct BrowserFaviconDownloadTests {
    @MainActor static func main() async throws {
        let base = URL(string: CommandLine.arguments[1])!
        func url(_ path: String) -> URL { base.appendingPathComponent(path) }
        for path in ["known", "unknown", "chunked", "compressed", "rejected", "redirect-large"] {
            let result = await BrowserFaviconProduction.download(url(path))
            precondition(result == nil, "Oversized or rejected favicon was accepted: \(path)")
        }
        for path in ["small", "exact", "redirect-small"] {
            let result = await BrowserFaviconProduction.download(url(path))
            let expected = path == "exact" ? 2 * 1_024 * 1_024 : 8
            precondition(result?.count == expected, "Valid favicon failed: \(path)")
        }

        var ticks = 0
        let heartbeat = Task { @MainActor in
            while !Task.isCancelled {
                ticks += 1
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        let started = Date()
        await withTaskGroup(of: Data?.self) { group in
            for index in 0..<8 {
                group.addTask { await BrowserFaviconProduction.download(url("concurrent-\(index)")) }
            }
            for await result in group { precondition(result == nil, "Concurrent oversized response was accepted") }
        }
        heartbeat.cancel()
        precondition(ticks > 5, "Favicon downloads blocked the main actor")
        print("Concurrent favicon downloads: \(ticks) main-actor ticks in \(Date().timeIntervalSince(started))s")

        for index in 0..<12 {
            let session = URLSession(configuration: .ephemeral)
            defer { session.invalidateAndCancel() }
            let status = URL(string: "cancel-status-\(index)", relativeTo: base)!.absoluteURL
            let transfer = Task { await BrowserFaviconProduction.download(url("cancel-\(index)")) }
            let deadline = Date().addingTimeInterval(3)
            var hasStarted = false
            while !hasStarted, Date() < deadline {
                let result = try await session.data(from: status)
                hasStarted = result.0 == Data("started".utf8)
                if !hasStarted { try await Task.sleep(for: .milliseconds(5)) }
            }
            precondition(hasStarted, "Cancelable favicon request never started")
            try await Task.sleep(for: .milliseconds(20))
            transfer.cancel()
            let result = await transfer.value
            precondition(result == nil, "Canceled favicon returned data")
        }
        let canceled = Task { await BrowserFaviconProduction.download(url("cancel-before-start")) }
        canceled.cancel()
        let canceledResult = await canceled.value
        precondition(canceledResult == nil, "A pre-canceled request completed")
        let recovered = await BrowserFaviconProduction.download(url("recovery"))
        precondition(recovered?.count == 8, "Canceled downloads poisoned the shared URLSession")

        #if BOUNDED_FAVICON_TESTS
        try await verifyDelegates(base, secureBase: URL(string: CommandLine.arguments[2])!)
        await verifyCancellationRaces(base)
        #endif
        print("Favicon download: response boundaries, exact limit, compression, redirects, cancellation, concurrency and recovery passed")
    }

    #if BOUNDED_FAVICON_TESTS
    @MainActor private static func verifyDelegates(_ base: URL, secureBase: URL) async throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let policy = RedirectPolicy()
        let request = URLRequest(url: base.appendingPathComponent("redirect-policy"))
        let (data, _) = try await BrowserFaviconDownload.data(for: request, session: session, delegate: policy)
        precondition(data.count == 8 && policy.redirects == 1, "The per-task redirect delegate was bypassed")
        let fallback = try await BrowserFaviconDownload.data(
            for: URLRequest(url: base.appendingPathComponent("redirect-small")), session: session, delegate: DefaultPolicy()
        )
        precondition(fallback.0.count == 8, "An omitted redirect method lost URLSession's default handling")

        let authentication = AuthenticationPolicy()
        let authenticated = try await BrowserFaviconDownload.data(
            for: URLRequest(url: base.appendingPathComponent("authenticate")), session: session, delegate: authentication
        )
        precondition(authenticated.0.count == 8 && authentication.challenges == 1,
                     "The per-task authentication delegate was bypassed")
        do {
            _ = try await BrowserFaviconDownload.data(for: URLRequest(url: secureBase), session: session,
                                                     delegate: DefaultPolicy())
            preconditionFailure("An untrusted TLS certificate was accepted by default")
        } catch {}
        let trust = AuthenticationPolicy()
        do {
            _ = try await BrowserFaviconDownload.data(for: URLRequest(url: secureBase), session: session, delegate: trust)
            preconditionFailure("The explicit trust rejection was bypassed")
        } catch {}
        precondition(trust.challenges == 1, "The TLS authentication policy was not invoked")

        let delayed = DelayedRedirectPolicy()
        let transfer = Task {
            try await BrowserFaviconDownload.data(
                for: URLRequest(url: base.appendingPathComponent("redirect-late")), session: session, delegate: delayed
            )
        }
        let deadline = Date().addingTimeInterval(3)
        while delayed.redirects == 0, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        precondition(delayed.redirects == 1, "The delayed redirect callback never arrived")
        transfer.cancel()
        do {
            _ = try await transfer.value
            preconditionFailure("Cancellation was ignored while a redirect was pending")
        } catch is CancellationError {}
        delayed.resume()
        try await Task.sleep(for: .milliseconds(50))
    }

    @MainActor private static func verifyCancellationRaces(_ base: URL) async {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<64 {
                group.addTask {
                    do {
                        _ = try await BrowserFaviconDownload.data(
                            for: URLRequest(url: base.appendingPathComponent("chaos-\(index)")), session: session
                        )
                        preconditionFailure("A canceled download completed during its creation race")
                    } catch is CancellationError {}
                    catch { preconditionFailure("Cancellation race returned an unexpected error: \(error)") }
                }
            }
            group.cancelAll()
        }
        let deadline = Date().addingTimeInterval(3)
        var tasks = await session.allTasks
        while !tasks.isEmpty, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
            tasks = await session.allTasks
        }
        precondition(tasks.isEmpty, "Cancellation left URLSession tasks alive")
        let recovered = try? await BrowserFaviconDownload.data(
            for: URLRequest(url: base.appendingPathComponent("recovery")), session: session
        )
        precondition(recovered?.0.count == 8, "The session did not recover after cancellation races")
        print("Favicon delegate policies and 64 task-creation cancellation races passed; no URLSession tasks remain")
    }
    #endif
}

#if BOUNDED_FAVICON_TESTS
nonisolated private final class RedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var redirects: Int { lock.withLock { count } }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        lock.withLock { count += 1 }
        var request = request
        request.url = request.url?.deletingLastPathComponent().appendingPathComponent("policy-target")
        completionHandler(request)
    }
}

nonisolated private final class DefaultPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {}

nonisolated private final class AuthenticationPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var challenges: Int { lock.withLock { count } }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        lock.withLock { count += 1 }
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodHTTPBasic {
            completionHandler(.useCredential, URLCredential(user: "fixture", password: "fixture", persistence: .none))
        } else { completionHandler(.cancelAuthenticationChallenge, nil) }
    }
}

nonisolated private final class DelayedRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: (@Sendable (URLRequest?) -> Void)?
    private var request: URLRequest?
    var redirects: Int { lock.withLock { pending == nil ? 0 : 1 } }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        lock.withLock { self.request = request; pending = completionHandler }
    }
    func resume() {
        let state = lock.withLock {
            let state = (pending, request)
            pending = nil
            request = nil
            return state
        }
        state.0?(state.1)
    }
}
#endif
