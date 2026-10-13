import Foundation

/// When the session list's row positions are renewed.
///
/// Row content follows the server live; row *position* does not. `SessionListStore` orders the
/// list by a placement each row was last given, and this decides when placements are renewed: in
/// one step, after the list has been quiet for a while, and never while the list is being
/// touched, scrolled, or scrolled away from its top. A busy session therefore rises once its
/// activity has settled instead of on every message, and a row never moves under a finger.
///
/// The web client keeps the same rule with the same numbers (`stores/sessionOrder.ts` in
/// pai-cloud); `docs/IOS_PARITY.md` there names the row. A reader's own action settles at once
/// through ``settleNow()``.
@MainActor
public final class SessionOrderSettler {
    public struct Timing: Sendable, Equatable {
        /// A burst of changes settles this long after the last one.
        public var settle: UInt64
        /// A list that never goes quiet still settles this long after its first unsettled change.
        public var settleMax: UInt64
        /// A touch or a scroll counts as using the list for this long after it ends.
        public var interactionIdle: UInt64
        /// Once the list is free again, the pending settle runs after this pause.
        public var release: UInt64

        public init(settle: UInt64, settleMax: UInt64, interactionIdle: UInt64, release: UInt64) {
            self.settle = settle
            self.settleMax = settleMax
            self.interactionIdle = interactionIdle
            self.release = release
        }

        public static let production = Timing(
            settle: 2_500_000_000, settleMax: 10_000_000_000, interactionIdle: 1_000_000_000,
            release: 500_000_000)
    }

    /// Scrolled further than this from the top counts as "away": the rows in view stay put.
    public static let awayFromTopPoints: Double = 8

    /// What a settle does to the list; the store sets it.
    public var onSettle: (() -> Void)?

    private let timing: Timing
    private var settleTask: Task<Void, Never>?
    private var interactionTask: Task<Void, Never>?
    private var firstUnsettled: ContinuousClock.Instant?
    private var unsettled = false
    private var interacting = false
    private var touching = false
    private var awayFromTop = false

    public init(timing: Timing = .production) {
        self.timing = timing
    }

    private var held: Bool { interacting || touching || awayFromTop }

    /// Something that changes the order happened in the background: renew placements once quiet.
    public func markUnsettled() {
        let now = ContinuousClock.now
        let first = firstUnsettled ?? now
        firstUnsettled = first
        unsettled = true
        let elapsed = UInt64(max(0, (now - first).components.seconds)) * 1_000_000_000
        let untilMax = timing.settleMax > elapsed ? timing.settleMax - elapsed : 0
        schedule(after: min(timing.settle, untilMax))
    }

    /// The reader acted: renew every placement now, pending changes included.
    public func settleNow() {
        run()
    }

    /// The list is being used (a scroll in motion, a tap): hold until it has been idle a moment.
    public func noteInteraction() {
        interacting = true
        interactionTask?.cancel()
        interactionTask = Task { [weak self, timing] in
            try? await Task.sleep(nanoseconds: timing.interactionIdle)
            guard let self, !Task.isCancelled else { return }
            self.interacting = false
            self.interactionTask = nil
            self.release()
        }
    }

    /// A finger is on the list (tracking or dragging); held for as long as it stays there.
    public func setTouching(_ touching: Bool) {
        guard self.touching != touching else { return }
        self.touching = touching
        if !touching { noteInteraction() }
    }

    /// Whether the list is scrolled away from its top.
    public func setAwayFromTop(_ away: Bool) {
        guard awayFromTop != away else { return }
        awayFromTop = away
        if !away { release() }
    }

    /// The list left the screen: nothing is being looked at, so nothing is held.
    public func releaseHold() {
        interactionTask?.cancel()
        interactionTask = nil
        interacting = false
        touching = false
        awayFromTop = false
        release()
    }

    private func release() {
        if unsettled && !held { schedule(after: timing.release) }
    }

    private func schedule(after nanos: UInt64) {
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanos)
            guard let self, !Task.isCancelled else { return }
            self.settleTask = nil
            if !self.held { self.run() }
        }
    }

    private func run() {
        settleTask?.cancel()
        settleTask = nil
        unsettled = false
        firstUnsettled = nil
        onSettle?()
    }
}
