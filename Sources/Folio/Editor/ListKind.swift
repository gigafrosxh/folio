import Foundation

/// List markers handled by the editor. Lists are plain-text prefixes so they survive RTF round trips
/// and look the same everywhere.
enum ListKind: String, CaseIterable {
    case bullet = "• "
    case dash = "– "
    case numbered = "1. "
    case checklist = "☐ "

    static let checked = "☑ "

    var label: String {
        switch self {
        case .bullet: return "Aufzählung"
        case .dash: return "Strichliste"
        case .numbered: return "Nummerierte Liste"
        case .checklist: return "Checkliste"
        }
    }

    var icon: String {
        switch self {
        case .bullet: return "list.bullet"
        case .dash: return "list.dash"
        case .numbered: return "list.number"
        case .checklist: return "checklist"
        }
    }

    /// Detects a list marker at the start of `line` (after indentation).
    static func detect(_ line: String) -> (indent: String, marker: String, kind: ListKind)? {
        let indent = String(line.prefix { $0 == "\t" || $0 == " " })
        let rest = line.dropFirst(indent.count)
        for kind in [ListKind.bullet, .dash, .checklist] where rest.hasPrefix(kind.rawValue) {
            return (indent, kind.rawValue, kind)
        }
        if rest.hasPrefix(checked) { return (indent, checked, .checklist) }
        let digits = rest.prefix { $0.isNumber }
        if !digits.isEmpty, rest.dropFirst(digits.count).hasPrefix(". ") {
            return (indent, String(digits) + ". ", .numbered)
        }
        return nil
    }

    static func next(after marker: String, kind: ListKind) -> String {
        switch kind {
        case .numbered: return "\((Int(marker.dropLast(2)) ?? 0) + 1). "
        case .checklist: return ListKind.checklist.rawValue
        default: return marker
        }
    }
}
