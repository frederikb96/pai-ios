import Foundation
import PAIKit
import UIKit

/// A note made ready for the text view: its painted text and its line index, built together.
///
/// A value so it can be built away from the main thread, which is what keeps opening a very large
/// note from freezing the screen. Nothing shares the attributed string until the text view takes
/// its own copy, which is what the unchecked conformance rests on.
struct NoteEditorDocument: @unchecked Sendable {
    let attributed: NSAttributedString
    let index: MarkdownDocumentIndex

    init(text: String, showsHangingIndent: Bool) {
        let painted = NSMutableAttributedString(string: text)
        let index = MarkdownDocumentIndex(text: painted.mutableString)
        NoteEditorTheme.paint(
            painted, in: NSRange(location: 0, length: painted.length), index: index, text: painted.mutableString,
            showsHangingIndent: showsHangingIndent)
        attributed = painted
        self.index = index
    }
}

/// The owner side of a live editor: what has to outlast the view or reach into it.
///
/// A class the screen keeps, because SwiftUI does not guarantee one `UITextView` across a screen
/// being covered and revealed, and because the screen must be able to ask for the text still in
/// the view at the moments it saves.
@MainActor
final class NoteEditorHandle {
    /// Hands anything typed since the last publish to the store at once.
    var publishPending: () -> Void = {}
    /// Where the reader was, restored whenever a text view is built for this note.
    var offsetY: CGFloat = 0
}

/// Text to place into the note. Tokenised for the same reason ``CaretRequest`` is.
struct NoteInsertion: Equatable {
    let token: Int
    /// A UTF-16 offset into the note's whole source.
    let offset: Int
    let snippet: String
}
