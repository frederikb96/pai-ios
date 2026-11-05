#!/usr/bin/env bash
# Drives the composer probe page in the simulator's Safari with real touches and the software
# keyboard, once per layout mode, and leaves screenshots, the accessibility frames and the page's
# own event log in $OUT.
#
#   run.sh [modes]   modes default to "A B C D E" (see index.html)
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../sim/lib.sh
. "$HERE/../sim/lib.sh"

OUT=${OUT:-probe-out}
PORT=8123
MODES=${1:-A B C D E}
mkdir -p "$OUT"

# The software keyboard only appears with no hardware keyboard attached; it is what pans the page.
defaults write com.apple.iphonesimulator ConnectHardwareKeyboard -bool false

udid=$(sim_pick_device)
[ -n "$udid" ] || { echo '::error::no iPhone simulator'; exit 1; }
xcrun simctl boot "$udid" || true
sim_wait_booted "$udid" 600 || { echo '::error::simulator did not boot'; exit 1; }
xcrun simctl ui "$udid" appearance dark
xcrun simctl list devices | grep "$udid"

python3 "$HERE/server.py" "$PORT" "$OUT/events.jsonl" &
server=$!
trap 'kill $server 2>/dev/null' EXIT
sleep 1
curl -sf "http://127.0.0.1:$PORT/index.html" > /dev/null || { echo '::error::probe server not answering'; exit 1; }

idb_() { idb "$@" --udid "$udid" 2>> "$OUT/idb-errors.log"; }
mark() { curl -sf -X POST "http://127.0.0.1:$PORT/mark?step=$1" > /dev/null; }
shot() { xcrun simctl io "$udid" screenshot "$OUT/$mode-$1.png" > /dev/null 2>&1; idb_ ui describe-all --json > "$OUT/$mode-$1.ax.json"; mark "$mode-$1"; }

# frame <label> → "x y w h" of the first accessibility element with that label, in points. Safari
# exposes its own controls this way, and the software keyboard's keys, but not the page.
frame() {
  idb_ ui describe-all --json | python3 -c "
import json, sys
want = sys.argv[1].lower()
for e in json.load(sys.stdin):
    if (e.get('AXLabel') or '').lower() == want:
        f = e['frame']; print(int(f['x']), int(f['y']), int(f['width']), int(f['height'])); break
" "$1"
}

# composer → "x y w h" in points of the composer as it is drawn right now.
composer() {
  xcrun simctl io "$udid" screenshot "$OUT/.locate.png" > /dev/null 2>&1
  python3 "$HERE/locate.py" "$OUT/.locate.png"
}

# Types by tapping the software keyboard's own keys. Keyboard events from idb would read as a
# hardware keyboard, and iOS then hides the software one, which is the thing under test.
# Letters and space as themselves, "|" for return, "<" for delete.
type_keys() {
  idb_ ui describe-all --json > "$OUT/.keys.json"
  python3 - "$OUT/.keys.json" "$1" <<'PY' | while read -r x y; do idb_ ui tap "$x" "$y" < /dev/null; done
import json, sys
keys = {}
for e in json.load(open(sys.argv[1])):
    label = e.get("AXLabel")
    if e.get("type") == "Button" and label is not None:
        f = e["frame"]
        keys[label.lower()] = (int(f["x"] + f["width"] / 2), int(f["y"] + f["height"] / 2))
for ch in sys.argv[2]:
    name = {"|": "return", "<": "delete"}.get(ch, ch.lower())
    if name in keys:
        print(*keys[name])
    else:
        print(f"no key {name!r} on the keyboard", file=sys.stderr)
PY
}

# Safari's first launch shows its Start Page over whatever it was asked to open.
xcrun simctl openurl "$udid" "http://127.0.0.1:$PORT/index.html?mode=B"
sleep 12
idb_ ui describe-all --json > "$OUT/warmup.ax.json"
xcrun simctl io "$udid" screenshot "$OUT/warmup.png" > /dev/null 2>&1

for mode in $MODES; do
  echo "== mode $mode"
  xcrun simctl openurl "$udid" "http://127.0.0.1:$PORT/index.html?mode=$mode"
  sleep 6
  shot 1-loaded

  c=$(composer)
  [ -n "$c" ] || { echo "::warning::$mode: composer not on screen"; continue; }
  set -- $c
  idb_ ui tap $(($1 + $3 / 2)) $(($2 + $4 / 2))
  sleep 3
  shot 2-focused

  type_keys 'first|||||||last'
  sleep 2
  shot 3-typed

  type_keys '<<<<<<<<<<<'

  sleep 2
  shot 4-deleted

  # Tap on the first line of the composer, then again where the caret landed: the second tap is
  # what brings up the edit menu. The log's selectionStart says where the first tap put the caret.
  c=$(composer)
  if [ -n "$c" ]; then
    set -- $c
    idb_ ui tap $(($1 + 40)) $(($2 + 22))
    sleep 1.5
    shot 5-tap-first-line
    idb_ ui tap $(($1 + 40)) $(($2 + 22))
    sleep 1.5
    shot 6-second-tap
    idb_ ui tap $(($1 + $3 - 30)) $(($2 + $4 - 22))
    sleep 1.5
    shot 7-tap-last-line
  fi

  # Leave the field so the next mode starts with the keyboard down.
  idb_ ui tap 200 120
  sleep 2
  shot 8-blurred
done

python3 "$HERE/summarise.py" "$OUT/events.jsonl" | tee "$OUT/summary.txt"
