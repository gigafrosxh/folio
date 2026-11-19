import Foundation

public enum CodeExport {
    public enum LinkState: Equatable, Sendable {
        case same, differs, missing, unreadable(String)
    }

    // ArchiveLimits govern compressed notes, not source files.
    public static let maximumFileSize = 5 * 1024 * 1024

    public static func suggestedFileName(code: String, language: String, caption: String?) -> String {
        let caption = caption?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var name = caption.isEmpty ? definitionName(code) ?? "code" : caption
        let forbidden = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/:"))
        name = name.components(separatedBy: forbidden).joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        name = String(name.drop(while: { $0 == "." }))
        if name.isEmpty { name = "code" }
        let existingExtension = (name as NSString).pathExtension
        let ext =
            !caption.isEmpty && !existingExtension.isEmpty
            ? existingExtension : Languages.spec(for: language).fileExtension
        let base =
            !caption.isEmpty && !existingExtension.isEmpty
            ? (name as NSString).deletingPathExtension : name
        // Preserve the extension while bounding the complete suggested name.
        let suffix = String(ext.prefix(40))
        return String(base.prefix(79 - suffix.count)) + "." + suffix
    }

    private static func definitionName(_ code: String) -> String? {
        let beginning = code.components(separatedBy: "\n").prefix(30).joined(separator: "\n")
        let pattern =
            #"(?m)^\s*(?:(?:public|private|internal|fileprivate|open|final|static|export|default|async|pub)\s+)*(?:def|class|function\s*\*?|func|struct|enum|actor|protocol|interface|fn|fun|sub)\s+([\p{L}_$][\p{L}\p{N}_$]*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(in: beginning, range: NSRange(beginning.startIndex..., in: beginning)),
            let range = Range(match.range(at: 1), in: beginning)
        else { return nil }
        return String(beginning[range])
    }

    public static func fileContents(code: String) -> Data {
        var text = code.replacingOccurrences(of: "\r\n", with: "\n")
        while text.hasSuffix("\n") { text.removeLast() }
        return Data((text + "\n").utf8)
    }

    public static func write(code: String, to url: URL) throws {
        try fileContents(code: code).write(to: url, options: .atomic)
    }

    /// Reads at most `limit` bytes of a regular file; anything else (missing, too large, a FIFO or device that could
    /// block, a folder) is reported as a `LinkState` instead of being read (#263).
    public static func boundedData(at url: URL, limit: Int = maximumFileSize) -> Result<Data, LinkStateError> {
        do {
            let target = url.resolvingSymlinksInPath()
            let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else { return .failure(.init(.unreadable("Keine reguläre Datei"))) }
            if let size = attributes[.size] as? NSNumber, size.int64Value > Int64(limit) { return .failure(.init(.unreadable("Datei ist zu groß"))) }
            let handle = try FileHandle(forReadingFrom: target)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: limit + 1) ?? Data()
            guard data.count <= limit else { return .failure(.init(.unreadable("Datei ist zu groß"))) }
            return .success(data)
        } catch {
            let error = error as NSError
            if error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) {
                return .failure(.init(.missing))
            }
            return .failure(.init(.unreadable(error.localizedDescription)))
        }
    }

    public struct LinkStateError: Error, Equatable {
        public var state: LinkState
        public init(_ state: LinkState) { self.state = state }
    }

    /// The file as text with LF line ends, or why it cannot be shown.
    public static func readText(at url: URL) -> Result<String, LinkStateError> {
        boundedData(at: url).flatMap { data in
            guard let text = String(data: data, encoding: .utf8) else { return .failure(.init(.unreadable("Datei ist kein gültiger UTF-8-Text"))) }
            return .success(text.replacingOccurrences(of: "\r\n", with: "\n"))
        }
    }

    public static func compare(code: String, fileAt url: URL) -> LinkState {
        switch readText(at: url) {
        case .failure(let e): return e.state
        case .success(let rhs):
            // Byte-exact: Swift's == treats composed and decomposed "é" as equal (#265).
            let lhs = Array(code.replacingOccurrences(of: "\r\n", with: "\n").utf8)
            let r = Array(rhs.utf8)
            return lhs == r || lhs + [0x0A] == r || r + [0x0A] == lhs ? .same : .differs
        }
    }
}
