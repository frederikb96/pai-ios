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

Empty.
