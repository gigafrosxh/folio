import Foundation

public enum CodeExport {
    public enum LinkState: Equatable, Sendable {
        case same, differs, missing, unreadable(String)
    }

    // ArchiveLimits govern compressed notes, not source files.
    private static let maximumFileSize = 5 * 1024 * 1024

    public static func suggestedFileName(code: String, language: String, caption: String?) -> String {
        let caption = caption?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var name = caption.isEmpty ? definitionName(code) ?? "code" : caption
        let forbidden = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/:"))
        name = name.components(separatedBy: forbidden).joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        name = String(name.drop(while: { $0 == "." }))
        if name.isEmpty { name = "code" }
        let existingExtension = (name as NSString).pathExtension
        let ext = !caption.isEmpty && !existingExtension.isEmpty
            ? existingExtension : Languages.spec(for: language).fileExtension
        let base = !caption.isEmpty && !existingExtension.isEmpty
            ? (name as NSString).deletingPathExtension : name
        // Preserve the extension while bounding the complete suggested name.
        let suffix = String(ext.prefix(40))
        return String(base.prefix(79 - suffix.count)) + "." + suffix
    }

    private static func definitionName(_ code: String) -> String? {
        let beginning = code.components(separatedBy: "\n").prefix(30).joined(separator: "\n")
        let pattern = #"(?m)^\s*(?:(?:public|private|internal|fileprivate|open|final|static|export|default|async|pub)\s+)*(?:def|class|function\s*\*?|func|struct|enum|actor|protocol|interface|fn|fun|sub)\s+([\p{L}_$][\p{L}\p{N}_$]*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: beginning, range: NSRange(beginning.startIndex..., in: beginning)),
              let range = Range(match.range(at: 1), in: beginning) else { return nil }
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

    public static func compare(code: String, fileAt url: URL) -> LinkState {
        do {
            let target = url.resolvingSymlinksInPath()
            let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
            if let size = attributes[.size] as? NSNumber, size.int64Value > maximumFileSize {
                return .unreadable("Datei ist zu groß")
            }
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                return .unreadable("Keine reguläre Datei")
            }
            let handle = try FileHandle(forReadingFrom: target)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: maximumFileSize + 1) ?? Data()
            guard data.count <= maximumFileSize else { return .unreadable("Datei ist zu groß") }
            guard let text = String(data: data, encoding: .utf8) else {
                return .unreadable("Datei ist kein gültiger UTF-8-Text")
            }
            let lhs = code.replacingOccurrences(of: "\r\n", with: "\n")
            let rhs = text.replacingOccurrences(of: "\r\n", with: "\n")
            return lhs == rhs || lhs + "\n" == rhs || rhs + "\n" == lhs ? .same : .differs
        } catch {
            let error = error as NSError
            if error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) {
                return .missing
            }
            return .unreadable(error.localizedDescription)
        }
    }
}
