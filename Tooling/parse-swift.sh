#!/usr/bin/env bash
# Syntax-check every Swift file an Apple SDK would otherwise be needed to see.
#
# `swiftc -parse` builds a syntax tree and stops before name resolution, so it never needs SwiftUI
# or UIKit to exist. That covers the two places nothing else reaches on a free runner: the app
# target, and the package files `Package.swift` excludes from the Linux build. Both are otherwise
# unverified until a metered runner compiles them.
#
# It catches unbalanced delimiters, malformed declarations and bad generic syntax. It cannot catch
# a wrong type, a missing argument label or a misspelled API: those still wait for a Mac. Files the
# Linux build already compiles are parsed too — redundant, and cheaper than working out which.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ $# -gt 0 ]; then
    dirs=("$@")
else
    dirs=("$root/PAI" "$root/PAIKit/Sources")
fi

mapfile -t files < <(find "${dirs[@]}" -name '*.swift' -type f | sort)

if [ ${#files[@]} -eq 0 ]; then
    echo "no Swift files under ${dirs[*]}"
    exit 0
fi

failed=0
for f in "${files[@]}"; do
    if ! swiftc -parse "$f" 2>/tmp/parse-swift.err; then
        echo "--- ${f#"$root/"}"
        cat /tmp/parse-swift.err
        failed=1
    fi
done

rm -f /tmp/parse-swift.err

if [ "$failed" -ne 0 ]; then
    echo "app target has syntax errors"
    exit 1
fi

echo "parsed ${#files[@]} files, no syntax errors"
