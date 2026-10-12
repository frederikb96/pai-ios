import Foundation
import Observation

/// The notes list's semantic search: one query at a time, debounced, with the phase the list
/// needs to show the plain filter matches first and swap the tiered result in when it lands.
///
/// The text-match twin is the notes filter, which runs on the phone and is already on screen, so
/// this store has no lexical request of its own. It answers ids and tiers only; the screen
/// resolves them against the index it holds.
///
/// A response is applied only if no newer query or window has been asked for since it was fired.
@MainActor
@Observable
public final class NoteMeaningSearchStore {
    public typealias Search = @MainActor (String, TimeBounds?) async throws -> [NoteSemanticHit]

    public private(set) var phase: SemanticSearchPhase = .idle
    /// Empty until the tiered result lands, and again as soon as a newer query is asked for.
    public private(set) var hits: [NoteSemanticHit] = []

    private let search: Search
    private let debounceNanos: UInt64
    private let now: @Sendable () -> Date
    private var task: Task<Void, Never>?
    private var generation = 0
    private var lastQuery = ""

    public init(
        debounceNanos: UInt64 = SearchTiming.debounceNanos,
        now: @escaping @Sendable () -> Date = { Date() },
        search: @escaping Search
    ) {
        self.debounceNanos = debounceNanos
        self.now = now
        self.search = search
    }

    /// Asks for the tiered result of `query` within `window`. Typed text waits out the debounce;
    /// the same text under a new window goes out at once, since it is a discrete choice. Blank
    /// text ends the search.
    public func update(query: String, window: TimeWindow?) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let textChanged = trimmed != lastQuery
        lastQuery = trimmed
        task?.cancel()
        generation += 1
        let mine = generation
        hits = []
        guard !trimmed.isEmpty else {
            phase = .idle
            return
        }
        phase = .searching
        let wait = textChanged ? debounceNanos : 0
        task = Task { [weak self, search, now] in
            if wait > 0 {
                try? await Task.sleep(nanoseconds: wait)
            }
            guard !Task.isCancelled else { return }
            do {
                let found = try await search(trimmed, window?.bounds(now: now()))
                guard !Task.isCancelled, let self, self.generation == mine else { return }
                self.hits = found
                self.phase = .ready
            } catch {
                guard !Task.isCancelled, let self, self.generation == mine else { return }
                if error is CancellationError { return }
                self.phase = SemanticSearchPhase.outcome(of: error)
            }
        }
    }

    /// Ends whatever is running and forgets the result, for leaving semantic mode.
    public func reset() {
        task?.cancel()
        generation += 1
        lastQuery = ""
        hits = []
        phase = .idle
    }
}
