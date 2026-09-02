import PAIKit
import SwiftUI

/// The line-number gutter beside a note's source — Obsidian's own look: dim numbers, no
/// background band or separator, right-aligned against the text.
///
/// Drawn as an ordinary sibling in the page's own `ScrollView` rather than a synced overlay —
/// see `NoteEditorSurface`'s own doc comment for why that removes the scroll-tracking problem a
/// gutter would otherwise need to solve. Every number sits at the y-offset TextKit already
/// computed for its line's first visual row, so a wrapped line's continuation carries no number
/// of its own — the same thing Obsidian's own gutter does.
struct NoteLineNumberGutter: View {
    let metrics: NoteLineMetrics

    static let width: CGFloat = 32

    private static let font: Font = .system(size: 13, weight: .regular, design: .monospaced)

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ForEach(metrics.lines, id: \.lineNumber) { line in
                Text("\(line.lineNumber)")
                    .font(Self.font)
                    .foregroundStyle(PaiPalette.Notes.muted)
                    .offset(y: line.y)
            }
        }
        .frame(width: Self.width, height: max(metrics.contentHeight, 0), alignment: .topTrailing)
        .padding(.top, MarkdownSourceTextView.verticalInset)
        .padding(.trailing, 6)
        // A gutter number is chrome describing the text, not text itself — VoiceOver and a
        // selection both skip straight to the note.
        .accessibilityHidden(true)
    }
}
