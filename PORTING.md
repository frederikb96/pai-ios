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
that. Correcting the badge and the shade while the app is backgrounded and untouched has a
separate, permanent ceiling this cannot close regardless of device verification: nothing sends a
silent push to wake the app for it (`push.py` only ever sends an alert push).
