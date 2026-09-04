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

### Notes: `readPositionPayload` now gates on `hasNewer`
Closed the gap this file used to note here — `TranscriptWindow.hasNewer` exists now (row 25's own
piece), and `TranscriptAnchor.readPositionPayload(for:hasNewer:)` reads it live at save time, the
same way the web's own `saveReadPosition` does, rather than trusting a possibly-stale `atLiveEdge`.
