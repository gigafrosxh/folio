import Foundation

/// German counts for the graph statistics: "1 Notiz", "2 Notizen" (#165).
public enum GermanCount {
    public static func format(_ count: Int, _ singular: String, _ plural: String) -> String {
        "\(count) \(count == 1 ? singular : plural)"
    }
}

/// What the graph shows, as one sentence for the legend and for assistive technologies (#165).
public struct GraphSummary: Equatable, Sendable {
    public var notes: Int
    public var folders: Int
    public var links: Int
    public var orphans: Int

    public init(notes: Int, folders: Int, links: Int, orphans: Int) {
        self.notes = notes
        self.folders = folders
        self.links = links
        self.orphans = orphans
    }

    private var counts: [String] {
        [GermanCount.format(notes, "Notiz", "Notizen"), GermanCount.format(folders, "Ordner", "Ordner"),
         GermanCount.format(links, "Verknüpfung", "Verknüpfungen")]
    }

    /// "2 Notizen · 1 Ordner · 1 Verknüpfung · 1 verwaist"
    public var legend: String { (counts + ["\(orphans) verwaist"]).joined(separator: " · ") }

    /// "1 Notiz, 1 Ordner, 1 Verknüpfung"
    public var spoken: String { counts.joined(separator: ", ") }
}
