import XCTest

@testable import PAIKit

/// These target the property the cache exists for — measuring a block once — rather than the
/// arithmetic of any one height. A test that only checked returned values would pass identically
/// whether or not caching happened at all; every test here instead asserts on the measurer's call
/// count, which is the one observable a caching regression actually breaks.
final class BlockHeightCacheTests: XCTestCase {

    private let environment = MeasurementEnvironment(sizeCategoryToken: "L")
    private let block = MarkdownBlock.paragraph(InlineText(runs: [InlineRun(text: "hello world")]))

    // MARK: - The core promise: measured once

    func testRepeatedLookupOfTheSameKeyMeasuresOnlyOnce() {
        let measurer = StubBlockMeasurer()
        let cache = BlockHeightCache()

        let first = cache.height(of: block, width: 300, environment: environment, measurer: measurer)
        let second = cache.height(of: block, width: 300, environment: environment, measurer: measurer)
        let third = cache.height(of: block, width: 300, environment: environment, measurer: measurer)

        XCTAssertEqual(
            measurer.callCount, 1, "a repeated lookup of an unchanged key re-measured instead of hitting the cache")
        XCTAssertEqual(first, second)
        XCTAssertEqual(second, third)
    }

    /// The reason `MarkdownBlock` is `Hashable` at all, per its own doc comment: an identical
    /// block reached through two unrelated call sites — standing in for two different messages
    /// sharing the same code block — must not be measured twice.
    func testAnIdenticalBlockFromADifferentCallSiteHitsTheSameEntry() {
        let measurer = StubBlockMeasurer()
        let cache = BlockHeightCache()
        let sameContentDifferentInstance = MarkdownBlock.paragraph(InlineText(runs: [InlineRun(text: "hello world")]))

        _ = cache.height(of: block, width: 300, environment: environment, measurer: measurer)
        _ = cache.height(of: sameContentDifferentInstance, width: 300, environment: environment, measurer: measurer)

        XCTAssertEqual(
            measurer.callCount, 1, "two blocks equal by content were measured as if they were different keys")
    }

    // MARK: - Everything in the key actually participates in the key

    func testADifferentWidthIsATrueCacheMissAndKeepsBothValues() {
        let measurer = StubBlockMeasurer()
        let cache = BlockHeightCache()
        // Long enough that width 100 wraps it across several of the stub's lines while width 500
        // fits it on one — the short `block` above wraps to one line at either width, which would
        // make this assertion pass for the wrong reason.
        let longBlock = MarkdownBlock.paragraph(
            InlineText(runs: [InlineRun(text: String(repeating: "word ", count: 40))]))

        let atNarrow = cache.height(of: longBlock, width: 100, environment: environment, measurer: measurer)
        let atWide = cache.height(of: longBlock, width: 500, environment: environment, measurer: measurer)

        XCTAssertEqual(measurer.callCount, 2, "changing width did not trigger a fresh measurement")
        XCTAssertNotEqual(
            atNarrow, atWide,
            "the stub measurer is width-sensitive, so equal results here mean width was not passed through")

        // Both entries must coexist rather than the second overwriting the first under a
        // collapsed key.
        XCTAssertEqual(cache.cachedHeight(of: longBlock, width: 100, environment: environment), atNarrow)
        XCTAssertEqual(cache.cachedHeight(of: longBlock, width: 500, environment: environment), atWide)
    }

    func testADifferentEnvironmentIsATrueCacheMissAndKeepsBothValues() {
        let measurer = StubBlockMeasurer()
        let cache = BlockHeightCache()
        let large = MeasurementEnvironment(sizeCategoryToken: "accessibilityExtraExtraExtraLarge")

        let atL = cache.height(of: block, width: 300, environment: environment, measurer: measurer)
        let atLarge = cache.height(of: block, width: 300, environment: large, measurer: measurer)

        XCTAssertEqual(measurer.callCount, 2, "changing the size-category token did not trigger a fresh measurement")
        XCTAssertNotEqual(
            atL, atLarge,
            "the stub measurer is environment-sensitive, so equal results mean environment was not passed through")
        XCTAssertEqual(cache.cachedHeight(of: block, width: 300, environment: environment), atL)
        XCTAssertEqual(cache.cachedHeight(of: block, width: 300, environment: large), atLarge)
    }

    /// Two widths a real layout pass could plausibly produce for what is visually the same
    /// constraint — sub-point floating-point noise, not a real difference — must land on one
    /// entry. Framed as a call-count assertion, not as a check that `.rounded()` behaves as
    /// `.rounded()` always does; the point is the cache's observable behavior under jitter, which
    /// a refactor of the rounding rule could silently change without this test's math changing.
    func testWidthJitterWellUnderAPointSharesOneEntry() {
        let measurer = StubBlockMeasurer()
        let cache = BlockHeightCache()

        _ = cache.height(of: block, width: 300.0, environment: environment, measurer: measurer)
        _ = cache.height(of: block, width: 300.0001, environment: environment, measurer: measurer)
        _ = cache.height(of: block, width: 299.9999, environment: environment, measurer: measurer)

        XCTAssertEqual(measurer.callCount, 1, "sub-point width jitter was treated as three distinct widths")
    }

    /// The companion boundary case: quantization must not erase a difference a reader could
    /// actually notice. Two widths a whole point apart land on different entries.
    func testWidthsAWholePointApartAreDistinctEntries() {
        let measurer = StubBlockMeasurer()
        let cache = BlockHeightCache()

        _ = cache.height(of: block, width: 300.0, environment: environment, measurer: measurer)
        _ = cache.height(of: block, width: 302.0, environment: environment, measurer: measurer)

        XCTAssertEqual(measurer.callCount, 2, "widths a whole point apart were folded into the same cache entry")
    }

    // MARK: - Fast-path lookup never measures

    func testCachedHeightNeverInvokesTheMeasurer() {
        let measurer = StubBlockMeasurer()
        let cache = BlockHeightCache()

        XCTAssertNil(
            cache.cachedHeight(of: block, width: 300, environment: environment), "an empty cache reported a hit")
        XCTAssertEqual(measurer.callCount, 0, "the fast-path lookup measured on a miss instead of returning nil")
    }

    // MARK: - Invalidation

    func testInvalidateAllForcesEveryEntryToBeRemeasured() {
        let measurer = StubBlockMeasurer()
        let cache = BlockHeightCache()

        _ = cache.height(of: block, width: 300, environment: environment, measurer: measurer)
        XCTAssertEqual(measurer.callCount, 1)
        XCTAssertNotNil(cache.cachedHeight(of: block, width: 300, environment: environment))

        cache.invalidateAll()

        XCTAssertNil(
            cache.cachedHeight(of: block, width: 300, environment: environment),
            "invalidateAll left a stale entry behind")
        _ = cache.height(of: block, width: 300, environment: environment, measurer: measurer)
        XCTAssertEqual(
            measurer.callCount, 2, "a lookup after invalidateAll hit a surviving entry instead of re-measuring")
    }

    // MARK: - Concurrent access does not corrupt the cache

    /// Not a proof of race-freedom — no unit test is — but it exercises the exact pattern the
    /// design is meant to support: many callers reading and populating the same cache from
    /// different threads at once, as a background prefetch and a main-thread layout pass would.
    /// A lock bug here tends to show up as a crash or a wildly wrong `count`, both of which this
    /// would catch.
    func testConcurrentAccessFromManyBlocksDoesNotCorruptTheCache() {
        let measurer = StubBlockMeasurer()
        let cache = BlockHeightCache()
        let blockCount = 50

        let blocks = (0..<blockCount).map { index in
            MarkdownBlock.paragraph(InlineText(runs: [InlineRun(text: "block number \(index)")]))
        }

        let expectation = expectation(description: "all concurrent measurements complete")
        expectation.expectedFulfillmentCount = blockCount

        let environment = self.environment
        let queue = DispatchQueue(label: "cache-stress", attributes: .concurrent)
        for block in blocks {
            queue.async {
                for _ in 0..<5 {
                    _ = cache.height(of: block, width: 300, environment: environment, measurer: measurer)
                }
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 10)
        XCTAssertEqual(
            cache.count, blockCount,
            "concurrent population produced a different entry count than the number of distinct blocks")
    }
}
