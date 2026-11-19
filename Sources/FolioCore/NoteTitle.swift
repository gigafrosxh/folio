import Foundation

/// How a note's title and preview come from its text, the same on Mac and iPad (#265).
public enum NoteTitle {
    /// A text line without leading list marker (•, ☐, ☑, „1.“, „1“ + Tab …) and with single spaces.
    public static func plainLine(_ line: String) -> String {
        // Bullets and checkboxes before any space; numbers only as "1." / "1)" or followed by a tab,
        // so "10 km/h" keeps its number.
        var s = line.replacingOccurrences(of: #"^[\t ]*(?:[•◦▪‣☐☑✓✔︎–\-*][\t ]+|\d{1,3}[.)][\t ]+|\d{1,3}\t+)"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[\t ]+"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// Quick capture's date lines ("— 20. Okt. 2026, 19:31 —") separate entries; they are no title (#95).
    public static func isCaptureSeparator(_ line: String) -> Bool {
        line.hasPrefix("— ") && line.hasSuffix(" —") && line.count < 60
    }

    /// The lines that count for title and preview.
    public static func lines(of text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map { plainLine(String($0)) }.filter { !$0.isEmpty && !isCaptureSeparator($0) }
    }
}
