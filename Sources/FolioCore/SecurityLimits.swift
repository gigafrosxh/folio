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
    /// Most bytes one note may unpack to in total: 4 GB, but never more than half the Mac's memory, so even a valid
    /// huge note cannot push the system into swapping (#283). Saving uses the same budget (#272).
    public static let maxTotal: UInt64 = min(4 << 30, ProcessInfo.processInfo.physicalMemory / 2)
    /// Largest attachment header (name, type, id as JSON); checked before it is read (#284).
    public static let maxAttachmentHeader: UInt32 = 64 << 10
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

    /// Every occurrence of a secret of 3 or more characters is replaced. Shorter ones would hide ordinary text, so they
    /// are replaced only where they stand as a value: after `=` or `:` (`password=ab`, `"pwd": "ab"`) (#285).
    /// Passwords in connection URLs (`postgres://user:pass@host`) are always hidden (#286).
    public static func redact(_ text: String, secrets: [String]) -> String {
        var out = secrets.filter { $0.count >= 3 }.sorted { $0.count > $1.count }
            .reduce(text) { $0.replacingOccurrences(of: $1, with: mask) }
        for short in Set(secrets.filter { !$0.isEmpty && $0.count < 3 }) {
            let pattern = #"([=:]\s*["']?)"# + NSRegularExpression.escapedPattern(for: short) + #"(?=$|[\s"',;&)\]}])"#
            out = out.replacingOccurrences(of: pattern, with: "$1" + mask, options: .regularExpression)
        }
        return out.replacingOccurrences(of: #"(://[^:/@\s]+:)[^@\s]+@"#, with: "$1" + mask + "@", options: .regularExpression)
    }

    /// Words in variable names that mark a secret (#286): passwords, tokens, API and access keys, credentials.
    static let secretNameParts = ["PASSWORD", "PASSWD", "SECRET", "TOKEN", "API_KEY", "APIKEY", "ACCESS_KEY", "PRIVATE_KEY", "CREDENTIAL", "AUTH"]

    /// The values of environment variables that hold secrets (`PGPASSWORD`, `MYSQL_PWD`, `GITHUB_TOKEN`, `OPENAI_API_KEY` …).
    public static func secrets(in environment: [String: String]) -> [String] {
        environment.filter { key, _ in
            let k = key.uppercased()
            return k.hasSuffix("PWD") || secretNameParts.contains { k.contains($0) }
        }.map(\.value)
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
