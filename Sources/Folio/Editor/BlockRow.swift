import AppKit
import ImagePlayground
import SwiftUI
import UniformTypeIdentifiers
import FolioCore

/// One block in the editor. Non-text blocks get floating controls in a gutter on the left; the gutter is
/// part of the hover area, so the controls stay put while the pointer moves onto them.
struct BlockRow: View {
    static let gutter: CGFloat = 40

    @ObservedObject var block: BlockModel
    @ObservedObject var doc: NoteDocument
    var isFirst: Bool
    var actions: EditorActions
    @EnvironmentObject var theme: ThemeManager
    @State private var height: CGFloat = 24
    @State private var hovering = false
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ZStack(alignment: .topLeading) {
                Color.clear
                if block.kind != .text && hovering {
                    blockControls
                        .padding(.top, 6)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .frame(width: Self.gutter)
            content
        }
        .contentShape(Rectangle())
        .zIndex(block.kind == .text ? 1 : 0)
        .onHover(perform: setHover)
        .contextMenu {
            if block.kind != .text {
                Button("Nach oben") { doc.move(block.id, by: -1) }
                Button("Nach unten") { doc.move(block.id, by: 1) }
                Divider()
                Button("Entfernen", role: .destructive) { doc.remove(block.id) }
            }
        }
        .animation(Motion.quick, value: hovering)
    }

    /// Hides the controls with a short delay so they don't vanish while the pointer crosses a gap.
    private func setHover(_ inside: Bool) {
        hideTask?.cancel()
        if inside {
            hovering = true
        } else {
            hideTask = Task {
                try? await Task.sleep(for: .milliseconds(450))
                if !Task.isCancelled { hovering = false }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch block.kind {
        case .text:
            RichTextView(block: block, isFirstBlock: isFirst, height: $height, theme: theme,
                         onChange: { doc.markDirty() },
                         onFocus: {
                             FormattingController.shared.didFocus(FormattingController.shared.textView(for: block.id), blockID: block.id)
                         },
                         onDeleteEmpty: { deleteEmptyText() },
                         onPasteFiles: { actions.pasteFiles($0, block.id) },
                         onPasteImage: { actions.pasteImage($0, block.id) },
                         onPasteURL: { actions.pasteURL($0, block.id) })
                .frame(height: height)
        case .code:
            CodeBlockView(block: block, doc: doc)
        case .pdf:
            PDFBlockView(block: block, doc: doc)
        case .web:
            WebBlockView(block: block, doc: doc)
        case .image:
            ImageBlockView(block: block, doc: doc)
        case .file:
            FileBlockView(block: block, doc: doc)
        case .drawing:
            DrawingBlockView(block: block, doc: doc)
        case .database:
            DatabaseBlockView(block: block, doc: doc)
        case .math:
            RenderedBlockView(block: block, doc: doc, kind: .math)
        case .diagram:
            RenderedBlockView(block: block, doc: doc, kind: .diagram)
        case .audio:
            AudioBlockView(block: block, doc: doc)
        }
    }

    private var blockControls: some View {
        VStack(spacing: 2) {
            control("chevron.up", "Nach oben") { doc.move(block.id, by: -1) }
            control("chevron.down", "Nach unten") { doc.move(block.id, by: 1) }
            Divider().frame(width: 16).padding(.vertical, 2)
            control("trash", "Entfernen", destructive: true) { doc.remove(block.id) }
        }
        .padding(4)
        .floating(cornerRadius: 10)
    }

    private func control(_ icon: String, _ help: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 24, height: 24)
                .foregroundStyle(destructive ? Color.red : Color.primary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func deleteEmptyText() {
        guard let i = doc.blocks.firstIndex(where: { $0.id == block.id }), i > 0 else { return }
        let previous = doc.blocks[i - 1]
        if previous.kind == .text {
            doc.remove(block.id)
            FormattingController.shared.focus(blockID: previous.id)
        } else if i >= 2, doc.blocks[i - 2].kind == .text {
            FormattingController.shared.focus(blockID: doc.blocks[i - 2].id)
        }
    }
}
