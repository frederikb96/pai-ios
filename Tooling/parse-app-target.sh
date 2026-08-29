#!/usr/bin/env bash
# Syntax-check the app target without an Apple SDK.
#
# `swiftc -parse` builds a syntax tree and stops before name resolution, so it never needs SwiftUI
# or UIKit to exist. That makes it the only check on `PAI/` that runs anywhere but macOS — which
# matters because everything under `PAI/` is otherwise unverified until a metered runner builds it.
#
# It catches unbalanced delimiters, malformed declarations and bad generic syntax. It cannot catch
# a wrong type, a missing argument label or a misspelled API: those still wait for a Mac.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
target_dir="${1:-$root/PAI}"

mapfile -t files < <(find "$target_dir" -name '*.swift' -type f | sort)

if [ ${#files[@]} -eq 0 ]; then
    echo "no Swift files under $target_dir"
    exit 0
fi

failed=0
for f in "${files[@]}"; do
    if ! swiftc -parse "$f" 2>/tmp/parse-app-target.err; then
        echo "--- ${f#"$root/"}"
        cat /tmp/parse-app-target.err
        failed=1
    fi
done

rm -f /tmp/parse-app-target.err

if [ "$failed" -ne 0 ]; then
    echo "app target has syntax errors"
    exit 1
fi

echo "parsed ${#files[@]} files, no syntax errors"
