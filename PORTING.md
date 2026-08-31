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
