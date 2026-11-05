"""One line per probe step: the page's last reported state before the next step began.

Reads events.jsonl as server.py wrote it. A step with no page report after it says so, rather
than repeating the previous step's numbers.
"""

import json
import sys

steps: list[tuple[str, dict | None]] = []
last: dict | None = None
for raw in open(sys.argv[1]):
    entry = json.loads(raw)
    if "mark" in entry:
        steps.append((entry["mark"], last))
        last = None
    else:
        last = entry

for name, state in steps:
    if state is None:
        print(f"{name:24} no report since the previous step")
        continue
    vv = state["vv"]
    print(
        f"{name:24} vv h={vv['height']} top={vv['offsetTop']} pageTop={vv['pageTop']} "
        f"scrollY={state['scrollY']} shellTop={state['shell']['top']} "
        f"headerVisible={state['headerVisible']} gapBelowComposer={state['gapBelowComposer']} "
        f"input h={state['input']['height']} sel={state['selectionStart']}-{state['selectionEnd']} "
        f"len={state['valueLength']} focused={state['focused']}"
    )
