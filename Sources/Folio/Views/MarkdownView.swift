import SwiftUI

/// Renders Markdown with block structure (headings, lists, code blocks, quotes, rules) and inline
/// formatting (bold, italic, `code`, links). Enough for release notes and changelogs.
struct MarkdownView: View {
    var markdown: String

    private enum Block: Hashable {
        case heading(Int, String)
        case bullet(Int, String)
        case numbered(String, String)
        case code(String)
        case quote(String)
        case rule
        case paragraph(String)
    }

    private var blocks: [Block] {
        var out: [Block] = []
        var paragraph: [String] = []
        var code: [String]? = nil
        func flush() {
            if !paragraph.isEmpty { out.append(.paragraph(paragraph.joined(separator: " "))); paragraph = [] }
        }
        for raw in markdown.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let c = code { out.append(.code(c.joined(separator: "\n"))); code = nil } else { flush(); code = [] }
                continue
            }
            if code != nil { code!.append(raw); continue }
            if line.isEmpty { flush(); continue }
            let indent = raw.prefix { $0 == " " }.count / 2
            if let m = line.range(of: #"^#{1,6} "#, options: .regularExpression) {
                flush(); out.append(.heading(line[m].count - 1, String(line[m.upperBound...])))
            } else if line == "---" || line == "***" {
                flush(); out.append(.rule)
            } else if let m = line.range(of: #"^[-*+] "#, options: .regularExpression) {
                flush(); out.append(.bullet(indent, String(line[m.upperBound...])))
            } else if let m = line.range(of: #"^\d+[.)] "#, options: .regularExpression) {
                flush(); out.append(.numbered(String(line[m].dropLast()), String(line[m.upperBound...])))
            } else if line.hasPrefix(">") {
                flush(); out.append(.quote(String(line.dropFirst()).trimmingCharacters(in: .whitespaces)))
            } else {
                paragraph.append(line)
            }
        }
        if let c = code { out.append(.code(c.joined(separator: "\n"))) }
        flush()
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func view(for block: Block) -> some View {
        switch block {
        case .heading(let level, let text):
            inline(text)
                .font(level <= 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                .padding(.top, level <= 2 ? 8 : 4)
        case .bullet(let indent, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(indent == 0 ? "•" : "◦").foregroundStyle(.secondary)
                inline(text).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(indent) * 16 + 4)
        case .numbered(let number, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(number).monospacedDigit().foregroundStyle(.secondary)
                inline(text).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 4)
        case .code(let code):
            Text(code)
                .font(.system(size: 11.5, design: .monospaced))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        case .quote(let text):
            inline(text)
                .foregroundStyle(.secondary)
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(Color.secondary.opacity(0.4)).frame(width: 3) }
        case .rule:
            Divider()
        case .paragraph(let text):
            inline(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func inline(_ text: String) -> Text {
        if let attributed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attributed)
        }
        return Text(text)
    }
}
