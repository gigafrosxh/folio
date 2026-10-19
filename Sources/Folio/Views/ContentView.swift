import SwiftUI

/// Main window: a floating sidebar panel, the note list and the editor "paper", laid out like the mockups
/// instead of a stock split view so every part can float.
struct ContentView: View {
    @EnvironmentObject var store: NoteStore
    @EnvironmentObject var theme: ThemeManager
    @AppStorage("folio.sidebarVisible") private var sidebarVisible = true
    @AppStorage("folio.listWidth") private var listWidth: Double = 300

    var body: some View {
        HStack(spacing: 0) {
            if sidebarVisible {
                SidebarView()
                    .frame(width: 240)
                    .padding(10)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            NoteListView(sidebarVisible: $sidebarVisible)
                .frame(width: CGFloat(listWidth))
                .padding(.leading, sidebarVisible ? 0 : 76)
            ColumnResizer(width: $listWidth, range: 240...460)
            editor
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 14, bottomLeadingRadius: 14, style: .continuous))
                .shadow(color: .black.opacity(theme.settings.shadows ? 0.08 : 0), radius: 12, x: -2)
                .padding(.vertical, 0)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .ignoresSafeArea()
        .animation(.snappy(duration: 0.25), value: sidebarVisible)
        .onReceive(NotificationCenter.default.publisher(for: .folioToggleSidebar)) { _ in sidebarVisible.toggle() }
        .alert("Fehler", isPresented: Binding(get: { store.lastError != nil }, set: { if !$0 { store.lastError = nil } })) {
            Button("OK") {}
        } message: {
            Text(store.lastError ?? "")
        }
    }

    @ViewBuilder
    private var editor: some View {
        if let doc = store.currentDocument {
            NoteEditorView(doc: doc)
                .id(doc.id)
        } else {
            ZStack {
                Color(nsColor: .textBackgroundColor)
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
            .frame(width: 6)
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
}
