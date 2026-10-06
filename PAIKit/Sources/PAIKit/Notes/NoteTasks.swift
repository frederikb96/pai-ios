import Foundation
import Markdown

/// Where one drawn task box lives in the note's body: the UTF-8 offset of the character between
/// its brackets, and whether it is ticked.
public struct NoteTaskMark: Equatable, Sendable {
    public let offset: Int
    public let checked: Bool

    public init(offset: Int, checked: Bool) {
        self.offset = offset
        self.checked = checked
    }
}

/// What a tick in a rendered note writes to.
///
/// Swift port of the web's `bodyTasks` / `renderNote` matching (`notePipeline.ts`) and
/// `toggleTaskAt` (`noteEditing.ts`). A wrong offset ticks some other line, so a box is only
/// ever tied to a place in the body when the body's own parse and the drawn page agree on every
/// box, in order; otherwise nothing is tickable.
public enum NoteTasks {

    /// The body's own task items in document order, located by one parse of the whole body.
    /// `nil` when any of them cannot be found in the source.
    public static func bodyMarks(in body: String) -> [NoteTaskMark]? {
        let bytes = Array(body.utf8)
        var lineStarts = [0]
        for (index, byte) in bytes.enumerated() where byte == 0x0A { lineStarts.append(index + 1) }

        var marks: [NoteTaskMark] = []
        var lost = false
        func walk(_ markup: Markup) {
            if let item = markup as? ListItem, let checkbox = item.checkbox {
                guard let start = item.range?.lowerBound,
                    start.line >= 1, start.line <= lineStarts.count,
                    let state = stateOffset(in: bytes, itemStart: lineStarts[start.line - 1] + start.column - 1)
                else {
                    lost = true
                    return
                }
                marks.append(NoteTaskMark(offset: state, checked: checkbox == .checked))
            }
            for child in markup.children { walk(child) }
        }
        walk(Document(parsing: body, options: MarkdownParser.defaultOptions))
        return lost ? nil : marks
    }

    /// `marker whitespace [ state ]` from where a list item starts — the offset of `state`.
    private static func stateOffset(in bytes: [UInt8], itemStart: Int) -> Int? {
        guard itemStart >= 0, itemStart < bytes.count else { return nil }
        var i = itemStart
        if [0x2D, 0x2A, 0x2B].contains(bytes[i]) {
            i += 1
        } else {
            let digitsStart = i
            while i < bytes.count, (0x30...0x39).contains(bytes[i]) { i += 1 }
            guard i > digitsStart, i < bytes.count, bytes[i] == 0x2E || bytes[i] == 0x29 else { return nil }
            i += 1
        }
        let gapStart = i
        while i < bytes.count, bytes[i] == 0x20 || bytes[i] == 0x09 { i += 1 }
        guard i > gapStart, i + 2 < bytes.count, bytes[i] == 0x5B, bytes[i + 2] == 0x5D,
            [0x20, 0x78, 0x58].contains(bytes[i + 1])
        else { return nil }
        return i + 1
    }

    /// How many task boxes a block draws, nested ones included.
    public static func boxCount(in block: MarkdownBlock) -> Int {
        switch block {
        case .blockQuote(let blocks): return blocks.reduce(0) { $0 + boxCount(in: $1) }
        case .list(let list): return list.items.reduce(0) { $0 + boxCount(in: $1) }
        default: return 0
        }
    }

    /// A list item's own box, if it has one, plus every box beneath it.
    public static func boxCount(in item: MarkdownListItem) -> Int {
        (item.checkbox == nil ? 0 : 1) + item.blocks.reduce(0) { $0 + boxCount(in: $1) }
    }

    /// Each drawn box's state, in drawing order: an item's own box before the boxes inside it.
    public static func drawnStates(in blocks: [MarkdownBlock]) -> [Bool] {
        var states: [Bool] = []
        func visit(_ block: MarkdownBlock) {
            switch block {
            case .blockQuote(let nested): nested.forEach(visit)
            case .list(let list):
                for item in list.items {
                    if let checkbox = item.checkbox { states.append(checkbox == .checked) }
                    item.blocks.forEach(visit)
                }
            default: break
            }
        }
        blocks.forEach(visit)
        return states
    }

    /// The ordinal of the first box each of `blocks` draws, given that the first of them starts
    /// at `base`.
    public static func starts(of blocks: [MarkdownBlock], from base: Int) -> [Int] {
        var next = base
        return blocks.map { block in
            defer { next += boxCount(in: block) }
            return next
        }
    }

    /// The ordinal of each list item's own box (or, for an ordinary item, of the first box
    /// beneath it), given that the list's first box has ordinal `base`.
    public static func starts(of items: [MarkdownListItem], from base: Int) -> [Int] {
        var next = base
        return items.map { item in
            defer { next += boxCount(in: item) }
            return next
        }
    }

    /// The marks the drawn page may use: the body's own, but only when they agree with `drawn`
    /// on every box in order. Empty means nothing is tickable.
    public static func marks(in body: String, drawn: [Bool]) -> [NoteTaskMark] {
        guard let marks = bodyMarks(in: body), marks.map(\.checked) == drawn else { return [] }
        return marks
    }

    /// `body` with the box at `mark` flipped, or `nil` when `body` no longer holds a box in the
    /// state `mark` describes at that offset — which is what a body changed since it was drawn
    /// looks like. The tap is then dropped rather than landing on whatever moved under it.
    public static func toggled(_ body: String, mark: NoteTaskMark) -> String? {
        var bytes = Array(body.utf8)
        let offset = mark.offset
        guard offset >= 1, offset + 1 < bytes.count, bytes[offset - 1] == 0x5B, bytes[offset + 1] == 0x5D else {
            return nil
        }
        let current = bytes[offset]
        if mark.checked ? (current != 0x78 && current != 0x58) : current != 0x20 { return nil }
        bytes[offset] = mark.checked ? 0x20 : 0x78
        return String(decoding: bytes, as: UTF8.self)
    }
}
