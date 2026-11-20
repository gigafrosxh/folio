import Foundation

/// The file operations Folio's safety code uses, behind a narrow protocol so tests can make any step fail on purpose
/// (#314). `LocalFileOperations` is the real file system.
public protocol FileOperations: Sendable {
    func fileExists(_ url: URL) -> Bool
    func isDirectory(_ url: URL) -> Bool
    func createDirectory(_ url: URL) throws
    func moveItem(_ source: URL, to target: URL) throws
    func copyItem(_ source: URL, to target: URL) throws
    func removeItem(_ url: URL) throws
    /// Atomic: the file is either the old or the new one.
    func write(_ data: Data, to url: URL) throws
    func read(_ url: URL) throws -> Data
}

public struct LocalFileOperations: FileOperations {
    public init() {}
    private var fm: FileManager { .default }
    public func fileExists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }
    public func isDirectory(_ url: URL) -> Bool {
        var dir: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &dir) && dir.boolValue
    }
    public func createDirectory(_ url: URL) throws { try fm.createDirectory(at: url, withIntermediateDirectories: true) }
    public func moveItem(_ source: URL, to target: URL) throws { try fm.moveItem(at: source, to: target) }
    public func copyItem(_ source: URL, to target: URL) throws { try fm.copyItem(at: source, to: target) }
    public func removeItem(_ url: URL) throws { try fm.removeItem(at: url) }
    public func write(_ data: Data, to url: URL) throws { try data.write(to: url, options: .atomic) }
    public func read(_ url: URL) throws -> Data { try Data(contentsOf: url) }
}

extension FileOperations where Self == LocalFileOperations {
    public static var local: LocalFileOperations { LocalFileOperations() }
}
