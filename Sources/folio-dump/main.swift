import Foundation
import FolioCore

// Small inspection tool: prints a .folio file's metadata and blocks, or searches a library.
// Usage: folio-dump <file.folio> [--rtf <outdir>]  |  folio-dump --find <text> <library dir>
let args = CommandLine.arguments
if args.count >= 4, args[1] == "--find" {
    let needle = args[2]
    let e = FileManager.default.enumerator(at: URL(fileURLWithPath: args[3]), includingPropertiesForKeys: nil)
    while let url = e?.nextObject() as? URL {
        guard url.pathExtension == FolioArchive.fileExtension, let m = try? NoteFile.readMetadata(at: url) else { continue }
        if m.searchText.localizedCaseInsensitiveContains(needle) || m.title.localizedCaseInsensitiveContains(needle) { print(url.path) }
    }
    exit(0)
}
guard args.count >= 2 else { print("Usage: folio-dump <file.folio> [--rtf <outdir>] | --find <text> <dir>"); exit(1) }
do {
    let file = try NoteFile.read(from: URL(fileURLWithPath: args[1]))
    print("title:", file.meta.title, "tags:", file.meta.tags, "attachments:", file.attachments.count)
    for (i, b) in file.body.blocks.enumerated() {
        print(i, b.kind.rawValue, b.rtf.map { "rtf \($0.count)B" } ?? "", b.url ?? "", b.height.map { "h=\($0)" } ?? "")
        if args.count >= 4, args[2] == "--rtf", let rtf = b.rtf {
            try rtf.write(to: URL(fileURLWithPath: args[3]).appendingPathComponent("block\(i).rtf"))
        }
    }
} catch {
    print("error:", error)
    exit(1)
}
