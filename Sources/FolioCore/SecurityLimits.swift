import Foundation

/// Fixed limits for reading untrusted note files (#161): a small file must not be able to claim gigabytes.
public enum ArchiveLimits {
    /// Largest uncompressed section (metadata, body or one attachment).
    public static let maxSection: UInt64 = 1 << 30
    /// Above this size a section must not be packed tighter than `maxRatio`: real notes (text, pictures, recordings)
    /// stay far below, a forged file that unpacks small input into gigabytes does not. Smaller sections may pack any
    /// way they like, so a short silent recording or an empty drawing always opens.
    public static let ratioCheckedAbove: UInt64 = 128 << 20
    public static let maxRatio: UInt64 = 1_000
    /// Most bytes one note may unpack to in total.
    public static let maxTotal: UInt64 = 4 << 30
    /// Most attachments one note may have.
    public static let maxAttachments: UInt32 = 100_000

    /// Whether a section that claims `raw` bytes from `stored` compressed bytes may be unpacked.
    public static func allows(raw: UInt64, stored: UInt64) -> Bool {
        // Divided, not multiplied: a forged stored length must not overflow.
        raw <= maxSection && (raw <= ratioCheckedAbove || raw / maxRatio <= stored)
    }
}

/// Removes secrets (database passwords) from text Folio shows or saves, such as error messages (#161).
public enum SecretRedaction {
    public static let mask = "••••••"

    /// Every occurrence of a secret is replaced; secrets shorter than 3 characters are left alone, they would hide
    /// ordinary text.
    public static func redact(_ text: String, secrets: [String]) -> String {
        secrets.filter { $0.count >= 3 }.sorted { $0.count > $1.count }
            .reduce(text) { $0.replacingOccurrences(of: $1, with: mask) }
    }

    /// The values of environment variables that hold passwords (`PGPASSWORD`, `MYSQL_PWD`, `SQLCMDPASSWORD` …).
    public static func secrets(in environment: [String: String]) -> [String] {
        environment.filter { key, _ in key.uppercased().contains("PASSWORD") || key.uppercased().hasSuffix("PWD") }.map(\.value)
    }
}

/// Which links in imported text may stay clickable (#161): web, mail and Folio's own links, nothing that runs code
/// or opens local files.
public enum LinkSafety {
    public static let allowedSchemes: Set<String> = ["http", "https", "mailto", "folio"]

    public static func isSafe(_ link: String) -> Bool {
        guard let scheme = URL(string: link.trimmingCharacters(in: .whitespaces))?.scheme?.lowercased() else { return false }
        return allowedSchemes.contains(scheme)
    }

    /// The file a relative path in an imported document points to, if it stays inside `base` (no `..`, no absolute
    /// path, no symbolic link out of the folder).
    public static func fileInside(_ base: URL, relativePath: String) -> URL? {
        guard !relativePath.hasPrefix("/"), !relativePath.contains("://") else { return nil }
        let root = base.resolvingSymlinksInPath().standardizedFileURL.path
        let file = base.appendingPathComponent(relativePath).resolvingSymlinksInPath().standardizedFileURL
        return file.path.hasPrefix(root + "/") ? file : nil
    }
}
