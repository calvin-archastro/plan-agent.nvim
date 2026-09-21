#!/usr/bin/env python3
# Fake `archdev agents run --stream` (release 0.44.0 shape): loop_state,
# assistant deltas, then one authoritative assistant event per stdin line.
import json
import sys

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    body = "echo %d" % len(line)
    events = [
        {"type": "loop_state", "state": {"phase": "responding"}},
        {"type": "assistant_delta", "delta": body[:2]},
        {"type": "assistant_delta", "delta": body[2:]},
        {"type": "assistant", "content": body},
    ]
    for event in events:
        sys.stdout.write(json.dumps(event) + "\n")
    sys.stdout.flush()
