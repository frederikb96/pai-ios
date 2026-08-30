# Porting backlog

Deferred pai-cloud parity work — entries that reached the "yes, needs `PAI/`" branch of
[pai-cloud's `docs/IOS_PARITY.md`](https://github.com/frederikb96/pai-cloud/blob/main/docs/IOS_PARITY.md)
decision rule. Append-only: add an entry, never edit or reorder another agent's.

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

### Notes: semantic search mode — pai-cloud anchor: `web/src/apps/notes/NoteList.tsx`'s `mode === 'semantic'` branch
Needs `PAI/` because: it needs a screen-level UI (a relative-threshold slider shared with the
session sidebar) and a simulator run to check the ranking reads sensibly; `PaiApiClient` has no
`searchMemory`/`/api/memory/search` route at all yet, so the networking layer is also unbuilt.
Filter mode and full-text mode (`/api/notes/search`) are both ported and cover the same ground for
a vault this size; semantic search is a genuine third mode, not a fallback for either.
