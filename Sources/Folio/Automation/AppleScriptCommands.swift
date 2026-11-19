import AppKit
import FolioCore

// AppleScript commands from Resources/Folio.sdef (#70). Each one runs NoteAutomation on the main thread and reports
// failures as AppleScript errors instead of changing anything.

class FolioScriptCommand: NSScriptCommand {
    var text: String { (directParameter as? String) ?? "" }

    func fail(_ error: Error) -> Any? {
        scriptErrorNumber = -10000
        scriptErrorString = error.localizedDescription
        return nil
    }

    func onMain(_ body: @MainActor () throws -> Any?) -> Any? {
        do { return try MainActor.assumeIsolated(body) } catch { return fail(error) }
    }
}

@objc(FolioCreateNoteCommand)
final class FolioCreateNoteCommand: FolioScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let body = evaluatedArguments?["FTxt"] as? String ?? ""
        return onMain { try NoteAutomation.create(title: text, text: body).id.uuidString }
    }
}

@objc(FolioSearchNotesCommand)
final class FolioSearchNotesCommand: FolioScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let ids = evaluatedArguments?["FIds"] as? Bool ?? false
        return onMain { NoteAutomation.search(text).map { ids ? $0.id.uuidString : $0.meta.title } }
    }
}

@objc(FolioOpenNoteCommand)
final class FolioOpenNoteCommand: FolioScriptCommand {
    override func performDefaultImplementation() -> Any? {
        onMain {
            let ref = try NoteAutomation.find(text)
            NoteAutomation.open(ref)
            return ref.id.uuidString
        }
    }
}

@objc(FolioAppendCommand)
final class FolioAppendCommand: FolioScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let addition = evaluatedArguments?["FTxt"] as? String ?? ""
        return onMain {
            try NoteAutomation.append(addition, to: try NoteAutomation.find(text))
        }
    }
}
