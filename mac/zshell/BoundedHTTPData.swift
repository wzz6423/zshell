import Foundation

nonisolated enum BoundedHTTPData {
    enum Failure: Error {
        case invalidResponse, tooLarge
    }

    static func data(
        for request: URLRequest, session: URLSession, maximumBytes: Int,
        delegate: (any URLSessionTaskDelegate)? = nil
    ) async throws -> (Data, URLResponse) {
        let transfer = Transfer(maximumBytes: maximumBytes, delegate: delegate)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                transfer.start(request, session: session, continuation: continuation)
            }
        } onCancel: {
            transfer.finish(.failure(CancellationError()))
        }
    }

    /// Data callbacks append whole chunks off the main actor. The lock also
    /// orders cancellation before task creation and discards late callbacks.
    private final class Transfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private let maximumBytes: Int
        private let delegate: (any URLSessionTaskDelegate)?
        private var task: URLSessionDataTask?
        private var continuation: CheckedContinuation<(Data, URLResponse), any Error>?
        private var bytes = Data()
        private var response: URLResponse?
        private var finished = false
        private var failure: (any Error)?

        init(maximumBytes: Int, delegate: (any URLSessionTaskDelegate)?) {
            precondition(maximumBytes >= 0)
            self.maximumBytes = maximumBytes
            self.delegate = delegate
        }

        func start(
            _ request: URLRequest, session: URLSession,
            continuation: CheckedContinuation<(Data, URLResponse), any Error>
        ) {
            lock.lock()
            guard !finished else {
                let error = failure ?? CancellationError()
                lock.unlock()
                continuation.resume(throwing: error)
                return
            }
            self.continuation = continuation
            let task = session.dataTask(with: request)
            self.task = task
            task.delegate = self
            lock.unlock()
            task.resume()
        }

        func finish(_ result: Result<(Data, URLResponse), any Error>) {
            lock.lock()
            guard !finished else { lock.unlock(); return }
            finished = true
            let task = task
            self.task = nil
            let continuation = continuation
            self.continuation = nil
            bytes = Data()
            response = nil
            if case .failure(let error) = result { failure = error }
            lock.unlock()
            if case .failure = result { task?.cancel() }
            continuation?.resume(with: result)
        }

        func urlSession(
            _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
            completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
        ) {
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                finish(.failure(Failure.invalidResponse))
                completionHandler(.cancel)
                return
            }
            guard http.expectedContentLength <= maximumBytes else {
                finish(.failure(Failure.tooLarge))
                completionHandler(.cancel)
                return
            }
            let allowed = lock.withLock {
                guard !finished else { return false }
                self.response = response
                if http.expectedContentLength > 0 { bytes.reserveCapacity(Int(http.expectedContentLength)) }
                return true
            }
            completionHandler(allowed ? .allow : .cancel)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            lock.lock()
            guard !finished else { lock.unlock(); return }
            guard data.count <= maximumBytes - bytes.count else {
                lock.unlock()
                finish(.failure(Failure.tooLarge))
                return
            }
            bytes.append(data)
            lock.unlock()
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
            let result: Result<(Data, URLResponse), any Error>? = lock.withLock {
                guard !finished else { return nil }
                if let error { return .failure(error) }
                guard let response else { return .failure(Failure.invalidResponse) }
                return .success((bytes, response))
            }
            if let result { finish(result) }
        }

        // Callers' redirect and TLS policies must survive replacing their
        // original per-task delegate with this data delegate.
        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            if let delegate {
                delegate.urlSession?(session, task: task, willPerformHTTPRedirection: response,
                                     newRequest: request, completionHandler: completionHandler)
                    ?? completionHandler(request)
            } else { completionHandler(request) }
        }

        func urlSession(
            _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            if let delegate {
                delegate.urlSession?(session, task: task, didReceive: challenge, completionHandler: completionHandler)
                    ?? completionHandler(.performDefaultHandling, nil)
            } else { completionHandler(.performDefaultHandling, nil) }
        }
    }
}
