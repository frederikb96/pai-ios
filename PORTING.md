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
