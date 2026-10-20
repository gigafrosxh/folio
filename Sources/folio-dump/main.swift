import Foundation
import FolioCore

// Small inspection tool: prints a .folio file's metadata and blocks, or searches a library.
// Usage: folio-dump <file.folio> [--rtf <outdir>]  |  folio-dump --find <text> <library dir>  |  folio-dump --check <file or dir>
let args = CommandLine.arguments
if args.count >= 3, args[1] == "--seed" {
    // A small note with one text block, for scripted UI checks.
    var block = BlockRecord(kind: .text)
    block.rtf = Data(#"{\rtf1\ansi{\fonttbl\f0 Helvetica;}\f0\fs30 Testnotiz\par Inhalt}"#.utf8)
    let file = NoteFile(meta: NoteMetadata(title: "Testnotiz"), body: NoteBody(blocks: [block]))
    do { try file.write(to: URL(fileURLWithPath: args[2])); print(args[2]) } catch { print("error:", error); exit(1) }
    exit(0)
}
if args.count >= 3, args[1] == "--check" {
    // Diagnoses one file or every note in a folder: exit status 1 when anything is damaged.
    let target = URL(fileURLWithPath: args[2])
    var isDir: ObjCBool = false
    FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir)
    var files: [URL] = [target]
    if isDir.boolValue {
        files = []
        let e = FileManager.default.enumerator(at: target, includingPropertiesForKeys: nil)
        while let url = e?.nextObject() as? URL { if url.pathExtension == FolioArchive.fileExtension { files.append(url) } }
    }
    var damaged = 0
    for url in files {
        let r = FolioDiagnostics.diagnose(at: url)
        if r.isHealthy { if !isDir.boolValue { print("OK", url.path) }; continue }
        damaged += 1
        print("BESCHÄDIGT", url.path)
        for p in r.problems { print("  -", p.message) }
        print("  rettbar: \(r.blocks.count) Blöcke, \(r.attachments.count) Anhänge")
    }
    if isDir.boolValue { print("\(files.count) Notizen geprüft, \(damaged) beschädigt") }
    exit(damaged == 0 ? 0 : 1)
}
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
    print("id:", file.meta.id, "title:", file.meta.title, "tags:", file.meta.tags, "attachments:", file.attachments.count)
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
