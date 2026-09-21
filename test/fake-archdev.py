#!/usr/bin/env python3
# Fake `archdev agents run --stream`: one assistant event per stdin line.
import json
import sys

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    event = {"type": "assistant", "content": "echo %d" % len(line)}
    sys.stdout.write(json.dumps(event) + "\n")
    sys.stdout.flush()
