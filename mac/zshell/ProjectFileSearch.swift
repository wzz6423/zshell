//
//  ProjectFileSearch.swift
//  zshell
//

import Foundation
import FuzzyMatch

nonisolated struct ProjectFileSearchRoot: Hashable, Sendable {
    let projectID: UUID
    let projectName: String
    let root: String
    let canonicalRoot: String

    init?(projectID: UUID, projectName: String, root: String, homeDirectory: String) {
        let rootURL = Self.canonicalURL(for: root, isDirectory: true)
        let homeURL = Self.canonicalURL(for: homeDirectory, isDirectory: true)
        guard rootURL.path != homeURL.path,
              FileManager.default.fileExists(atPath: rootURL.path)
        else { return nil }

        self.projectID = projectID
        self.projectName = projectName
        self.root = rootURL.path
        self.canonicalRoot = rootURL.path
    }

    private static func canonicalURL(for path: String, isDirectory: Bool) -> URL {
        URL(fileURLWithPath: path, isDirectory: isDirectory)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
    }
}

nonisolated struct ProjectFileSearchItem: Hashable, Sendable {
    let projectID: UUID
    let projectName: String
    let projectRoot: String
    let name: String
    let relativePath: String
    let absolutePath: String
    let canonicalAbsolutePath: String

    var parentPath: String? {
        let parent = (relativePath as NSString).deletingLastPathComponent
        return parent.isEmpty ? nil : parent
    }
}

nonisolated struct ProjectFileSearchResult: Sendable {
    let file: ProjectFileSearchItem
    let score: Double
}

nonisolated enum ProjectFileSearch {
    static let defaultLimit = 50
    static let matcher = FuzzyMatcher(config: .smithWaterman)

    static func canonicalRoots(
        _ roots: [ProjectFileSearchRoot]
    ) -> [ProjectFileSearchRoot] {
        var seen = Set<String>()
        return roots.filter { seen.insert($0.canonicalRoot).inserted }
    }

    static func index(
        roots: [ProjectFileSearchRoot],
        gitRunner: any GitCommandRunning = GitCommandRunner()
    ) async -> [ProjectFileSearchItem] {
        let uniqueRoots = canonicalRoots(roots)
        return await withTaskGroup(of: [ProjectFileSearchItem].self) { group in
            for root in uniqueRoots {
                group.addTask(priority: .userInitiated) {
                    await index(root: root, gitRunner: gitRunner)
                }
            }

            var files: [ProjectFileSearchItem] = []
            for await projectFiles in group {
                guard !Task.isCancelled else {
                    group.cancelAll()
                    return []
                }
                files.append(contentsOf: projectFiles)
            }
            return deduplicated(files)
        }
    }

    static func search(
        _ query: String,
        in files: [ProjectFileSearchItem],
        limit: Int = defaultLimit
    ) async -> [ProjectFileSearchResult] {
        guard limit > 0 else { return [] }
        let pattern = query.trimmingCharacters(in: .whitespaces)
        guard !pattern.isEmpty, !Task.isCancelled else { return [] }

        let fuzzyQuery = matcher.prepare(pattern)
        var buffer = matcher.makeBuffer()
        var best: [ProjectFileSearchResult] = []
        best.reserveCapacity(min(limit, files.count))
        for (index, file) in files.enumerated() {
            if index.isMultiple(of: 256), Task.isCancelled { return [] }
            guard let score = fileScore(file, query: fuzzyQuery, buffer: &buffer) else {
                continue
            }
            let match = ProjectFileSearchResult(file: file, score: score)
            if best.count == limit,
               let weakest = best.last,
               !ranksBefore(match, weakest) {
                continue
            }
            best.insert(match, at: insertionIndex(for: match, in: best))
            if best.count > limit { best.removeLast() }
        }
        return Task.isCancelled ? [] : best
    }

    static func deduplicated(
        _ files: [ProjectFileSearchItem]
    ) -> [ProjectFileSearchItem] {
        var seen = Set<String>()
        return files.filter { seen.insert($0.canonicalAbsolutePath).inserted }
    }

    private static func index(
        root: ProjectFileSearchRoot,
        gitRunner: any GitCommandRunning
    ) async -> [ProjectFileSearchItem] {
        if let paths = await gitProjectFilePaths(in: root.root, gitRunner: gitRunner) {
            return projectFiles(for: paths, in: root)
        }
        guard !Task.isCancelled else { return [] }
        return enumeratedProjectFiles(in: root)
    }

    private static func gitProjectFilePaths(
        in root: String,
        gitRunner: GitCommandRunning
    ) async -> Set<String>? {
        var tracked = await gitRunner.run(
            ["ls-files", "--cached", "--recurse-submodules", "-z"],
            in: root
        )
        guard !Task.isCancelled else { return nil }
        if tracked.status != 0 {
            tracked = await gitRunner.run(["ls-files", "--cached", "-z"], in: root)
        }
        guard !Task.isCancelled else { return nil }
        let untracked = await gitRunner.run(
            ["ls-files", "--others", "--exclude-standard", "-z"],
            in: root
        )
        guard !Task.isCancelled,
              tracked.status == 0,
              untracked.status == 0
        else { return nil }
        return Set(nulSeparatedPaths(tracked.stdout) + nulSeparatedPaths(untracked.stdout))
    }

    private static func nulSeparatedPaths(_ output: String) -> [String] {
        output.split(separator: "\0").map(String.init)
    }

    private static func projectFiles(
        for relativePaths: Set<String>,
        in root: ProjectFileSearchRoot
    ) -> [ProjectFileSearchItem] {
        let fileManager = FileManager.default
        return relativePaths.compactMap { relativePath in
            guard !Task.isCancelled else { return nil }
            let absolutePath = (root.root as NSString).appendingPathComponent(relativePath)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: absolutePath, isDirectory: &isDirectory),
                  !isDirectory.boolValue
            else { return nil }
            return makeFile(relativePath: relativePath, absolutePath: absolutePath, root: root)
        }
        .sorted(by: fileOrder)
    }

    private static func enumeratedProjectFiles(
        in root: ProjectFileSearchRoot
    ) -> [ProjectFileSearchItem] {
        let rootURL = URL(fileURLWithPath: root.root, isDirectory: true).standardizedFileURL
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey]
        let keySet = Set(keys)
        let rootPrefix = rootURL.path == "/" ? "/" : rootURL.path + "/"
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            errorHandler: { _, _ in true }
        ) else { return [] }

        var files: [ProjectFileSearchItem] = []
        while let url = enumerator.nextObject() as? URL {
            if Task.isCancelled { return [] }
            if url.lastPathComponent == ".git" {
                enumerator.skipDescendants()
                continue
            }
            // Enumeration can expand /var to /private/var; compare the same path form.
            let absolutePath = url.standardizedFileURL.path
            guard let values = try? url.resourceValues(forKeys: keySet),
                  values.isDirectory != true,
                  values.isRegularFile == true,
                  absolutePath.hasPrefix(rootPrefix)
            else { continue }
            let relativePath = String(absolutePath.dropFirst(rootPrefix.count))
            files.append(makeFile(relativePath: relativePath, absolutePath: absolutePath, root: root))
        }
        return files.sorted(by: fileOrder)
    }

    private static func makeFile(
        relativePath: String,
        absolutePath: String,
        root: ProjectFileSearchRoot
    ) -> ProjectFileSearchItem {
        let canonicalPath = URL(fileURLWithPath: absolutePath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .standardizedFileURL.path
        return ProjectFileSearchItem(
            projectID: root.projectID,
            projectName: root.projectName,
            projectRoot: root.root,
            name: (relativePath as NSString).lastPathComponent,
            relativePath: relativePath,
            absolutePath: canonicalPath,
            canonicalAbsolutePath: canonicalPath
        )
    }

    private static func fileOrder(
        _ lhs: ProjectFileSearchItem,
        _ rhs: ProjectFileSearchItem
    ) -> Bool {
        lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
    }

    private static func fileScore(
        _ file: ProjectFileSearchItem,
        query: FuzzyQuery,
        buffer: inout ScoringBuffer
    ) -> Double? {
        if let basenameScore = fuzzyScore(file.name, query: query, buffer: &buffer) {
            return 1 + basenameScore
        }
        return fuzzyScore(file.relativePath, query: query, buffer: &buffer)
    }

    @inline(__always)
    private static func fuzzyScore(
        _ candidate: String,
        query: FuzzyQuery,
        buffer: inout ScoringBuffer
    ) -> Double? {
        var candidate = candidate
        return candidate.withUTF8 { bytes in
            matcher.score(utf8: bytes, against: query, buffer: &buffer)?.score
        }
    }

    private static func insertionIndex(
        for match: ProjectFileSearchResult,
        in matches: [ProjectFileSearchResult]
    ) -> Int {
        var lowerBound = 0
        var upperBound = matches.count
        while lowerBound < upperBound {
            let middle = (lowerBound + upperBound) / 2
            if ranksBefore(match, matches[middle]) {
                upperBound = middle
            } else {
                lowerBound = middle + 1
            }
        }
        return lowerBound
    }

    private static func ranksBefore(
        _ lhs: ProjectFileSearchResult,
        _ rhs: ProjectFileSearchResult
    ) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        let pathOrder = lhs.file.relativePath.localizedStandardCompare(rhs.file.relativePath)
        if pathOrder != .orderedSame { return pathOrder == .orderedAscending }
        return lhs.file.canonicalAbsolutePath < rhs.file.canonicalAbsolutePath
    }
}
