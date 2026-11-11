import Foundation

nonisolated enum BrowserFaviconDownload {
    static let maximumBytes = 2 * 1_024 * 1_024

    static func data(
        for request: URLRequest, session: URLSession, delegate: (any URLSessionTaskDelegate)? = nil
    ) async throws -> (Data, URLResponse) {
        try await BoundedHTTPData.data(for: request, session: session, maximumBytes: maximumBytes, delegate: delegate)
    }
}
