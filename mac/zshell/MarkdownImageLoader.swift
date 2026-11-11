//
//  MarkdownImageLoader.swift
//  zshell
//

import AppKit

/// Loads the images a rendered markdown document references, and caches them
/// for the life of the preview.
///
/// Rendering is synchronous, so the renderer can only draw what is already in
/// hand: an image that has to be fetched renders as its alt text, and `onLoad`
/// asks the view to render again once the bytes arrive.
///
/// Remote sources are fetched over the network — README badges are the usual
/// case. That means opening a preview can tell the image's host that this file
/// was viewed.
@MainActor
final class MarkdownImageLoader {
    /// Called after an image finishes loading, so the preview can re-render.
    /// May fire several times while a document's images arrive.
    var onLoad: (() -> Void)?

    private var cache: [URL: NSImage] = [:]
    private(set) var inFlight: [URL: Task<Void, Never>] = [:]
    /// Sources that failed or were rejected. Kept so a broken link is asked for
    /// once per document rather than on every re-render.
    private var failed: Set<URL> = []
    private var generation: UInt = 0

    /// A decoded image, or nil while it loads (or after it failed). Starts the
    /// load on the first miss.
    func image(for url: URL) -> NSImage? {
        if let cached = cache[url] { return cached }
        guard inFlight[url] == nil, !failed.contains(url) else { return nil }

        if url.isFileURL {
            load(url) { await Self.readFile(url) }
        } else if url.scheme == "http" || url.scheme == "https" {
            load(url) { await Self.fetch(url) }
        } else {
            // data:, mailto:, anything else — nothing to draw.
            failed.insert(url)
        }
        return nil
    }

    /// Drops everything so a re-opened or re-pointed document re-reads from
    /// disk instead of showing the previous file's images.
    func reset() {
        generation &+= 1
        cache.removeAll()
        failed.removeAll()
        // In-flight loads are left alone; their results are simply discarded
        // when they land, because they belong to an older generation.
        inFlight.removeAll()
    }

    private func load(_ url: URL, using work: @escaping () async -> NSImage?) {
        let expectedGeneration = generation
        inFlight[url] = Task { [weak self] in
            let image = await work()
            guard let self, self.generation == expectedGeneration else { return }
            self.inFlight.removeValue(forKey: url)
            guard let image else {
                self.failed.insert(url)
                return
            }
            self.cache[url] = image
            self.onLoad?()
        }
    }

    /// Ceiling on a single image, so a preview can't be made to buffer an
    /// arbitrarily large download or read.
    private nonisolated static let maxBytes = 20 << 20

    private nonisolated static func readFile(_ url: URL) async -> NSImage? {
        await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  data.count <= maxBytes
            else { return nil }
            return NSImage(data: data)
        }.value
    }

    private nonisolated static func fetch(_ url: URL) async -> NSImage? {
        var request = URLRequest(url: url)
        // Idle timeout: it also covers a stalling body, since receiving data
        // resets it.
        request.timeoutInterval = 15
        // Whole-chunk callbacks keep large images fast while enforcing the cap
        // before buffering, even without Content-Length or after decompression.
        guard let (data, _) = try? await BoundedHTTPData.data(
            for: request, session: .shared, maximumBytes: maxBytes
        )
        else { return nil }
        return NSImage(data: data)
    }
}
