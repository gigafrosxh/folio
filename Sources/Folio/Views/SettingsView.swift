import AppKit
import SwiftUI
import FolioCore

/// The settings window: one tab per area, each its own view in `Views/Settings` (#217).
struct SettingsView: View {
    @EnvironmentObject var theme: ThemeManager

    /// "Folio 0.5.1 (7)" from the app bundle; "Folio (Entwicklung)" when run outside the .app.
    static var versionString: String {
        let info = Bundle.main.infoDictionary ?? [:]
        guard let version = info["CFBundleShortVersionString"] as? String else { return "Folio (Entwicklungsversion)" }
        let build = info["CFBundleVersion"] as? String
        return "Folio \(version)" + (build.map { " (\($0))" } ?? "")
    }

    static var issuesURL: URL { FeedbackSettingsView.issuesURL }
    static var newIssueURL: URL { FeedbackSettingsView.newIssueURL }

    /// The open tab; the Help menu opens „Tastenkürzel“ directly (#106).
    @AppStorage("folio.settingsTab") private var tab = "general"

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $tab) {
                GeneralSettingsView().tabItem { Label("Allgemein", systemImage: "gearshape") }.tag("general")
                EditorSettingsView().tabItem { Label("Editor", systemImage: "textformat") }.tag("editor")
                CodeSettingsView().tabItem { Label("Code", systemImage: "chevron.left.forwardslash.chevron.right") }.tag("code")
                ExecutionSettingsView().tabItem { Label("Ausführung", systemImage: "play.circle") }.tag("execution")
                AppearanceSettingsView().tabItem { Label("Darstellung", systemImage: "square.on.square") }.tag("appearance")
                SafetySettingsView().tabItem { Label("Sicherheit", systemImage: "lock.shield") }.tag("safety")
                QuickAccessSettingsView().tabItem { Label("Schnellzugriff", systemImage: "bolt") }.tag("quick")
                ShortcutSettingsView().tabItem { Label("Tastenkürzel", systemImage: "keyboard") }.tag("shortcuts")
                FeedbackSettingsView().tabItem { Label("Feedback", systemImage: "bubble.left.and.exclamationmark.bubble.right") }.tag("feedback")
            }
            Divider()
            Text(Self.versionString)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        // Wide enough for all nine tabs; at 620 pt „Feedback“ went into the overflow menu (#104).
        .frame(width: 760, height: 548)
        .tint(theme.accent)
        .preferredColorScheme(theme.settings.appearance.colorScheme)
    }
}
