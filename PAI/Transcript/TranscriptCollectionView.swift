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

/// How the rows changed since the last measurement pass.
///
/// A transcript's loaded window is always a contiguous, ascending suffix (``TranscriptWindow``'s
/// own doc comment) — ids are never reordered and never removed except by a whole-session LRU
/// eviction this view controller never sees, since that only ever targets a *different* session.
/// So the only shapes a change can take are these four, and telling them apart this way is what
/// lets each get exactly the scroll treatment it needs, instead of one generic diff that cannot
/// distinguish "grew at the top" from "grew at the bottom".
private enum RowDelta {
    case unchanged
    case appended(count: Int)
    case prepended(count: Int)
    /// Anything else — should not happen given the invariant above, but a full reload is the
    /// honest fallback rather than a crash if it ever does.
    case replaced

    static func compute(old: [Int], new: [Int]) -> RowDelta {
        if old == new { return .unchanged }
        if new.count > old.count, Array(new.suffix(old.count)) == old {
            return .appended(count: new.count - old.count)
        }
        if new.count > old.count, Array(new.prefix(old.count)) == old {
            return .prepended(count: new.count - old.count)
        }
        return .replaced
    }
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
/// until it runs on a device; see this block's report.
final class TranscriptCollectionViewController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegate {

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

    private let measurer = TextKitBlockMeasurer()
    private let cache = BlockHeightCache()
    private let layout = TranscriptLayout()
    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)

    private var rows: [TranscriptRow] = []
    /// `"\(messageId)#\(expandKey)"` → override. Applies to every card in that message sharing
    /// the key, not to one specific tool-call instance — a simplification from the web's true
    /// per-card `useState`, made under this block's time budget and flagged in its report.
    private var expandOverrides: [String: Bool] = [:]

    private var edgeFollow = EdgeFollowLatch()
    private let holdController = TranscriptHoldController()
    private var lastRecordedAnchor: TranscriptAnchor?
    private var isLoadingOlder = false
    private var lastMeasuredWidth: Double = -1
    private var sseClient: PaiSseClient?
    /// Where a session's own bootstrap-resolved restore target goes until it can actually be
    /// applied — `recomputeRows` is a no-op below a measured width of zero, and the bootstrap can
    /// resolve before `viewDidLayoutSubviews` has ever run once (see `apply(_:intent:)`'s
    /// `.initialLoad` case). Whichever of the two runs second is the one that applies it.
    private var pendingInitialLoad: TranscriptRestoreTarget?
    /// Every session's last recorded read position, kept only for the life of the process — the
    /// view controller itself is recreated on every navigation into a session, so an instance
    /// property alone would forget it on every return. An app relaunch always opens at the live
    /// edge; see this block's report for why that scope was chosen over persisting to disk.
    private static var lastAnchors: [String: TranscriptAnchor] = [:]

    private lazy var jumpToLatestHostingController = UIHostingController(
        rootView: JumpToLatestButton(onTap: { [weak self] in self?.jumpToLatestTapped() }))

    init(
        sessionID: String, store: TranscriptStore, apiClient: PaiApiClient, settings: SettingsStore,
        requestFactory: PaiRequestFactory
    ) {
        self.sessionID = sessionID
        self.store = store
        self.apiClient = apiClient
        self.settings = settings
        self.requestFactory = requestFactory
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        // `deinit` is nonisolated and `disconnect()` is not. Copy the reference out so the hop
        // captures the client rather than `self`, which is already being deallocated.
        let client = sseClient
        Task { @MainActor in client?.disconnect() }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.frame = view.bounds
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .clear
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(UICollectionViewCell.self, forCellWithReuseIdentifier: Self.cellReuseIdentifier)
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

        Task { await bootstrap() }
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

    private func bootstrap() async {
        store.setBootstrapping(sessionID)
        do {
            let entries = try await apiClient.getMessages(
                sessionId: sessionID, page: .tail(limit: TranscriptStore.tailLimit))
            store.applyBootstrap(sessionId: sessionID, entries: entries, requestedLimit: TranscriptStore.tailLimit)
        } catch {
            store.setBootstrapError(sessionID, error: (error as? PaiError)?.userMessage ?? "Couldn't load messages")
            return
        }
        let loadedIds = TranscriptStore.displayMessages(store.messages[sessionID] ?? []).map(\.id)
        let target = TranscriptRestore.target(for: Self.lastAnchors[sessionID], loadedMessageIds: loadedIds)
        pendingInitialLoad = target
        recomputeRows(applying: .initialLoad(target))
        connectStream(initialCursor: store.maxMessageId(for: sessionID))
    }

    private func connectStream(initialCursor: Int?) {
        let callbacks = PaiSseClient.Callbacks(
            onInit: { [weak self] event in self?.applySseInit(event) },
            onBatch: { [weak self] event in self?.applySseBatch(event) },
            onStatus: { [weak self] event in self?.applyStatus(event) },
            onConnected: { [weak self] in
                guard let self else { return }
                self.store.setSseConnected(sessionId: self.sessionID, connected: true)
            },
            onDisconnected: { [weak self] in
                guard let self else { return }
                self.store.setSseConnected(sessionId: self.sessionID, connected: false)
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

    private func recomputeRows(applying intent: UpdateIntent) {
        let displayMessages = TranscriptStore.displayMessages(store.messages[sessionID] ?? [])
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

        apply(newRows, intent: intent)
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

    // MARK: - Applying a new row list

    private func apply(_ newRows: [TranscriptRow], intent: UpdateIntent) {
        let oldIds = rows.map(\.id)
        let newIds = newRows.map(\.id)
        let delta = RowDelta.compute(old: oldIds, new: newIds)

        switch intent {
        case .initialLoad(let target):
            pendingInitialLoad = nil
            rows = newRows
            layout.rows = newRows.map { TranscriptLayout.Row(id: $0.id, height: $0.height) }
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
            rows = newRows
            layout.rows = newRows.map { TranscriptLayout.Row(id: $0.id, height: $0.height) }
            if let anchorId, let anchorOffsetBefore {
                layout.pendingAnchor = (id: anchorId, offsetTopBeforeUpdate: anchorOffsetBefore)
            }
            applyDelta(delta, oldCount: oldIds.count) { [weak self] in self?.reassertHoldIfNeeded() }

        case .stickToBottomIfPinned:
            rows = newRows
            layout.rows = newRows.map { TranscriptLayout.Row(id: $0.id, height: $0.height) }
            let shouldStick = edgeFollow.isPinned
            applyDelta(delta, oldCount: oldIds.count) { [weak self] in
                guard let self else { return }
                if self.reassertHoldIfNeeded() { return }
                guard shouldStick else { return }
                self.scrollToBottom(animated: true)
            }
        }
    }

    private func applyDelta(_ delta: RowDelta, oldCount: Int, completion: (() -> Void)?) {
        switch delta {
        case .unchanged:
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
                collectionView.insertItems(at: indexPaths)
            }) { _ in completion?() }

        case .prepended(let count):
            let indexPaths = (0..<count).map { IndexPath(item: $0, section: 0) }
            collectionView.performBatchUpdates({
                collectionView.insertItems(at: indexPaths)
            }) { _ in completion?() }

        case .replaced:
            collectionView.reloadData()
            completion?()
        }
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
        case .restore(let messageId), .search(let messageId):
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
    }

    // MARK: - UIScrollViewDelegate (via UICollectionViewDelegate)

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        recordCurrentAnchor()
        let distance = maxContentOffsetY() - scrollView.contentOffset.y
        edgeFollow.recordDistanceFromBottom(Double(distance))
        updateJumpToLatestVisibility()
        checkOlderPageTrigger()
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
                TranscriptRowContent(
                    message: row.message,
                    isExpanded: self.expandResolver(forMessageId: messageId),
                    onToggleExpand: { [weak self] key in self?.toggleExpand(messageId: messageId, key: key) }
                )
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

    func makeUIViewController(context: Context) -> TranscriptCollectionViewController {
        TranscriptCollectionViewController(
            sessionID: sessionID, store: store, apiClient: apiClient, settings: settings, requestFactory: requestFactory
        )
    }

    func updateUIViewController(_ uiViewController: TranscriptCollectionViewController, context: Context) {}
}
