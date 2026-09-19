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
        markerColorHex: String? = ProjectTabMarkerColor.defaultColor.hex
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

    static func defaultPlainName(_ number: Int) -> String {
        String(
            localized: "New Group \(number)",
            comment: "Default name of a newly created plain sidebar project group. The placeholder is the group number."
        )
    }
}

/// A top-level sidebar row. Projects inside a group are deliberately absent:
/// they always render immediately below their owning group.
enum ProjectSidebarItem: Hashable {
    case project(UUID)
    case group(UUID)
}

enum ProjectSidebarOrder {
    /// Keeps a saved order where possible, then appends rows introduced after
    /// that order was saved. An empty saved order preserves the legacy layout:
    /// ungrouped projects first, followed by groups.
    static func normalized(
        _ saved: [ProjectSidebarItem],
        projectIDs: [UUID],
        groupIDs: [UUID]
    ) -> [ProjectSidebarItem] {
        let fallback = projectIDs.map(ProjectSidebarItem.project)
            + groupIDs.map(ProjectSidebarItem.group)
        let available = Set(fallback)
        var seen = Set<ProjectSidebarItem>()
        var result = saved.filter { available.contains($0) && seen.insert($0).inserted }
        result.append(contentsOf: fallback.filter { seen.insert($0).inserted })
        return result
    }

    static func moving(
        _ item: ProjectSidebarItem,
        to target: ProjectSidebarItem?,
        in order: [ProjectSidebarItem]
    ) -> [ProjectSidebarItem] {
        guard let sourceIndex = order.firstIndex(of: item), target != item else { return order }
        let targetIndex = target.flatMap(order.firstIndex(of:)) ?? order.endIndex
        var result = order
        result.remove(at: sourceIndex)
        result.insert(item, at: min(targetIndex, result.endIndex))
        return result
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
        guard !groups.contains(where: { $0.name == group.name }) else { return }
        groups.append(group)
        save()
    }

    func nextPlainGroupName() -> String {
        var number = 1
        while groups.contains(where: { $0.name == ProjectGroup.defaultPlainName(number) }) {
            number += 1
        }
        return ProjectGroup.defaultPlainName(number)
    }

    @discardableResult
    func update(_ group: ProjectGroup) -> Bool {
        guard let index = groups.firstIndex(where: { $0.id == group.id }),
              !groups.contains(where: { $0.id != group.id && $0.name == group.name })
        else { return false }
        groups[index] = group
        save()
        return true
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
        markerColorHex: String? = ProjectTabMarkerColor.defaultColor.hex
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
