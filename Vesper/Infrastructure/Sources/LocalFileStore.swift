import Foundation

struct LocalFileEntry: Identifiable, Hashable, Sendable {
    let path: String
    let name: String
    let isDirectory: Bool
    var id: String { path }
}

/// Serializes filesystem changes and confines every path to the selected source.
actor LocalFileStore {
    static let shared = LocalFileStore()

    enum Failure: LocalizedError {
        case invalidName, outsideRoot, conflict, invalidMove
        var errorDescription: String? {
            switch self {
            case .invalidName: VesperLocalization.string("名称不能为空，且不能包含斜杠或冒号。")
            case .outsideRoot: VesperLocalization.string("无法访问本地来源以外的位置或符号链接。")
            case .conflict: VesperLocalization.string("目标位置已有同名文件或文件夹。")
            case .invalidMove: VesperLocalization.string("不能移动到原位置、文件夹自身或其子文件夹。")
            }
        }
    }

    func entries(root: URL, directory: String) throws -> [LocalFileEntry] {
        try access(root) { base in
            let folder = try checked(directory, root: base)
            return try FileManager.default.contentsOfDirectory(at: folder,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]).compactMap { url in
                    let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
                    guard values.isSymbolicLink != true,
                          values.isDirectory == true || values.isRegularFile == true else { return nil }
                    return LocalFileEntry(path: directory.isEmpty ? url.lastPathComponent : directory + "/" + url.lastPathComponent,
                                          name: url.lastPathComponent, isDirectory: values.isDirectory == true)
                }.sorted {
                    if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                    return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
        }
    }

    func createFolder(root: URL, directory: String, name: String) throws {
        try access(root) { base in
            let parent = try checked(directory, root: base)
            let target = parent.appendingPathComponent(try validName(name), isDirectory: true)
            try requireAvailable(target)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        }
    }

    func rename(root: URL, entry: LocalFileEntry, name: String) throws {
        try access(root) { base in
            let source = try checked(entry.path, root: base, allowRoot: false)
            let target = source.deletingLastPathComponent().appendingPathComponent(try validName(name))
            guard source != target else { return }
            try requireAvailable(target)
            try FileManager.default.moveItem(at: source, to: target)
        }
    }

    func move(root: URL, entry: LocalFileEntry, directory: String) throws {
        try access(root) { base in
            let source = try checked(entry.path, root: base, allowRoot: false)
            let parent = try checked(directory, root: base)
            let target = parent.appendingPathComponent(source.lastPathComponent)
            guard target != source,
                  !isWithin(parent, directory: source) else { throw Failure.invalidMove }
            try requireAvailable(target)
            try FileManager.default.moveItem(at: source, to: target)
        }
    }

    func delete(root: URL, entry: LocalFileEntry) throws {
        try access(root) { base in
            try FileManager.default.removeItem(at: checked(entry.path, root: base, allowRoot: false))
        }
    }

    private func access<T>(_ root: URL, operation: (URL) throws -> T) throws -> T {
        let scoped = root.startAccessingSecurityScopedResource()
        defer { if scoped { root.stopAccessingSecurityScopedResource() } }
        return try operation(root.resolvingSymlinksInPath().standardizedFileURL)
    }

    private func checked(_ path: String, root: URL, allowRoot: Bool = true) throws -> URL {
        guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { throw Failure.outsideRoot }
        let candidate = path.isEmpty ? root : root.appendingPathComponent(path).standardizedFileURL
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard candidate == resolved, isWithin(resolved, directory: root), allowRoot || resolved != root else {
            throw Failure.outsideRoot
        }
        return resolved
    }

    private func isWithin(_ url: URL, directory: URL) -> Bool {
        url.pathComponents.starts(with: directory.pathComponents)
    }

    private func validName(_ name: String) throws -> String {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value != ".", value != "..", !value.hasPrefix("."),
              !value.contains("/"), !value.contains(":"), !value.contains("\0"),
              value.utf8.count <= 255 else { throw Failure.invalidName }
        return value
    }

    private func requireAvailable(_ url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else { throw Failure.conflict }
    }
}
