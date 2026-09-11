//
//  DiffReview.swift
//  zshell
//

import AppKit
import Combine
import CryptoKit
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
        let input = "\(path)\u{0}\(payload)"
        return SHA256.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

enum DiffReviewFingerprint {
    typealias GitRunner = (_ args: [String], _ directory: String) -> (
        status: Int32, stdout: String, stderr: String
    )

    /// Uses Git's binary patch representation so text, binary, mode-only,
    /// rename, and deletion changes all receive an exact content identity.
    nonisolated static func load(
        path: String,
        originalPath: String? = nil,
        layer: DiffReviewLayer,
        hasHead: Bool,
        untracked: Bool,
        in repositoryRoot: String,
        runGit: GitRunner
    ) -> String? {
        var args = [
            "--literal-pathspecs", "diff", "--binary", "--no-ext-diff", "--no-textconv",
        ]
        let usesNoIndex = layer == .worktree && untracked
        if layer == .staged {
            args.append("--cached")
            if hasHead { args.append("HEAD") }
        } else if usesNoIndex {
            args.append("--no-index")
        }
        args.append("--")
        if usesNoIndex { args.append("/dev/null") }
        if let originalPath, originalPath != path { args.append(originalPath) }
        args.append(path)

        let patch = runGit(args, repositoryRoot)
        guard patch.status == 0 || (usesNoIndex && patch.status == 1) else { return nil }
        return DiffReviewSnapshot.fingerprint(path: path, payload: patch.stdout)
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

    func makeNSView(context: Context) -> DiffReviewSummaryNSView {
        DiffReviewSummaryNSView()
    }

    func updateNSView(_ view: DiffReviewSummaryNSView, context: Context) {
        view.update(reviewedCount: reviewedCount, totalCount: totalCount, fontScale: fontScale)
    }
}

final class DiffReviewSummaryNSView: NSView {
    private let imageView = NSImageView()
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for view in [imageView, label] {
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
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(reviewedCount: Int, totalCount: Int, fontScale: CGFloat) {
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
        setAccessibilityElement(true)
        setAccessibilityLabel(label.stringValue)
    }
}
