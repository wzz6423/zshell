//
//  DiffReview.swift
//  zshell
//

import AppKit
import Combine
import CryptoKit
import Darwin
import SwiftUI

enum DiffReviewLayer: String, Codable, Sendable {
    case staged
    case worktree
}

struct DiffReviewKey: Hashable, Codable, Sendable {
    let repositoryRoot: String
    let path: String
    let layer: DiffReviewLayer
}

struct DiffReviewSnapshot: Hashable, Sendable {
    let key: DiffReviewKey
    let fingerprint: String

    nonisolated static func fingerprint(path: String, payload: String) -> String {
        fingerprint(path: path, payload: Data(payload.utf8))
    }

    nonisolated static func fingerprint(path: String, payload: Data) -> String {
        var input = Data("\(path)\u{0}".utf8)
        input.append(payload)
        return SHA256.hash(data: input)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

enum DiffReviewFingerprint {
    typealias GitRunner = (_ args: [String], _ directory: String) -> GitCommandDataResult

    nonisolated static func load(
        path: String,
        originalPath: String? = nil,
        layer: DiffReviewLayer,
        hasHead: Bool,
        untracked: Bool,
        in repositoryRoot: String,
        runGit: GitRunner
    ) -> String? {
        if layer == .worktree && untracked {
            return untrackedFingerprint(path: path, in: repositoryRoot)
        }
        let paths = [originalPath, path].compactMap { $0 }
        guard let patches = trackedPatches(
            for: paths, layer: layer, hasHead: hasHead,
            in: repositoryRoot, runGit: runGit
        ) else { return nil }
        return fingerprint(path: path, originalPath: originalPath, patches: patches)
    }

    /// Raw NUL-delimited paths identify the following patches without decoding
    /// Git's quoted headers. Batches also keep large path lists below ARG_MAX.
    nonisolated static func trackedPatches(
        for paths: [String], layer: DiffReviewLayer, hasHead: Bool,
        in repositoryRoot: String, runGit: GitRunner
    ) -> [String: Data]? {
        var args = [
            "--literal-pathspecs", "diff", "--raw", "-z", "--patch", "--binary",
            "--full-index", "--no-abbrev", "--no-renames", "--no-color",
            "--no-ext-diff", "--no-textconv", "--src-prefix=a/", "--dst-prefix=b/",
        ]
        if layer == .staged {
            args.append("--cached")
            if hasHead { args.append("HEAD") }
        }
        args.append("--")

        var patches: [String: Data] = [:]
        var batch: [String] = []
        var bytes = 0
        func flush() -> Bool {
            guard !batch.isEmpty else { return true }
            let output = runGit(args + batch, repositoryRoot)
            guard output.status == 0, !output.truncated,
                  let parsed = parsePatches(output.stdout) else { return false }
            patches.merge(parsed, uniquingKeysWith: { _, latest in latest })
            batch.removeAll(keepingCapacity: true)
            bytes = 0
            return true
        }
        for path in Set(paths).sorted() {
            if bytes + path.utf8.count + 1 > 32_768, !flush() { return nil }
            batch.append(path)
            bytes += path.utf8.count + 1
        }
        return flush() ? patches : nil
    }

    nonisolated static func fingerprint(
        path: String, originalPath: String?, patches: [String: Data]
    ) -> String? {
        let originalPath = originalPath == path ? nil : originalPath
        let paths = Set([originalPath, path].compactMap { $0 }).sorted()
        let payloads = paths.compactMap { patches[$0] }
        guard !payloads.isEmpty else { return nil }
        // Rename/copy metadata remains part of the identity even when the
        // source has no patch, as in a copy from an unchanged staged file.
        var payload = Data((originalPath.map { "original\u{0}\($0)\u{0}" } ?? "").utf8)
        for patch in payloads { payload.append(patch) }
        return DiffReviewSnapshot.fingerprint(path: path, payload: payload)
    }

    private nonisolated static func parsePatches(_ output: Data) -> [String: Data]? {
        guard !output.isEmpty else { return [:] }
        guard let separator = output.range(of: Data([0, 0])),
              let raw = String(data: output[..<separator.lowerBound], encoding: .utf8) else { return nil }
        let records = raw.split(separator: "\u{0}", omittingEmptySubsequences: false)
        guard records.count.isMultiple(of: 2) else { return nil }
        var paths: [String] = []
        for index in stride(from: 0, to: records.count, by: 2) {
            let fields = records[index].split(separator: " ")
            guard fields.count == 5, fields[0].first == ":", !fields[0].hasPrefix("::"),
                  !["R", "C", "U"].contains(fields[4]), !records[index + 1].isEmpty else { return nil }
            paths.append(String(records[index + 1]))
        }
        // Git can emit non-UTF-8 text patches. Decode only the raw path table
        // so one file's encoding cannot discard the other files in its batch.
        let patch = output[separator.upperBound...]
        var starts: [Data.Index] = []
        var cursor = patch.startIndex
        while cursor < patch.endIndex {
            if patch[cursor...].starts(with: "diff --git ".utf8) { starts.append(cursor) }
            guard let newline = patch[cursor...].firstIndex(of: 10) else { break }
            cursor = patch.index(after: newline)
        }
        guard starts.first == patch.startIndex, starts.count == paths.count,
              Set(paths).count == paths.count else { return nil }
        return Dictionary(uniqueKeysWithValues: paths.enumerated().map { index, path in
            let end = index + 1 < starts.count ? starts[index + 1] : patch.endIndex
            return (path, Data(patch[starts[index]..<end]))
        })
    }

    /// Untracked files have no index blob. Hash their bytes and Git mode
    /// directly instead of launching a no-index Git process for every file.
    private nonisolated static func untrackedFingerprint(path: String, in root: String) -> String? {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.hasPrefix("/"), components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        let rootURL = URL(fileURLWithPath: root, isDirectory: true).resolvingSymlinksInPath()
        let url = rootURL.appendingPathComponent(path)
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().path
        guard parent == rootURL.path || parent.hasPrefix(rootURL.path + "/") else { return nil }
        var initial = stat()
        guard lstat(url.path, &initial) == 0 else { return nil }
        let data: Data
        let mode: String
        if initial.st_mode & S_IFMT == S_IFLNK {
            guard initial.st_size >= 0, initial.st_size <= AgentReviewGit.maxFileBytes else { return nil }
            var target = [UInt8](repeating: 0, count: Int(initial.st_size) + 1)
            let count = readlink(url.path, &target, target.count)
            guard count == initial.st_size else { return nil }
            data = Data(target.prefix(count))
            mode = "120000"
        } else {
            guard let file = try? AgentReviewGit.readFile(root: rootURL.path, path: path) else { return nil }
            data = file.data
            mode = file.permissions & S_IXUSR == 0 ? "100644" : "100755"
        }
        var final = stat()
        guard lstat(url.path, &final) == 0,
              initial.st_dev == final.st_dev, initial.st_ino == final.st_ino,
              initial.st_mode == final.st_mode, initial.st_size == final.st_size,
              initial.st_mtimespec.tv_sec == final.st_mtimespec.tv_sec,
              initial.st_mtimespec.tv_nsec == final.st_mtimespec.tv_nsec,
              initial.st_ctimespec.tv_sec == final.st_ctimespec.tv_sec,
              initial.st_ctimespec.tv_nsec == final.st_ctimespec.tv_nsec else { return nil }
        var input = Data("untracked\u{0}\(path)\u{0}\(mode)\u{0}".utf8)
        input.append(data)
        return SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
    }
}

/// Keeps a review attached to the exact staged or worktree contents that were
/// inspected. A later Git snapshot with a different fingerprint invalidates it.
@MainActor
final class DiffReviewStore: ObservableObject {
    static let shared = DiffReviewStore()

    private struct SavedReview: Codable {
        let key: DiffReviewKey
        let fingerprint: String
    }

    private static let defaultsKey = "diffReview.reviewedSnapshots"

    @Published private(set) var revision: UInt = 0
    private var currentFingerprints: [DiffReviewKey: String] = [:]
    private var reviewedFingerprints: [DiffReviewKey: String]

    private init() {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
              let saved = try? JSONDecoder().decode([SavedReview].self, from: data)
        else {
            reviewedFingerprints = [:]
            return
        }
        reviewedFingerprints = Dictionary(
            saved.map { ($0.key, $0.fingerprint) },
            uniquingKeysWith: { _, latest in latest }
        )
    }

    func isCurrent(_ snapshot: DiffReviewSnapshot) -> Bool {
        currentFingerprints[snapshot.key] == snapshot.fingerprint
    }

    func isReviewed(_ snapshot: DiffReviewSnapshot) -> Bool {
        isCurrent(snapshot)
            && reviewedFingerprints[snapshot.key] == snapshot.fingerprint
    }

    func reviewedCount(in snapshots: [DiffReviewSnapshot]) -> Int {
        snapshots.reduce(into: 0) { count, snapshot in
            if isReviewed(snapshot) { count += 1 }
        }
    }

    func setReviewed(_ reviewed: Bool, for snapshot: DiffReviewSnapshot) {
        guard isCurrent(snapshot) else { return }
        if reviewed {
            reviewedFingerprints[snapshot.key] = snapshot.fingerprint
        } else {
            reviewedFingerprints.removeValue(forKey: snapshot.key)
        }
        save()
        revision &+= 1
    }

    func replaceCurrentSnapshots(
        _ snapshots: [DiffReviewSnapshot], repositoryRoot: String
    ) {
        let active = Dictionary(
            snapshots.map { ($0.key, $0.fingerprint) },
            uniquingKeysWith: { _, latest in latest }
        )
        let previousCurrent = currentFingerprints
        currentFingerprints = currentFingerprints.filter {
            $0.key.repositoryRoot != repositoryRoot
        }
        currentFingerprints.merge(active, uniquingKeysWith: { _, latest in latest })

        let previousReviewed = reviewedFingerprints
        reviewedFingerprints = reviewedFingerprints.filter { key, fingerprint in
            key.repositoryRoot != repositoryRoot || active[key] == fingerprint
        }
        if reviewedFingerprints != previousReviewed { save() }
        if currentFingerprints != previousCurrent || reviewedFingerprints != previousReviewed {
            revision &+= 1
        }
    }

    /// A Git status refresh is authoritative when it already knows this key.
    /// This prevents an older asynchronous diff load from restoring stale state.
    @discardableResult
    func register(_ snapshot: DiffReviewSnapshot) -> Bool {
        if let current = currentFingerprints[snapshot.key] {
            return current == snapshot.fingerprint
        }
        currentFingerprints[snapshot.key] = snapshot.fingerprint
        if reviewedFingerprints[snapshot.key] != snapshot.fingerprint,
           reviewedFingerprints.removeValue(forKey: snapshot.key) != nil {
            save()
        }
        revision &+= 1
        return true
    }

    func invalidate(_ key: DiffReviewKey) {
        let removedCurrent = currentFingerprints.removeValue(forKey: key) != nil
        let removedReview = reviewedFingerprints.removeValue(forKey: key) != nil
        guard removedCurrent || removedReview else { return }
        if removedReview { save() }
        revision &+= 1
    }

    private func save() {
        let saved = reviewedFingerprints.map {
            SavedReview(key: $0.key, fingerprint: $0.value)
        }
        guard let data = try? JSONEncoder().encode(saved) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
}

@MainActor
final class DiffReviewButton: NSButton {
    var onToggle: ((Bool) -> Void)?
    private var reviewed = false
    private var available = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .accessoryBarAction
        controlSize = .small
        imagePosition = .imageLeading
        target = self
        action = #selector(toggleReview)
        setAccessibilityLabel(String(localized: "File review status"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(reviewed: Bool, available: Bool) {
        self.reviewed = reviewed
        self.available = available
        isEnabled = available
        image = NSImage(
            systemSymbolName: reviewed ? "checkmark.circle.fill" : "circle",
            accessibilityDescription: nil
        )
        title = reviewed
            ? String(localized: "Reviewed")
            : String(localized: "Mark Reviewed")
        toolTip = available
            ? (reviewed
                ? String(localized: "Mark this file as unreviewed")
                : String(localized: "Mark these exact changes as reviewed"))
            : String(localized: "Review status is unavailable for this diff")
        setAccessibilityValue(
            reviewed ? String(localized: "Reviewed") : String(localized: "Unreviewed")
        )
    }

    @objc private func toggleReview() {
        guard available else { return }
        onToggle?(!reviewed)
    }
}

enum DiffReviewState {
    case reviewed
    case unreviewed
}

/// AppKit status/action embedded in the legacy SwiftUI Git row.
struct DiffReviewIndicatorView: NSViewRepresentable {
    let state: DiffReviewState
    let onToggle: () -> Void

    func makeNSView(context: Context) -> DiffReviewIndicatorButton {
        DiffReviewIndicatorButton()
    }

    func updateNSView(_ view: DiffReviewIndicatorButton, context: Context) {
        view.update(state: state, onToggle: onToggle)
    }
}

@MainActor
final class DiffReviewIndicatorButton: NSButton {
    private var reviewed = false
    private var onToggle: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        imagePosition = .imageOnly
        target = self
        action = #selector(toggleReview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(state: DiffReviewState, onToggle: @escaping () -> Void) {
        reviewed = state == .reviewed
        self.onToggle = onToggle
        image = NSImage(
            systemSymbolName: reviewed ? "checkmark.circle.fill" : "circle.dashed",
            accessibilityDescription: nil
        )
        contentTintColor = reviewed ? Theme.accent : .secondaryLabelColor
        let label = reviewed ? String(localized: "Reviewed") : String(localized: "Unreviewed")
        toolTip = reviewed
            ? String(localized: "Mark this file as unreviewed")
            : String(localized: "Mark these exact changes as reviewed")
        setAccessibilityLabel(String(localized: "File review status"))
        setAccessibilityValue(label)
    }

    @objc private func toggleReview() {
        onToggle?()
    }
}

/// Native summary used by the legacy Git panel without adding another SwiftUI
/// interaction tree to its dense file list.
struct DiffReviewSummaryView: NSViewRepresentable {
    let reviewedCount: Int
    let totalCount: Int
    let fontScale: CGFloat
    let repositoryRoot: String

    func makeNSView(context: Context) -> DiffReviewSummaryNSView {
        DiffReviewSummaryNSView()
    }

    func updateNSView(_ view: DiffReviewSummaryNSView, context: Context) {
        view.update(
            reviewedCount: reviewedCount, totalCount: totalCount,
            fontScale: fontScale, repositoryRoot: repositoryRoot
        )
    }
}

final class DiffReviewSummaryNSView: NSView {
    private let imageView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let reviewButton = NSButton(title: "", target: nil, action: nil)
    private var repositoryRoot = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        reviewButton.bezelStyle = .accessoryBarAction
        reviewButton.controlSize = .small
        reviewButton.target = self
        reviewButton.action = #selector(openReview)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view in [imageView, label, reviewButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        label.lineBreakMode = .byTruncatingTail
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 13),
            imageView.heightAnchor.constraint(equalToConstant: 13),
            label.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(lessThanOrEqualTo: reviewButton.leadingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            reviewButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            reviewButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(reviewedCount: Int, totalCount: Int, fontScale: CGFloat, repositoryRoot: String) {
        self.repositoryRoot = repositoryRoot
        reviewButton.title = String(localized: "Review Changes…")
        reviewButton.setAccessibilityLabel(reviewButton.title)
        reviewButton.isEnabled = !repositoryRoot.isEmpty
        let complete = totalCount > 0 && reviewedCount == totalCount
        imageView.image = NSImage(
            systemSymbolName: complete ? "checkmark.circle.fill" : "circle.dotted",
            accessibilityDescription: nil
        )
        imageView.contentTintColor = complete ? Theme.accent : .secondaryLabelColor
        label.font = .systemFont(ofSize: 10.5 * fontScale, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.stringValue = complete
            ? String(
                localized: "All \(totalCount) changes reviewed",
                comment: "Git review summary. The placeholder is the number of staged and unstaged file changes."
            )
            : String(
                localized: "Reviewed \(reviewedCount) of \(totalCount) changes",
                comment: "Git review summary. The placeholders are reviewed and total staged and unstaged file changes."
            )
        setAccessibilityElement(false)
    }

    @objc private func openReview() {
        AgentReviewWindowController.show(repositoryRoot: repositoryRoot)
    }
}
