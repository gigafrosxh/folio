import AppKit
import SwiftUI

struct ShortcutSettingsView: View {
    @EnvironmentObject var theme: ThemeManager
    @State private var recordingAction: ShortcutAction?
    @State private var monitor: Any?
    @State private var hint: String?

    var body: some View {
        Form {
            Section {
                ForEach(ShortcutAction.allCases) { action in
                    shortcutRow(action)
                }
            } header: {
                Text("Werkzeuge")
            } footer: {
                Text("Klicke auf ein Kürzel und drücke die neue Tastenkombination. ⌃, ⌥ oder ⌘ ist nötig. Esc bricht ab, ⌫ entfernt das Kürzel.")
            }

            Button("Alle zurücksetzen") {
                stopRecording()
                theme.settings.shortcuts.removeAll()
            }

            ForEach(FixedShortcuts.groups.indices, id: \.self) { index in
                let group = FixedShortcuts.groups[index]
                Section(group.title) {
                    ForEach(group.items.indices, id: \.self) { itemIndex in
                        let item = group.items[itemIndex]
                        HStack {
                            Text(item.1)
                            Spacer(minLength: 12)
                            keyCap(item.0)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onDisappear { stopRecording() }
    }

    private func shortcutRow(_ action: ShortcutAction) -> some View {
        let combo = ShortcutCenter.shared.combo(for: action)
        let recording = recordingAction == action
        let conflicts = combo.key == "none" ? [] : ShortcutCenter.shared.actions(using: combo).filter { $0 != action }

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(action.title, systemImage: action.icon)
                Spacer(minLength: 12)
                Button {
                    startRecording(action)
                } label: {
                    keyCap(recording ? "Taste drücken …" : combo.key == "none" ? "–" : combo.display,
                           recording: recording)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Tastenkürzel für \(action.title)")
                .accessibilityValue(recording ? "Taste drücken" : combo.key == "none" ? "Nicht belegt" : combo.display)
                .help("Klicken, um das Tastenkürzel zu ändern")

                if combo != action.defaultCombo {
                    Button {
                        stopRecording()
                        ShortcutCenter.shared.set(nil, for: action)
                    } label: {
                        Label("Zurücksetzen", systemImage: "arrow.uturn.backward")
                            .labelStyle(.iconOnly)
                    }
                    .controlSize(.small)
                    .help("Zurücksetzen")
                    .accessibilityLabel("\(action.title) zurücksetzen")
                }
            }
            if recording, let hint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !conflicts.isEmpty {
                Text("Auch belegt von: \(conflicts.map(\.title).joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func keyCap(_ text: String, recording: Bool = false) -> some View {
        Text(text)
            .font(.system(.callout, design: .monospaced))
            .multilineTextAlignment(.trailing)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(recording ? theme.accent : Color.secondary.opacity(0.35), lineWidth: recording ? 2 : 1)
            }
    }

    private func startRecording(_ action: ShortcutAction) {
        stopRecording()
        recordingAction = action
        ShortcutCenter.shared.isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated {
                capture(event, for: action)
            }
            return nil
        }
        if monitor == nil { stopRecording() }
    }

    private func capture(_ event: NSEvent, for action: ShortcutAction) {
        if event.keyCode == 53 {
            stopRecording()
            return
        }
        let modifiers = event.modifierFlags.intersection([.control, .option, .shift, .command])
        if (event.keyCode == 51 || event.keyCode == 117), modifiers.isEmpty {
            ShortcutCenter.shared.set(KeyCombo(key: "none"), for: action)
            stopRecording()
            return
        }
        guard let combo = KeyCombo(event: event), combo.isUsable else {
            hint = "Bitte halte ⌃, ⌥ oder ⌘ zusammen mit einer Taste gedrückt."
            return
        }
        ShortcutCenter.shared.set(combo, for: action)
        stopRecording()
    }

    private func stopRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        recordingAction = nil
        hint = nil
        ShortcutCenter.shared.isRecording = false
    }
}
