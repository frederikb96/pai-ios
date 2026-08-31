#!/usr/bin/env python3
"""Catch the Swift 6 / SwiftUI mistakes that compile nowhere but a metered macOS runner.

``parse-swift.sh`` stops before name resolution, so everything below is invisible to it — and the
package build never sees the app target at all. Every pattern here is one that has actually failed
a Mac run, and a Mac run costs ten times a Linux minute to answer what a scan answers for nothing.

Heuristics, not a compiler. They are deliberately narrow, and each errs towards missing a real
problem rather than flagging a good line: the Mac run is still the real check, so a miss costs one
run while a false positive blocks work every time it fires.

Add a check when a Mac run fails for a reason a scan could have found.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

TYPE_DECLARATION = re.compile(r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:public |internal |private |fileprivate |final |open )*(?:class|struct|enum|actor|extension)\b")
STORED_STATIC_VAR = re.compile(r"^\s*(?:public |internal |private |fileprivate )?static var [A-Za-z_]\w*\s*(?::[^={]*)?=")
SHADOWED_WRAPPER = re.compile(r"^\s*(?:public |internal |private |fileprivate )?(?:enum|struct|class|actor) (State|Binding|Environment|Namespace|Observable)\s*[:{]")
AMBIGUOUS_PAIR = re.compile(r"(?:width|x|dx): \.[A-Za-z]\w*, (?:height|y|dy): \.[A-Za-z]\w*")
ISOLATED_STATIC = re.compile(r"^\s*(?:public |internal |private |fileprivate )?static (?:let|var) ([A-Za-z_]\w*)\b")
DETACHED_TASK = re.compile(r"\bTask\.detached\b")


#: Inheriting from one of these carries main-actor isolation with no annotation in sight — the
#: SDK declares them `@MainActor`. A `UIViewController` subclass's statics are isolated and legal,
#: and reporting them is the false positive that makes a check like this get ignored.
IMPLICITLY_ISOLATED_BASE = re.compile(r":\s*(?:[\w.]+\s*,\s*)*(?:UI[A-Z]\w*|NS[A-Z]\w*View\w*)\b")


def main_actor_line_numbers(lines: list[str]) -> set[int]:
    """Line numbers covered by a main-actor-isolated *type*.

    A static inside one is actor-isolated and legal. Isolation has to be attributed to the type
    rather than merely present in the file: `@MainActor` on a single method — which is how it
    usually appears in an `AppIntent` — isolates nothing about the type's statics, and treating the
    whole file as safe there is what let an earlier version of this check miss the very error it
    was written for.

    Scoping is by indentation rather than by brace matching, which is enough for the one question
    being asked and does not need a parser.
    """
    covered: set[int] = set()
    for index, line in enumerate(lines):
        isolated_here = "@MainActor" in line
        inherits = TYPE_DECLARATION.match(line) and IMPLICITLY_ISOLATED_BASE.search(line)
        if not isolated_here and not inherits:
            continue
        # The declaration is on this line, or on the next non-blank one.
        declaration = index if TYPE_DECLARATION.match(line) else None
        if declaration is None:
            for lookahead in range(index + 1, min(index + 4, len(lines))):
                if not lines[lookahead].strip():
                    continue
                if TYPE_DECLARATION.match(lines[lookahead]):
                    declaration = lookahead
                break
        if declaration is None:
            continue
        indent = len(lines[declaration]) - len(lines[declaration].lstrip())
        # A long inheritance list wraps, and the opening brace then sits on its own line at the
        # declaration's own indent — which the scope walk below would read as the end of the type
        # before it has seen any of it. Find the brace first and scope from there.
        opening = declaration
        while opening < len(lines) and "{" not in lines[opening]:
            opening += 1
            if opening - declaration > 8:
                opening = declaration
                break
        for cursor in range(opening + 1, len(lines)):
            body = lines[cursor]
            if body.strip() and (len(body) - len(body.lstrip())) <= indent:
                break
            covered.add(cursor)
    return covered


def detached_reads_of_isolated_statics(lines: list[str], isolated: set[int]) -> list[tuple[int, str, str]]:
    """A static declared inside a main-actor type, read from inside `Task.detached`.

    The static is isolated to that actor, so the detached body cannot touch it — and the error
    names the *use*, several lines from the declaration that caused it. Everything else in the
    body is usually a `Sendable` snapshot taken deliberately, which is what makes the one
    unsnapshotted name easy to miss when reading.

    Scoped by indentation like the rest of this file. Only names declared in this same file count,
    so a static reached through a type prefix is not considered — that form is qualified and reads
    as remote, which is exactly when nobody needs a reminder.
    """
    names = {
        match.group(1)
        for index, line in enumerate(lines)
        if index in isolated and (match := ISOLATED_STATIC.match(line)) and "nonisolated" not in line
    }
    if not names:
        return []

    findings: list[tuple[int, str, str]] = []
    for index, line in enumerate(lines):
        if not DETACHED_TASK.search(line):
            continue
        indent = len(line) - len(line.lstrip())
        for cursor in range(index + 1, len(lines)):
            body = lines[cursor]
            if body.strip() and (len(body) - len(body.lstrip())) <= indent:
                break
            for name in names:
                if re.search(rf"(?<![.\w]){re.escape(name)}\b", body):
                    findings.append((
                        cursor + 1, body.strip(),
                        f"'{name}' is a static on a main-actor-isolated type and cannot be read "
                        "from a detached task — move it to file scope, or snapshot it before the task",
                    ))
    return findings


def check(path: Path) -> list[tuple[int, str, str]]:
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    isolated = main_actor_line_numbers(lines)
    findings: list[tuple[int, str, str]] = detached_reads_of_isolated_statics(lines, isolated)

    for index, line in enumerate(lines):
        if STORED_STATIC_VAR.match(line) and index not in isolated and "nonisolated(unsafe)" not in line:
            findings.append((
                index + 1, line.strip(),
                "stored 'static var' is global mutable state under Swift 6 — make it computed "
                "({ ... }), a 'static let', or 'nonisolated(unsafe)'",
            ))
        if SHADOWED_WRAPPER.match(line):
            findings.append((
                index + 1, line.strip(),
                "a type named after a SwiftUI property wrapper shadows it in this scope — rename it",
            ))
        if AMBIGUOUS_PAIR.search(line):
            findings.append((
                index + 1, line.strip(),
                "both members inferred leaves the literal's type ambiguous — name it "
                "(CGFloat.greatestFiniteMagnitude)",
            ))
    return findings


def main() -> int:
    targets = [Path(arg) for arg in sys.argv[1:]] or [ROOT / "PAI", ROOT / "PAIKit/Sources"]
    files = sorted(f for target in targets for f in target.rglob("*.swift"))
    if not files:
        print(f"no Swift files under {', '.join(str(t) for t in targets)}", file=sys.stderr)
        return 1

    total = 0
    for path in files:
        for line_number, source, message in check(path):
            total += 1
            print(f"::error file={path},line={line_number}::{message}")
            print(f"  {path}:{line_number}: {source}")

    if total:
        print(f"\n{total} known Swift 6 / SwiftUI trap(s) — each of these has failed a Mac run before")
        return 1
    print(f"no known Swift 6 / SwiftUI traps in {len(files)} files")
    return 0


if __name__ == "__main__":
    sys.exit(main())
