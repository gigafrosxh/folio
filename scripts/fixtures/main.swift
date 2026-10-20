import Foundation
// Writes a note with the old app's own types: JSON in, old encoder out.
let args = CommandLine.arguments
let meta = try JSONDecoder().decode(NoteMetadata.self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
let body = try JSONDecoder().decode(NoteBody.self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
var atts: [FolioArchive.Attachment] = []
if args.count > 4 {
    atts.append(FolioArchive.Attachment(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!, filename: "bild.png", typeIdentifier: "public.png", data: Data(repeating: 7, count: 4096)))
}
let file = NoteFile(meta: meta, body: body, attachments: atts)
try file.write(to: URL(fileURLWithPath: args[3]))
print("ok", args[3])
