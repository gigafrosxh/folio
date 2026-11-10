import Foundation

/// Walks the library folder: notes, folders and files that cannot be read.
///
/// Symbolic links (#56) are followed only when they point to a place inside the library, and every
/// real folder is visited once, so a link back to a parent folder cannot make the scan loop. Metadata is
/// read in parallel and cached by path, size and modification date, so a rescan of a large library only
/// reads the files that changed (#62).
public final class LibraryScanner: @unchecked Sendable {
    public struct Folder: Equatable, Sendable {
        public var url: URL
        public var name: String
        public var children: [Folder]
    }

    public struct Result: Sendable {
        public var folders: [Folder]
        public var notes: [(url: URL, meta: NoteMetadata)]
        /// Note files whose metadata could not be read.
        public var unreadable: [URL]
        /// Links that were not followed, with the reason.
        public var skippedLinks: [(url: URL, reason: String)]
        /// How many notes came from the cache (for benchmarks).
        public var cacheHits: Int
    }

    private struct CacheKey: Hashable {
        var path: String
        var size: Int
        var modified: Date
    }

    private let lock = NSLock()
    private var cache: [CacheKey: NoteMetadata] = [:]

    public init() {}

    /// Forgets cached metadata (e.g. when another library is opened).
    public func clearCache() { lock.lock(); cache.removeAll(); lock.unlock() }

    public func scan(_ root: URL) -> Result {
        let walk = LibraryWalk(root: root)
        let folders = walk.folders(in: root)
        let (metas, hits) = readMetadata(walk.notePaths)
        var notes: [(URL, NoteMetadata)] = []
        var unreadable: [URL] = []
        for (url, meta) in zip(walk.notePaths, metas) {
            if let meta { notes.append((url, meta)) } else { unreadable.append(url) }
        }
        // The same note reachable twice (through a link inside the library) is listed once.
        var seen = Set<UUID>()
        notes = notes.filter { seen.insert($0.1.id).inserted }
        return Result(folders: folders, notes: notes, unreadable: unreadable, skippedLinks: walk.skipped, cacheHits: hits)
    }

    /// Reading metadata is the expensive part: in parallel, from the cache when unchanged.
    private func readMetadata(_ paths: [URL]) -> ([NoteMetadata?], Int) {
        var metas = [NoteMetadata?](repeating: nil, count: paths.count)
        var hits = [Bool](repeating: false, count: paths.count)
        metas.withUnsafeMutableBufferPointer { out in
            hits.withUnsafeMutableBufferPointer { hitOut in
                DispatchQueue.concurrentPerform(iterations: paths.count) { i in
                    (out[i], hitOut[i]) = metadata(of: paths[i])
                }
            }
        }
        return (metas, hits.filter { $0 }.count)
    }

    private func metadata(of url: URL) -> (NoteMetadata?, cached: Bool) {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let key = CacheKey(path: url.path, size: (attrs?[.size] as? NSNumber)?.intValue ?? -1,
                           modified: attrs?[.modificationDate] as? Date ?? .distantPast)
        lock.lock(); let cached = cache[key]; lock.unlock()
        if let cached { return (cached, true) }
        guard let meta = try? NoteFile.readMetadata(at: url) else { return (nil, false) }
        lock.lock(); cache[key] = meta; lock.unlock()
        return (meta, false)
    }
}

/// One pass over the folders: what is a note, what a folder, and which links are not followed. Reads no notes.
private final class LibraryWalk {
    private enum Entry {
        case note(URL)
        case folder(URL)
        case skipped(URL, String)
        case other
    }

    private static let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey]
    private let fm = FileManager.default
    private let realRoot: String
    private var visited = Set<String>()
    private(set) var notePaths: [URL] = []
    private(set) var skipped: [(url: URL, reason: String)] = []

    init(root: URL) { realRoot = Self.realPath(root) }

    private static func realPath(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path }

    private func inside(_ path: String) -> Bool { path == realRoot || path.hasPrefix(realRoot + "/") }

    /// Every real folder is visited once; a folder that cannot be read counts as empty.
    func folders(in dir: URL) -> [LibraryScanner.Folder] {
        guard visited.insert(Self.realPath(dir)).inserted,
              let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: Self.keys, options: [.skipsHiddenFiles]) else { return [] }
        var folders: [LibraryScanner.Folder] = []
        for item in items.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
            switch classify(item) {
            case .note(let url): notePaths.append(url)
            case .folder(let url): folders.append(LibraryScanner.Folder(url: url, name: url.lastPathComponent, children: self.folders(in: url)))
            case .skipped(let url, let reason): skipped.append((url, reason))
            case .other: break
            }
        }
        return folders
    }

    private func classify(_ item: URL) -> Entry {
        let target: URL
        switch linkTarget(of: item) {
        case .success(let url): target = url
        case .failure(let problem): return .skipped(item, problem.reason)
        }
        var isDir: ObjCBool = false
        fm.fileExists(atPath: target.path, isDirectory: &isDir)
        if item.pathExtension == FolioArchive.fileExtension, !isDir.boolValue { return .note(item) }
        guard isDir.boolValue, (try? target.resourceValues(forKeys: [.isPackageKey]).isPackage) != true else { return .other }
        return visited.contains(Self.realPath(target)) ? .skipped(item, "Schleife (Ordner ist schon enthalten)") : .folder(item)
    }

    private struct LinkProblem: Error { let reason: String }

    /// Symbolic links (#56) are followed only when they point to a place inside the library.
    private func linkTarget(of item: URL) -> Swift.Result<URL, LinkProblem> {
        guard (try? item.resourceValues(forKeys: Set(Self.keys)))?.isSymbolicLink == true else { return .success(item) }
        let resolved = item.resolvingSymlinksInPath().standardizedFileURL
        guard fm.fileExists(atPath: resolved.path) else { return .failure(LinkProblem(reason: "Ziel fehlt")) }
        guard inside(resolved.path) else { return .failure(LinkProblem(reason: "zeigt aus der Bibliothek heraus")) }
        return .success(resolved)
    }
}
