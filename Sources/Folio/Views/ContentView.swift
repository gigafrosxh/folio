import SwiftUI

/// Main window: a floating sidebar panel, the note list and the editor "paper", laid out like the mockups
/// instead of a stock split view so every part can float.
struct ContentView: View {
    @EnvironmentObject var store: NoteStore
    @EnvironmentObject var theme: ThemeManager
    @AppStorage("folio.sidebarVisible") private var sidebarVisible = true
    @AppStorage("folio.listWidth") private var listWidth: Double = 300
    @StateObject private var windowState = WindowState()
    @State private var showUpdates = false
    @State private var quickOpen: QuickOpenMode?

    var body: some View {
        HStack(spacing: 0) {
            if sidebarVisible {
                SidebarView()
                    .frame(width: 240)
                    .padding(.trailing, 12)
                    .transition(Motion.enabled ? .move(edge: .leading).combined(with: .opacity) : .identity)
            }
            if store.sidebarSelection == .trash {
                TrashView(sidebarVisible: $sidebarVisible)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .panel(theme: theme, fill: Color(nsColor: .textBackgroundColor))
            } else if store.sidebarSelection == .damaged {
                DamagedListView(sidebarVisible: $sidebarVisible)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .panel(theme: theme, fill: Color(nsColor: .textBackgroundColor))
            } else {
                NoteListView(sidebarVisible: $sidebarVisible)
                    .frame(width: CGFloat(listWidth))
                    .frame(maxHeight: .infinity)
                    .panel(theme: theme)
                ColumnResizer(width: $listWidth, range: 240...460)
                editor
                    .animation(Motion.quick, value: store.currentDocument?.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .panel(theme: theme, fill: Color(nsColor: .textBackgroundColor))
            }
        }
        .padding(12)
        .background(AmbientBackground(accent: theme.accent))
        .background(WindowAccessor(window: $windowState.window))
        .environmentObject(windowState)
        .fontDesign(.rounded)
        .ignoresSafeArea()
        .animation(Motion.standard, value: sidebarVisible)
        .onReceive(NotificationCenter.default.publisher(for: .folioToggleSidebar)) { _ in sidebarVisible.toggle() }
        .onReceive(NotificationCenter.default.publisher(for: .folioShowUpdates)) { _ in showUpdates = true }
        .onReceive(UpdateManager.shared.$state) { state in
            // A background check that finds a new version brings up the update sheet.
            if case .available = state, !showUpdates, ThemeManager.shared.settings.askForUpdatesOnLaunch { showUpdates = true }
        }
        .overlay(alignment: .top) {
            if let mode = quickOpen {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.18).ignoresSafeArea().onTapGesture { quickOpen = nil }
                    QuickOpenView(mode: mode) { quickOpen = nil }
                        .padding(.top, 90)
                        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
                }
            }
        }
        .animation(Motion.quick, value: quickOpen)
        .onReceive(NotificationCenter.default.publisher(for: .folioQuickOpen)) { note in
            quickOpen = (note.object as? QuickOpenMode) ?? .open
        }
        .sheet(isPresented: $showUpdates) { UpdateSheet() }
        .sheet(item: $store.conflict) { conflict in
            ConflictSheet(conflict: conflict).environmentObject(store).environmentObject(theme)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.checkExternalChange()
        }
        .alert("Fehler", isPresented: Binding(get: { store.lastError != nil }, set: { if !$0 { store.lastError = nil } })) {
            Button("OK") {}
        } message: {
            Text(store.lastError ?? "")
        }
    }

    @ViewBuilder
    private var editor: some View {
        if let damaged = store.openFailure {
            DamagedNoteView(damaged: damaged)
        } else if let doc = store.currentDocument {
            NoteEditorView(doc: doc)
                // A reloaded note (restored version, external change) is a new document with the same id.
                .id(ObjectIdentifier(doc))
                .transition(Motion.enabled ? .opacity.combined(with: .offset(y: 8)) : .identity)
        } else {
            ZStack {
                VStack(spacing: 14) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("Keine Notiz ausgewählt").font(.title3.weight(.semibold))
                    Text("Wähle eine Notiz oder lege eine neue an.").foregroundStyle(.secondary)
                    Button {
                        store.createNote(initialTag: currentTag)
                    } label: {
                        Label("Neue Notiz", systemImage: "plus").padding(.horizontal, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                .padding(32)
                .floating()
            }
        }
    }

    private var currentTag: String? {
        if case .tag(let t) = store.sidebarSelection { return t }
        return nil
    }
}

/// Thin draggable divider between the note list and the editor.
struct ColumnResizer: View {
    @Binding var width: Double
    var range: ClosedRange<Double>
    @State private var start: Double?

    var body: some View {
        Color.clear
            .frame(width: 12)
            .contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { v in
                    if start == nil { start = width }
                    width = min(max((start ?? width) + v.translation.width, range.lowerBound), range.upperBound)
                }
                .onEnded { _ in start = nil })
    }
}

extension Notification.Name {
    static let folioToggleSidebar = Notification.Name("folio.toggleSidebar")
    static let folioShowUpdates = Notification.Name("folio.showUpdates")
}

extension View {
    /// A floating, rounded, shadowed panel used for the note list and the editor.
    func panel(theme: ThemeManager, fill: Color? = nil) -> some View {
        let radius = CGFloat(theme.settings.cornerRadius) + 4
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return self
            .background(fill ?? Color(nsColor: .windowBackgroundColor).opacity(0.92), in: shape)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(0.09), lineWidth: 1))
            .shadow(color: .black.opacity(theme.settings.shadows ? 0.25 : 0), radius: 22, y: 10)
    }
}
