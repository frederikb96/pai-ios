#!/usr/bin/env bash
# Launch the app once per screen in fixture mode, photograph it, and check what only the running
# app can answer. Every screen is attempted even after one fails, and the script fails once at the
# end: a run that stops at the second screen has spent the minutes and answered the fewest
# questions it could have.
#
# Fixture mode, the launch-argument router and the debug bridge are all `#if DEBUG`, so a Release
# build has none of this. The first launch (no route, the root session list) also asks the bridge
# for `/screens`, so a screen becomes photographable the moment its `Route` case exists.
#
# Environment:
#   SIM_UDID  the booted simulator
#   ONLY      comma-separated sections and route names to run; empty runs everything, `none` only
#             the root screen. `routes` selects every route screen. A name matching nothing fails.
#   PROBE     a script sourced after the sections; `screenshot`, `want`, $udid and $bundle are in scope
set -o pipefail
# shellcheck source=lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

SECTIONS="none routes measure note-bench auth-rejected fullscreen-image fullscreen-pdf secret-prompt
new-session-landing notes-filtering notifications-filter scheduler-task-push settings-notes-cache
note-uncached-online notes-offline jump-landing deep-link-landing warm-jump clamped-landing note-refused"

mkdir -p artifacts
udid="${SIM_UDID:?SIM_UDID is required}"
bundle=$BUNDLE
ONLY=${ONLY:-}
fail=0

# True when nothing was selected, or any of the given names was.
want() {
  [ -z "$ONLY" ] && return 0
  local name
  for name in "$@"; do
    case ",$ONLY," in *",$name,"*) return 0 ;; esac
  done
  return 1
}


chrome_assert() {
  curl -sS --max-time 5 "http://127.0.0.1:8765/screen/scroll-views" -o "artifacts/scroll-views-$1.json" || true
  python3 - "artifacts/scroll-views-$1.json" <<'PY' || { echo "::error::$1: a scroll view besides the list, see scroll-views-$1.json"; fail=1; }
import json, sys
views = json.load(open(sys.argv[1]))["views"]
print(views)
sys.exit(0 if views and all(v["height"] > 300 for v in views) else 1)
PY
}

screenshot() {
  name="$1"; shift
  xcrun simctl launch "$udid" "$bundle" -PaiFixtureMode "$@" > /dev/null
  ok=0
  for attempt in $(seq 1 10); do
    if curl -sS --max-time 3 "http://127.0.0.1:8765/health" -o "artifacts/health-$name.json"; then
      # Why the app is on whatever screen it is on. A gate that never opens renders a
      # real screen, passes every check and satisfies the size floor — so without this
      # a wrong screen is indistinguishable from the right one.
      curl -sS --max-time 3 "http://127.0.0.1:8765/fixture" -o "artifacts/fixture-$name.json" || true
      ok=1
      break
    fi
    sleep 2
  done
  if [ "$ok" -ne 1 ]; then
    echo "::warning::$name: debug bridge never answered"
    fail=1
  fi
  # 🚨 The bridge starts listening in `PAIApp.init()`, BEFORE the first frame is drawn —
  # so "/health answered" proves the process is alive and proves nothing about the
  # screen. Without this settle the screenshot is a race the app usually wins and
  # occasionally loses, producing a black PNG that is indistinguishable from a genuinely
  # broken screen and costs an investigation to dismiss.
  sleep 6
  xcrun simctl io "$udid" screenshot "artifacts/screen-$name.png"
  # Asked of every screen rather than of one guessed to be a transcript: the endpoint
  # answers with an empty list anywhere else, and the evaluation below takes whichever
  # report actually has rows in it. Guessing which screenshot leaves a transcript on top
  # is how this check came to run against no rows at all and report a warning nobody
  # would have read as "it proved nothing".
  curl -sS --max-time 10 "http://127.0.0.1:8765/transcript/row-agreement" \
    -o "artifacts/rowagree-$name.json" || true
  # A screen caught before its first frame is a black PNG that still compresses to tens
  # of kilobytes, so the size floor below cannot see it — and it is indistinguishable
  # from a screen that genuinely renders nothing, which would otherwise cost another
  # whole run to tell apart. One retake settles it: a real blank screen is blank twice.
  if [ "$(stat -f %z "artifacts/screen-$name.png")" -le 100000 ]; then
    sleep 5
    xcrun simctl io "$udid" screenshot "artifacts/screen-$name.png"
  fi
  # Read AFTER the screenshot, not with the health probe: the bridge answers the moment
  # it is listening, which is before the screen has fetched, measured or drawn anything
  # worth logging. This is what distinguishes "nothing arrived" from "nothing measured"
  # from "nothing drawn" — three causes a picture cannot tell apart.
  curl -sS --max-time 3 "http://127.0.0.1:8765/logs?level=info&limit=200" \
    -o "artifacts/logs-$name.json" || true
  bytes=$(stat -f %z "artifacts/screen-$name.png")
  echo "$name: ${bytes} bytes"
  # A wholly blank screen still produces a valid PNG, just a small one — the one thing
  # every other check here can pass while the screen renders nothing.
  #
  # 🚨 It catches only a screen that is blank ALL OVER. A screen that draws its
  # navigation bar and composer but none of its content is several times this size and
  # sails past — which has happened. The size floor is the cheap half; `logs-<name>.json`
  # above is the half that actually distinguishes an empty screen from a full one.
  if [ "$bytes" -le 20000 ]; then
    echo "::warning::$name: screenshot suspiciously small — the screen may be blank"
    fail=1
  fi
}

screenshot root
curl -sS --max-time 5 "http://127.0.0.1:8765/screens" -o artifacts/screens.json \
  || echo '{"screens":[]}' > artifacts/screens.json
names=$(python3 -c "import json; print('\n'.join(json.load(open('artifacts/screens.json'))['screens']))")

# A selection that matches nothing would pass by doing nothing.
for item in $(echo "$ONLY" | tr ',' ' '); do
  case " $(echo "$SECTIONS $names" | tr '\n' ' ') " in
    *" $item "*) ;;
    *) echo "::error::--only: '$item' is neither a section nor a screen"; exit 1 ;;
  esac
done

if want measure; then
  # Does the measured row height agree with what the view actually draws? Nothing checked
  # that until a nested list proved it false — the transcript lays out from analytic
  # heights and never asks a cell its size, so a disagreement is invisible to every other
  # check here and shows up as the reader being dragged around. Nested lists and a quote
  # are the shapes that were wrong; keep an easy case first so a failure is legible.
  printf 'Plain paragraph.\n' > /tmp/m1.md
  printf -- '- one\n- two\n  - nested a\n  - nested b\n    - deeper\n' > /tmp/m2.md
  printf -- '> quoted\n>\n> - a list inside a quote\n>   - and deeper\n' > /tmp/m3.md
  for m in 1 2 3; do
    curl -sS --max-time 5 --data-binary "@/tmp/m$m.md" \
      "http://127.0.0.1:8765/markdown/measure?width=360" \
      -o "artifacts/measure-$m.json" || true
  done

  # The Thinking card's block wraps through TextKit when measured and through SwiftUI `Text`
  # when drawn, and nothing else compares the two. A plain paragraph, a long unbroken
  # token and a run of short words are the shapes where the two wrap differently; a
  # non-zero `delta` in these reports is a Thinking card clipping or leaving a gap.
  python3 -c "
open('/tmp/t1.txt', 'w').write(
    'Thinking through the plan step by step, weighing each option against the others. ' * 40)
open('/tmp/t2.txt', 'w').write(
    'before ' + '/very/long/path/with/no/break/opportunities/' * 12 + ' after ' + 'x' * 300)
open('/tmp/t3.txt', 'w').write(' '.join('w%d' % i for i in range(600)))
"
  for t in 1 2 3; do
    curl -sS --max-time 5 --data-binary "@/tmp/t$t.txt" \
      "http://127.0.0.1:8765/markdown/measure?width=360&block=preformatted" \
      -o "artifacts/measure-thinking-$t.json" || true
  done
fi

if want note-bench; then
  # What a keystroke costs in the open editor on a note the size of the largest real ones, and
  # whether its heights hold still, with the line numbers off and on. Nothing else runs beside it:
  # a sampler pauses the app it measures.
  bench() {
    local name=$1 query=$2
    xcrun simctl terminate "$udid" "$bundle" || true
    screenshot "note-bench-$name" -PaiFixtureRoute noteLarge
    curl -sS --max-time 90 -X POST "http://127.0.0.1:8765/notes/editor-bench?keys=60&$query" \
      -o "artifacts/note-editor-bench-$name.json" || true
    cat "artifacts/note-editor-bench-$name.json" || true
    echo
    xcrun simctl io "$udid" screenshot "artifacts/screen-note-bench-$name-after.png" || true
    xcrun simctl terminate "$udid" "$bundle" || true
  }
  bench plain lineNumbers=0
  bench line-numbers lineNumbers=1
fi

if want auth-rejected; then
  # The sign-in card, in its rejected state, over a screen with its own list content —
  # reproduces the shape of the bug report (the card drawn see-through over the
  # notification list beneath it) rather than only the ordinary session list, which has
  # no list content directly under the card to prove is or isn't bleeding through.
  screenshot auth-rejected -PaiFixtureRoute notifications -PaiFixtureAuthState rejected
  xcrun simctl terminate "$udid" "$bundle" || true
fi

if want fullscreen-image; then
  # `FilePreviewViewer` is a `.fullScreenCover(item:)`, reachable by no `Route` — the
  # session screen fetches the fixture attachment directly and presents it under this flag
  # (`SessionDetailView`'s own `.task`), rather than through a message row's attachment
  # chip, which the fixture corpus deliberately places outside the default tail window.
  screenshot fullscreen-image -PaiFixtureRoute session -PaiFixtureOpenImage
  xcrun simctl terminate "$udid" "$bundle" || true
fi

if want fullscreen-pdf; then
  # The same cover on a generated two-page PDF: `PDFPreviewView` and its scroll tracking
  # are drawn by nothing else.
  screenshot fullscreen-pdf -PaiFixtureRoute session -PaiFixtureOpenPdf
  xcrun simctl terminate "$udid" "$bundle" || true
fi

if want secret-prompt; then
  # The grant sheet a session pops up by itself when it needs a gated secret — the same
  # sheet the composer's plus menu opens manually, auto-presented on opening a session
  # that is carrying one. Nothing in fixture mode has a live conversation to raise a real
  # prompt, so `-PaiFixtureSecretPrompt` hands the session list one instead.
  screenshot secret-prompt -PaiFixtureRoute session -PaiFixtureSecretPrompt
  xcrun simctl terminate "$udid" "$bundle" || true
fi

if want new-session-landing; then
  # The real "New Session" send button, pressed with no device interaction to tap it:
  # the outbox entry, the create response, the handover carrying the new id back to the
  # sheet, and the push racing that sheet's own dismissal. `/transcript/landing` is the
  # proof that matters here, not the screenshot — anything that breaks that chain leaves
  # the screen where it was and never mounts a transcript at all, so `topVisibleRowId`
  # stays null forever rather than merely answering late.
  screenshot new-session-landing -PaiFixtureRoute createSession -PaiFixtureAutoCreateSession
  opened=0
  for attempt in $(seq 1 10); do
    if curl -sS --max-time 3 "http://127.0.0.1:8765/transcript/landing" -o artifacts/new-session-landing.json; then
      top=$(python3 -c "import json; print(json.load(open('artifacts/new-session-landing.json')).get('topVisibleRowId'))")
      if [ "$top" != "None" ]; then opened=1; break; fi
    fi
    sleep 2
  done
  xcrun simctl terminate "$udid" "$bundle" || true
  if [ "$opened" -ne 1 ]; then
    echo "::error::new-session-landing: no transcript ever mounted after the push+dismiss race — see new-session-landing.json"
    fail=1
  fi
fi

if want notes-filtering; then
  # The note index, then with its filter field focused. Its chip row draws only if the list is the
  # scroll view the navigation bar treats as content: a thin scroll view in the row takes the bar's
  # edge effect, which can mask the chips while they stay tappable.
  screenshot notes-chrome -PaiFixtureRoute notes
  chrome_assert notes-chrome
  xcrun simctl terminate "$udid" "$bundle" || true
  screenshot notes-filtering -PaiFixtureRoute notes -PaiFixtureNotesFilterFocused
  chrome_assert notes-filtering
  xcrun simctl terminate "$udid" "$bundle" || true
fi

if want notifications-filter; then
  # The notification centre under its source filter. The fixture feed holds a quiet
  # scheduled row (stored read), a blocking one that pushed, and the ordinary rows; the
  # filtered screens must show only the rows each view keeps, task chip included.
  screenshot notifications-scheduled -PaiFixtureRoute notifications -PaiFixtureNotificationSource only
  xcrun simctl terminate "$udid" "$bundle" || true
  screenshot notifications-not-scheduled -PaiFixtureRoute notifications -PaiFixtureNotificationSource exclude
  xcrun simctl terminate "$udid" "$bundle" || true
fi

if want scheduler-task-push; then
  # The task form's push setting, below the fold of the plain `schedulerTask` screenshot.
  screenshot scheduler-task-push -PaiFixtureRoute schedulerTask -PaiFixtureScrollTo taskNotifyPush
  xcrun simctl terminate "$udid" "$bundle" || true
fi

if want settings-notes-cache; then
  # The notes cache section, below the fold of the plain `settings` screenshot, holding
  # the seeded cache.
  screenshot settings-notes-cache -PaiFixtureRoute settings -PaiFixtureNotesCacheSeeded \
    -PaiFixtureScrollTo notesCache
  xcrun simctl terminate "$udid" "$bundle" || true
fi

if want note-uncached-online; then
  # A note opened online under an id the corpus holds besides the rich note: the router
  # answers each note under its own id, so this photographs the Wikilink note, never the
  # Engram one.
  screenshot note-uncached-online -PaiFixtureRoute noteUncached
  xcrun simctl terminate "$udid" "$bundle" || true
fi

while IFS= read -r name; do
  [ -n "$name" ] && want "$name" routes || continue
  screenshot "$name" -PaiFixtureRoute "$name"
  xcrun simctl terminate "$udid" "$bundle" || true
done <<< "$names"

if want notes-offline; then
  # The notes without a connection. `-PaiFixtureOffline` fails every request the way
  # URLSession does in flight mode; the seed flags put the fixture index, note, files and an
  # unsynced edit on disk as if opened before. `/notes/cache` answers what the store holds,
  # and `/notes/offline` + `/notes/sync` take the edit back online the way the network
  # returning does.
  notes_assert() {
    label="$1"; file="$2"; shift 2
    python3 - "$file" "$@" <<'PY' || { echo "::error::$label: see $file"; fail=1; }
import json, sys
state = json.load(open(sys.argv[1]))
for check in sys.argv[2:]:
    if not eval(check, {}, {"s": state}):
        print(f"failed: {check}")
        print(json.dumps(state, indent=2))
        sys.exit(1)
print("ok:", ", ".join(sys.argv[2:]))
PY
  }

  screenshot notes-offline -PaiFixtureRoute notes -PaiFixtureOffline -PaiFixtureNotesCacheSeeded
  curl -sS --max-time 5 "http://127.0.0.1:8765/notes/cache" -o artifacts/notes-cache-notes-offline.json || true
  notes_assert notes-offline artifacts/notes-cache-notes-offline.json "s['isOffline']" "s['indexCount'] == 3"
  xcrun simctl terminate "$udid" "$bundle" || true

  screenshot note-offline -PaiFixtureRoute note -PaiFixtureOffline -PaiFixtureNotesCacheSeeded \
    -PaiFixtureNotePendingEdit
  curl -sS --max-time 5 "http://127.0.0.1:8765/notes/cache" -o artifacts/notes-cache-note-offline.json || true
  notes_assert note-offline artifacts/notes-cache-note-offline.json \
    "s['isOffline']" "len([p for p in s['pending'] if p['kind'] == 'body']) == 1"
  curl -sS --max-time 5 -X POST "http://127.0.0.1:8765/notes/offline?on=false" || true
  curl -sS --max-time 70 -X POST "http://127.0.0.1:8765/notes/sync" -o artifacts/notes-sync-note-offline.json || true
  curl -sS --max-time 5 "http://127.0.0.1:8765/notes/cache" -o artifacts/notes-cache-note-offline-synced.json || true
  notes_assert note-offline-synced artifacts/notes-cache-note-offline-synced.json \
    "s['pending'] == []" "s['lastSyncReport']['replayed'] == 1"
  sleep 3
  xcrun simctl io "$udid" screenshot artifacts/screen-note-offline-synced.png || true
  xcrun simctl terminate "$udid" "$bundle" || true

  # The conflict policy: the first save meets a 409 with a different body, and the edit is
  # written over it, marked source=offline, without asking.
  screenshot note-offline-conflict -PaiFixtureRoute note -PaiFixtureOffline -PaiFixtureNotesCacheSeeded \
    -PaiFixtureNotePendingEdit -PaiFixtureNoteConflict
  curl -sS --max-time 5 -X POST "http://127.0.0.1:8765/notes/offline?on=false" || true
  curl -sS --max-time 70 -X POST "http://127.0.0.1:8765/notes/sync" -o artifacts/notes-sync-note-offline-conflict.json || true
  notes_assert note-offline-conflict artifacts/notes-sync-note-offline-conflict.json \
    "s['conflictsResolved'] == 1" "s['stillPending'] == 0"
  curl -sS --max-time 3 "http://127.0.0.1:8765/logs?level=info&limit=200" \
    -o artifacts/logs-note-offline-conflict-synced.json || true
  grep -q 'source=offline' artifacts/logs-note-offline-conflict-synced.json \
    || { echo "::error::note-offline-conflict: no log line for the write carrying source=offline"; fail=1; }
  sleep 3
  xcrun simctl io "$udid" screenshot artifacts/screen-note-offline-conflict-synced.png || true
  xcrun simctl terminate "$udid" "$bundle" || true

  # A note never opened on this phone, opened without a connection.
  screenshot note-offline-unavailable -PaiFixtureRoute noteUncached -PaiFixtureOffline
  xcrun simctl terminate "$udid" "$bundle" || true
fi

if want jump-landing; then
  # Where a jump into UNLOADED history actually lands — a screenshot alone shows the
  # result, not the row id the controller computed, so this is what proves the .replaced
  # window path (the fault that shipped) rather than only the ordinary .prepended one
  # (the path that always worked, and the one every other screenshot here happens to
  # exercise since nothing else jumps far from the loaded tail). `boundary` kind search
  # lands on the session's own first row and its one `system`/`compact` row — both several
  # hundred ids clear of the fixture corpus's own tail window by construction.
  screenshot jump-landing -PaiFixtureRoute session -PaiFixtureSearchKind boundary
  landed=0
  for attempt in $(seq 1 10); do
    if curl -sS --max-time 3 "http://127.0.0.1:8765/transcript/landing" -o artifacts/landing.json; then
      top=$(python3 -c "import json; print(json.load(open('artifacts/landing.json')).get('topVisibleRowId'))")
      if [ "$top" != "None" ]; then landed=1; break; fi
    fi
    sleep 2
  done
  xcrun simctl terminate "$udid" "$bundle" || true
  if [ "$landed" -ne 1 ]; then
    echo "::warning::jump-landing: /transcript/landing never reported a row — see landing.json"
    fail=1
  else
    # The two boundary hits in the fixture corpus (search-virtualization design's own
    # "the around page, and merge-or-replace") — landing anywhere else means the .replaced
    # path is still reading stale offsets.
    python3 -c "
import json, sys
top = json.load(open('artifacts/landing.json'))['topVisibleRowId']
ok = top in (9001, 9042) or 9001 <= top <= 9010 or 9033 <= top <= 9042
print(f'landed on row {top}')
sys.exit(0 if ok else 1)
" || { echo "::error::jump-landing: landed far from both boundary targets (9001, 9042) — see landing.json"; fail=1; }
  fi
fi

if want deep-link-landing; then
  # A tapped notification opening a session at a message far older than its tail — the
  # jump made inside the transcript's own first load, not on a settled screen the way the
  # search jump above is. 9020 is several hundred ids clear of the fixture tail, so this is
  # the `.replaced` landing. `deepLinkLandedMessageId` outlives the ring's fade, so polling
  # it cannot race the ring the way reading `highlightedMessageId` would.
  screenshot deep-link-landing -PaiFixtureRoute session -PaiFixtureJumpMessage 9020
  linked=0
  for attempt in $(seq 1 10); do
    if curl -sS --max-time 3 "http://127.0.0.1:8765/transcript/landing" -o artifacts/deep-link-landing.json; then
      got=$(python3 -c "import json; print(json.load(open('artifacts/deep-link-landing.json')).get('deepLinkLandedMessageId'))")
      if [ "$got" != "None" ]; then linked=1; break; fi
    fi
    sleep 2
  done
  if [ "$linked" -ne 1 ]; then
    echo "::error::deep-link-landing: no deep-link landing was reported — see deep-link-landing.json"
    fail=1
  else
    python3 -c "
import json, sys
s = json.load(open('artifacts/deep-link-landing.json'))
top = s['topVisibleRowId'] or 0
print('landed on', s['deepLinkLandedMessageId'], 'with top row', top)
sys.exit(0 if s['deepLinkLandedMessageId'] == 9020 and 9001 <= top <= 9020 else 1)
" || { echo "::error::deep-link-landing: did not land on 9020 — see deep-link-landing.json"; fail=1; }

    # The landing's own window is not at the tail (9020 is far short of the corpus's
    # 9900), so it pages itself forward on its own once the reader's position sits near
    # its loaded edge — legitimate, and not what this checks. What it checks is whether
    # the edge-follow latch wrongly treats the bottom of that still-incomplete window as
    # the live edge while the catch-up runs: it then chases every page `loadNewer()`
    # brings in with its own `scrollToBottom`, walking the reader toward the corpus's true
    # tail in several steps — the bug a notification jump into old history hit. A read
    # right after landing cannot see that drift; only a read after it has had time to
    # happen can.
    sleep 5
    xcrun simctl io "$udid" screenshot artifacts/screen-deep-link-landing-settled.png || true
    curl -sS --max-time 3 "http://127.0.0.1:8765/transcript/landing" -o artifacts/deep-link-landing-settled.json || true
    python3 -c "
import json, sys
s = json.load(open('artifacts/deep-link-landing-settled.json'))
top = s['topVisibleRowId'] or 0
print('after settle: top row', top)
sys.exit(0 if 9001 <= top <= 9020 else 1)
" || { echo "::error::deep-link-landing: drifted away from row 9020 during the settle window — see deep-link-landing-settled.json"; fail=1; }
  fi
  xcrun simctl terminate "$udid" "$bundle" || true
fi

if want warm-jump; then
  # A notification tapped while its session is already open and following the live edge
  # — the path a phone takes coming back from the lock screen. 9850 is inside the fixture
  # tail, so the jump animates from the bottom rather than replacing the window. The
  # fixture stream ends after each pass and reconnects every couple of seconds, replaying
  # its `init`, and every replay asks the transcript to stick to the bottom if it is
  # following — so a jump that re-armed following on its way out is carried back down
  # within the settle window. Both the position and the follow state are read, since a
  # position that holds only because no event arrived in time proves nothing.
  screenshot warm-jump -PaiFixtureRoute session
  ready=0
  for attempt in $(seq 1 10); do
    if curl -sS --max-time 3 "http://127.0.0.1:8765/transcript/landing" -o artifacts/warm-jump-before.json; then
      top=$(python3 -c "import json; print(json.load(open('artifacts/warm-jump-before.json')).get('topVisibleRowId'))")
      if [ "$top" != "None" ]; then ready=1; break; fi
    fi
    sleep 2
  done
  if [ "$ready" -ne 1 ]; then
    echo "::error::warm-jump: the transcript never reported a row before the jump — see warm-jump-before.json"
    fail=1
  else
    curl -sS --max-time 3 -X POST "http://127.0.0.1:8765/transcript/jump?messageId=9850" || true
    sleep 10
    xcrun simctl io "$udid" screenshot artifacts/screen-warm-jump-settled.png || true
    curl -sS --max-time 3 "http://127.0.0.1:8765/transcript/landing" -o artifacts/warm-jump-settled.json || true
    python3 -c "
import json, sys
before = json.load(open('artifacts/warm-jump-before.json'))
s = json.load(open('artifacts/warm-jump-settled.json'))
top = s['topVisibleRowId'] or 0
print('before jump: top row', before['topVisibleRowId'], 'following', before.get('isFollowingLiveEdge'))
print('after settle: landed', s['deepLinkLandedMessageId'], 'top row', top, 'following', s.get('isFollowingLiveEdge'))
ok = s['deepLinkLandedMessageId'] == 9850 and 9830 <= top <= 9850 and s.get('isFollowingLiveEdge') is False
sys.exit(0 if ok else 1)
" || { echo "::error::warm-jump: did not stay on row 9850 — see warm-jump-settled.json"; fail=1; }
  fi
  xcrun simctl terminate "$udid" "$bundle" || true
fi

if want clamped-landing; then
  # A cold landing on a target in the last screen is clamped onto the bottom, so the one
  # scroll sample it produces reads "at the edge". Nothing visibly moves in the fixture —
  # no new content arrives below — so the follow state is the only witness: the next
  # message to arrive on a real session would otherwise carry the reader off the target.
  screenshot clamped-landing -PaiFixtureRoute session -PaiFixtureJumpMessage 9899
  clamped=0
  for attempt in $(seq 1 10); do
    if curl -sS --max-time 3 "http://127.0.0.1:8765/transcript/landing" -o artifacts/clamped-landing.json; then
      got=$(python3 -c "import json; print(json.load(open('artifacts/clamped-landing.json')).get('deepLinkLandedMessageId'))")
      if [ "$got" != "None" ]; then clamped=1; break; fi
    fi
    sleep 2
  done
  if [ "$clamped" -ne 1 ]; then
    echo "::error::clamped-landing: no deep-link landing was reported — see clamped-landing.json"
    fail=1
  else
    sleep 5
    curl -sS --max-time 3 "http://127.0.0.1:8765/transcript/landing" -o artifacts/clamped-landing-settled.json || true
    python3 -c "
import json, sys
s = json.load(open('artifacts/clamped-landing-settled.json'))
print('clamped landing on', s['deepLinkLandedMessageId'], 'following', s.get('isFollowingLiveEdge'))
sys.exit(0 if s['deepLinkLandedMessageId'] == 9899 and s.get('isFollowingLiveEdge') is False else 1)
" || { echo "::error::clamped-landing: a landing clamped onto the bottom re-armed following — see clamped-landing-settled.json"; fail=1; }
  fi
  xcrun simctl terminate "$udid" "$bundle" || true
fi

if want note-refused; then
  # An edit the server refused (the note was deleted elsewhere), seeded in the outbox. It
  # stays on the simulator for every launch after it, and a note holds one edit, so these
  # screens come after every other note screenshot. The editor shows the failed-save
  # badge (its Try again / Copy / Discard menu opens only on a tap, so it stays
  # unphotographed); Settings lists the text under "Not saved".
  screenshot note-refused-edit -PaiFixtureRoute note -PaiFixtureNotesCacheSeeded -PaiFixtureNoteRefusedEdit
  curl -sS --max-time 5 "http://127.0.0.1:8765/notes/cache" -o artifacts/notes-cache-note-refused-edit.json || true
  notes_assert note-refused-edit artifacts/notes-cache-note-refused-edit.json \
    "len([p for p in s['pending'] if p['kind'] == 'body' and p['state'] == 'failed']) == 1"
  xcrun simctl terminate "$udid" "$bundle" || true
  screenshot settings-not-saved -PaiFixtureRoute settings -PaiFixtureNotesCacheSeeded \
    -PaiFixtureNoteRefusedEdit -PaiFixtureScrollTo notSaved
  xcrun simctl terminate "$udid" "$bundle" || true
fi

if [ -z "$ONLY" ]; then
  # The same question one level out: does a whole ROW's laid-out height agree with what
  # it draws? The transcript places rows from analytic heights and never asks a cell its
  # size, so a register's chrome, a visual clamp or a trailer being off by a few points is
  # invisible everywhere else and shows up only as the reader being dragged around.
  python3 - <<'PY'
import json, pathlib, sys
reports = []
for path in sorted(pathlib.Path('artifacts').glob('rowagree-*.json')):
    if not path.stat().st_size:
        continue
    try:
        rows = json.loads(path.read_text())
    except json.JSONDecodeError:
        continue
    if rows:
        reports.append((path.name, rows))
if not reports:
    print('::error::row agreement: no screen answered with a single transcript row, so nothing was checked')
    sys.exit(1)
name, rows = max(reports, key=lambda r: len(r[1]))
worst = max(rows, key=lambda r: abs(r['delta']))
print(f"row agreement: {len(rows)} rows from {name}, worst delta {worst['delta']:.2f}pt on message {worst['messageId']}")
# A point of slack for fractional font metrics; anything past that is a real disagreement.
if abs(worst['delta']) > 1.0:
    print(f"::error::row {worst['messageId']} measures {worst['measured']:.2f} and draws {worst['rendered']:.2f}")
    sys.exit(1)
PY
fi

# A probe is a branch-local script run with everything above in scope, so a question nobody
# has a section for needs no change to the workflow.
if [ -n "${PROBE:-}" ]; then
  # shellcheck source=/dev/null
  . "$PROBE"
fi

[ "$fail" -eq 0 ] || { echo 'one or more screens failed — see the warnings above'; exit 1; }
