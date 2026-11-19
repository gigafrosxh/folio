import Foundation
import FolioCore

/// macOS starts a downloaded app that still has the quarantine flag from a read-only random copy
/// (`/private/var/folders/…/AppTranslocation/…`). Folio's updater has to replace the original instead (#259).
enum AppTranslocation {
    static func isTranslocated(_ url: URL) -> Bool { UpdatePaths.isTranslocated(url.path) }

    /// The original location, through Security.framework's `SecTranslocateCreateOriginalPathForURL`
    /// (available since macOS 10.12, not in the public headers, so it is looked up at run time).
    static func originalURL(of url: URL) -> URL? {
        typealias Fn = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        guard let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let symbol = dlsym(handle, "SecTranslocateCreateOriginalPathForURL") else { return nil }
        let fn = unsafeBitCast(symbol, to: Fn.self)
        guard let original = fn(url as CFURL, nil)?.takeRetainedValue() as URL?, !isTranslocated(original) else { return nil }
        return original
    }

    static let advice = """
    macOS startet Folio aus einem schreibgeschützten Zufallsordner, weil die App noch als Download markiert ist. \
    Beende Folio, ziehe es im Finder einmal in den Ordner „Programme“ (oder führe im Terminal \
    „xattr -dr com.apple.quarantine <Pfad>/Folio.app“ aus) und starte es neu. Danach funktioniert der Update-Knopf.
    """
}
