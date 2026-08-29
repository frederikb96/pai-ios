import Foundation

@testable import PAIKit

/// A deterministic, real-computation stand-in for the TextKit measurer this package cannot
/// contain. It is honest about what it can and cannot prove: everything about *composing and
/// caching* heights is exercised faithfully, because that machinery genuinely does not care what
/// the numbers mean. Nothing about whether the numbers a real measurer would produce are
/// plausible, or whether a GFM table actually lays out the way `MessageContentLayoutComposer`
/// expects, is proven here — that stays unverified until this runs on Apple hardware.
///
/// The formula is deliberately simple and deliberately sensitive to all three inputs, so a test
/// that varies width, environment or block content sees the height actually change: a stub that
/// always returned the same number would let every cache-key test pass by coincidence rather
/// than by exercising the key.
final class StubBlockMeasurer: BlockMeasuring, @unchecked Sendable {
    private let lock = NSLock()
    private var _callCount = 0

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _callCount
    }

    func height(of block: MarkdownBlock, width: Double, environment: MeasurementEnvironment) -> Double {
        lock.lock()
        _callCount += 1
        lock.unlock()

        let lineHeight = 20.0 + Double(environment.sizeCategoryToken.count)
        let charsPerLine = max(width, 1)
        let charCount = Double(block.plainText.count)
        let lines = (charCount / charsPerLine).rounded(.up)
        return max(lines, 1) * lineHeight
    }
}
