import AppKit
import SwiftUI
import FolioCore

/// „Feedback“: links to the issues page with version and macOS prefilled (#217).
struct FeedbackSettingsView: View {
    static let issuesURL = URL(string: "https://github.com/gigafrosxh/folio/issues")!

    /// New-issue page with app and system version prefilled, so reports say what they were seen on.
    static var newIssueURL: URL {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let body = "\n\n---\n\(SettingsView.versionString) · macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        var components = URLComponents(url: issuesURL.appendingPathComponent("new"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "body", value: body)]
        return components.url ?? issuesURL
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Fehler gefunden oder eine Idee?", systemImage: "bubble.left.and.exclamationmark.bubble.right").font(.headline)
                    Text("Rückmeldungen laufen über die Issues-Seite des Folio-Repositorys auf GitHub. Version und macOS-Version werden im neuen Eintrag schon vorausgefüllt.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            }
            Section {
                LabeledContent("Neues Feedback") {
                    Button("Issue anlegen …") { NSWorkspace.shared.open(Self.newIssueURL) }
                }
                LabeledContent("Bisherige Rückmeldungen") {
                    Button("Issues öffnen") { NSWorkspace.shared.open(Self.issuesURL) }
                }
            } footer: {
                Text("Das Repository ist privat: Die Seite öffnet sich nur mit einem GitHub-Konto, das Zugriff darauf hat.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}
