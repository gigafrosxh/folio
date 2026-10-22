import Foundation
import PDFKit

/// Text of a PDF for importing it as a note (#130): its title and the text of each page, with lines
/// that a PDF breaks mid-sentence joined back into paragraphs.
public enum PDFText {
    public struct Result: Equatable, Sendable {
        public var title: String?
        public var pages: [String]
        public var pageCount: Int
        /// No selectable text at all (a scan or pictures).
        public var isEmpty: Bool { pages.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
    }

    public enum Failure: Error, Equatable { case notAPDF, locked }

    public static func extract(from data: Data, maxCharacters: Int = 400_000) throws -> Result {
        guard let doc = PDFDocument(data: data) else { throw Failure.notAPDF }
        guard !doc.isLocked else { throw Failure.locked }
        let title = (doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var pages: [String] = []
        var total = 0
        for i in 0..<doc.pageCount {
            guard total < maxCharacters, let page = doc.page(at: i) else { break }
            let text = reflow(page.string ?? "")
            total += text.count
            pages.append(text)
        }
        return Result(title: title?.isEmpty == false ? title : nil, pages: pages, pageCount: doc.pageCount)
    }

    /// Joins lines that belong to one paragraph and words split with a hyphen at the line end.
    public static func reflow(_ text: String) -> String {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        var paragraphs: [String] = []
        var current = ""
        for line in lines {
            if line.isEmpty {
                if !current.isEmpty { paragraphs.append(current); current = "" }
                continue
            }
            if current.isEmpty { current = line; continue }
            let last = current.last!
            let startsLower = line.first?.isLowercase == true
            if last == "-", current.count > 1, current.dropLast().last?.isLetter == true {
                // „Bei-\nspiel“ → „Beispiel“; „Nord-\nSüd“ keeps its hyphen: „Nord-Süd“.
                if startsLower { current.removeLast() }
                current += line
            } else if ".!?:;".contains(last) || isListItem(line) {
                paragraphs.append(current)
                current = line
            } else {
                current += " " + line
            }
        }
        if !current.isEmpty { paragraphs.append(current) }
        return paragraphs.joined(separator: "\n")
    }

    private static func isListItem(_ line: String) -> Bool {
        if let f = line.first, "•–-*▪◦".contains(f) { return true }
        let digits = line.prefix { $0.isNumber }
        return !digits.isEmpty && digits.count <= 3 && (line.dropFirst(digits.count).first == "." || line.dropFirst(digits.count).first == ")")
    }
}
