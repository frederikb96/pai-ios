import Foundation
import Testing

@testable import PAIKit

@Suite("Paste markers")
struct PasteMarkersTests {

    @Test("Numbering continues past a marker whose file was removed")
    func continuesPastOrphanedMarker() {
        #expect(PasteMarkers.nextNumber(text: "see [📎 paste-1] and [📎 paste-4]", filenames: ["paste-2.png"]) == 5)
    }

    /// Another device's upload comes back under the VM's stamped name.
    @Test("Numbering continues past a file whose marker was deleted, as the server names it")
    func continuesPastOrphanedFile() {
        let names = ["2026-10-22T14-00-00-000000-paste-7.png"]
        #expect(PasteMarkers.nextNumber(text: "only [📎 paste-1]", filenames: names) == 8)
    }

    @Test("A picked file that merely contains the word does not count")
    func ignoresLookalikeName() {
        #expect(PasteMarkers.nextNumber(text: "", filenames: ["copy-paste-3-notes.pdf", "photo.jpg"]) == 1)
    }

    @Test("Several images in one paste number on consecutively, each keeping its own extension")
    func severalImagesInOnePaste() {
        let named = PasteMarkers.name(
            ["pasted-image-1.png", "pasted-image-2.jpeg"], text: "[📎 paste-2]", filenames: [])
        #expect(named.filenames == ["paste-3.png", "paste-4.jpeg"])
        #expect(named.markers == "[📎 paste-3] [📎 paste-4]")
    }

    @Test("The marker replaces the selection and never fuses with a neighbouring word")
    func insertPadsAgainstWords() {
        let placed = PasteMarkers.insert(
            "[📎 paste-1]", into: "look atTHISnow", replacing: NSRange(location: 7, length: 4))
        #expect(placed.text == "look at [📎 paste-1] now")
        #expect((placed.text as NSString).substring(to: placed.caret) == "look at [📎 paste-1]")
    }

    /// The caret offset is UTF-16, as `UITextView` reads it; text before the paste carrying an
    /// emoji is where a `Character` count would land the caret in the wrong place.
    @Test("The caret lands past the marker after text with wide characters")
    func caretIsUtf16() {
        let placed = PasteMarkers.insert("M", into: "🙂 x", replacing: NSRange(location: 4, length: 0))
        #expect(placed.text == "🙂 x M")
        #expect((placed.text as NSString).substring(to: placed.caret) == "🙂 x M")
    }

    /// The text view applies this through `replace(_:withText:)` over exactly this range, so the
    /// range must be the selection (clamped) and the replacement carry the padding.
    @Test("The planned edit replaces only the selection and carries the padding")
    func editReplacesOnlyTheSelection() {
        let planned = PasteMarkers.edit("M", in: "look atTHISnow", replacing: NSRange(location: 7, length: 4))
        #expect(planned.range == NSRange(location: 7, length: 4))
        #expect(planned.replacement == " M ")
        #expect(planned.caret == 9)

        let spaced = PasteMarkers.edit("M", in: "a  b", replacing: NSRange(location: 2, length: 0))
        #expect(spaced.replacement == "M")
    }
}
