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

    /// AppleScript commands arrive on the main thread; the result stays there (Swift 6, #309).
    func onMain(_ body: @MainActor () throws -> Any?) -> Any? {
        nonisolated(unsafe) var result: Any?
        do { try MainActor.assumeIsolated { result = try body() } } catch { return fail(error) }
        return result
    }
}

@objc(FolioCreateNoteCommand)
final class FolioCreateNoteCommand: FolioScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let body = evaluatedArguments?["FTxt"] as? String ?? "", title = text
        return onMain { try NoteAutomation.create(title: title, text: body).id.uuidString }
    }
}

@objc(FolioSearchNotesCommand)
final class FolioSearchNotesCommand: FolioScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let ids = evaluatedArguments?["FIds"] as? Bool ?? false, query = text
        return onMain { NoteAutomation.search(query).map { ids ? $0.id.uuidString : $0.meta.title } }
    }
}

@objc(FolioOpenNoteCommand)
final class FolioOpenNoteCommand: FolioScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let name = text
        return onMain {
            let ref = try NoteAutomation.find(name)
            NoteAutomation.open(ref)
            return ref.id.uuidString
        }
    }
}

@objc(FolioAppendCommand)
final class FolioAppendCommand: FolioScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let addition = evaluatedArguments?["FTxt"] as? String ?? "", name = text
        return onMain {
            try NoteAutomation.append(addition, to: try NoteAutomation.find(name))
        }
    }
}
