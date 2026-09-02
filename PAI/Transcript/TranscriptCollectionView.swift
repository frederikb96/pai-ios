import Observation
import PAIKit
import SwiftUI
import UIKit

/// A floating control shown once the reader has scrolled away from the live edge — the control
/// `EdgeFollowLatch.isAtLiveEdge`'s own doc comment names as its reason for being a stateless
/// check ("safe to compute … for whether to show a jump-to-bottom control"). Hosted as SwiftUI,
/// matching every other button in the app, rather than a bare `UIButton`.
private struct JumpToLatestButton: View {
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Image(systemName: "arrow.down")
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 36, height: 36)
                .foregroundStyle(.white)
                .background(PaiPalette.primary500)
                .clipShape(Circle())
                .shadow(radius: 3)
        }
        .accessibilityLabel("Jump to latest")
        .accessibilityIdentifier("transcript-jump-to-latest")
    }
}

/// One measured row, ready to hand to ``TranscriptLayout``.
private struct TranscriptRow {
    let id: Int
    let message: Message
    let height: Double
}

/// The transcript list: a `UICollectionView` on ``TranscriptLayout``, owning the bootstrap/SSE
/// lifecycle, the measured-height pipeline, and the scroll mechanics the `scrolling` skill lays
/// out — the edge-follow latch, the hold, identity-based anchoring, and older-page paging.
///
/// Row heights are computed synchronously on the main actor for the whole loaded window whenever
/// it changes, using the real ``TextKitBlockMeasurer`` and a ``BlockHeightCache`` owned by this
/// controller. `BlockHeightCache` explicitly supports measuring off the main thread and reading
/// back synchronously (see its doc comment) — this controller does not exercise that yet, so a
/// large loaded window measures on the main thread. Whether that is fast enough is unverified
/// until it runs on a device.
final class TranscriptCollectionViewController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegate,
    UIGestureRecognizerDelegate
{

    private static let cellReuseIdentifier = "TranscriptRow"
    /// Rows from the top edge within which an older page is requested — a rough stand-in for
    /// "a screen or two ahead of the reader" (the web's 1500px `IntersectionObserver` margin),
    /// expressed in rows rather than points since this controller has no cheap way to convert a
    /// row count to a point distance before the rows are laid out.
    private static let olderPageTriggerRowMargin = 8

    let sessionID: String
    private let store: TranscriptStore
    private let apiClient: PaiApiClient
    private let settings: SettingsStore
    /// Owns the same `Authorization` header every other transport applies, per
    /// `PaiRequestFactory`'s own doc comment. `PaiApiClient` keeps its own copy private, so the
    /// stream needs one passed in rather than reached for through the client.
    private let requestFactory: PaiRequestFactory
    /// Shared with ``TranscriptSearchBar`` — a sibling view under the same `SessionDetailView`,
    /// not a parent or child of this one, so the shared `@Observable` instance is the only channel
    /// between them. Nothing here mutates it except ``searchState/isLoadingFullHistory``; every
    /// other field is the search bar's own, and this controller only ever reacts to it.
    private let searchState: TranscriptSearchState

    private let measurer = TextKitBlockMeasurer()
    private let cache = BlockHeightCache()
    private let layout = TranscriptLayout()
    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)

    private var rows: [TranscriptRow] = []
    /// `"\(messageId)#\(expandKey)"` → override. Applies to every card in that message sharing
    /// the key, not to one specific tool-call instance — a simplification from the web's true
    /// per-card `useState`.
    private var expandOverrides: [String: Bool] = [:]

    private var edgeFollow = EdgeFollowLatch()
    private let holdController = TranscriptHoldController()
    private var lastRecordedAnchor: TranscriptAnchor?
    private var isLoadingOlder = false
    private var lastMeasuredWidth: Double = -1
    /// Set for the duration of `apply(_:intent:)`'s synchronous work — `apply()` forces a layout
    /// pass with `reloadData()`/`layoutIfNeeded()`, and UIKit can call back into
    /// `viewDidLayoutSubviews()` from inside that call, most reliably seen mid
    /// `_UINavigationParallaxTransition`, where the view's own bounds are still animating frame to
    /// frame. Recursing into a second `apply()` before the first one returns is how two calls end
    /// up disagreeing about `rows`/UIKit's own item count at once — see `recomputeRows(applying:)`.
    private var isApplyingRows = false
    /// Set when a layout pass arrives while `isApplyingRows` is already true. The recompute it
    /// asked for is not dropped, only deferred to the next run-loop turn — by then
    /// `isApplyingRows` has settled back to `false`, so it is safe to apply for real. Coalesces
    /// naturally: several skipped passes in a row leave only the first deferred call still
    /// finding the flag set, and every recompute reads live state regardless of which one runs.
    private var hasPendingRecompute = false
    /// `bootstrap()` now retries indefinitely on failure (`TranscriptBootstrapBackoff`), so unlike
    /// a one-shot fetch it can genuinely still be running when this controller is torn down —
    /// stored so `deinit` can cancel it rather than leaving it retrying network calls against a
    /// session nothing is looking at anymore.
    private var bootstrapTask: Task<Void, Never>?
    private var sseClient: PaiSseClient?
    /// Where a session's own bootstrap-resolved restore target goes until it can actually be
    /// applied — `recomputeRows` is a no-op below a measured width of zero, and the bootstrap can
    /// resolve before `viewDidLayoutSubviews` has ever run once (see `apply(_:intent:)`'s
    /// `.initialLoad` case). Whichever of the two runs second is the one that applies it.
    private var pendingInitialLoad: TranscriptRestoreTarget?
    /// Every session's last recorded read position, kept only for the life of the process — the
    /// view controller itself is recreated on every navigation into a session, so an instance
    /// property alone would forget it on every return. Seeded once per session, on this
    /// process's first visit, from `persistedReadPosition` — see `bootstrap()`.
    private static var lastAnchors: [String: TranscriptAnchor] = [:]
    /// What the server last had for this session, from `Session.readPosition*` — read once, in
    /// `bootstrap()`, to seed `lastAnchors` the first time this process visits this session.
    /// `nil` both when there has never been a recorded position and when the session was not yet
    /// loaded at the moment this screen was constructed (a cold deep link); either way the
    /// restore falls back to the bottom, same as it already does for an anchor the LRU evicted.
    private let persistedReadPosition: PersistedReadPosition?
    /// Debounces `putReadPosition` the same 2s the web does (`READ_POSITION_SAVE_DEBOUNCE_MS`) —
    /// one request per burst of scrolling, not one per frame.
    private var readPositionSaveTask: Task<Void, Never>?
    /// `nonisolated(unsafe)` so `deinit` — which is nonisolated — can unregister it, same
    /// discipline as `VoiceRecorderController`'s own observer tokens: written once on the main
    /// actor during setup and read once at deallocation, when nothing else holds a reference, so
    /// there is no concurrent access for the isolation to protect.
    private nonisolated(unsafe) var backgroundObserver: NSObjectProtocol?

    /// The row currently wearing the deep-link ring, if any — see `beginDeepLinkHighlight(for:)`.
    private var highlightedMessageId: Int?
    /// Clears `highlightedMessageId` after its window — cancelled and restarted, never left to
    /// race a second jump.
    private var highlightClearTask: Task<Void, Never>?
    /// A deep link's own retry ladder (search-virtualization design) — the id may not be
    /// ingested yet, arriving a moment after the link was generated. Matches the web's
    /// `DEEP_LINK_RETRY_DELAYS_MS`.
    private static let deepLinkRetryDelays: [Duration] = [
        .seconds(1.5), .seconds(3), .seconds(6), .seconds(12), .seconds(24),
    ]

    private lazy var jumpToLatestHostingController = UIHostingController(
        rootView: JumpToLatestButton(onTap: { [weak self] in self?.jumpToLatestTapped() }))

    /// Debounced 250ms after the last keystroke, matching the web's own `SearchBar` constant —
    /// longer than the client-only scan this replaced ever needed, since every fire now costs a
    /// network round trip rather than a re-scan of the loaded window.
    private static let findDebounce: Duration = .milliseconds(250)
    private var findDebounceTask: Task<Void, Never>?
    /// The server hit ids for the current query/kind — mirrors the web's `hitIdsRef`. Never in
    /// `TranscriptSearchState` itself: this can run to thousands of ids, and that type is meant
    /// to be lightweight UI state.
    private var hitIds: [Int] = []
    /// Supersedes every new `runFind()`/`landOn(index:direction:)` so a stale response can never
    /// overwrite a newer one's state.
    private var findToken = 0
    /// The reader's own position, captured once when a search opens — every result set this
    /// session computes starts from it, so typing a longer query does not silently re-anchor the
    /// start position to wherever the previous query happened to land.
    private var searchOpenedAtMessageId: Int?
    private var hasBegunCurrentSearchSession = false
    private var lastSearchedQuery: String?
    private var lastSearchedKind: MessageKind?

    /// Where to jump once bootstrap has loaded — row 5.28. Consumed once: bootstrap reads it,
    /// pages backward if the message is not already in the loaded window, and clears it, so a
    /// later reconnect or width change never re-triggers the jump.
    private var initialJumpMessageID: Int?
    /// A later jump request for this exact session, while this controller is already alive — see
    /// `TranscriptJumpRequests`'s own doc comment. `observeJumpRequests()` subscribes to it once,
    /// in `viewDidLoad`, independent of anything SwiftUI decides about the wrapping view.
    private let jumpRequests: TranscriptJumpRequests

    init(
        sessionID: String, store: TranscriptStore, apiClient: PaiApiClient, settings: SettingsStore,
        requestFactory: PaiRequestFactory, searchState: TranscriptSearchState, initialJumpMessageID: Int? = nil,
        jumpRequests: TranscriptJumpRequests, persistedReadPosition: PersistedReadPosition? = nil
    ) {
        self.sessionID = sessionID
        self.store = store
        self.apiClient = apiClient
        self.settings = settings
        self.requestFactory = requestFactory
        self.searchState = searchState
        self.initialJumpMessageID = initialJumpMessageID
        self.jumpRequests = jumpRequests
        self.persistedReadPosition = persistedReadPosition
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        bootstrapTask?.cancel()
        highlightClearTask?.cancel()
        readPositionSaveTask?.cancel()
        if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
        // `deinit` is nonisolated and `disconnect()` is not. Copy the reference out so the hop
        // captures the client rather than `self`, which is already being deallocated.
        let client = sseClient
        Task { @MainActor in client?.disconnect() }
        // This controller is recreated on every navigation into a session (`Route.session`'s own
        // doc comment), so `deinit` is exactly the moment the web's own per-session cleanup
        // effect flushes on — leaving these screens, not only quitting the app. `apiClient`,
        // `sessionID` and `store` are plain `let`s, safe to read synchronously here same as
        // `sseClient` above (a reference, not a call into its `@MainActor` isolation); reading
        // `store.window(for:)` itself is a call and has to hop, same as `sseClient?.disconnect()`
        // does — done inside the `Task` below rather than out here, so `hasNewer` is read live
        // rather than a moment stale.
        if let anchor = lastRecordedAnchor {
            let client = apiClient
            let sessionID = sessionID
            let store = store
            Task { @MainActor in
                let payload = TranscriptAnchor.readPositionPayload(
                    for: anchor, hasNewer: store.window(for: sessionID).hasNewer)
                try? await client.putReadPosition(
                    sessionId: sessionID, messageId: payload.messageId, offsetPx: payload.offsetPx,
                    atBottom: payload.atBottom)
            }
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Every other screen now paints its own ground explicitly (`paiScreenBackground()`) —
        // this one relied on UIKit's own default (`.systemBackground`), which does not track the
        // app's screenBackground token and reads wrong the same way an unset screen did before
        // that modifier existed.
        view.backgroundColor = UIColor(PaiPalette.Semantic.screenBackground)
        collectionView.frame = view.bounds
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .clear
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(UICollectionViewCell.self, forCellWithReuseIdentifier: Self.cellReuseIdentifier)
        // The composer's `UITextView` has no focus binding and Return is always a newline
        // (`ComposerTextEditor`'s own doc comment), so without this the keyboard has no route
        // down at all once it is up. `.interactive` — a drag on the transcript itself dismisses
        // it, tracking the gesture the way Messages.app does — rather than `.onDrag`, which only
        // commits at the end of the gesture and reads as unresponsive mid-drag.
        collectionView.keyboardDismissMode = .interactive
        // A drag dismisses; so does a tap on the conversation. `.interactive` alone requires
        // knowing to drag downward *through* the keyboard, while tapping an empty patch of
        // transcript is the gesture every other messaging app on this phone answers — and a
        // reader who tries it and gets nothing concludes the keyboard cannot be dismissed at all.
        // `cancelsTouchesInView = false` keeps this purely additive: a tap that lands on a card
        // still reaches the card, because this only ever ends editing and never consumes a touch.
        let dismissTap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboardOnTap))
        dismissTap.cancelsTouchesInView = false
        dismissTap.delegate = self
        collectionView.addGestureRecognizer(dismissTap)
        view.addSubview(collectionView)

        addChild(jumpToLatestHostingController)
        jumpToLatestHostingController.view.backgroundColor = .clear
        jumpToLatestHostingController.view.translatesAutoresizingMaskIntoConstraints = false
        jumpToLatestHostingController.view.isHidden = true
        view.addSubview(jumpToLatestHostingController.view)
        jumpToLatestHostingController.didMove(toParent: self)
        NSLayoutConstraint.activate([
            jumpToLatestHostingController.view.trailingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            jumpToLatestHostingController.view.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
        ])

        bootstrapTask = Task { [weak self] in await self?.bootstrap() }
        observeSearchState()
        observePendingBubbles()
        observeJumpRequests()
        // The debounce below never elapses on its own once the app stops running frames — same
        // reasoning as the web's `visibilitychange`/`pagehide` flush, the closest UIKit
        // equivalent to a tab actually closing.
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.flushReadPositionSaveNow() }
        }
    }

    /// Rows arrive here through this controller's own SSE handling, so a send tracked by the
    /// composer — a mutation of the same store from somewhere else entirely — would otherwise not
    /// redraw anything until the next unrelated event happened to. Same recursive re-registration
    /// as `observeSearchState`.
    private func observePendingBubbles() {
        withObservationTracking {
            _ = store.pendingBubbleTexts(sessionId: sessionID)
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.recomputeRows(applying: .stickToBottomIfPinned)
                self.observePendingBubbles()
            }
        }
    }

    /// A tapped push notification for this exact session, arriving while this controller is
    /// already alive — see `TranscriptJumpRequests`'s own doc comment for why `Route` cannot
    /// deliver this on its own. Reuses `jumpToInitialMessage(_:)`: the stream is already
    /// connected by the time this fires, so nothing bootstrap-specific is needed.
    private func observeJumpRequests() {
        withObservationTracking {
            _ = jumpRequests.pendingMessageID(for: sessionID)
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if let messageID = self.jumpRequests.consume(sessionID: self.sessionID) {
                    await self.jumpToInitialMessage(messageID)
                }
                self.observeJumpRequests()
            }
        }
    }

    /// The dismiss tap must never be the reason a card's own tap is missed. UIKit resolves two
    /// recognizers competing for the same touch by letting only one win unless asked otherwise,
    /// and which one wins is not something to leave to chance in a list whose rows are tappable.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        true
    }

    @objc private func dismissKeyboardOnTap() {
        // The window rather than this view: the first responder is the composer's text view,
        // which is a sibling of this controller's view, not a descendant of it.
        view.window?.endEditing(true)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = measurementWidth()
        guard width > 0, width != lastMeasuredWidth else { return }
        lastMeasuredWidth = width
        if let target = pendingInitialLoad {
            // The bootstrap already resolved a restore target before this ever ran — see
            // `pendingInitialLoad`'s doc comment.
            recomputeRows(applying: .initialLoad(target))
        } else {
            // A width change re-wraps every block; the whole window is re-measured and the
            // reader's own position is corrected by the anchor delta rather than lost.
            recomputeRows(applying: .compensateFromTopVisibleRow)
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard traitCollection.preferredContentSizeCategory != previousTraitCollection?.preferredContentSizeCategory
        else {
            return
        }
        cache.invalidateAll()
        recomputeRows(applying: .compensateFromTopVisibleRow)
    }

    // MARK: - Bootstrap and streaming

    /// One tunnel blip or one 502 during a deploy used to strand the screen permanently — a
    /// failed fetch set the error and returned, and nothing ever called this again. Retries with
    /// `TranscriptBootstrapBackoff`'s capped schedule instead, the same shape `PaiSseClient` uses
    /// for its own reconnect, until it succeeds or `bootstrapTask` is cancelled. The error is
    /// shown between attempts (`setBootstrapError`) and the spinner returns just before the next
    /// one (`setBootstrapping`, which also clears it) — the two existing `TranscriptLoadState`
    /// states already cover this, so retrying needs no UI of its own.
    private func bootstrap() async {
        store.setBootstrapping(sessionID)
        var backoff = TranscriptBootstrapBackoff()
        let entries: [Message]
        while true {
            do {
                entries = try await apiClient.getMessages(
                    sessionId: sessionID, page: .tail(limit: TranscriptStore.tailLimit))
                break
            } catch {
                guard !Task.isCancelled else { return }
                store.setBootstrapError(sessionID, error: (error as? PaiError)?.userMessage ?? "Couldn't load messages")
                try? await Task.sleep(for: backoff.next())
                guard !Task.isCancelled else { return }
                store.setBootstrapping(sessionID)
            }
        }
        store.applyBootstrap(sessionId: sessionID, entries: entries, requestedLimit: TranscriptStore.tailLimit)

        // A notification deep link (row 5.28) overrides the ordinary restore-to-last-anchor
        // below — the target is almost certainly not in the tail just loaded, so this lands at
        // the bottom first (the same fallback an unresolvable anchor already uses) and refines
        // once the target page is actually loaded, rather than blocking the first paint on it.
        if let jumpTarget = initialJumpMessageID {
            initialJumpMessageID = nil
            pendingInitialLoad = .bottom
            recomputeRows(applying: .initialLoad(.bottom))
            connectStream(initialCursor: store.maxMessageId(for: sessionID))
            await jumpToInitialMessage(jumpTarget)
            return
        }

        fallBackToReadPosition()
        connectStream(initialCursor: store.maxMessageId(for: sessionID))
    }

    /// The ordinary open's own target resolution (search-virtualization design: a deep link's
    /// retry ladder degrades to this once exhausted, never to silently loading nothing). Only
    /// ever seeds `lastAnchors` when it is an EMPTY slot — a session revisited later in the same
    /// process already has a more current in-memory anchor than whatever the server held when
    /// this screen was constructed, and that must win.
    private func fallBackToReadPosition() {
        if Self.lastAnchors[sessionID] == nil, let seeded = TranscriptAnchor.fromPersisted(persistedReadPosition) {
            Self.lastAnchors[sessionID] = seeded
        }
        let loadedIds = TranscriptStore.displayMessages(store.messages[sessionID] ?? []).map(\.id)
        let target = TranscriptRestore.target(for: Self.lastAnchors[sessionID], loadedMessageIds: loadedIds)
        pendingInitialLoad = target
        recomputeRows(applying: .initialLoad(target))
    }

    /// `locate`s the deep link's target with the retry ladder a deep link needs — the id may not
    /// be ingested yet, arriving a moment after the link was generated — and rings the row once
    /// it lands. Degrades to ``fallBackToReadPosition()`` once the ladder is exhausted, never to
    /// silently loading nothing.
    private func jumpToInitialMessage(_ targetID: Int) async {
        let loaded = await locate(targetID, retryLadder: Self.deepLinkRetryDelays)
        guard loaded else {
            fallBackToReadPosition()
            return
        }
        revealRow(targetID, ringAsDeepLink: true)
    }

    /// Rings `messageId`'s card for a few seconds, or until the reader makes a deliberate gesture
    /// — `scrollViewWillBeginDragging` clears it early, matching the design's "fading out after
    /// ~4s or on the first deliberate gesture".
    private func beginDeepLinkHighlight(for messageId: Int) {
        highlightedMessageId = messageId
        reconfigureVisibleCells()
        highlightClearTask?.cancel()
        highlightClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, !Task.isCancelled else { return }
            self.clearDeepLinkHighlight()
        }
    }

    private func clearDeepLinkHighlight() {
        guard highlightedMessageId != nil else { return }
        highlightClearTask?.cancel()
        highlightClearTask = nil
        highlightedMessageId = nil
        reconfigureVisibleCells()
    }

    private func connectStream(initialCursor: Int?) {
        let callbacks = PaiSseClient.Callbacks(
            onInit: { [weak self] event in self?.applySseInit(event) },
            onBatch: { [weak self] event in self?.applySseBatch(event) },
            onStatus: { [weak self] event in self?.applyStatus(event) },
            onActivity: { [weak self] in
                guard let self else { return }
                self.store.recordSseActivity(sessionId: self.sessionID, at: Date())
            },
            onConnected: { [weak self] in
                guard let self else { return }
                self.store.recordSseConnected(sessionId: self.sessionID, at: Date())
            },
            onDisconnected: { [weak self] in
                guard let self else { return }
                self.store.recordSseDisconnected(sessionId: self.sessionID)
            }
        )
        let client = PaiSseClient(
            sessionId: sessionID, requestFactory: requestFactory, callbacks: callbacks, initialCursor: initialCursor)
        sseClient = client
        client.connect()
    }

    /// Routed separately from ``applySseBatch(_:)`` — the two differ by exactly one call,
    /// `evictOldSessions()` (`TranscriptStore.applySseInit`'s own doc comment), which only the
    /// real init event should trigger.
    private func applySseInit(_ event: SseInitEvent) {
        store.applySseInit(sessionId: sessionID, event: event)
        recomputeRows(applying: .stickToBottomIfPinned)
    }

    private func applySseBatch(_ event: SseBatchEvent) {
        store.applySseBatch(sessionId: sessionID, event: event)
        recomputeRows(applying: .stickToBottomIfPinned)
    }

    private func applyStatus(_ event: SseStatusEvent) {
        store.applySseStatus(sessionId: sessionID, event: event)
    }

    // MARK: - Paging older

    private func loadOlder() {
        guard !isLoadingOlder else { return }
        let window = store.window(for: sessionID)
        guard window.hasOlder, let oldestId = window.oldestLoadedId else { return }
        isLoadingOlder = true
        store.setLoadingOlder(sessionID, loading: true)
        Task { [weak self] in
            guard let self else { return }
            defer { self.isLoadingOlder = false }
            do {
                let entries = try await self.apiClient.getMessages(
                    sessionId: self.sessionID, page: .before(id: oldestId, limit: TranscriptStore.olderPageLimit))
                self.store.prependOlder(
                    sessionId: self.sessionID, entries: entries, requestedLimit: TranscriptStore.olderPageLimit)
                self.recomputeRows(applying: .compensateFromTopVisibleRow)
            } catch {
                self.store.setOlderError(
                    self.sessionID, error: (error as? PaiError)?.userMessage ?? "Couldn't load earlier messages")
            }
        }
    }

    private func checkOlderPageTrigger() {
        guard !isLoadingOlder, store.window(for: sessionID).hasOlder else { return }
        guard let firstVisible = collectionView.indexPathsForVisibleItems.map(\.item).min() else { return }
        if firstVisible < Self.olderPageTriggerRowMargin {
            loadOlder()
        }
    }

    // MARK: - Paging newer

    /// Symmetric to ``loadOlder()`` — reached only once a `locate` has landed a window somewhere
    /// other than the tail (search-virtualization design). Appending below never moves anything
    /// a reader is looking at, unlike a prepend, so this needs no scroll compensation of its own;
    /// `.stickToBottomIfPinned` already carries that reasoning for an ordinary SSE append.
    private func loadNewer() {
        guard !store.window(for: sessionID).loadingNewer else { return }
        let window = store.window(for: sessionID)
        guard window.hasNewer, let newestId = window.newestLoadedId else { return }
        store.setLoadingNewer(sessionID, loading: true)
        Task { [weak self] in
            guard let self else { return }
            do {
                let entries = try await self.apiClient.getMessages(
                    sessionId: self.sessionID, page: .after(id: newestId, limit: TranscriptStore.olderPageLimit))
                self.store.appendNewer(
                    sessionId: self.sessionID, entries: entries, requestedLimit: TranscriptStore.olderPageLimit)
                await self.catchUpOnPendingNewerIfSettled()
                self.recomputeRows(applying: .stickToBottomIfPinned)
            } catch {
                self.store.setNewerError(
                    self.sessionID, error: (error as? PaiError)?.userMessage ?? "Couldn't load newer messages")
            }
        }
    }

    /// The reason `loadNewer()` is not a mirror-image one-liner of `loadOlder()`: the page above
    /// can come back short (settling `hasNewer` false) while a live message arrived via SSE in
    /// the exact gap between that query being issued and this line running. SSE cannot have
    /// appended it — `TranscriptStore.foldLiveEntries` holds it aside by id for precisely this
    /// reason while the window is not at the tail — so without this one more fetch, it would be
    /// silently lost from the window forever, with nothing left to notice.
    private func catchUpOnPendingNewerIfSettled() async {
        let settled = store.window(for: sessionID)
        guard !settled.hasNewer else { return }
        guard let highWaterMark = store.getPendingNewerHighWaterMark(sessionID), let newestId = settled.newestLoadedId,
            highWaterMark > newestId
        else {
            // Whatever was held aside is now either in the window already or was never actually
            // beyond it once this page's own results landed — either way, nothing is pending.
            store.clearPendingNewer(sessionID)
            return
        }
        store.setLoadingNewer(sessionID, loading: true)
        do {
            let entries = try await apiClient.getMessages(
                sessionId: sessionID, page: .after(id: newestId, limit: TranscriptStore.olderPageLimit))
            store.appendNewer(sessionId: sessionID, entries: entries, requestedLimit: TranscriptStore.olderPageLimit)
        } catch {
            // Best-effort: the pending set stays as a record that something is still missing,
            // and the next `loadNewer()` (another sentinel trigger, or a jump to the latest)
            // tries again.
            return
        }
        store.clearPendingNewer(sessionID)
    }

    private func checkNewerPageTrigger() {
        guard !store.window(for: sessionID).loadingNewer, store.window(for: sessionID).hasNewer else { return }
        guard let lastVisible = collectionView.indexPathsForVisibleItems.map(\.item).max() else { return }
        if lastVisible > rows.count - 1 - Self.olderPageTriggerRowMargin {
            loadNewer()
        }
    }

    // MARK: - Row measurement

    private enum UpdateIntent {
        /// A prepend, an expand/collapse, or a width/Dynamic-Type change — anything that can move
        /// content above the reader. Corrected by the delta the current top-visible row moved.
        case compensateFromTopVisibleRow
        /// New content arrived (SSE). Sticks to the bottom only if the latch says the reader was
        /// already following; otherwise nothing above the fold moves, so nothing is corrected.
        case stickToBottomIfPinned
        /// The very first load — lands at the resolved restore target (the live edge, or a row
        /// from a previous visit still in the loaded window) and begins the matching hold, since
        /// the layout is still settling immediately after `reloadData()`.
        case initialLoad(TranscriptRestoreTarget)
    }

    /// `onSettled` runs once the layout this call produces has actually landed — honoured only
    /// by `.compensateFromTopVisibleRow`, which is the only intent `reveal(_:)` ever recomputes
    /// under. That is what lets a locate-and-reveal expand a collapsed card and scroll to it
    /// with no settle hold at all (design row 25's own note): the layout precomputes every
    /// height synchronously, so this one completion, timed to the actual layout pass rather than
    /// to when the call returns, is all a caller needs.
    private func recomputeRows(applying intent: UpdateIntent, onSettled: (() -> Void)? = nil) {
        guard !isApplyingRows else {
            hasPendingRecompute = true
            Task { @MainActor [weak self] in
                guard let self, self.hasPendingRecompute else { return }
                self.hasPendingRecompute = false
                self.recomputeRows(applying: intent, onSettled: onSettled)
            }
            return
        }

        // Sends with no entry of their own yet ride along at the tail as ordinary rows — see
        // `Message.pendingBubble(sessionId:index:text:)` for why they are synthesised messages
        // rather than a row kind of their own.
        let displayMessages =
            TranscriptStore.displayMessages(store.messages[sessionID] ?? [])
            + store.pendingBubbleTexts(sessionId: sessionID).enumerated().map { index, text in
                Message.pendingBubble(sessionId: sessionID, index: index, text: text)
            }
        let width = measurementWidth()
        guard width > 0 else { return }
        let environment = MeasurementEnvironment(
            sizeCategoryToken: traitCollection.preferredContentSizeCategory.rawValue)
        let metrics = MessageLayoutMetrics(blockSpacing: TranscriptContentMetrics.blockSpacing)

        var newRows: [TranscriptRow] = []
        newRows.reserveCapacity(displayMessages.count)
        for message in displayMessages {
            let isExpanded = expandResolver(forMessageId: message.id)
            guard
                let height = TranscriptRowLayout.height(
                    for: message, width: width, environment: environment, isExpanded: isExpanded, measurer: measurer,
                    cache: cache, metrics: metrics)
            else { continue }
            newRows.append(TranscriptRow(id: message.id, message: message, height: height))
        }

        #if DEBUG
            // The one question a screenshot of this screen cannot answer: whether an empty
            // transcript means no messages arrived, no rows survived measurement, or rows exist
            // with no height. All three look identical, and every automated check passes for all
            // three.
            DebugLogBuffer.shared.append(
                .info, "transcript",
                "recomputeRows width=\(Int(width)) messages=\(displayMessages.count) "
                    + "rows=\(newRows.count) totalHeight=\(Int(newRows.reduce(0) { $0 + $1.height }))")
        #endif

        isApplyingRows = true
        defer { isApplyingRows = false }
        apply(newRows, intent: intent, onSettled: onSettled)
    }

    private func expandResolver(forMessageId messageId: Int) -> (String) -> Bool {
        { [weak self] key in
            guard let self else { return false }
            if let override = self.expandOverrides["\(messageId)#\(key)"] { return override }
            return self.settings.isExpandEnabled(key)
        }
    }

    private func toggleExpand(messageId: Int, key: String) {
        let overrideKey = "\(messageId)#\(key)"
        let current = expandOverrides[overrideKey] ?? settings.isExpandEnabled(key)
        expandOverrides[overrideKey] = !current
        recomputeRows(applying: .compensateFromTopVisibleRow)
    }

    // MARK: - Search: find / locate / reveal / mark

    /// Every occurrence of the current query inside `messageId`'s own rendered text, computed
    /// on demand from whatever is already loaded — never a precomputed array over the whole
    /// window, which is exactly the cost this design avoids. `TranscriptSearchIndex` still does
    /// the counting; only its SCOPE changed, from "the whole loaded window" to "one message at a
    /// time". Empty whenever there is no needle (kind mode has none to paint — matching the
    /// web's own `useSearchHighlight`, which clears rather than paints when `needle` is empty) or
    /// the message is not one `matchedIds` already says matches.
    private func searchHighlights(forMessageId messageId: Int) -> [TranscriptSearchHit] {
        guard searchState.isActive, !searchState.query.isEmpty, searchState.matchedIds.contains(messageId),
            let message = store.messages[sessionID]?.first(where: { $0.id == messageId })
        else { return [] }
        return TranscriptSearchIndex.hits(in: [message], query: searchState.query).hits
    }

    /// Which of `hits` (already scoped to one message by ``searchHighlights(forMessageId:)``) is
    /// the current one, by ordinal — never by re-deriving "current" from anything else, since the
    /// ordinal `searchState.inner` already holds is the single source of truth for it.
    private func currentSearchHit(forMessageId messageId: Int, among hits: [TranscriptSearchHit])
        -> TranscriptSearchHit?
    {
        guard messageId == searchState.currentMessageId, let ordinal = searchState.inner?.ordinal,
            hits.indices.contains(ordinal)
        else { return nil }
        return hits[ordinal]
    }

    /// Recursive `withObservationTracking` registration — the standard way to react to an
    /// `@Observable` outside a SwiftUI view body. Every access inside the tracking closure is
    /// what is watched; `onChange` fires once per mutation and has to re-register itself to keep
    /// watching, or the second keystroke would go unnoticed.
    private func observeSearchState() {
        withObservationTracking {
            _ = searchState.isActive
            _ = searchState.query
            _ = searchState.kind
            _ = searchState.pendingStep
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.handleSearchStateChange()
                self?.observeSearchState()
            }
        }
    }

    private func handleSearchStateChange() {
        if searchState.isActive, !hasBegunCurrentSearchSession {
            hasBegunCurrentSearchSession = true
            searchOpenedAtMessageId = topVisibleRowId()
        } else if !searchState.isActive, hasBegunCurrentSearchSession {
            hasBegunCurrentSearchSession = false
            lastSearchedQuery = nil
            lastSearchedKind = nil
            findDebounceTask?.cancel()
            hitIds = []
            clearSearchHighlighting()
        }

        if searchState.query != lastSearchedQuery || searchState.kind != lastSearchedKind {
            scheduleFind()
        }

        if let step = searchState.consumePendingStep() {
            Task { [weak self] in await self?.performStep(step) }
        }
    }

    private func scheduleFind() {
        lastSearchedQuery = searchState.query
        lastSearchedKind = searchState.kind
        findDebounceTask?.cancel()
        findDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.findDebounce)
            guard !Task.isCancelled else { return }
            await self?.runFind()
        }
    }

    /// `find`: asks the server for every id matching the query/kind, then lands on the first hit
    /// at or after where the reader is (search-virtualization design) — never a long journey to
    /// the oldest hit, the same convention the client-only version always used.
    private func runFind() async {
        let query = searchState.query
        let kind = searchState.kind
        findToken += 1
        let token = findToken

        // Instant highlight: whatever is already loaded and matches, painted the moment the
        // request is sent rather than once it answers. Kind mode has no client-side equivalent —
        // there is no needle to scan the loaded window for.
        let instant: Set<Int> =
            query.isEmpty
            ? []
            : Set(
                TranscriptSearchIndex.hits(
                    in: TranscriptStore.displayMessages(store.messages[sessionID] ?? []), query: query
                )
                .hits.map(\.messageId))
        searchState.beginFind(instantMatchedIds: instant)
        reconfigureVisibleCells()

        guard !query.isEmpty || kind != nil else {
            hitIds = []
            searchState.clearResults()
            reconfigureVisibleCells()
            return
        }

        do {
            let result = try await apiClient.findMessages(
                sessionId: sessionID, q: query.isEmpty ? nil : query, kind: kind?.rawValue,
                limit: TranscriptSearchIndex.maxHits)
            guard token == findToken else { return }  // a newer query/kind superseded this one
            hitIds = result.messageIds
            searchState.applyFindResult(
                total: result.total, capped: result.capped,
                serverMatchedIdsForKindMode: query.isEmpty ? result.messageIds : nil)
            reconfigureVisibleCells()
            guard !result.messageIds.isEmpty else { return }
            var startIndex = 0
            if let openedAt = searchOpenedAtMessageId {
                if let forward = result.messageIds.firstIndex(where: { $0 >= openedAt }) {
                    startIndex = forward
                } else {
                    startIndex = result.messageIds.count - 1
                }
            }
            await landOn(index: startIndex, direction: .forward)
        } catch {
            guard token == findToken else { return }
            searchState.setError((error as? PaiError)?.userMessage ?? "Search failed")
        }
    }

    private enum StepDirection { case forward, backward }

    /// Lands on `hitIds[index]`: `locate`s it, counts its occurrences in the loaded, rendered
    /// text, reveals, and commits the new position.
    private func landOn(index: Int, direction: StepDirection) async {
        guard hitIds.indices.contains(index) else { return }
        let messageId = hitIds[index]
        let token = findToken
        let loaded = await locate(messageId)
        guard token == findToken else { return }  // a newer step/search superseded this one
        guard loaded else {
            // A hit the server listed a moment ago is now gone (a reingest) — dropped rather
            // than retried, since a server-derived hit's own contract is "not here" means
            // "gone", not "not yet". Left where it was; the next explicit step tries its
            // neighbour.
            return
        }

        let query = searchState.query
        if !query.isEmpty, let message = store.messages[sessionID]?.first(where: { $0.id == messageId }) {
            let hits = TranscriptSearchIndex.hits(in: [message], query: query).hits
            if !hits.isEmpty {
                let ordinal = direction == .backward ? hits.count - 1 : 0
                searchState.commitLanding(outerIndex: index, messageId: messageId, inner: (ordinal, hits.count))
                await revealHit(hits[ordinal])
                return
            }
        }
        // A kind hit, or a text hit that counted to zero here (the term sat in a field the
        // client does not render) — still a row-level landing, no inner counter.
        searchState.commitLanding(outerIndex: index, messageId: messageId, inner: nil)
        revealRow(messageId, ringAsDeepLink: false)
    }

    /// The inner ordinal steps first; the outer cursor only advances once it runs out, wrapping
    /// around the hit list the same way the stepping chevrons always have — the decision itself
    /// is `TranscriptSearchState`'s own pure function, this only ever executes it.
    private func performStep(_ step: TranscriptSearchState.PendingStep) async {
        let decision =
            step == .next ? searchState.next(hitCount: hitIds.count) : searchState.previous(hitCount: hitIds.count)
        switch decision {
        case .none:
            return
        case .innerOnly(let ordinal):
            searchState.stepInner(to: ordinal)
            guard let messageId = searchState.currentMessageId,
                let message = store.messages[sessionID]?.first(where: { $0.id == messageId })
            else { return }
            let hits = TranscriptSearchIndex.hits(in: [message], query: searchState.query).hits
            guard hits.indices.contains(ordinal) else { return }
            await revealHit(hits[ordinal])
        case .outerIndex(let index):
            await landOn(index: index, direction: step == .next ? .forward : .backward)
        }
    }

    /// `locate`'s own two stages: already-loaded is a no-op, else fetch `around_id` and merge
    /// into the window when the page overlaps or abuts it, replace the window outright when it
    /// doesn't (search-virtualization design — "the around page, and merge-or-replace").
    /// `retryLadder` turns a 404 from "the row is gone, give up" into "not ingested yet, try
    /// again" — a deep link's own contract; a server-derived hit never passes one, since a 404
    /// there means it vanished under a reingest.
    private func locate(_ messageId: Int, retryLadder: [Duration] = []) async -> Bool {
        if isLoaded(messageId) { return true }

        for attempt in 0...retryLadder.count {
            switch try? await apiClient.messages(
                around: messageId, limit: TranscriptStore.olderPageLimit, sessionId: sessionID)
            {
            case .ok(let entries):
                guard !entries.isEmpty else { return false }
                mergeOrReplaceWindow(entries: entries, aroundId: messageId)
                await settleRows()
                return isLoaded(messageId)
            case .notFound, nil:
                guard attempt < retryLadder.count else { return false }
                try? await Task.sleep(for: retryLadder[attempt])
            }
        }
        return false
    }

    private func isLoaded(_ messageId: Int) -> Bool {
        store.messages[sessionID]?.contains { $0.id == messageId } ?? false
    }

    private func mergeOrReplaceWindow(entries: [Message], aroundId: Int) {
        guard let pageMin = entries.map(\.id).min(), let pageMax = entries.map(\.id).max() else { return }
        let win = store.window(for: sessionID)
        if TranscriptStore.overlapsOrAbuts(win, pageMin: pageMin, pageMax: pageMax) {
            store.mergeWindow(
                sessionId: sessionID, entries: entries, aroundId: aroundId, limit: TranscriptStore.olderPageLimit)
        } else {
            store.replaceWindow(
                sessionId: sessionID, entries: entries, aroundId: aroundId, limit: TranscriptStore.olderPageLimit)
        }
    }

    /// Recomputes rows and waits for the layout it produces to actually land, rather than
    /// returning as soon as the call is made — `reveal`'s whole "no settle hold" claim (design
    /// row 25's own note) depends on the caller seeing FRESH `rows`/`layout` the instant this
    /// returns, not a moment later on some other run-loop turn.
    private func settleRows() async {
        guard measurementWidth() > 0 else { return }
        await withCheckedContinuation { continuation in
            recomputeRows(applying: .compensateFromTopVisibleRow) { continuation.resume() }
        }
    }

    /// Opens the hit's card if it is collapsed FIRST, and only scrolls once that settles — the
    /// ordering that makes "no settle hold" true at all: nothing changes height after the
    /// landing frame, because nothing can. Then reads the live viewport's own 30%-lead at the
    /// moment of the scroll itself, never a value computed earlier — a keyboard or safe-area
    /// change in between is what used to land it wrong.
    private func revealHit(_ hit: TranscriptSearchHit) async {
        if let key = hit.expandKey, !expandResolver(forMessageId: hit.messageId)(key) {
            expandOverrides["\(hit.messageId)#\(key)"] = true
            await settleRows()
        }
        let width = measurementWidth()
        guard width > 0, let index = rows.firstIndex(where: { $0.id == hit.messageId }) else { return }
        let environment = MeasurementEnvironment(
            sizeCategoryToken: traitCollection.preferredContentSizeCategory.rawValue)
        let metrics = MessageLayoutMetrics(blockSpacing: TranscriptContentMetrics.blockSpacing)
        let blockOffset =
            TranscriptRowLayout.blockOffset(
                cardIndex: hit.cardIndex, blockIndex: hit.blockIndex, for: rows[index].message, width: width,
                environment: environment, isExpanded: expandResolver(forMessageId: hit.messageId), measurer: measurer,
                cache: cache, metrics: metrics) ?? 0
        scrollToTarget(messageId: hit.messageId, blockOffset: blockOffset)
        reconfigureVisibleCells()
    }

    /// Lands on the row's own top (minus the 30%-from-top lead) — the honest position for a
    /// target with no specific text occurrence: a kind hit, or a deep link, whose target is the
    /// whole message rather than one range inside it. `ringAsDeepLink` draws the deep-link ring
    /// instead of a search highlight, matching which caller this is.
    private func revealRow(_ messageId: Int, ringAsDeepLink: Bool) {
        scrollToTarget(messageId: messageId, blockOffset: 0)
        if ringAsDeepLink {
            beginDeepLinkHighlight(for: messageId)
        } else {
            reconfigureVisibleCells()
        }
    }

    /// A row can run to thousands of points, so scrolling only to its top would not bring a hit
    /// deep inside it on screen. Lands a third of the way down the viewport rather than flush at
    /// the top, leaving room to read what comes before it (the web's own `SEARCH_ROW_LEAD`).
    ///
    /// No settle hold: the layout precomputes every row height synchronously before this ever
    /// runs, so this one write lands exactly, PROVIDED the caller already settled any height
    /// change (`revealHit`'s own expand-first step) and this reads the viewport live, which is
    /// exactly what it does.
    private func scrollToTarget(messageId: Int, blockOffset: Double) {
        guard let rowTop = layout.offsetTop(forRowId: messageId) else { return }
        let lead = collectionView.bounds.height * 0.3
        let target = max(0, min(maxContentOffsetY(), CGFloat(rowTop + blockOffset) - lead))
        collectionView.setContentOffset(CGPoint(x: 0, y: target), animated: true)
        edgeFollow = EdgeFollowLatch(isPinned: false)
        updateJumpToLatestVisibility()
    }

    private func clearSearchHighlighting() {
        reconfigureVisibleCells()
    }

    /// Forces every visible cell to redraw with whatever it should show right now — search
    /// highlighting turning on or off, or the deep-link ring beginning or fading. Shared by both
    /// rather than each keeping its own copy, since a cell's `UIHostingConfiguration` closure
    /// (`cellForItemAt`) already reads every one of these flags fresh on every call.
    private func reconfigureVisibleCells() {
        let visible = collectionView.indexPathsForVisibleItems
        if !visible.isEmpty { collectionView.reconfigureItems(at: visible) }
    }

    // MARK: - Applying a new row list

    private func apply(_ newRows: [TranscriptRow], intent: UpdateIntent, onSettled: (() -> Void)? = nil) {
        let oldIds = rows.map(\.id)
        let newIds = newRows.map(\.id)
        let delta = RowDelta.compute(old: oldIds, new: newIds)

        switch intent {
        case .initialLoad(let target):
            pendingInitialLoad = nil
            commitRows(newRows)
            collectionView.reloadData()
            // `scrollToItem` right after `reloadData()` runs before the new layout's `prepare()`
            // has — forcing it here is the usual guard against landing at the wrong place, or not
            // moving at all.
            collectionView.layoutIfNeeded()
            switch target {
            case .bottom:
                edgeFollow = EdgeFollowLatch(isPinned: true)
                scrollToBottom(animated: false)
                holdController.begin(.bottom)
            case .message(let id):
                if let index = rows.firstIndex(where: { $0.id == id }) {
                    edgeFollow = EdgeFollowLatch(isPinned: false)
                    collectionView.scrollToItem(at: IndexPath(item: index, section: 0), at: .top, animated: false)
                    holdController.begin(.restore(messageId: id))
                } else {
                    // The row named by the restore target isn't in this load after all — the
                    // display filter can drop it even though `loadedMessageIds` at bootstrap said
                    // it was there. The bottom is the same predictable fallback
                    // `TranscriptRestore.target` itself uses when it cannot honour an anchor.
                    edgeFollow = EdgeFollowLatch(isPinned: true)
                    scrollToBottom(animated: false)
                    holdController.begin(.bottom)
                }
            }
            updateJumpToLatestVisibility()
            return

        case .compensateFromTopVisibleRow:
            let anchorId = topVisibleRowId()
            let anchorOffsetBefore = anchorId.flatMap { layout.offsetTop(forRowId: $0) }
            if let anchorId, let anchorOffsetBefore {
                layout.pendingAnchor = (id: anchorId, offsetTopBeforeUpdate: anchorOffsetBefore)
            }
            applyDelta(delta, newRows: newRows, oldCount: oldIds.count) { [weak self] in
                self?.reassertHoldIfNeeded()
                onSettled?()
            }

        case .stickToBottomIfPinned:
            let shouldStick = edgeFollow.isPinned
            applyDelta(delta, newRows: newRows, oldCount: oldIds.count) { [weak self] in
                guard let self else { return }
                if self.reassertHoldIfNeeded() { return }
                guard shouldStick else { return }
                self.scrollToBottom(animated: true)
            }
        }
    }

    /// Hands `newRows` to the data source and tells UIKit what changed.
    ///
    /// 🚨 The model is committed **inside** the update block, never before it. `performBatchUpdates`
    /// asks the data source for the pre-update count itself whenever its cached one is stale — a
    /// pending `reloadData()` that no layout pass has resolved yet, which is the normal state
    /// off screen and while the app runs in the background behind a recording. Commit first and
    /// that question is answered with the *new* count, so UIKit sees "462 before, 462 after, three
    /// inserts" and raises `_Bug_Detected_In_Client_Of_UICollectionView_...`. Committing inside the
    /// block is the documented contract and makes the arithmetic true whether or not the cache was
    /// fresh.
    private func applyDelta(
        _ delta: RowDelta, newRows: [TranscriptRow], oldCount: Int, completion: (() -> Void)?
    ) {
        // `oldCount` is this controller's own bookkeeping (`rows.count` before the update it
        // describes) — not UIKit's, which tracks its own item count from the data source at its
        // last completed layout pass. The two normally agree, but the `isApplyingRows` guard
        // above exists precisely because a re-entrant layout pass could otherwise call this a
        // second time before the first has finished mutating `rows`/the collection view, and an
        // `insertItems(at:)` built against a count that no longer matches what UIKit actually has
        // on screen is exactly what `_Bug_Detected_In_Client_Of_UICollectionView_...` raises for.
        // Trust nothing the guard cannot also verify: a mismatch here falls back to a full reload,
        // same as `.replaced`, rather than asserting an insert UIKit did not ask for.
        let actualCount = collectionView.numberOfItems(inSection: 0)
        guard actualCount == oldCount || delta == .unchanged || delta == .replaced else {
            // A `reloadData()` here throws away the update `.pendingAnchor` was set for — leaving
            // it set would apply a stale snapshot's correction to whatever update next reaches
            // `.unchanged`, an arbitrary jump unrelated to anything that update actually moved.
            layout.pendingAnchor = nil
            self.commitRows(newRows)
            collectionView.reloadData()
            completion?()
            return
        }

        switch delta {
        case .unchanged:
            self.commitRows(newRows)
            // Row ids are unchanged — an id-based diff cannot distinguish "same rows, new
            // heights or content" (an expand/collapse toggle, a width or Dynamic Type change, a
            // streamed edit to the last loaded message) from a true no-op, so this branch always
            // runs for those. `reconfigureItems(at:)` re-runs `cellForItemAt` for the cells
            // currently mounted, which is what actually redraws a card's content —
            // `invalidateLayout()` alone only re-applies frames, since `UIHostingConfiguration`
            // rebuilds on assignment, not on a size change.
            //
            // Done outside `performBatchUpdates`: its documented update-block contract is
            // inserts/deletes/moves/reloads, and a call with none of those has no item-count
            // change to animate, so nothing guarantees `targetContentOffset(forProposedContentOffset:)`
            // runs — the mechanism the `.appended`/`.prepended` branches below rely on, and a call
            // to `invalidateLayout()` with nothing to animate is a known source of layout-update
            // exceptions. `layoutIfNeeded()` forces the new layout's `prepare()` to run
            // synchronously, in the same run-loop turn, so the anchor's new offset can be read and
            // the same delta correction applied directly.
            let visible = collectionView.indexPathsForVisibleItems
            if !visible.isEmpty {
                collectionView.reconfigureItems(at: visible)
            }
            let anchor = layout.pendingAnchor
            layout.pendingAnchor = nil
            collectionView.collectionViewLayout.invalidateLayout()
            collectionView.layoutIfNeeded()
            if let anchor, let newTop = layout.offsetTop(forRowId: anchor.id) {
                let correction = newTop - anchor.offsetTopBeforeUpdate
                if correction != 0 {
                    collectionView.contentOffset.y += correction
                }
            }
            completion?()

        case .appended(let count):
            let indexPaths = (oldCount..<(oldCount + count)).map { IndexPath(item: $0, section: 0) }
            collectionView.performBatchUpdates({
                self.commitRows(newRows)
                collectionView.insertItems(at: indexPaths)
            }) { _ in completion?() }

        case .prepended(let count):
            let indexPaths = (0..<count).map { IndexPath(item: $0, section: 0) }
            collectionView.performBatchUpdates({
                self.commitRows(newRows)
                collectionView.insertItems(at: indexPaths)
            }) { _ in completion?() }

        case .tailReplaced(let commonPrefix, let removed, let inserted):
            // Deletes index into the OLD list and inserts into the NEW one, which is exactly
            // `performBatchUpdates`' contract — so the two ranges legitimately overlap. Kept in
            // one batch, and not a reload, so `targetContentOffset(forProposedContentOffset:)`
            // still runs and the anchor set for this update is still honoured: everything above
            // `commonPrefix` is untouched, and the reader is sitting in it.
            let deletes = (commonPrefix..<(commonPrefix + removed)).map { IndexPath(item: $0, section: 0) }
            let inserts = (commonPrefix..<(commonPrefix + inserted)).map { IndexPath(item: $0, section: 0) }
            collectionView.performBatchUpdates({
                self.commitRows(newRows)
                if !deletes.isEmpty { collectionView.deleteItems(at: deletes) }
                if !inserts.isEmpty { collectionView.insertItems(at: inserts) }
            }) { _ in completion?() }

        case .replaced:
            // Same reasoning as the count-mismatch fallback above: this reload discards whatever
            // update set `.pendingAnchor`, so the anchor must not survive it either.
            layout.pendingAnchor = nil
            self.commitRows(newRows)
            collectionView.reloadData()
            completion?()
        }
    }

    /// The one place `rows` and the layout's copy of it change together — they describe the same
    /// list to two readers, and a pass where only one of them moved is a wrong height applied to
    /// the wrong row.
    private func commitRows(_ newRows: [TranscriptRow]) {
        rows = newRows
        layout.rows = newRows.map { TranscriptLayout.Row(id: $0.id, height: $0.height) }
    }

    private func scrollToBottom(animated: Bool) {
        guard !rows.isEmpty else { return }
        collectionView.scrollToItem(at: IndexPath(item: rows.count - 1, section: 0), at: .bottom, animated: animated)
    }

    private func measurementWidth() -> Double {
        Double(
            max(
                0, view.bounds.width - view.safeAreaInsets.left - view.safeAreaInsets.right - layout.horizontalInset * 2
            ))
    }

    // MARK: - Anchoring

    /// The row currently at the top of the viewport, from the layout's last completed `prepare()`
    /// — read before any mutation, never after.
    ///
    /// Rows are laid out top-to-bottom with a monotonically increasing offset (`TranscriptLayout`
    /// never reorders or overlaps them), so a binary search finds the last one whose top is at or
    /// above the viewport's own top edge in O(log n) — this runs on every `scrollViewDidScroll`,
    /// the one place on the transcript path that is on the main thread inside a scroll callback,
    /// so an O(rows-above-the-fold) scan is the one place it could show up as stutter.
    private func topVisibleRowId() -> Int? {
        guard !rows.isEmpty else { return nil }
        let top = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
        var low = 0
        var high = rows.count - 1
        var candidate = rows[0].id
        while low <= high {
            let mid = (low + high) / 2
            guard let offset = layout.offsetTop(forRowId: rows[mid].id) else { break }
            if offset <= top {
                candidate = rows[mid].id
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return candidate
    }

    /// Re-drives the held scroll target if a hold is active — the hold's entire purpose, since
    /// rows mounting or resizing while it is protecting a position otherwise move the reader off
    /// it. Re-extends the hold's own window too, matching ``TranscriptHold``'s doc comment ("call
    /// this every time the layout it is protecting settles again"). Returns whether it acted, so a
    /// caller with its own scroll for the same event can skip it rather than compete.
    @discardableResult
    private func reassertHoldIfNeeded() -> Bool {
        guard holdController.isActive, let hold = holdController.hold else { return false }
        holdController.extend()
        switch hold.kind {
        case .bottom:
            scrollToBottom(animated: false)
            return true
        case .restore(let messageId), .jump(let messageId):
            guard let index = rows.firstIndex(where: { $0.id == messageId }) else { return false }
            collectionView.scrollToItem(at: IndexPath(item: index, section: 0), at: .top, animated: false)
            return true
        }
    }

    /// A stateless geometry check (`EdgeFollowLatch.isAtLiveEdge`'s own doc comment), deliberately
    /// not driven by `edgeFollow.isPinned` — a reader who scrolled up and drifted back close to the
    /// bottom without landing inside the latch's narrower re-pin threshold should still see the
    /// control disappear, since visually they are back at the edge.
    private func updateJumpToLatestVisibility() {
        let distance = maxContentOffsetY() - collectionView.contentOffset.y
        jumpToLatestHostingController.view.isHidden = EdgeFollowLatch.isAtLiveEdge(distanceFromBottom: Double(distance))
    }

    private func jumpToLatestTapped() {
        edgeFollow = EdgeFollowLatch(isPinned: true)
        holdController.release()
        scrollToBottom(animated: true)
    }

    private func maxContentOffsetY() -> CGFloat {
        max(
            0,
            collectionView.contentSize.height - collectionView.bounds.height
                + collectionView.adjustedContentInset.bottom)
    }

    private func recordCurrentAnchor() {
        guard let id = topVisibleRowId(), let offsetTop = layout.offsetTop(forRowId: id) else { return }
        let viewportOffset = offsetTop - collectionView.contentOffset.y
        let distance = maxContentOffsetY() - collectionView.contentOffset.y
        let anchor = TranscriptAnchor(
            messageId: id, offset: Double(viewportOffset),
            atLiveEdge: EdgeFollowLatch.isAtLiveEdge(distanceFromBottom: Double(distance)))
        lastRecordedAnchor = anchor
        // Kept beyond this instance's own lifetime — see `lastAnchors`'s doc comment.
        Self.lastAnchors[sessionID] = anchor
        scheduleReadPositionSave()
    }

    /// One request per burst of scrolling rather than one per frame — restarted on every new
    /// anchor, same shape as the web's `scheduleReadPositionSave`.
    private func scheduleReadPositionSave() {
        readPositionSaveTask?.cancel()
        readPositionSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.flushReadPositionSaveNow()
        }
    }

    /// Sends whatever is pending right now rather than waiting out the debounce — for the app
    /// backgrounding, or this controller being torn down, where the window might never otherwise
    /// elapse. Best-effort: the in-memory anchor and the next successful save stay the source of
    /// truth for this device: a lost write only costs a relaunch landing one scroll behind.
    private func flushReadPositionSaveNow() {
        readPositionSaveTask?.cancel()
        readPositionSaveTask = nil
        guard let anchor = lastRecordedAnchor else { return }
        // Read live, not from whatever `hasNewer` was when the anchor was recorded — this can
        // fire well after that scroll, and `loadNewer`'s catch-up can have settled the flag in
        // between.
        let payload = TranscriptAnchor.readPositionPayload(for: anchor, hasNewer: store.window(for: sessionID).hasNewer)
        Task {
            try? await apiClient.putReadPosition(
                sessionId: sessionID, messageId: payload.messageId, offsetPx: payload.offsetPx,
                atBottom: payload.atBottom)
        }
    }

    // MARK: - UIScrollViewDelegate (via UICollectionViewDelegate)

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        recordCurrentAnchor()
        let distance = maxContentOffsetY() - scrollView.contentOffset.y
        edgeFollow.recordDistanceFromBottom(Double(distance))
        updateJumpToLatestVisibility()
        checkOlderPageTrigger()
        checkNewerPageTrigger()
        if holdController.isActive {
            holdController.extend()
        }
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        // iOS has no wheel-delta to read a direction from at the moment a drag begins, unlike the
        // web's asymmetric wheel/touch rule (`references/native.md`). Un-pinning unconditionally
        // here and re-pinning from `scrollViewDidScroll`'s distance sample once the drag actually
        // lands back within the latch's re-pin threshold reproduces the same end behaviour: a
        // short flick up still does not snap back down, since the distance never gets there.
        edgeFollow.recordScrollAway()
        holdController.release()
        // The deep-link ring's other release path — "fading out after ~4s or on the first
        // deliberate gesture" (row 5.28's design). A drag is exactly that gesture.
        clearDeepLinkHighlight()
    }

    // MARK: - UICollectionViewDataSource

    func numberOfSections(in collectionView: UICollectionView) -> Int { 1 }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        rows.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell
    {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: Self.cellReuseIdentifier, for: indexPath)
        guard indexPath.item < rows.count else { return cell }
        let row = rows[indexPath.item]
        let messageId = row.id
        // Weak throughout: `contentConfiguration` is retained by the cell, which the collection
        // view pools and keeps around off-screen — a strong `self` here would keep this
        // controller (and everything it owns, including the SSE connection) alive indefinitely.
        cell.contentConfiguration = UIHostingConfiguration { [weak self] in
            if let self {
                let highlights = self.searchHighlights(forMessageId: messageId)
                TranscriptRowContent(
                    message: row.message,
                    sessionID: self.sessionID,
                    apiClient: self.apiClient,
                    isExpanded: self.expandResolver(forMessageId: messageId),
                    onToggleExpand: { [weak self] key in self?.toggleExpand(messageId: messageId, key: key) },
                    highlights: highlights,
                    currentHit: self.currentSearchHit(forMessageId: messageId, among: highlights),
                    isDeepLinkTarget: messageId == self.highlightedMessageId
                )
                // Faded, at the same 0.6 the web uses, so a message still on its way is
                // legible but visibly not yet part of the conversation. Opacity only — it
                // must not change the row's geometry, which was measured for a full bubble.
                .opacity(row.message.isPendingBubble ? 0.6 : 1)
                // An https link in a message gets the same accidental-tap guard notes already
                // have — a touchscreen tap can land on one without meaning to. No `onNoteLink`:
                // a transcript message is not known to carry an in-app note deep link, so one
                // falls through to `.systemAction` exactly as it did before this row asked for
                // anything at all.
                .confirmingExternalLinks()
            } else {
                EmptyView()
            }
        }
        .margins(.all, 0)
        return cell
    }
}

/// `UIViewControllerRepresentable` wrapper — the seam between the SwiftUI screen and the UIKit
/// list, per the app's own decided architecture (see `PAI/Transcript/CLAUDE.md`-adjacent notes:
/// `UICollectionView`, not SwiftUI `List`).
struct TranscriptCollectionView: UIViewControllerRepresentable {
    let sessionID: String
    let store: TranscriptStore
    let apiClient: PaiApiClient
    let settings: SettingsStore
    let requestFactory: PaiRequestFactory
    let searchState: TranscriptSearchState
    /// Where to jump once the transcript is open — row 5.28. `nil` for an ordinary open.
    var initialJumpMessageID: Int? = nil
    /// Reaches this screen for a push notification's jump while it is already on top — see
    /// `TranscriptJumpRequests`'s own doc comment for why `initialJumpMessageID` alone cannot.
    let jumpRequests: TranscriptJumpRequests
    /// What the server last held for this session's read position — `nil` when there is none, or
    /// when the caller does not know yet (a cold deep link, before `ensureSessionLoaded` returns).
    var persistedReadPosition: PersistedReadPosition? = nil

    func makeUIViewController(context: Context) -> TranscriptCollectionViewController {
        TranscriptCollectionViewController(
            sessionID: sessionID, store: store, apiClient: apiClient, settings: settings,
            requestFactory: requestFactory, searchState: searchState, initialJumpMessageID: initialJumpMessageID,
            jumpRequests: jumpRequests, persistedReadPosition: persistedReadPosition
        )
    }

    func updateUIViewController(_ uiViewController: TranscriptCollectionViewController, context: Context) {}
}
