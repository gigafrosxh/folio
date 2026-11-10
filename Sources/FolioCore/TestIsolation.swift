import Foundation

/// Keeps test runs out of the real preferences (#136). macOS stores defaults, window frames included, under the
/// bundle ID and no longer reliably honours CFFIXED_USER_HOME, so tests need an app copy with its own bundle ID.
public enum TestIsolation {
    public static let releaseBundleID = "de.daniel.folio"

    /// Why this start must be refused, or nil when it is fine: the released identity never runs in test mode.
    public static func refusal(bundleID: String?, environment: [String: String]) -> String? {
        guard bundleID == releaseBundleID else { return nil }
        let keys = environment.keys.filter { $0 == "FOLIO_LIBRARY" || ($0.hasPrefix("FOLIO_") && $0.hasSuffix("_TEST")) }.sorted()
        guard !keys.isEmpty else { return nil }
        return "Folio startet nicht im Testmodus (\(keys.joined(separator: ", "))) mit der Bundle-ID \(releaseBundleID), "
            + "sonst ändern sich die echten Einstellungen. Testkopie erzeugen: scripts/make-test-app.sh"
    }
}
