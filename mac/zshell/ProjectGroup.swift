//
//  ProjectGroup.swift
//  zshell
//

import AppKit
import Combine
import Foundation

/// A user-made grouping of sidebar projects. Two kinds:
/// - `.plain` groups are pure labels; a session opened from them starts in
///   the home directory.
/// - `.folder` groups anchor a folder; a session opened from them — and a
///   new terminal in a project placed inside — starts in that folder.
struct ProjectGroup: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var kind: Kind
    /// The section renders collapsed in the sidebar.
    var isCollapsed: Bool
    /// Opaque sRGB marker color. Older group files omit this field.
    var markerColorHex: String?

    enum Kind: Codable, Equatable {
        case plain
        case folder(path: String)
    }

    init(
        id: UUID = UUID(),
        name: String,
        kind: Kind,
        isCollapsed: Bool = false,
        markerColorHex: String? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.isCollapsed = isCollapsed
        self.markerColorHex = markerColorHex
    }

    var markerColor: ProjectTabMarkerColor? {
        get { markerColorHex.flatMap(ProjectTabMarkerColor.init(hex:)) }
        set { markerColorHex = newValue?.hex }
    }

    /// The directory a session opened from this group starts in: home for a
    /// plain group, the anchored folder for a folder group.
    var sessionDirectory: String {
        switch kind {
        case .plain: return NSHomeDirectory()
        case .folder(let path): return path
        }
    }

    /// The anchored folder path, nil for a plain group.
    var folderPath: String? {
        if case .folder(let path) = kind { return path }
        return nil
    }

    /// A folder group's display name defaults to the folder's own name so the
    /// sidebar reads naturally; an explicit rename wins afterwards.
    static func defaultName(for kind: Kind) -> String {
        if case .folder(let path) = kind {
            return URL(fileURLWithPath: path, isDirectory: true).lastPathComponent
        }
        return String(
            localized: "New Group",
            comment: "Default name of a newly created sidebar project group."
        )
    }
}

/// The saved project groups, persisted as JSON under the same Debug/Release-
/// separated directory as the SSH project store. Group membership lives on
/// each `Project` (`groupID`) and survives through the session snapshot.
@MainActor
final class ProjectGroupStore: ObservableObject {
    static let shared = ProjectGroupStore()

    @Published private(set) var groups: [ProjectGroup] = []

    static var fileURL: URL {
        AppSettings.configURL
            .deletingLastPathComponent()
            .appendingPathComponent("project-groups.json")
    }

    private init() {
        groups = Self.load()
    }

    func group(id: UUID?) -> ProjectGroup? {
        guard let id else { return nil }
        return groups.first { $0.id == id }
    }

    func add(_ group: ProjectGroup) {
        groups.append(group)
        save()
    }

    func update(_ group: ProjectGroup) {
        guard let index = groups.firstIndex(where: { $0.id == group.id }) else { return }
        groups[index] = group
        save()
    }

    func move(_ groupID: UUID, to targetID: UUID) {
        guard groupID != targetID,
              let source = groups.firstIndex(where: { $0.id == groupID }),
              let target = groups.firstIndex(where: { $0.id == targetID }) else { return }
        let group = groups.remove(at: source)
        groups.insert(group, at: target)
        save()
    }

    func remove(_ group: ProjectGroup) {
        groups.removeAll { $0.id == group.id }
        save()
    }

    private func save() {
        let url = Self.fileURL
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(groups)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("zshell: failed to write \(url.path): \(error)")
        }
    }

    private static func load() -> [ProjectGroup] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        do {
            return try JSONDecoder().decode([ProjectGroup].self, from: data)
        } catch {
            NSLog("zshell: failed to read \(fileURL.path): \(error)")
            return []
        }
    }
}

/// Tab groups belong to one project; their identifiers must never follow a
/// transferred tab into another project's independent group namespace.
struct SessionTabGroup: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var isCollapsed: Bool
    /// Opaque sRGB marker color. Older session snapshots omit this field.
    var markerColorHex: String?

    init(
        id: UUID = UUID(),
        name: String,
        isCollapsed: Bool = false,
        markerColorHex: String? = nil
    ) {
        self.id = id
        self.name = name
        self.isCollapsed = isCollapsed
        self.markerColorHex = markerColorHex
    }

    var markerColor: ProjectTabMarkerColor? {
        get { markerColorHex.flatMap(ProjectTabMarkerColor.init(hex:)) }
        set { markerColorHex = newValue?.hex }
    }
}
