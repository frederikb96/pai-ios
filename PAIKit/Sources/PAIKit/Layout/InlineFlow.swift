import Foundation

/// Lays pieces out left to right like words in a line, starting a new row when the next one does
/// not fit — the arithmetic behind the note preview's run of text and attachment chips
/// (`PAI/Notes/NoteBodyView.swift`'s `NoteInlineFlowLayout`), kept here so it can be proven
/// without an Apple framework.
///
/// A piece that does not fit the rest of its row starts the next one, and a piece wider than a
/// whole row is offered the width left to it and wraps there, the way a long text does. Pieces in
/// a row are centred on each other vertically.
public enum InlineFlow {
    public struct Frame: Equatable, Sendable {
        public let x: Double
        public let y: Double
        public let width: Double
        public let height: Double
    }

    /// - Parameters:
    ///   - count: how many pieces there are.
    ///   - width: the width a row may take; `.infinity` lays everything out on one row.
    ///   - measure: a piece's size when offered a width, or its ideal size for `nil`.
    /// - Returns: one frame per piece, and the size of the whole run.
    public static func arrange(
        count: Int, width: Double, spacing: Double, lineSpacing: Double,
        measure: (_ index: Int, _ proposedWidth: Double?) -> (width: Double, height: Double)
    ) -> (frames: [Frame], width: Double, height: Double) {
        var placed: [(x: Double, width: Double, height: Double, row: Int)] = []
        var rowHeights: [Double] = []
        var x = 0.0
        var widest = 0.0

        for index in 0..<count {
            var size = measure(index, nil)
            if x > 0, x + size.width > width {
                x = 0
                rowHeights.append(0)
            }
            if rowHeights.isEmpty { rowHeights.append(0) }
            if size.width > width - x { size = measure(index, width - x) }
            placed.append((x: x, width: size.width, height: size.height, row: rowHeights.count - 1))
            rowHeights[rowHeights.count - 1] = max(rowHeights[rowHeights.count - 1], size.height)
            widest = max(widest, x + size.width)
            x += size.width + spacing
        }

        var rowTops: [Double] = []
        var top = 0.0
        for height in rowHeights {
            rowTops.append(top)
            top += height + lineSpacing
        }
        let frames = placed.map { piece in
            Frame(
                x: piece.x, y: rowTops[piece.row] + (rowHeights[piece.row] - piece.height) / 2,
                width: piece.width, height: piece.height)
        }
        let height = rowHeights.isEmpty ? 0 : top - lineSpacing
        return (frames, widest, height)
    }
}
