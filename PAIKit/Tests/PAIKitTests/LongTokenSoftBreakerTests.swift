import XCTest
@testable import PAIKit

final class LongTokenSoftBreakerTests: XCTestCase {

    func testOrdinaryProseComesBackUnchanged() {
        let text = "This is an ordinary sentence with normal words, nothing to break."
        let (result, insertions) = LongTokenSoftBreaker.apply(to: text)
        XCTAssertEqual(result, text)
        XCTAssertTrue(insertions.isEmpty)
    }

    /// The one shape this exists for: a single unbroken run with nowhere for ordinary
    /// word-wrapping to break.
    func testALongUnbrokenRunGetsASoftBreakEveryThreshold() {
        let token = String(repeating: "a", count: LongTokenSoftBreaker.breakEvery * 2)
        let (result, insertions) = LongTokenSoftBreaker.apply(to: token)
        XCTAssertEqual(insertions.count, 2)
        XCTAssertEqual(result.unicodeScalars.filter { $0.value == 0x200B }.count, 2)
        // Stripping the soft breaks back out must recover the original text exactly.
        XCTAssertEqual(result.replacingOccurrences(of: "\u{200B}", with: ""), token)
    }

    /// Whitespace resets the run — two ordinary words either side of threshold length never gain
    /// a break neither individually crosses.
    func testWhitespaceResetsTheRunLength() {
        let word = String(repeating: "b", count: LongTokenSoftBreaker.breakEvery - 1)
        let text = "\(word) \(word)"
        let (result, insertions) = LongTokenSoftBreaker.apply(to: text)
        XCTAssertEqual(result, text)
        XCTAssertTrue(insertions.isEmpty)
    }

    /// A run exactly at the threshold gets a break right after it, not withheld for a
    /// possibly-longer run that never materializes.
    func testARunExactlyAtTheThresholdGetsOneBreakImmediatelyAfter() {
        let token = String(repeating: "c", count: LongTokenSoftBreaker.breakEvery)
        let (result, insertions) = LongTokenSoftBreaker.apply(to: token)
        XCTAssertEqual(insertions, [LongTokenSoftBreaker.breakEvery])
        XCTAssertEqual(result, token + "\u{200B}")
    }

    // MARK: - remap

    func testRemapIsANoOpWhenNothingWasInserted() {
        let range = NSRange(location: 3, length: 5)
        XCTAssertEqual(LongTokenSoftBreaker.remap(range, insertionOffsets: []), range)
    }

    /// A highlight entirely before the first insertion is untouched.
    func testRemapLeavesARangeBeforeEveryInsertionUnchanged() {
        let range = NSRange(location: 0, length: 3)
        XCTAssertEqual(LongTokenSoftBreaker.remap(range, insertionOffsets: [10, 20]), range)
    }

    /// A highlight entirely after an insertion shifts forward by however many insertions precede
    /// it, without changing its own length.
    func testRemapShiftsARangeAfterEveryInsertionForward() {
        let range = NSRange(location: 12, length: 2)
        let remapped = LongTokenSoftBreaker.remap(range, insertionOffsets: [4, 8])
        XCTAssertEqual(remapped, NSRange(location: 14, length: 2))
    }

    /// A highlight straddling exactly where a break landed widens by one to still cover the same
    /// original characters, now with an invisible character sitting between them.
    func testRemapWidensARangeThatStraddlesAnInsertion() {
        // insertion recorded at original offset 4 means "one character now sits at index 4"
        let range = NSRange(location: 3, length: 2)  // covers original indices 3,4
        let remapped = LongTokenSoftBreaker.remap(range, insertionOffsets: [4])
        XCTAssertEqual(remapped, NSRange(location: 3, length: 3))
    }

    /// An insertion exactly at a range's own end boundary belongs to whatever comes after it, not
    /// to this range.
    func testRemapExcludesAnInsertionExactlyAtTheRangesEndBoundary() {
        let range = NSRange(location: 0, length: 4)  // covers original indices 0...3
        let remapped = LongTokenSoftBreaker.remap(range, insertionOffsets: [4])
        XCTAssertEqual(remapped, NSRange(location: 0, length: 4))
    }

    /// End-to-end: remapping a highlight range against `apply(to:)`'s own output lands on exactly
    /// the substring the original range named.
    func testRemappedRangeLandsOnTheSameSubstringInTheTransformedText() {
        let token = String(repeating: "d", count: LongTokenSoftBreaker.breakEvery + 4)
        let original = "see \(token) here"
        let targetSubstring = "here"
        let originalRange = (original as NSString).range(of: targetSubstring)

        let (transformed, insertions) = LongTokenSoftBreaker.apply(to: original)
        let remapped = LongTokenSoftBreaker.remap(originalRange, insertionOffsets: insertions)

        let substring = (transformed as NSString).substring(with: remapped)
        XCTAssertEqual(substring, targetSubstring)
    }

    /// An insertion landing exactly on a hit's first character.
    ///
    /// The `<=` in `remap`'s `before` filter is what decides this, and the whole suite stayed
    /// green with it weakened to `<` — every other case puts insertions strictly inside or
    /// strictly before a range, so none of them can tell the two apart. It is not a hypothetical
    /// input either: a 24-character boundary falling on the start of a match inside an unbroken
    /// run is a hit in the middle of exactly the long URL this transform exists for.
    func testAHitStartingExactlyOnAnInsertionBoundaryStillLandsOnItsOwnText() async {
        let original = String(repeating: "x", count: 24) + "NEEDLE"
        let result = LongTokenSoftBreaker.apply(to: original)
        let needle = NSRange(location: 24, length: 6)
        let moved = LongTokenSoftBreaker.remap(needle, insertionOffsets: result.insertionOffsets)

        let transformed = result.text as NSString
        XCTAssertEqual(transformed.substring(with: moved), "NEEDLE")
    }
}
