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

## Backlog

### Relay palette swatch — pai-cloud anchor: `web/src/index.css` `--color-relay-500`/`--color-relay-600`
Needs `PAI/` because: `PaiPalette.swift` is `#if canImport(SwiftUI)`-guarded, so neither the
Linux build nor the local toolchain compiles it — only a `Mac` run proves a new swatch there
builds and reads correctly.
