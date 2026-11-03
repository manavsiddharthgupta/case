import SwiftUI

/// Claude's answers in markdown, laid out instead of shown raw: paragraphs, headings, bullet
/// and numbered lists, and code blocks, with bold, italics, code and links inside a line.
/// Font and line spacing come from the surroundings, so it fits a chat or a small bubble.
struct FormattedText: View {
    let text: String

    var body: some View {
        let blocks = Self.blocks(in: text)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(blocks.indices, id: \.self) { index in
                view(for: blocks[index])
                    .padding(.top, index == 0 ? 0 : gap(before: blocks[index], after: blocks[index - 1]))
            }
        }
    }

    @ViewBuilder
    private func view(for block: Block) -> some View {
        switch block {
        case .paragraph(let line):
            Text(Self.inline(line))
                .fixedSize(horizontal: false, vertical: true)
        case .heading(let line):
            Text(Self.inline(line))
                .fontWeight(.semibold)
                .fixedSize(horizontal: false, vertical: true)
        case .item(let marker, let line, let depth):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker)
                    .foregroundStyle(Theme.muted)
                    .monospacedDigit()
                Text(Self.inline(line))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(depth) * 18)
        case .code(let code):
            Text(code)
                .font(.system(size: 12.5, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.card, in: .rect(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
        }
    }

    /// List items sit close together; everything else gets room to breathe.
    private func gap(before block: Block, after previous: Block) -> CGFloat {
        if case .item = block, case .item = previous { return 5 }
        if case .heading = block { return 16 }
        return 11
    }

    // MARK: - Parsing

    enum Block {
        case paragraph(String)
        case heading(String)
        case item(marker: String, text: String, depth: Int)
        case code(String)
    }

    /// Splits the answer into blocks a line at a time. It copes with half-streamed text:
    /// an unclosed code fence is shown as code so far.
    static func blocks(in text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var code: [String]?

        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            paragraph = []
        }

        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if let lines = code {
                    blocks.append(.code(lines.joined(separator: "\n")))
                    code = nil
                } else {
                    flush()
                    code = []
                }
                continue
            }
            if code != nil {
                code?.append(line)
                continue
            }
            if trimmed.isEmpty {
                flush()
                continue
            }
            let depth = min(line.prefix { $0 == " " || $0 == "\t" }.count / 2, 3)
            if let match = trimmed.wholeMatch(of: /#{1,6}\s+(.+)/) {
                flush()
                blocks.append(.heading(String(match.1)))
            } else if let match = trimmed.wholeMatch(of: /[-*•]\s+(.+)/) {
                flush()
                blocks.append(.item(marker: "–", text: String(match.1), depth: depth))
            } else if let match = trimmed.wholeMatch(of: /(\d+)[.)]\s+(.+)/) {
                flush()
                blocks.append(.item(marker: "\(match.1).", text: String(match.2), depth: depth))
            } else if paragraph.isEmpty, depth > 0, case .item(let marker, let item, let itemDepth)? = blocks.last {
                // An indented line under a list item carries that item on.
                blocks[blocks.count - 1] = .item(marker: marker, text: item + " " + trimmed, depth: itemDepth)
            } else {
                paragraph.append(trimmed)
            }
        }
        flush()
        if let code { blocks.append(.code(code.joined(separator: "\n"))) }
        return blocks
    }

    /// Bold, italics, code and links within a line. Anything it can't read stays as typed.
    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
