import XCTest

@testable import PAIKit

final class NoteAttachmentCacheTests: XCTestCase {
    func testTheLeastRecentlyUsedFileLeavesFirstWhenTheEntryLimitIsHit() {
        var cache = NoteAttachmentCache(maxBytes: 1000, maxEntries: 2)
        cache.insert(Data([1]), containerId: "c", path: "a")
        cache.insert(Data([2]), containerId: "c", path: "b")
        _ = cache.data(containerId: "c", path: "a")
        cache.insert(Data([3]), containerId: "c", path: "d")

        XCTAssertNotNil(cache.data(containerId: "c", path: "a"))
        XCTAssertNil(cache.data(containerId: "c", path: "b"))
        XCTAssertNotNil(cache.data(containerId: "c", path: "d"))
    }

    func testTheByteBoundEvictsAndAnOversizedFileIsNeverKept() {
        var cache = NoteAttachmentCache(maxBytes: 10, maxEntries: 10)
        cache.insert(Data(count: 6), containerId: "c", path: "a")
        cache.insert(Data(count: 6), containerId: "c", path: "b")
        XCTAssertNil(cache.data(containerId: "c", path: "a"))
        XCTAssertEqual(cache.totalBytes, 6)

        cache.insert(Data(count: 11), containerId: "c", path: "big")
        XCTAssertNil(cache.data(containerId: "c", path: "big"))
    }

    func testTheSamePathInAnotherContainerIsAnotherFile() {
        var cache = NoteAttachmentCache()
        cache.insert(Data([1]), containerId: "c1", path: "a")
        XCTAssertNil(cache.data(containerId: "c2", path: "a"))
    }
}
