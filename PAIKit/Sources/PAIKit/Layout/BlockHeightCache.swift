import Foundation

/// Caches a block's measured height, keyed by everything the height depends on.
///
/// Keyed by the block's own value rather than by a message or a row id: ``MarkdownBlock`` is
/// `Hashable` specifically so that two identical code blocks in different messages, or the same
/// block scrolled past twice, are measured once — see that type's doc comment. Width and
/// ``MeasurementEnvironment`` join the key because both change what the same block measures to.
///
/// A plain lock-protected dictionary, not an actor. A `UICollectionViewLayout` must return a
/// size synchronously — `sizeForItem` cannot `await` — so a cache reachable only from async
/// context is the wrong shape for the one place this matters most. The same synchronous shape is
/// what lets a background task warm the cache ahead of scrolling (call ``height(of:width:environment:measurer:)``
/// off the main thread for rows about to come on screen) while the main thread's layout pass
/// reads it back with ``cachedHeight(of:width:environment:)``, a lookup that never measures and
/// never blocks.
public final class BlockHeightCache: @unchecked Sendable {
    private struct Key: Hashable {
        let block: MarkdownBlock
        let width: Double
        let environment: MeasurementEnvironment
    }

    private let lock = NSLock()
    private var storage: [Key: Double] = [:]

    public init() {}

    /// Two layout passes rarely agree on a width down to the last bit of a `Double` — the same
    /// visual width comes back a few ULPs apart depending on which constraints produced it. Left
    /// alone that turns into a cache miss on every pass for a width that never actually changed,
    /// which defeats the point of caching at all. Rounding to the nearest point removes that
    /// jitter without giving up any precision a text layout could act on.
    private func quantize(_ width: Double) -> Double {
        width.rounded()
    }

    private func key(for block: MarkdownBlock, width: Double, environment: MeasurementEnvironment) -> Key {
        Key(block: block, width: quantize(width), environment: environment)
    }

    /// The fast path: a value already measured, with no work done on a miss.
    public func cachedHeight(
        of block: MarkdownBlock,
        width: Double,
        environment: MeasurementEnvironment
    ) -> Double? {
        let key = key(for: block, width: width, environment: environment)
        lock.lock()
        defer { lock.unlock() }
        return storage[key]
    }

    /// Returns the cached height, or measures, stores and returns it.
    ///
    /// `measurer` runs outside the lock: a slow first layout of one block must never stall a
    /// cache hit for every other block a concurrent caller is reading. Two callers can end up
    /// measuring the same missing key at once — that costs one duplicated measurement, never a
    /// corrupted entry, because `measurer` is required to be a pure function of its inputs (see
    /// ``BlockMeasuring``), so whichever result is stored last is identical to the other.
    public func height(
        of block: MarkdownBlock,
        width: Double,
        environment: MeasurementEnvironment,
        measurer: some BlockMeasuring
    ) -> Double {
        let key = key(for: block, width: width, environment: environment)

        lock.lock()
        if let cached = storage[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let measured = measurer.height(of: block, width: width, environment: environment)

        lock.lock()
        storage[key] = measured
        lock.unlock()

        return measured
    }

    /// Discards every cached height.
    ///
    /// Correctness never depends on calling this: `environment` is already part of every key, so
    /// a Dynamic Type change simply misses the cache rather than returning a stale height. It
    /// exists for memory, not correctness — every entry measured under a size category the app is
    /// not about to return to is otherwise held forever, and a long session with many distinct
    /// code blocks makes that a real amount of memory. Call it from `traitCollectionDidChange`
    /// when the content-size category changes.
    public func invalidateAll() {
        lock.lock()
        storage.removeAll()
        lock.unlock()
    }

    /// The number of distinct (block, width, environment) entries currently cached. Exposed for
    /// tests and for the debug bridge; not meant to drive any layout decision.
    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage.count
    }
}
