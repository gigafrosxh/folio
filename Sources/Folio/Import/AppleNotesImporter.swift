import AppKit
import FolioCore
import UniformTypeIdentifiers

enum AppleNotesImporter {
    struct RawNote: Decodable, Sendable {
        let account: String
        let folderPath: [String]
        let name: String
        let body: String
        let created: Date
        let modified: Date
        let id: String
    }

    private enum ImportError: LocalizedError {
        case automationDenied
        case execution(String)
        case invalidData

        var errorDescription: String? {
            switch self {
            case .automationDenied:
                return "Bitte erlaube Folio unter Systemeinstellungen › Datenschutz & Sicherheit › Automation, die App Notizen zu steuern."
            case .execution(let detail):
                return "Apple Notizen konnte nicht gelesen werden. \(detail)"
            case .invalidData:
                return "Die Daten aus Apple Notizen konnten nicht verarbeitet werden."
            }
        }
    }

    static func fetch() async throws -> [RawNote] {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-l", "JavaScript", "-e", script]
            process.standardInput = FileHandle.nullDevice
            let output = Pipe(), errors = Pipe()
            process.standardOutput = output
            process.standardError = errors
            do { try process.run() }
            catch { throw ImportError.execution(error.localizedDescription) }

            let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 300, execute: timeout)
            defer { timeout.cancel() }
            // Drain both pipes concurrently before waiting for process termination.
            let errorReader = Task.detached { errors.fileHandleForReading.readDataToEndOfFile() }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let errorData = await errorReader.value
            let detail = String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard process.terminationStatus == 0 else {
                if detail.contains("-1743") || detail.localizedCaseInsensitiveContains("not authorized") {
                    throw ImportError.automationDenied
                }
                throw ImportError.execution(detail.isEmpty ? "Der Lesevorgang wurde abgebrochen oder hat zu lange gedauert." : detail)
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .custom { decoder in
                let value = try decoder.singleValueContainer().decode(String.self)
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let date = formatter.date(from: value) { return date }
                formatter.formatOptions = [.withInternetDateTime]
                if let date = formatter.date(from: value) { return date }
                throw ImportError.invalidData
            }
            do { return try decoder.decode([RawNote].self, from: data) }
            catch { throw ImportError.invalidData }
        }.value
    }

    @MainActor
    static func convert(_ raw: RawNote, multipleAccounts: Bool) -> ImportedNote {
        var blocks: [BlockRecord] = []
        var attachments: [FolioArchive.Attachment] = []
        var plainSegments: [String] = []
        let html = raw.body as NSString
        let images = try! NSRegularExpression(
            pattern: #"<img\b[^>]*?\ssrc\s*=\s*(["'])data:([^;,"']+);base64,([^"']*)\1[^>]*>"#,
            options: [.caseInsensitive]
        )

        func appendText(_ html: String) {
            guard !html.isEmpty else { return }
            let styled = "<style>body{font-family:-apple-system;font-size:15px}</style>" + html
            let text = (try? NSMutableAttributedString(
                data: Data(styled.utf8),
                options: [.documentType: NSAttributedString.DocumentType.html,
                          .characterEncoding: String.Encoding.utf8.rawValue],
                documentAttributes: nil
            )) ?? NSMutableAttributedString(string: html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
            RichTextCodec.normalizeImported(text, bodyFont: ThemeManager.shared.bodyFont())
            let string = text.string as NSString
            let content = string.rangeOfCharacter(from: CharacterSet.newlines.inverted)
            guard content.location != NSNotFound else { return }
            let last = string.rangeOfCharacter(from: CharacterSet.newlines.inverted, options: .backwards)
            let trimmed = text.attributedSubstring(from: NSRange(location: content.location, length: NSMaxRange(last) - content.location))
            guard !trimmed.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            var block = BlockRecord(kind: .text)
            block.rtf = RichTextCodec.rtfData(from: trimmed)
            blocks.append(block)
            plainSegments.append(trimmed.string)
        }

        var offset = 0
        for match in images.matches(in: raw.body, range: NSRange(location: 0, length: html.length)) {
            appendText(html.substring(with: NSRange(location: offset, length: match.range.location - offset)))
            let mime = html.substring(with: match.range(at: 2)).lowercased()
            let encoded = html.substring(with: match.range(at: 3)).components(separatedBy: .whitespacesAndNewlines).joined()
            if let data = Data(base64Encoded: encoded), !data.isEmpty {
                let type = UTType(mimeType: mime) ?? .image
                let attachment = FolioArchive.Attachment(
                    filename: "Bild \(attachments.count + 1).\(type.preferredFilenameExtension ?? "bin")",
                    typeIdentifier: type.identifier, data: data
                )
                attachments.append(attachment)
                var block = BlockRecord(kind: .image)
                block.attachmentID = attachment.id
                blocks.append(block)
            } else {
                appendText("<p>[Bild konnte nicht importiert werden]</p>")
            }
            offset = NSMaxRange(match.range)
        }
        appendText(html.substring(from: offset))
        if blocks.first?.kind != .text { blocks.insert(BlockRecord(kind: .text), at: 0) }
        if blocks.last?.kind != .text { blocks.append(BlockRecord(kind: .text)) }
        let plainText = plainSegments.joined(separator: "\n")
        var lines = plainText.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if lines.first?.trimmingCharacters(in: .whitespaces) == raw.name.trimmingCharacters(in: .whitespacesAndNewlines) {
            lines.removeFirst()
        }
        let meta = NoteMetadata(title: raw.name, preview: String(lines.joined(separator: "\n").prefix(200)),
                                tags: TagParser.tags(in: plainText), created: raw.created, modified: raw.modified,
                                searchText: plainText)
        return ImportedNote(folderPath: ["Apple Notizen"] + (multipleAccounts ? [raw.account] : []) + raw.folderPath,
                            file: NoteFile(meta: meta, body: NoteBody(blocks: blocks), attachments: attachments))
    }

    private static let script = #"""
    const notes = Application('Notes');
    const result = [];
    const visited = new Set();
    function walk(folder, account, path) {
        const folderID = folder.id();
        if (visited.has(folderID)) return;
        visited.add(folderID);
        const name = folder.name();
        if (name === 'Recently Deleted' || name === 'Zuletzt gelöscht') return;
        const folderPath = path.concat([name]);
        const names = folder.notes.name();
        const created = folder.notes.creationDate();
        const modified = folder.notes.modificationDate();
        const ids = folder.notes.id();
        const locked = folder.notes.passwordProtected();
        let bodies;
        try { bodies = folder.notes.body(); }
        catch (error) {
            if (String(error).includes('-1743') || /not authorized/i.test(String(error))) throw error;
            bodies = ids.map((id, i) => locked[i] ? null : folder.notes[i].body());
        }
        for (let i = 0; i < ids.length; i++) {
            if (locked[i] || bodies[i] == null) continue;
            result.push({account: account, folderPath: folderPath, name: names[i], body: bodies[i],
                         created: created[i].toISOString(), modified: modified[i].toISOString(), id: ids[i]});
        }
        folder.folders().forEach(child => walk(child, account, folderPath));
    }
    notes.accounts().forEach(account => {
        const accountID = account.id();
        const accountName = account.name();
        account.folders().forEach(folder => {
            if (folder.container().id() === accountID) walk(folder, accountName, []);
        });
    });
    JSON.stringify(result);
    """#
}
