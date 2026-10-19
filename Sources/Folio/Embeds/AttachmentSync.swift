import AppKit
import UniformTypeIdentifiers
import FolioCore

/// Attachments live inside the compressed note file. To show them with Quick Look or edit them in
/// another app (Numbers, Preview, Pages) they are materialized into a stable cache folder; edits made
/// there are pulled back into the note when Folio becomes active again.
@MainActor
enum AttachmentSync {
    static var cacheRoot: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Folio/Attachments", isDirectory: true)
    }

    static func cacheURL(noteID: UUID, attachment: FolioArchive.Attachment) -> URL {
        cacheRoot.appendingPathComponent(noteID.uuidString, isDirectory: true)
            .appendingPathComponent(attachment.id.uuidString, isDirectory: true)
            .appendingPathComponent(attachment.header.filename)
    }

    /// Writes the attachment to the cache if it is not there yet and returns its URL.
    @discardableResult
    static func materialize(_ attachment: FolioArchive.Attachment, noteID: UUID, overwrite: Bool = false) -> URL? {
        let url = cacheURL(noteID: noteID, attachment: attachment)
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) && !overwrite { return url }
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
            if attachment.header.isPackage {
                guard let wrapper = FileWrapper(serializedRepresentation: attachment.data) else { return nil }
                try wrapper.write(to: url, options: .atomic, originalContentsURL: nil)
            } else {
                try attachment.data.write(to: url)
            }
            return url
        } catch {
            return nil
        }
    }

    /// Reads a file or package from disk into attachment data.
    static func read(_ url: URL) -> (data: Data, isPackage: Bool)? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }
        if isDir.boolValue {
            guard let wrapper = try? FileWrapper(url: url, options: .immediate),
                  let data = wrapper.serializedRepresentation else { return nil }
            return (data, true)
        }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (data, false)
    }

    static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// Pulls in edits made to cached attachments of `doc` in other apps.
    static func syncExternalEdits(in doc: NoteDocument) {
        var changed = false
        for block in doc.blocks where block.kind == .file || block.kind == .pdf || block.kind == .image {
            guard let id = block.attachmentID, let att = doc.attachments[id] else { continue }
            let url = cacheURL(noteID: doc.id, attachment: att)
            guard let mod = modificationDate(url) else { continue }
            let reference = block.syncedAt ?? doc.meta.modified
            guard mod.timeIntervalSince(reference) > 1, let fresh = read(url), fresh.data != att.data else { continue }
            doc.attachments[id]?.data = fresh.data
            doc.attachments[id]?.header.isPackage = fresh.isPackage
            block.syncedAt = mod
            block.revision += 1
            changed = true
        }
        if changed { doc.markDirty() }
    }

    /// Opens an attachment in its default app (or a specific one) for editing.
    static func open(_ block: BlockModel, in doc: NoteDocument, withApp app: String? = nil) {
        guard let id = block.attachmentID, let att = doc.attachments[id],
              let url = materialize(att, noteID: doc.id) else { return }
        if block.syncedAt == nil { block.syncedAt = modificationDate(url) }
        if let app, let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app) {
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Creating blocks from files

    enum ImportError: LocalizedError {
        case unreadable(String)
        var errorDescription: String? {
            switch self { case .unreadable(let n): return "„\(n)“ konnte nicht gelesen werden." }
        }
    }

    /// Creates the right block for a file: PDF → PDF view, image → image, everything else → Quick Look.
    static func makeBlock(for url: URL, in doc: NoteDocument) throws -> BlockModel {
        guard let content = read(url) else { throw ImportError.unreadable(url.lastPathComponent) }
        let type = UTType(filenameExtension: url.pathExtension) ?? .data
        let kind: BlockKind
        if type.conforms(to: .pdf) { kind = .pdf }
        else if type.conforms(to: .image) && !content.isPackage { kind = .image }
        else { kind = .file }
        let id = doc.addAttachment(filename: url.lastPathComponent, typeIdentifier: type.identifier,
                                   data: content.data, isPackage: content.isPackage)
        let block = BlockModel(kind: kind)
        block.attachmentID = id
        if kind == .file, ["numbers", "xlsx", "xls", "csv"].contains(url.pathExtension.lowercased()) { block.mode = "table" }
        if kind == .image { block.width = 1 }
        return block
    }

    static func makeImageBlock(data: Data, filename: String = "Bild.png", in doc: NoteDocument) -> BlockModel {
        let type = UTType(filenameExtension: (filename as NSString).pathExtension) ?? .png
        let id = doc.addAttachment(filename: filename, typeIdentifier: type.identifier, data: data)
        let block = BlockModel(kind: .image)
        block.attachmentID = id
        return block
    }

    // MARK: Numbers

    enum NumbersError: LocalizedError {
        case script(String)
        var errorDescription: String? {
            switch self {
            case .script(let msg):
                if msg.contains("-1743") || msg.localizedCaseInsensitiveContains("not authorized") || msg.contains("nicht berechtigt") {
                    return "Folio darf Numbers nicht steuern. Bitte in Systemeinstellungen › Datenschutz & Sicherheit › Automation erlauben."
                }
                return "Numbers konnte die Tabelle nicht anlegen: \(msg)"
            }
        }
    }

    /// Creates an empty Numbers document, opens it in Numbers for editing and returns a table block for it.
    static func createNumbersTable(in doc: NoteDocument, name: String = "Tabelle") async throws -> BlockModel {
        let attachmentID = UUID()
        let placeholder = FolioArchive.Attachment(id: attachmentID, filename: "\(name).numbers", typeIdentifier: "com.apple.iwork.numbers.sffnumbers", isPackage: false, data: Data())
        let url = cacheURL(noteID: doc.id, attachment: placeholder)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let path = url.path.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Numbers"
            activate
            set newDoc to make new document
            save newDoc in POSIX file "\(path)"
        end tell
        """
        try await runAppleScript(script)
        guard let content = read(url) else { throw NumbersError.script("Datei wurde nicht gespeichert.") }
        let type = UTType(filenameExtension: "numbers")?.identifier ?? "com.apple.iwork.numbers.sffnumbers"
        doc.attachments[attachmentID] = FolioArchive.Attachment(id: attachmentID, filename: url.lastPathComponent, typeIdentifier: type,
                                                                  isPackage: content.isPackage, data: content.data)
        let block = BlockModel(kind: .file)
        block.attachmentID = attachmentID
        block.mode = "table"
        block.height = 360
        block.syncedAt = modificationDate(url)
        return block
    }

    static func runAppleScript(_ source: String) async throws {
        let result: (Int32, String) = await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", source]
            let err = Pipe()
            p.standardError = err
            p.standardOutput = FileHandle.nullDevice
            do { try p.run() } catch { return (Int32(-1), error.localizedDescription) }
            let data = err.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return (p.terminationStatus, String(decoding: data, as: UTF8.self))
        }.value
        if result.0 != 0 { throw NumbersError.script(result.1.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
}
