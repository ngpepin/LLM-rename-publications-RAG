import os
import re

directory = "/mnt/drive2/Reading/MIN"
if not os.path.exists(directory):
    print(f"Directory {directory} not found")
    exit(1)

files = [f for f in os.listdir(directory) if os.path.isfile(os.path.join(directory, f))]

pattern_prefixed = re.compile(r'^(\d{4}|____) - ')
targets = [f for f in files if not pattern_prefixed.match(f)]

results = []
summary = {"no-4digit": 0, "has-inrange": 0, "has-only-out-of-range": 0}

for f in targets:
    tokens = re.findall(r'\b\d{4}\b', f)
    if not tokens:
        summary["no-4digit"] += 1
        results.append((f, tokens, "None"))
    else:
        in_range = [int(t) for t in tokens if 1900 <= int(t) <= 2026]
        if in_range:
            summary["has-inrange"] += 1
            results.append((f, tokens, "Yes"))
        else:
            summary["has-only-out-of-range"] += 1
            results.append((f, tokens, "No"))

# Print first 40
for f, tokens, inrange in results[:40]:
    print(f"File: {f}")
    print(f"  Tokens: {tokens} | InRange: {inrange}")

print("\n--- Summary ---")
for k in ["no-4digit", "has-inrange", "has-only-out-of-range"]:
    print(f"{k}: {summary[k]}")
