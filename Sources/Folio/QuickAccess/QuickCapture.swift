import AppKit
import Carbon.HIToolbox
import SwiftUI
import FolioCore

// MARK: - Window (#87)

/// The small floating capture window. It can open over any app and keeps its draft when closed with Esc.
@MainActor
final class QuickCaptureController {
    static let shared = QuickCaptureController()
    private var panel: NSPanel?
    let model = QuickCaptureModel()

    func show(text: String? = nil, target: CaptureTarget? = nil) {
        if let text { model.text = model.text.isEmpty ? text : model.text + "\n" + text }
        if let target { model.target = target }
        if panel == nil {
            let p = CapturePanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 250),
                                 styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
            p.title = "Schnellerfassung"
            p.titlebarAppearsTransparent = true
            p.isFloatingPanel = true
            p.level = .floating
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.contentView = NSHostingView(rootView: QuickCaptureView(model: model) { [weak self] in self?.close() }
                .environmentObject(ThemeManager.shared)
                .environmentObject(NoteStore.shared))
            p.center()
            p.setFrameAutosaveName("FolioQuickCapture")
            panel = p
        }
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        model.focusToken += 1
    }

    func close() {
        model.saveDraft()
        panel?.orderOut(nil)
    }

    var isVisible: Bool { panel?.isVisible == true }
}

/// A panel that can become key, so the text field takes typing even though the panel does not
/// activate Folio's other windows.
private final class CapturePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class QuickCaptureModel: ObservableObject {
    @Published var text = ""
    @Published var images: [Data] = []
    @Published var target: CaptureTarget = .inbox
    @Published var status: (ok: Bool, text: String)?
    @Published var focusToken = 0
    private static let draftKey = "folio.captureDraft"

    init() {
        // Esc never loses anything: the draft comes back next time.
        if let d = UserDefaults.standard.data(forKey: Self.draftKey), let item = try? JSONDecoder().decode(CaptureItem.self, from: d) {
            text = item.text
            images = item.images
            target = item.target
        }
    }

    func saveDraft() {
        let item = CaptureItem(text: text, images: images, target: target)
        if item.isEmpty { UserDefaults.standard.removeObject(forKey: Self.draftKey); return }
        if let d = try? JSONEncoder().encode(item) { UserDefaults.standard.set(d, forKey: Self.draftKey) }
    }

    func submit() -> Bool {
        let item = CaptureItem(text: text, images: images, target: target)
        guard !item.isEmpty else { status = (false, "Nichts zu speichern."); return false }
        let result = CaptureService.shared.save(item)
        status = (result.ok, result.message)
        if result.ok {
            text = ""
            images = []
            saveDraft()
        }
        return result.ok
    }

    func discard() {
        text = ""
        images = []
        status = nil
        saveDraft()
    }

    func pasteImage() -> Bool {
        let pb = NSPasteboard.general
        guard let data = FolioTextView.imageData(in: pb) else { return false }
        images.append(FolioTextView.normalizedImage(data))
        return true
    }
}

struct QuickCaptureView: View {
    @ObservedObject var model: QuickCaptureModel
    var onClose: () -> Void
    @EnvironmentObject var store: NoteStore
    @EnvironmentObject var theme: ThemeManager
    @ObservedObject private var service = CaptureService.shared
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "square.and.pencil").foregroundStyle(theme.accent)
                Picker("Ziel", selection: $model.target) {
                    Text("Inbox").tag(CaptureTarget.inbox)
                    let recent = store.recent.ids.prefix(8).compactMap { id in store.notes.first { $0.id == id } }
                    if !recent.isEmpty {
                        Divider()
                        ForEach(recent, id: \.id) { ref in
                            Text(ref.meta.title.isEmpty ? "Ohne Titel" : ref.meta.title).tag(CaptureTarget.note(ref.id))
                        }
                    }
                }
                .labelsHidden()
                .fixedSize()
                .helpLabel("Wohin die Erfassung kommt")
                Spacer()
                if !service.pending.isEmpty {
                    Label("\(service.pending.count) wartend", systemImage: "clock.arrow.circlepath")
                        .font(.caption).foregroundStyle(.orange)
                        .helpLabel("Erfassungen, die noch nicht gespeichert werden konnten; Folio versucht es weiter.")
                }
            }
            TextEditor(text: $model.text)
                .font(.system(size: 14))
                .scrollContentBackground(.hidden)
                .focused($focused)
                .frame(minHeight: 90)
                .padding(6)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                .onPasteCommand(of: [.png, .tiff, .jpeg, .fileURL]) { _ in _ = model.pasteImage() }
                .accessibilityLabel("Text erfassen")
            if !model.images.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(Array(model.images.enumerated()), id: \.offset) { i, data in
                            if let img = NSImage(data: data) {
                                Image(nsImage: img).resizable().scaledToFit().frame(height: 46)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .overlay(alignment: .topTrailing) {
                                        Button { model.images.remove(at: i) } label: { Image(systemName: "xmark.circle.fill") }
                                            .buttonStyle(.plain).helpLabel("Bild entfernen")
                                    }
                            }
                        }
                    }
                }
            }
            if let status = model.status {
                Text(status.text).font(.caption).foregroundStyle(status.ok ? Color.secondary : Color.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Verwerfen") { model.discard() }
                    .disabled(model.text.isEmpty && model.images.isEmpty)
                    .helpLabel("Text löschen, ohne zu speichern")
                Spacer()
                Text("Esc schließt (Entwurf bleibt)").font(.caption2).foregroundStyle(.tertiary)
                Button("Sichern") { if model.submit() { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { onClose() } } }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .helpLabel("Speichern (⌘↩)")
            }
        }
        .padding(14)
        .padding(.top, 14)
        .frame(minWidth: 380, minHeight: 220)
        .tint(theme.accent)
        .onExitCommand { onClose() }
        .onAppear { focused = true }
        .onChange(of: model.focusToken) { focused = true }
    }
}

// MARK: - Global hotkey (#86)

/// A system-wide shortcut through the Carbon hot key API: it works from any app and needs no
/// accessibility permission. Registering fails when another app already uses the combination.
@MainActor
final class GlobalHotKey {
    static let shared = GlobalHotKey()
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    /// Why the shortcut could not be registered (shown in the settings).
    private(set) var problem: String?

    static let defaultCombo = KeyCombo(key: "n", control: true, option: true, command: true)

    /// Carbon key codes for the keys a hotkey may use.
    static func keyCode(_ key: String) -> UInt32? {
        if let code = KeyCombo.ansiLetters.first(where: { $0.value == key })?.key { return UInt32(code) }
        let special: [String: UInt32] = ["space": 49, "return": 36, "0": 29, "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25]
        return special[key]
    }

    func register(_ combo: KeyCombo?) {
        unregister()
        problem = nil
        guard let combo else { return }
        guard combo.command || combo.control || combo.option else { problem = "Ein globales Kürzel braucht ⌘, ⌃ oder ⌥."; return }
        guard let code = Self.keyCode(combo.key) else { problem = "Diese Taste kann nicht global belegt werden."; return }
        var mods: UInt32 = 0
        if combo.command { mods |= UInt32(cmdKey) }
        if combo.option { mods |= UInt32(optionKey) }
        if combo.control { mods |= UInt32(controlKey) }
        if combo.shift { mods |= UInt32(shiftKey) }
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { QuickCaptureController.shared.show() } }
                return noErr
            }, 1, &spec, nil, &handler)
        }
        let id = EventHotKeyID(signature: OSType(0x464F4C49), id: 1)   // "FOLI"
        let status = RegisterEventHotKey(code, mods, id, GetApplicationEventTarget(), 0, &ref)
        if status != noErr {
            ref = nil
            problem = status == OSStatus(eventHotKeyExistsErr)
                ? "\(combo.display) ist schon von einer anderen App belegt. Wähle ein anderes Kürzel."
                : "Das Kürzel konnte nicht eingerichtet werden (Fehler \(status))."
        }
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }

    var isActive: Bool { ref != nil }
}
