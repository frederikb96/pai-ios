# Porting backlog

Deferred parity work against the backend's own client — entries that reached the "yes, needs
`PAI/`" branch of that project's parity decision rule (the backend repository is private).
Append-only: add an entry, never edit or reorder another agent's.

A row here means a view, a screen flow, or something needing a macOS or simulator run to verify —
never a field, an enum case or a `CodingKey`. Those are cheap and get ported immediately, not
listed here.

## Entry format

```
### <what> — pai-cloud anchor: <path or symbol>
Needs `PAI/` because: <one line>
```

Remove an entry once it is ported. A backlog that keeps finished work reads as a list of things
still owed, and the next agent either redoes them or stops trusting the file.

## Backlog

### Verify: the in-session right-to-left swipe actually reaches the reader — pai-cloud anchor: none, iOS-only
Needs `PAI/` because: `SessionDetailView` attaches `DragGesture(minimumDistance: 30)` via
`.simultaneousGesture` over a `UIViewControllerRepresentable` wrapping a `UICollectionView`
(`TranscriptCollectionView`) — whether a SwiftUI gesture sibling to a UIKit view's own pan/scroll
recognizers actually receives touches, rather than losing them to the collection view or a code
block's horizontal scroll, is exactly the class of question this repo's own layering doc calls
out as untestable without a device. The width/height thresholds are chosen to make an ordinary
vertical scroll fail the check, but nobody has swiped left on a real transcript and watched the
menu open.

The gesture now also requires `startLocation.x` to fall inside a trailing-edge margin
(`SessionDetailView.edgeSwipeWidth`, read via `.onGeometryChange`) before the width/height
thresholds are even considered — reasoned to make it behave like iOS's own edge swipes, and to
stop it ever competing with a horizontal drag that starts over a wide code block or table, which
never starts at the literal screen edge. Unverified for the same reason as above, plus one more:
whether a drag starting in that narrow a margin is even easy to land with a real thumb, or reads
as unreliable next to a native edge-swipe-back gesture occupying the opposite edge.

### Verify: the full-screen image viewer's pinch-to-zoom, pan and swipe-to-dismiss interplay — pai-cloud anchor: none, iOS-only
Needs `PAI/` because: `ZoomableImageView` wraps a `UIScrollView`/`UIImageView` pair for pinch and
double-tap zoom, matching Photos — `AspectFit.scale(fitting:into:)` (the one piece of arithmetic
it depends on) is unit-tested on Linux, but the gesture recognizer wiring itself is UIKit and
needs a device. Three things specifically are reasoned rather than watched: whether
`FullScreenImageViewer`'s own SwiftUI `DragGesture` (swipe-to-dismiss) still receives touches at
all now that it sits over a `UIScrollView` with its own pan recognizer, rather than over a plain
`Image` as before — the same "SwiftUI gesture sibling to a UIKit view's own recognizers" question
the transcript swipe above is already flagged for; whether gating that gesture on
`zoomScale <= 1.01` actually feels right rather than occasionally swallowing a pan meant to scroll
a barely-zoomed image; and whether double-tap-to-zoom's target point tracks the tapped location
convincingly on a real device. The Mac workflow's `fullscreen-image` fixture screenshot
(`-PaiFixtureRoute session -PaiFixtureOpenImage`, landing via `SessionDetailView`'s own
fixture-mode auto-open) proves the screen renders and its buttons are legible against the fixture
image; it cannot prove any gesture behaves.

### Verify: the ARC spec view's live refresh actually fires on an `arc` SSE signal — pai-cloud anchor: `pai_cloud.api._arc_event`
Needs `PAI/` because: `TranscriptStore.applySseArc`, `PaiSseClient`'s `"arc"` case and
`ArcSpecStore.applyLiveSignal` are each unit-tested on Linux with a synthetic event, but nothing
here can hold a real SSE connection open, watch this app receive the event, and confirm the
screen updates within a second rather than waiting for the 15s poll fallback. A write against a
live spec to trigger the event is not the obstacle — that is ordinary REST work, doable from this
VM. Running the app to watch the client side of the stream is. The poll fallback itself is real
and load-bearing regardless of whether the live path works, so this screen is never expected to
go stale for long even if the SSE half never fires as designed — but that is a claim, not yet an
observation.

### Verify: the marker bar's passed state reads clearly next to the divider rules — pai-cloud anchor: none, iOS-only
Needs `PAI/` because: `ArcMarkerBar` now swaps its centred icon for a two-word `Label` ("Passed")
when the marker's own status is Done, inside an `HStack` whose two `Rectangle` dividers are
expected to absorb the width difference — reasoned to lay out sensibly, unverified on a real
screen width whether the label crowds the dividers or wraps.

### Verify: the "Spec" swipe action and its picker sheet feel right on a real list and transcript — pai-cloud anchor: none, iOS-only
Needs `PAI/` because: `SessionListView`'s row now offers three trailing swipe actions
(Actions/Subagents/Spec) rather than one, and `SessionDetailView`'s new swipe opens a
`confirmationDialog` offering the same three — both are exercised only by a Mac CI screenshot of
the list and the dialog's structure, never by an actual thumb: whether three swipe buttons fit
comfortably on a real phone width, and whether the confirmation dialog reads as an obvious answer
to a left swipe rather than an unexpected menu, are feel questions only a device answers.

### Verify: the block detail sheet's markdown preview truncates sensibly — pai-cloud anchor: `MarkdownContentView` (`PAI/Transcript/TranscriptCards.swift`)
Needs `PAI/` because: `ArcNotesPreview` applies `.lineLimit(6)` to a whole `MarkdownContentView`
tree rather than to a single `Text`, which SwiftUI propagates through the environment to every
`Text` inside — reasoned to truncate visually reasonably for a short note, unverified for a note
whose first block is a large table or code block (both scroll sideways rather than wrap, so a
line limit interacts with them differently than with prose).

The fixture corpus now carries all three shapes (row 4's notes are plain prose, row 5's start
with a table, row 8's with a fenced code block), and `ArcFixturesTests` proves each one parses to
the block type it claims — that part no longer needs a device. What still does: `ArcBlockDetailSheet`
is a `.sheet(item:)`, not a `Route`, and the Mac workflow's screenshot sweep only opens named
routes (`-PaiFixtureRoute <name>`), so this sheet is not reached by any automated screenshot
today, prose included — the blocker is not fixture variety but that nothing taps into the sheet.

### Verify: the flow view's horizontal scrolling feels right on a real phone — pai-cloud anchor: `web/src/apps/arc/ArcFlowSegment.tsx`
Needs `PAI/` because: `ArcFlowSegmentView` lays a segment's blocks out in a `ScrollView(.horizontal)`
nested inside the outer vertical `ScrollView`, with a dashed `Path`-drawn trunk overlaid on the same
scrolling `HStack` the cards sit in — reasoned to scroll independently on both axes (the vertical
timeline never scrolls sideways, each segment's own row scrolls on its own), unverified whether a
real thumb's horizontal drag on a card row is ever captured by the outer vertical `ScrollView`
instead, which is exactly the class of gesture-ownership question this repo already flags as
untestable without a device (see the right-to-left swipe entry above). The fixture corpus
(`PaiFixtures.arcRecover`) now gives one segment five parallel cards plus the unassigned card
specifically so a Mac screenshot shows a row wide enough to actually need scrolling, but a
screenshot proves the row overflows, not that scrolling it feels right.

### Verify: the swipe-back from a subagent transcript returns to the same scroll position, both axes — pai-cloud anchor: `web/src/apps/arc/ArcApp.tsx` (`scrollPositions`)
Needs `PAI/` because: `ArcSpecView` deliberately carries no persistence layer for this the way the
web's `stores/arc.ts` does — `NavigationStack` keeps a pushed-under view alive rather than
unmounting it, so `topSegmentID`/`rowScrollAnchors` are plain `@State` bound through
`.scrollPosition(id:)`, reasoned to survive a badge tap's push to `.session(id:)` and a swipe back
with no explicit save/restore step at all (the same mechanism `SubagentListScreen` already uses for
an analogous list-position case). Unverified: whether `.scrollPosition(id:)` on a *horizontal*
`ScrollView` nested inside a *vertical* one survives the trip as cleanly as `SubagentListScreen`'s
single vertical list does — SwiftUI's own `ScrollView` state restoration across a push/pop has been
reported unreliable in exactly this nested-axis shape, and nothing on Linux can hold a real
navigation stack open, push, pop, and read back a content offset.

### Notes: sort by creation date — pai-cloud anchor: `GET /api/notes`
Needs a backend change first: the list route returns no creation timestamp, only
`GET /api/notes/{id}` does, so the sort menu can offer last-modified, name and favourites-first and
nothing else. Adding `created_at_ms` to the notes-list projection, to `web/src/api/types.ts`'s
`NoteSummary` and to this repo's own model would close it.

### Verify: a push into the session already on screen jumps — pai-cloud anchor: `web/src/components/ChatView.tsx` `?n=` handling
Needs `PAI/` because: implemented and green on Linux, but nobody has tapped a notification for a
conversation already open and watched it land. The fix routes the jump through
`TranscriptJumpRequests` rather than through the navigation path, deliberately, so it does not
depend on SwiftUI rebuilding an equal route element — but the interactive case itself is unwatched.

### Verify: the outline panel keeps keyboard focus — pai-cloud anchor: none, iOS-only
Needs `PAI/` because: the editor's text view only ever granted first responder and never released
it, so a presented sheet could not take focus. Both directions are now handled and the sheet passes
its coverage down. What is unconfirmed is whether keystrokes were reaching the note body during the
fault — neither confirmed nor ruled out, and only a device can say.

### Verify: a push for a different session tears down the old transcript — pai-cloud anchor: none, iOS-only
Needs `PAI/` because: the fix pins the session destination's identity to the session id
(`RootView.destination(for:)`'s `.id(id)`) so `NavigationStack` cannot reuse the old destination
in place — reasoned from a documented `NavigationStack` bug (path replaced wholesale with a
same-length array whose values differ, Apple Feedback FB18336684) and from
`TranscriptCollectionView`'s `updateUIViewController` being a deliberate no-op, never watched fail
and pass on a real device.

### Verify: the notification badge and delivered banners clear on a live read change — pai-cloud anchor: `GET /api/notifications/stream`'s `read` event
Needs `PAI/` because: the stream client, the badge mirror (`RootView`'s existing
`.onChange(of: connection.notifications.unread)`) and the delivered-notification sweep
(`PushRegistrar.reconcileDeliveredNotifications`) are each unit-tested on their own, but nothing
here can drive a real `UNUserNotificationCenter`, hold a real socket across a background/foreground
cycle, or watch the springboard badge and the notification shade actually update. Also unverified:
whether the reconnect-on-foreground timing feels prompt in practice, since only a device shows
that.

### Verify: a backgrounded phone wakes on a silent read-sync push — pai-cloud anchor: `push.send_silent_read_sync_push`
Needs `PAI/` because: the whole point of `application(_:didReceiveRemoteNotification:
fetchCompletionHandler:)` is running while nothing is on screen and nothing is being simulated —
`UIBackgroundModes` declaring `remote-notification` (`Config/Info.plist`), the delegate method
itself, and Apple's own throttling and coalescing of background notifications are none of them
things a simulator run or a unit test can exercise. Best-effort by Apple's own design: delivery is
never guaranteed, and a force-quit app never receives it at all — see `push.py`'s own doc comment
for the ceiling this cannot close regardless of device verification.

### Verify: a shortcut to a different note tears down stale editor state — pai-cloud anchor: none, iOS-only
Needs `PAI/` because: the fix pins the note destination's identity to the note id
(`RootView.destination(for:)`'s `.id(id)` on `.note`/`.notePreview`), the same fix and the same
`NavigationStack` bug as the session one above. Reasoned rather than watched: unlike the
transcript, `MarkdownSourceTextView.updateUIView` genuinely applies a changed `text`, so the note
body was never at risk here — what this actually guards is `NoteEditorScreen`'s own screen-level
`@State` (`titleText`, `isTitleFocused` above all), which a reused destination would otherwise
carry over from the note just left.

### Verify: https and note-link confirmation dialogs actually appear — pai-cloud anchor: none, iOS-only guard against an accidental touchscreen tap
Needs `PAI/` because: `ConfirmedLinkOpening`'s `OpenURLAction` override, and following a tapped
note link while previewing landing back in preview (`.notePreview`, not `.note`), are both proven
by what they route to and by a Mac CI screenshot of the resulting page — but a `confirmationDialog`
mid-presentation cannot be screenshotted from the fixture workflow, so nobody has watched either
dialog actually appear and dismiss on a real device.

### Verify: session attachment and pai-file chips actually load, confirm and share — pai-cloud anchor: `GET /api/session/{id}/attachment`
Needs `PAI/` because: `SessionAttachmentChipView`'s state machine (idle → loading → loaded, or the
confirm-then-fetch path for a `pai-file:` marker) is unit-tested at the row-height/plan level and a
Mac CI screenshot confirms the idle chip renders with the marker line left unmodified above it — but
nobody has tapped one on a device: the confirmation dialog, the fetch actually succeeding against a
live session, the iOS share sheet opening with real bytes, and ``FullScreenImageViewer``'s
swipe-to-dismiss gesture and its own share button are all unwatched. The same viewer, opened from a
note's inline embed instead, carries the identical gap.

### Verify: the formatting-bar settings screen — pai-cloud anchor: `web/src/apps/notes/settings/ToolbarSettings.tsx`
Needs `PAI/` because: the two-section enable/reorder screen (`NoteToolbarSettingsScreen`), drag
reordering via `.onMove` with edit mode forced on, and the always-visible drag handle are none of
them exercisable on Linux — only `NoteToolbarLayout.sanitize(rawIds:)` and `SettingsStore`'s
persistence are. Also unverified: whether an editor already open *underneath* this sheet in the
nav stack — reachable by opening a note, going Back to the list, then opening this screen — picks
up a layout change immediately, or only the next time that note is opened. `updateUIView`
compares old and new `toolbarLayout` on every call and calls `keyboardBar.setLayout(_:)` when they
differ, so correctness does not depend on when SwiftUI next processes an off-screen
`UIViewRepresentable`, but only a device shows whether that happens promptly or is deferred until
the screen is visible again.

### Verify: the read position actually restores across a relaunch — pai-cloud anchor: `PUT /api/session/{id}/read-position`
Needs `PAI/` because: the debounce (`scheduleReadPositionSave`/`flushReadPositionSaveNow`), the
background-flush (`UIApplication.didEnterBackgroundNotification`) and the deinit-flush (this
controller is recreated on every navigation into a session, so leaving is exactly when the web's
own per-session cleanup effect fires) are none of them exercisable without a real app lifecycle —
only the payload math and the seeding logic (`TranscriptAnchor.fromPersisted`) are unit-tested.
Also unwatched: whether 2s is a comfortable debounce on a real device, and whether backgrounding
mid-scroll actually reaches the network before the OS suspends the app. Seeding itself has a known,
accepted gap for a cold deep link — `SessionDetailView` reads `currentSession` synchronously when
constructing the transcript screen, so a session not yet in `SessionListStore`'s cache at that
instant seeds nothing and falls back to the bottom, same as an anchor the in-memory LRU evicted
would. The ordinary open-from-the-list path never hits this, since the tapped row's `Session` is
already cached with its read position by the time it is tapped.

### Verify: search, the kind navigator and deep links actually land right on a device — pai-cloud anchor: `web/src/hooks/useTranscriptFind.ts`
Needs `PAI/` because: `locate`'s merge-or-replace decision (`TranscriptStore.overlapsOrAbuts`), the
inner/outer stepping decision (`TranscriptSearchState.next(hitCount:)`/`previous(hitCount:)`), the
payload/seeding math, the nearest-row fallback (`TranscriptLanding`) and a code-block hit's line
(`CodeBlockHitGeometry`) are all unit-tested, and the `Mac` workflow's own
`GET /transcript/landing` now asserts the row a `.replaced`-window jump actually lands on — but
the `Menu` picker's real appearance and dismissal, whether 250ms reads as responsive against a
real network round trip, and whether the horizontal centring inside a code block
(`CodeBlockScrollView`'s `glyphAdvance`/`viewportEstimate`) actually lands the current hit on
screen rather than off one edge are none of them things Linux — or a fixture screenshot — can
watch. Also unwatched: the catch-up race `loadNewer()` closes (a live message arriving between a
settling `after_id` page and the flag flipping) — proven only by the store-level test that a
held-aside id is exactly the id a follow-up fetch would need to recover, never by a live SSE
stream actually racing a real fetch.

### Verify: the Apps sheet and the search-scope bar feel right on a real screen — pai-cloud anchor: none, iOS-only
Needs `PAI/` because: `AppsHomeSheet`'s `.presentationDetents([.medium])` with only two rows, and
`.searchScopes` replacing the semantic-search toolbar icon on `SessionListView`, are both proven
only by a Mac CI screenshot of their static structure — whether a two-row sheet reads sensibly at
`.medium` height rather than looking mostly empty, and whether the scope bar's appear/disappear
animation as the search field activates feels like part of the search bar rather than a
second, disconnected control, are feel questions only a device answers.

### Verify: Apps → Arc/Notes lands full screen rather than dropping the push — pai-cloud anchor: none, iOS-only
Needs `PAI/` because: `AppsHomeSheet.openArc()`/`openNotes()` push onto the router before calling
`dismiss()`, the same order `CreateSessionView` documents as the fix for a known iOS trap (a push
onto the stack behind a sheet mid-dismissal being dropped, silently). `ArcSpecPickerSheet`'s own
picker had the reverse order and was corrected to match — reasoned from that precedent and from
`CreateSessionView`'s own comment, never watched on a device for either sheet.

### Verify: the Arc spec list's scroll-triggered pagination and debounced search feel right — pai-cloud anchor: none, iOS-only
Needs `PAI/` because: `ArcSpecListView`'s near-the-end `loadMore` trigger and its 500ms search
debounce mirror `SessionListView`'s own shapes and are unit-tested at the `ArcSpecListStore`
level (offset math, `hasMore`, failure keeping what already loaded) — but the actual scroll
momentum against a real network round trip, and whether 500ms reads as responsive while typing a
spec name, are neither of them things Linux can watch.

### Notes: `readPositionPayload` now gates on `hasNewer`
Closed the gap this file used to note here — `TranscriptWindow.hasNewer` exists now (row 25's own
piece), and `TranscriptAnchor.readPositionPayload(for:hasNewer:)` reads it live at save time, the
same way the web's own `saveReadPosition` does, rather than trusting a possibly-stale `atLiveEdge`.
