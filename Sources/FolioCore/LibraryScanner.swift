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
        let fm = FileManager.default
        let realRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        var visited = Set<String>()
        var notePaths: [URL] = []
        var skipped: [(URL, String)] = []
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey]

        func inside(_ path: String) -> Bool { path == realRoot || path.hasPrefix(realRoot + "/") }

        func walk(_ dir: URL) -> [Folder] {
            let real = dir.resolvingSymlinksInPath().standardizedFileURL.path
            guard visited.insert(real).inserted else { return [] }
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
            var folders: [Folder] = []
            for item in items.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
                let values = try? item.resourceValues(forKeys: Set(keys))
                var target = item
                if values?.isSymbolicLink == true {
                    let resolved = item.resolvingSymlinksInPath().standardizedFileURL
                    guard fm.fileExists(atPath: resolved.path) else { skipped.append((item, "Ziel fehlt")); continue }
                    guard inside(resolved.path) else { skipped.append((item, "zeigt aus der Bibliothek heraus")); continue }
                    target = resolved
                }
                var isDir: ObjCBool = false
                fm.fileExists(atPath: target.path, isDirectory: &isDir)
                if item.pathExtension == FolioArchive.fileExtension, !isDir.boolValue {
                    notePaths.append(item)
                } else if isDir.boolValue, (try? target.resourceValues(forKeys: [.isPackageKey]).isPackage) != true {
                    let realTarget = target.resolvingSymlinksInPath().standardizedFileURL.path
                    if visited.contains(realTarget) {
                        skipped.append((item, "Schleife (Ordner ist schon enthalten)"))
                        continue
                    }
                    folders.append(Folder(url: item, name: item.lastPathComponent, children: walk(item)))
                }
            }
            return folders
        }

        let folders = walk(root)

        // Reading metadata is the expensive part: in parallel, from the cache when unchanged.
        var metas = [NoteMetadata?](repeating: nil, count: notePaths.count)
        var hits = [Bool](repeating: false, count: notePaths.count)
        metas.withUnsafeMutableBufferPointer { out in
            hits.withUnsafeMutableBufferPointer { hitOut in
                DispatchQueue.concurrentPerform(iterations: notePaths.count) { i in
                    let url = notePaths[i]
                    let attrs = try? fm.attributesOfItem(atPath: url.path)
                    let key = CacheKey(path: url.path, size: (attrs?[.size] as? NSNumber)?.intValue ?? -1,
                                       modified: attrs?[.modificationDate] as? Date ?? .distantPast)
                    lock.lock(); let cached = cache[key]; lock.unlock()
                    if let cached { out[i] = cached; hitOut[i] = true; return }
                    if let meta = try? NoteFile.readMetadata(at: url) {
                        out[i] = meta
                        lock.lock(); cache[key] = meta; lock.unlock()
                    }
                }
            }
        }
        var notes: [(URL, NoteMetadata)] = []
        var unreadable: [URL] = []
        for (i, url) in notePaths.enumerated() {
            if let m = metas[i] { notes.append((url, m)) } else { unreadable.append(url) }
        }
        // The same note reachable twice (through a link inside the library) is listed once.
        var seen = Set<UUID>()
        notes = notes.filter { seen.insert($0.1.id).inserted }
        return Result(folders: folders, notes: notes, unreadable: unreadable, skippedLinks: skipped, cacheHits: hits.filter { $0 }.count)
    }
}
