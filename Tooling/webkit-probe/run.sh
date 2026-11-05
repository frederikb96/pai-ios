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

# Safari's own tips (a popover over the toolbar) cover the page; their close buttons are in the
# accessibility tree.
dismiss_tips() {
  idb_ ui describe-all --json | python3 -c "
import json, sys
for e in json.load(sys.stdin):
    if e.get('type') == 'Button' and (e.get('AXLabel') or '').lower() in ('close', 'dismiss', 'not now', 'continue'):
        f = e['frame']; print(int(f['x'] + f['width'] / 2), int(f['y'] + f['height'] / 2))
" | while read -r x y; do idb_ ui tap "$x" "$y" < /dev/null; sleep 1; done
}

# open <mode> loads the page and waits for its own load report, so a screenshot never shows the
# page before it.
loads() { local n; n=$(grep -c '"ev":"load"' "$OUT/events.jsonl" 2> /dev/null); echo "${n:-0}"; }
open_mode() {
  local before
  before=$(loads)
  xcrun simctl openurl "$udid" "http://127.0.0.1:$PORT/index.html?mode=$1"
  for _ in $(seq 1 30); do
    [ "$(loads)" -gt "$before" ] && break
    sleep 1
  done
  sleep 2
  dismiss_tips
}

# Safari's first launch shows its Start Page over whatever it was asked to open.
open_mode B
sleep 5
dismiss_tips
xcrun simctl io "$udid" screenshot "$OUT/warmup.png" > /dev/null 2>&1

for mode in $MODES; do
  echo "== mode $mode"
  open_mode "$mode"
  shot 1-loaded

  c=$(composer)
  [ -n "$c" ] || { echo "::warning::$mode: composer not on screen"; continue; }
  set -- $c
  idb_ ui tap $(($1 + $3 / 2)) $(($2 + $4 / 2))
  sleep 3
  shot 2-focused

  # Eight lines: past the composer's 200 px cap, so it scrolls inside itself.
  type_keys 'one|two|three|four|five|six|seven|eight'
  sleep 2
  shot 3-typed

  # Back to six lines ("one".."six"), so each tap below has a line it should land on:
  # "one" is characters 0-3, "two" 4-7, "three" 8-13.
  type_keys '<<<<<<<<<<<<'
  sleep 2
  shot 4-shrunk

  line() { echo $(($2 + 13 + 24 * $1 - 12)); }
  c=$(composer)
  if [ -n "$c" ]; then
    set -- $c
    x=$(($1 + 30)) top=$2
    idb_ ui tap "$x" "$(line 1 "$top")"
    sleep 1.5
    shot 5-tap-line1
    idb_ ui tap "$x" "$(line 1 "$top")"
    sleep 1.5
    shot 6-second-tap-line1
    idb_ ui tap "$x" "$(line 3 "$top")"
    sleep 1.5
    shot 7-tap-line3
    # Scroll the transcript with the keyboard up, then aim at line 2 of wherever the composer is now.
    idb_ ui swipe 200 200 200 320 --duration 0.4
    sleep 1.5
    c=$(composer)
    if [ -n "$c" ]; then
      set -- $c
      idb_ ui tap $(($1 + 30)) "$(line 2 "$2")"
      sleep 1.5
      shot 8-scrolled-tap-line2
    fi
  fi

  type_keys '<<<<<<<<<<<<<<<<<<<<<<<<<<<'
  sleep 2
  shot 9-emptied

  # Leave the field so the next mode starts with the keyboard down.
  idb_ ui tap 200 120
  sleep 2
  shot 10-blurred
done

python3 "$HERE/summarise.py" "$OUT/events.jsonl" | tee "$OUT/summary.txt"
