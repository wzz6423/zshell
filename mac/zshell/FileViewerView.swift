//
//  FileViewerView.swift
//  zshell
//

import AppKit
import Combine
import QuickLookUI
import SwiftUI
import UniformTypeIdentifiers

/// A file opened as a tab in a project. Text content lives here (not in the
/// view) so edits survive tab switches.
@MainActor
final class FileTab: nonisolated ObservableObject, nonisolated Identifiable {
    nonisolated let id = UUID()
    /// Mutable so a rename in the file tree can re-point the tab without
    /// tearing it down (the id — hence the editor and its state — is stable).
    @Published private(set) var path: String

    enum Content {
        case text
        case image(NSImage)
        case quickLook
        case unavailable(String)
    }

    @Published private(set) var content: Content
    /// Current editor text, written back by the editor on every edit. Not
    /// published: the editor owns display, this is only read back for saves.
    var text: String
    /// The content as last loaded from or saved to disk. `isDirty` is the
    /// difference between this and `text`, so undoing edits back to it (or
    /// retyping the same characters) clears the dirty indicator rather than
    /// leaving it stuck on.
    private var savedText = ""
    /// Scroll position and cursor, written back by the editor as they
    /// change. Lives here (not in the view) so the state survives tab
    /// switches, and in the session snapshot so it survives relaunches. Not
    /// published for the same reason as `text`.
    var editorState = EditorState()

    @Published private(set) var isDirty = false
    @Published var saveError: String?
    /// Changes only when a clean tab picks up different bytes from disk. Text
    /// editors use this as their identity so an already-mounted pane is rebuilt
    /// with the new content while preserving its stored cursor/scroll state.
    @Published private(set) var reloadRevision: UInt = 0

    /// The editor's scroll view while this file is on screen, so a pane-move
    /// drag can snapshot it for the drag thumbnail. Weak — owned by the mounted
    /// editor, nils out when the pane unmounts.
    weak var editorView: NSView?

    private nonisolated static let maxTextBytes = 5 << 20
    /// These image types keep the existing native, pixel-accurate image view.
    /// Other visual types, such as SVG, route through Quick Look instead.
    private nonisolated static let directlyRenderedImageTypeIdentifiers = Set([
        "png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp", "icns",
    ].compactMap { UTType(filenameExtension: $0)?.identifier })
    /// Exact image bytes, kept so a reload can compare the new data against the
    /// old without a lossy hash (a hash here could collide and show a stale
    /// image for a different file).
    private var imageData: Data?
    /// Quick Look owns file decoding, so the file's metadata identifies whether
    /// a clean preview needs to be regenerated without loading its bytes here.
    private var quickLookSignature: QuickLookSignature?
    private var reloadGeneration: UInt = 0
    private var reloadTask: Task<Void, Never>?

    private nonisolated struct QuickLookSignature: Equatable, Sendable {
        let fileSize: UInt64
        let modificationTime: TimeInterval
    }

    private nonisolated enum ReadResult {
        case data(Data)
        case quickLook(QuickLookSignature)
        case tooLarge
        case unavailable
    }

    private struct LoadedContent {
        let content: Content
        let text: String
        let imageData: Data?
        let quickLookSignature: QuickLookSignature?
    }

    init(path: String) {
        self.path = path
        content = .unavailable("")
        text = ""
        savedText = ""
        imageData = nil
        quickLookSignature = nil
        reloadFromDiskIfClean()
    }

    var name: String {
        (path as NSString).lastPathComponent
    }

    /// Re-points this tab at a new location after the file (or a directory
    /// above it) was renamed on disk. The bytes are unchanged, so nothing
    /// reloads; subsequent saves write to the new path.
    func updatePath(_ newPath: String) {
        guard newPath != path else { return }
        invalidateReload()
        path = newPath
    }

    /// Recompute `isDirty` from the current `text` against the saved
    /// baseline. Called after every editor change (including undo/redo), so
    /// reverting to the saved content clears the dirty state.
    func refreshDirtyState() {
        let dirty: Bool
        if case .text = content {
            dirty = text != savedText
        } else {
            dirty = false
        }
        if isDirty != dirty {
            isDirty = dirty
            if dirty {
                // A read started while the buffer was clean must never replace
                // an edit that happened before that read completed.
                invalidateReload()
            }
        }
    }

    func save() {
        guard case .text = content, isDirty else { return }
        invalidateReload()
        do {
            try text.write(toFile: path, atomically: true, encoding: .utf8)
            savedText = text
            isDirty = false
            saveError = nil
        } catch {
            saveError = error.localizedDescription
        }
    }

    /// Re-read a clean preview when it returns on screen. Disk I/O happens off
    /// the main actor; generation/path/dirty guards keep an older read from
    /// winning over a rename, save, or edit performed while it was in flight.
    ///
    /// `init` already kicks off one load, and `.onAppear` fires immediately
    /// after the view mounts — without de-duplication the second call would
    /// cancel the first and re-read the same bytes. If a load for the current
    /// path is already in flight, this call is a no-op: the in-flight read will
    /// publish when it finishes.
    func reloadFromDiskIfClean() {
        guard !isDirty else { return }
        if let task = reloadTask, !task.isCancelled {
            return
        }
        reloadTask?.cancel()
        reloadGeneration &+= 1
        let generation = reloadGeneration
        let expectedPath = path

        reloadTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Self.readData(path: expectedPath)
            }.value
            guard let self else { return }
            // Clear the task handle once this generation settles so a later
            // re-check (returning from an external editor, a tab switch) starts
            // a fresh load instead of being blocked by the completed one.
            defer { if self.reloadGeneration == generation { self.reloadTask = nil } }
            guard !Task.isCancelled,
                  self.reloadGeneration == generation,
                  self.path == expectedPath,
                  !self.isDirty
            else { return }

            let loaded = Self.loadedContent(path: expectedPath, result: result)
            guard !self.matches(loaded) else { return }
            self.content = loaded.content
            self.text = loaded.text
            self.savedText = loaded.text
            self.imageData = loaded.imageData
            self.quickLookSignature = loaded.quickLookSignature
            self.saveError = nil
            self.reloadRevision &+= 1
        }
    }

    private func invalidateReload() {
        reloadTask?.cancel()
        reloadTask = nil
        reloadGeneration &+= 1
    }

    private func matches(_ loaded: LoadedContent) -> Bool {
        switch (content, loaded.content) {
        case (.text, .text):
            return savedText == loaded.text
        case (.image, .image):
            return imageData == loaded.imageData
        case (.quickLook, .quickLook):
            return quickLookSignature == loaded.quickLookSignature
        case (.unavailable(let current), .unavailable(let new)):
            return current == new
        default:
            return false
        }
    }

    private nonisolated static func readData(path: String) -> ReadResult {
        let url = URL(fileURLWithPath: path)
        if shouldUseQuickLook(for: url) {
            guard let signature = quickLookSignature(for: path) else { return .unavailable }
            return .quickLook(signature)
        }
        guard !usesDirectImagePreview(for: url) else {
            return (try? Data(contentsOf: url)).map(ReadResult.data) ?? .unavailable
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            return .unavailable
        }
        defer { try? handle.close() }

        do {
            let initialSize = try handle.seekToEnd()
            guard initialSize <= UInt64(maxTextBytes) else {
                return .tooLarge
            }
            try handle.seek(toOffset: 0)

            var data = Data()
            data.reserveCapacity(Int(initialSize))
            while data.count <= maxTextBytes {
                let remaining = maxTextBytes + 1 - data.count
                guard let chunk = try handle.read(upToCount: remaining), !chunk.isEmpty else {
                    break
                }
                data.append(chunk)
            }
            guard data.count <= maxTextBytes,
                  try handle.seekToEnd() <= UInt64(maxTextBytes) else {
                return .tooLarge
            }
            return .data(data)
        } catch {
            return .unavailable
        }
    }

    private nonisolated static func contentType(for url: URL) -> UTType? {
        let pathExtension = url.pathExtension
        guard !pathExtension.isEmpty else { return nil }
        return UTType(filenameExtension: pathExtension)
    }

    private nonisolated static func usesDirectImagePreview(for url: URL) -> Bool {
        guard let type = contentType(for: url) else { return false }
        return directlyRenderedImageTypeIdentifiers.contains(type.identifier)
    }

    private nonisolated static func shouldUseQuickLook(for url: URL) -> Bool {
        guard let type = contentType(for: url) else { return false }
        if type.conforms(to: .image) {
            return !directlyRenderedImageTypeIdentifiers.contains(type.identifier)
        }
        return type.conforms(to: .audiovisualContent)
            || type.conforms(to: .archive)
            || (!type.conforms(to: .text) && type.conforms(to: .compositeContent))
    }

    private nonisolated static func quickLookSignature(for path: String) -> QuickLookSignature? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? NSNumber
        else { return nil }
        let modificationTime = (attributes[.modificationDate] as? Date)?
            .timeIntervalSinceReferenceDate ?? 0
        return QuickLookSignature(
            fileSize: size.uint64Value,
            modificationTime: modificationTime
        )
    }

    private static func loadedContent(path: String, result: ReadResult) -> LoadedContent {
        let url = URL(fileURLWithPath: path)
        let data: Data
        switch result {
        case .data(let loadedData):
            data = loadedData
        case .quickLook(let signature):
            return LoadedContent(
                content: .quickLook,
                text: "",
                imageData: nil,
                quickLookSignature: signature
            )
        case .tooLarge:
            return LoadedContent(
                content: .unavailable(String(localized: "File is too large to open")),
                text: "",
                imageData: nil,
                quickLookSignature: nil
            )
        case .unavailable:
            return LoadedContent(
                content: .unavailable(String(localized: "Could not read file")),
                text: "",
                imageData: nil,
                quickLookSignature: nil
            )
        }
        if usesDirectImagePreview(for: url),
           let image = NSImage(data: data) {
            return LoadedContent(
                content: .image(image),
                text: "",
                imageData: data,
                quickLookSignature: nil
            )
        }
        guard data.count <= maxTextBytes else {
            return LoadedContent(
                content: .unavailable(String(localized: "File is too large to open")),
                text: "",
                imageData: nil,
                quickLookSignature: nil
            )
        }
        guard let string = String(data: data, encoding: .utf8) else {
            return LoadedContent(
                content: .unavailable(String(localized: "Binary file")),
                text: "",
                imageData: nil,
                quickLookSignature: nil
            )
        }
        return LoadedContent(
            content: .text,
            text: string,
            imageData: nil,
            quickLookSignature: nil
        )
    }
}

/// Content of a file tab, hosted in AppKit: the source editor, the rendered
/// markdown preview, an image, a native Quick Look preview, or a placeholder
/// for anything binary or oversized. SwiftUI is only the mount point —
/// `FileViewerContainerView` owns the views and the switching between them.
struct FileViewerView: NSViewRepresentable {
    @ObservedObject var file: FileTab
    /// Whether this file's pane is the focused one in its tab.
    var isFocused: Bool = true
    /// Called when the editor takes focus itself (e.g. a click), so the
    /// model's focused pane can follow.
    var onFocused: () -> Void = {}
    /// Splits this pane on the given edge — wired to the context-menu items.
    var onSplit: (PaneDropEdge) -> Void = { _ in }

    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var markdownPreferences = MarkdownViewPreferences.shared
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> FileViewerContainerView {
        let view = FileViewerContainerView(file: file)
        apply(to: view)
        return view
    }

    func updateNSView(_ view: FileViewerContainerView, context: Context) {
        apply(to: view)
    }

    private func apply(to view: FileViewerContainerView) {
        view.update(
            font: TerminalFont.current(),
            palette: .theme(dark: colorScheme == .dark),
            wrapLines: settings.wrapLines,
            isFocused: isFocused,
            showsSource: markdownPreferences.showsSource,
            onFocused: onFocused,
            onSplit: onSplit
        )
    }

    /// Take exactly the space SwiftUI offers. Without this, SwiftUI sizes the
    /// pane from the content's `fittingSize`, which a text view derives from the
    /// entire document — enormous for a large file, and degenerate for an empty
    /// one. Because the main window tracks its content's ideal size, that runaway
    /// measurement drives the window size and drops it into an unbounded layout
    /// loop (a hard crash: "more Layout Window passes than there are views").
    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView: FileViewerContainerView, context: Context
    ) -> CGSize? {
        func resolve(_ value: CGFloat?, fallback: CGFloat) -> CGFloat {
            guard let value, value.isFinite else { return fallback }
            return value
        }
        return CGSize(
            width: resolve(proposal.width, fallback: nsView.frame.width),
            height: resolve(proposal.height, fallback: nsView.frame.height)
        )
    }
}

/// The AppKit body of a file tab. Holds whichever content view the tab's state
/// calls for, plus the markdown mode chip and the save-error bar, and swaps
/// content in place as the file reloads or the reader toggles modes.
@MainActor
final class FileViewerContainerView: NSView {
    private let file: FileTab

    private var editor: SourceEditorController?
    private var preview: MarkdownPreviewView?
    private var quickLookPreview: QLPreviewView?
    /// The currently mounted content view, whichever kind it is.
    private var contentView: NSView?
    private var contentKind: ContentKind?
    private let chip = MarkdownModeChipView()
    private let errorBar = FileSaveErrorBar()

    private var font: NSFont = .monospacedSystemFont(ofSize: 12, weight: .regular)
    private var palette = EditorPalette.theme(dark: true)
    private var wrapLines = false
    private var isFocused = false
    private var showsSource = false
    private var onFocused: () -> Void = {}
    private var onSplit: (PaneDropEdge) -> Void = { _ in }

    /// Last reload the mounted content was built from. A bump means the bytes
    /// on disk changed under a clean tab, so the content has to be rebuilt.
    private var mountedRevision: UInt = 0
    /// Path the mounted content was built for, so a rename can re-resolve the
    /// preview's relative links and images against the new directory.
    private var mountedPath: String?
    private var errorBarHeight: NSLayoutConstraint?

    /// Which view the tab's current state calls for.
    private enum ContentKind: Equatable {
        case source
        case preview
        case image
        case quickLook
        case unavailable(String)
    }

    init(file: FileTab) {
        self.file = file
        super.init(frame: .zero)

        errorBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(errorBar)
        let height = errorBar.heightAnchor.constraint(equalToConstant: 0)
        errorBarHeight = height
        NSLayoutConstraint.activate([
            errorBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            errorBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            errorBar.topAnchor.constraint(equalTo: topAnchor),
            height,
        ])

        chip.translatesAutoresizingMaskIntoConstraints = false
        chip.isHidden = true
        chip.onToggle = { [weak self] in
            // Clicking the chip in an unfocused split has to move the model's
            // focus too, or the pane swaps modes while ⌘F and the Find menu
            // keep acting on whichever pane was focused before.
            self?.onFocused()
            MarkdownViewPreferences.shared.showsSource.toggle()
        }
        addSubview(chip)
        NSLayoutConstraint.activate([
            chip.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -MarkdownModeChipView.trailingInset
            ),
            chip.topAnchor.constraint(
                equalTo: errorBar.bottomAnchor,
                constant: MarkdownModeChipView.topInset
            ),
        ])

        // The selected file view stays mounted while zshell is inactive, so
        // returning from an external editor does not trigger a fresh mount.
        for name in [
            NSApplication.didBecomeActiveNotification,
            NSWindow.didBecomeKeyNotification,
        ] {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(reloadFromDisk),
                name: name,
                object: nil
            )
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        file.reloadFromDiskIfClean()
    }

    @objc private func reloadFromDisk() {
        file.reloadFromDiskIfClean()
    }

    func update(
        font: NSFont,
        palette: EditorPalette,
        wrapLines: Bool,
        isFocused: Bool,
        showsSource: Bool,
        onFocused: @escaping () -> Void,
        onSplit: @escaping (PaneDropEdge) -> Void
    ) {
        self.font = font
        self.palette = palette
        self.wrapLines = wrapLines
        self.isFocused = isFocused
        self.showsSource = showsSource
        self.onFocused = onFocused
        self.onSplit = onSplit

        errorBar.message = file.saveError
        errorBarHeight?.constant = file.saveError == nil ? 0 : FileSaveErrorBar.height

        // Markdown is the only file type with two ways to read it, so the chip
        // exists only there.
        let isMarkdown = Self.isMarkdown(file.path)
        chip.isHidden = !isMarkdown || !isTextContent
        chip.update(showsSource: showsSource)

        installContentIfNeeded()
        // A rename re-points the tab without touching the bytes, so nothing
        // above notices — but the preview resolves `./img.png` against the
        // file's directory, which just moved.
        if mountedPath != file.path {
            mountedPath = file.path
            preview?.reloadForPathChange()
            quickLookPreview?.previewItem = URL(fileURLWithPath: file.path) as NSURL
            quickLookPreview?.refreshPreviewItem()
        }
        editor?.update(
            font: font,
            palette: palette,
            wrapLines: wrapLines,
            isFocused: isFocused,
            onFocused: onFocused,
            onSplit: onSplit
        )
        preview?.onSplit = onSplit
    }

    private var isTextContent: Bool {
        if case .text = file.content { return true }
        return false
    }

    /// Rendered by default, source on request — and always source for anything
    /// that is not markdown.
    private var desiredKind: ContentKind {
        switch file.content {
        case .text:
            Self.isMarkdown(file.path) && !showsSource ? .preview : .source
        case .image:
            .image
        case .quickLook:
            .quickLook
        case .unavailable(let reason):
            .unavailable(reason)
        }
    }

    private func installContentIfNeeded() {
        let kind = desiredKind
        let revision = file.reloadRevision
        guard kind != contentKind || revision != mountedRevision else { return }
        let isModeSwitch = contentKind != nil && revision == mountedRevision
        // Only new bytes on disk make the cached views stale. Toggling modes
        // keeps them: rebuilding the editor would hand it a fresh STTextView,
        // and with it a fresh undo manager, so a round trip through the preview
        // would silently throw away everything ⌘Z could have undone.
        if revision != mountedRevision {
            editor = nil
            preview = nil
            quickLookPreview = nil
        }
        contentKind = kind
        mountedRevision = revision

        contentView?.removeFromSuperview()
        contentView = nil

        let view: NSView
        switch kind {
        case .source:
            let controller = editor ?? SourceEditorController(
                file: file,
                font: font,
                palette: palette,
                wrapLines: wrapLines,
                isFocused: isFocused,
                onFocused: onFocused,
                onSplit: onSplit
            )
            editor = controller
            // Find acts on whichever view is mounted, and a reused controller
            // set this only when it was first built.
            file.editorView = controller.scrollView
            view = controller.scrollView
        case .preview:
            let markdown: MarkdownPreviewView
            if let existing = preview {
                markdown = existing
            } else {
                markdown = MarkdownPreviewView(file: file)
                markdown.onFocused = onFocused
                markdown.onSplit = onSplit
                preview = markdown
            }
            // Edits made in the source since this view last drew. The image
            // cache survives, so toggling back does not refetch remote images,
            // and the scroll position is kept by the re-render.
            markdown.refresh()
            file.editorView = markdown
            view = markdown
        case .image:
            file.editorView = nil
            view = Self.imageView(for: file, palette: palette)
        case .quickLook:
            file.editorView = nil
            if let existing = quickLookPreview {
                view = existing
            } else if let preview = Self.quickLookView(for: file.path) {
                quickLookPreview = preview
                view = preview
            } else {
                view = Self.placeholderView(
                    path: file.path,
                    reason: String(localized: "Could not read file"),
                    palette: palette
                )
            }
        case .unavailable(let reason):
            file.editorView = nil
            view = Self.placeholderView(path: file.path, reason: reason, palette: palette)
        }

        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view, positioned: .below, relativeTo: chip)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: errorBar.bottomAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        contentView = view

        // Toggling modes should leave the keyboard where the reader is looking;
        // a plain remount (a disk reload) must not steal focus from elsewhere.
        if isModeSwitch, isFocused {
            switch kind {
            case .preview: preview?.takeFocus()
            case .source: editor?.takeFocus()
            case .image, .quickLook, .unavailable: break
            }
        }
    }

    /// v1 renders `.md` only. Other markdown spellings still open as source.
    static func isMarkdown(_ path: String) -> Bool {
        (path as NSString).pathExtension.lowercased() == "md"
    }

    private static func imageView(for file: FileTab, palette: EditorPalette) -> NSView {
        guard case .image(let image) = file.content else { return NSView() }
        return ImagePreviewView(image: image, backgroundColor: palette.background)
    }

    private static func quickLookView(for path: String) -> QLPreviewView? {
        guard let preview = QLPreviewView(frame: .zero, style: .normal) else { return nil }
        preview.previewItem = URL(fileURLWithPath: path) as NSURL
        preview.autostarts = false
        return preview
    }

    private static func placeholderView(
        path: String,
        reason: String,
        palette: EditorPalette
    ) -> NSView {
        let container = NSView()
        // An empty reason means the initial async load is still in flight —
        // show a spinner instead of an icon with no explanation.
        guard !reason.isEmpty else {
            let spinner = NSProgressIndicator()
            spinner.isIndeterminate = true
            spinner.controlSize = .small
            spinner.startAnimation(nil)
            spinner.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(spinner)
            NSLayoutConstraint.activate([
                spinner.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                spinner.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            ])
            return container
        }
        let icon = NSImageView()
        icon.image = MaterialFileIcon.image(forPath: path)
        icon.alphaValue = 0.72
        let label = NSTextField(labelWithString: reason)
        label.font = .systemFont(ofSize: 11)
        label.textColor = palette.gutterText

        for view in [icon, label] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            icon.widthAnchor.constraint(equalToConstant: 28),
            icon.heightAnchor.constraint(equalToConstant: 28),
            icon.bottomAnchor.constraint(equalTo: container.centerYAnchor, constant: -4),
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 8),
        ])
        return container
    }
}

/// Native bitmap preview with an explicit zoom state. The image sits in a
/// canvas that never becomes smaller than the viewport, keeping a fitted image
/// centered while still allowing the scroll view to expose an enlarged one.
@MainActor
final class ImagePreviewView: NSView {
    private static let imageMargin: CGFloat = 16
    private static let zoomStep: CGFloat = 1.25
    private static let minimumZoomScale: CGFloat = 0.05
    private static let maximumZoomScale: CGFloat = 16
    private static let controlSize: CGFloat = 24
    private static let controlInset: CGFloat = 8
    private static let controlPadding: CGFloat = 2

    private let scrollView = NSScrollView()
    private let canvas = NSView()
    private let imageView = NSImageView()
    private let controls = NSVisualEffectView()
    private let zoomOutButton = WorkspaceChromeButton(
        symbol: "minus.magnifyingglass",
        label: String(localized: "Zoom Out")
    )
    private let zoomInButton = WorkspaceChromeButton(
        symbol: "plus.magnifyingglass",
        label: String(localized: "Zoom In")
    )
    private let fitButton = WorkspaceChromeButton(
        symbol: "arrow.up.left.and.arrow.down.right",
        label: String(localized: "Fit Image to Window")
    )
    private let imageSize: CGSize

    private var zoomScale: CGFloat = 1
    private var automaticallyFitsImage = true

    init(image: NSImage, backgroundColor: NSColor) {
        let size = image.size
        imageSize = CGSize(
            width: size.width.isFinite && size.width > 0 ? size.width : 1,
            height: size.height.isFinite && size.height > 0 ? size.height : 1
        )
        super.init(frame: .zero)

        imageView.image = image
        imageView.imageAlignment = .alignCenter
        imageView.imageScaling = .scaleProportionallyUpOrDown
        canvas.addSubview(imageView)

        scrollView.documentView = canvas
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.drawsBackground = true
        scrollView.backgroundColor = backgroundColor
        addSubview(scrollView)

        controls.material = .hudWindow
        controls.blendingMode = .withinWindow
        controls.state = .active
        controls.wantsLayer = true
        controls.layer?.cornerRadius = 6
        controls.layer?.masksToBounds = true
        addSubview(controls)

        zoomOutButton.configure(
            symbol: "minus.magnifyingglass",
            label: String(localized: "Zoom Out"),
            pointSize: 11
        )
        zoomInButton.configure(
            symbol: "plus.magnifyingglass",
            label: String(localized: "Zoom In"),
            pointSize: 11
        )
        fitButton.configure(
            symbol: "arrow.up.left.and.arrow.down.right",
            label: String(localized: "Fit Image to Window"),
            pointSize: 11
        )
        for button in [zoomOutButton, zoomInButton, fitButton] {
            controls.addSubview(button)
        }
        zoomOutButton.onAction = { [weak self] in
            self?.changeZoom(by: 1 / Self.zoomStep)
        }
        zoomInButton.onAction = { [weak self] in
            self?.changeZoom(by: Self.zoomStep)
        }
        fitButton.onAction = { [weak self] in
            self?.fitImageToWindow()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        layoutControls()
        layoutImage()
    }

    private func layoutControls() {
        let buttons = [zoomOutButton, zoomInButton, fitButton]
        let side = Self.controlSize
        let padding = Self.controlPadding
        let controlsSize = CGSize(
            width: side * CGFloat(buttons.count) + padding * 2,
            height: side + padding * 2
        )
        controls.frame = NSRect(
            x: max(bounds.minX + Self.controlInset, bounds.maxX - Self.controlInset - controlsSize.width),
            y: max(bounds.minY + Self.controlInset, bounds.maxY - Self.controlInset - controlsSize.height),
            width: controlsSize.width,
            height: controlsSize.height
        )
        for (index, button) in buttons.enumerated() {
            button.frame = NSRect(
                x: padding + CGFloat(index) * side,
                y: padding,
                width: side,
                height: side
            )
        }
    }

    private func layoutImage() {
        let viewportSize = scrollView.contentView.bounds.size
        guard viewportSize.width > 0, viewportSize.height > 0 else { return }
        if automaticallyFitsImage {
            zoomScale = fitScale(for: viewportSize)
        }

        let scaledSize = CGSize(
            width: imageSize.width * zoomScale,
            height: imageSize.height * zoomScale
        )
        let canvasSize = CGSize(
            width: max(viewportSize.width, scaledSize.width + Self.imageMargin * 2),
            height: max(viewportSize.height, scaledSize.height + Self.imageMargin * 2)
        )
        canvas.frame = NSRect(origin: .zero, size: canvasSize)
        imageView.frame = NSRect(
            x: (canvasSize.width - scaledSize.width) / 2,
            y: (canvasSize.height - scaledSize.height) / 2,
            width: scaledSize.width,
            height: scaledSize.height
        )

        if automaticallyFitsImage {
            scroll(to: .zero)
        } else {
            constrainScrollPosition()
        }
    }

    private func fitScale(for viewportSize: CGSize) -> CGFloat {
        let availableWidth = max(1, viewportSize.width - Self.imageMargin * 2)
        let availableHeight = max(1, viewportSize.height - Self.imageMargin * 2)
        return min(1, availableWidth / imageSize.width, availableHeight / imageSize.height)
    }

    private func changeZoom(by multiplier: CGFloat) {
        let visibleBounds = scrollView.contentView.bounds
        let relativePoint = imageRelativePoint(
            at: NSPoint(x: visibleBounds.midX, y: visibleBounds.midY)
        )
        let minimumScale = min(Self.minimumZoomScale, fitScale(for: visibleBounds.size))
        zoomScale = min(
            Self.maximumZoomScale,
            max(minimumScale, zoomScale * multiplier)
        )
        automaticallyFitsImage = false
        layoutImage()

        let target = NSPoint(
            x: imageView.frame.minX + imageView.frame.width * relativePoint.x - visibleBounds.width / 2,
            y: imageView.frame.minY + imageView.frame.height * relativePoint.y - visibleBounds.height / 2
        )
        scroll(to: target)
    }

    private func fitImageToWindow() {
        automaticallyFitsImage = true
        layoutImage()
    }

    private func imageRelativePoint(at point: NSPoint) -> NSPoint {
        let frame = imageView.frame
        guard frame.width > 0, frame.height > 0 else {
            return NSPoint(x: 0.5, y: 0.5)
        }
        return NSPoint(
            x: min(1, max(0, (point.x - frame.minX) / frame.width)),
            y: min(1, max(0, (point.y - frame.minY) / frame.height))
        )
    }

    private func constrainScrollPosition() {
        scroll(to: scrollView.contentView.bounds.origin)
    }

    private func scroll(to origin: NSPoint) {
        let viewportSize = scrollView.contentView.bounds.size
        let maximumOrigin = NSPoint(
            x: max(0, canvas.bounds.width - viewportSize.width),
            y: max(0, canvas.bounds.height - viewportSize.height)
        )
        let constrainedOrigin = NSPoint(
            x: min(maximumOrigin.x, max(0, origin.x)),
            y: min(maximumOrigin.y, max(0, origin.y))
        )
        scrollView.contentView.scroll(to: constrainedOrigin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}

/// The strip above a file's content that reports a failed save.
private final class FileSaveErrorBar: NSView {
    static let height: CGFloat = 22

    var message: String? {
        didSet {
            isHidden = message == nil
            guard let message else { return }
            label.stringValue = String(localized: "Could not save: \(message)")
        }
    }

    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        isHidden = true
        updateAppearanceColors()

        let icon = NSImageView()
        icon.image = NSImage(
            systemSymbolName: "exclamationmark.triangle.fill",
            accessibilityDescription: nil
        )
        let warning = NSColor(red: 0.82, green: 0.60, blue: 0.13, alpha: 1)
        icon.contentTintColor = warning
        label.font = .systemFont(ofSize: 11)
        label.textColor = warning
        label.lineBreakMode = .byTruncatingTail

        for view in [icon, label] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 10),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateAppearanceColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearanceColors()
    }

    private func updateAppearanceColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.04).cgColor
        }
    }
}
