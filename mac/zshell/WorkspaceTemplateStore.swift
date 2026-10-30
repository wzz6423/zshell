import Combine
import Foundation

@MainActor
final class WorkspaceTemplateStore: ObservableObject {
    struct Entry: Codable, Identifiable {
        var id = UUID()
        var template: WorkspaceTemplate
    }

    private struct Library: Codable {
        var version = 1
        var entries: [Entry]
    }

    static let shared = WorkspaceTemplateStore()
    static var fileURL: URL {
        AppSettings.configURL.deletingLastPathComponent().appendingPathComponent("workspace-templates.json")
    }

    @Published private(set) var entries: [Entry] = []
    private(set) var loadError: String?
    private let url: URL

    init(url: URL? = nil) {
        let url = url ?? Self.fileURL
        self.url = url
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try PersistentCLIConnection.readPrivate(url, maximumBytes: 8 * WorkspaceTemplate.maximumBytes)
            let library = try JSONDecoder().decode(Library.self, from: data)
            guard library.version == 1, library.entries.count <= 128,
                  Set(library.entries.map(\.id)).count == library.entries.count else {
                throw WorkspaceTemplateError.libraryUnavailable
            }
            for entry in library.entries { try entry.template.validate() }
            entries = library.entries
        } catch { loadError = error.localizedDescription }
    }

    @discardableResult
    func add(_ template: WorkspaceTemplate) throws -> UUID {
        try template.validate()
        let entry = Entry(template: template)
        var updated = entries
        updated.append(entry)
        try persist(updated)
        return entry.id
    }

    func rename(_ id: UUID, to name: String) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        var updated = entries
        updated[index].template.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try updated[index].template.validate()
        try persist(updated)
    }

    func update(_ id: UUID, template: WorkspaceTemplate) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        try template.validate()
        var updated = entries
        updated[index].template = template
        try persist(updated)
    }

    func delete(_ id: UUID) throws { try persist(entries.filter { $0.id != id }) }

    @discardableResult
    func importTemplate(from url: URL) throws -> UUID {
        let text: String
        do { text = try SettingsConfigFile.read(at: url) }
        catch SettingsConfigFile.Failure.tooLarge { throw WorkspaceTemplateError.fileTooLarge }
        catch { throw WorkspaceTemplateError.invalidFile }
        return try add(WorkspaceTemplate.decode(Data(text.utf8)))
    }

    func exportTemplate(_ id: UUID, to url: URL) throws {
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        try entry.template.encoded().write(to: url, options: .atomic)
    }

    private func persist(_ updated: [Entry]) throws {
        guard loadError == nil else { throw WorkspaceTemplateError.libraryUnavailable }
        guard updated.count <= 128 else { throw WorkspaceTemplateError.libraryUnavailable }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(Library(entries: updated))
        guard data.count <= 8 * WorkspaceTemplate.maximumBytes else { throw WorkspaceTemplateError.fileTooLarge }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PersistentCLIConnection.writePrivate(data, to: url, durable: true)
        entries = updated
    }
}
