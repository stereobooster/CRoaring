#!/usr/bin/env python3
"""
Summarize a CodeQL SARIF file (terminal-friendly).
Used by tools/run_codeql_cpp_docker.sh after `codeql database analyze`.
"""
from __future__ import annotations

import json
import sys
from collections import Counter


def _location_uri_line(result: dict) -> str:
    locs = result.get("locations") or []
    if not locs:
        return "?"
    pl = (locs[0] or {}).get("physicalLocation") or {}
    uri = (pl.get("artifactLocation") or {}).get("uri", "?")
    if uri.startswith("file://"):
        uri = uri[7:]
    # Strip leading /work/ from Docker bind mounts
    if "/work/" in uri:
        uri = uri.split("/work/", 1)[-1]
    reg = pl.get("region") or {}
    line = reg.get("startLine", "?")
    return f"{uri}:{line}"


def main() -> int:
    if len(sys.argv) != 2:
        print("Usage: codeql_summarize_sarif.py <results.sarif>", file=sys.stderr)
        return 2
    path = sys.argv[1]
    try:
        with open(path, encoding="utf-8") as f:
            doc = json.load(f)
    except OSError as e:
        print(f"{path}: {e}", file=sys.stderr)
        return 1
    except json.JSONDecodeError as e:
        print(f"{path}: invalid JSON: {e}", file=sys.stderr)
        return 1

    runs = doc.get("runs") or []
    if not runs:
        print("SARIF has no runs.", file=sys.stderr)
        return 1
    run0 = runs[0]
    results = run0.get("results") or []
    rules = {
        r["id"]: r
        for r in (run0.get("tool") or {}).get("driver", {}).get("rules") or []
    }

    print(f"CodeQL SARIF: {path}")
    print(f"Total results: {len(results)}")
    if not results:
        return 0

    by_rule = Counter(r.get("ruleId", "?") for r in results)
    print("\nBy ruleId (top 30):")
    for rid, n in by_rule.most_common(30):
        print(f"  {n:5}  {rid}")

    # Pull defaultConfiguration.level from rule metadata when result has no level
    levels = Counter()
    for r in results:
        lvl = r.get("level")
        if lvl is None:
            rid = r.get("ruleId", "")
            rule = rules.get(rid, {})
            lvl = (rule.get("defaultConfiguration") or {}).get("level") or "unknown"
        levels[str(lvl)] += 1
    print("\nBy effective level:")
    for lv, n in sorted(levels.items(), key=lambda x: (-x[1], x[0])):
        print(f"  {n:5}  {lv}")

    # Non-style samples: exclude the very chatty commented-out-code rule
    noisy = {"cpp/commented-out-code"}
    interesting = [r for r in results if r.get("ruleId") not in noisy]
    if interesting:
        print(f"\nSample non-comment alerts (up to 15 of {len(interesting)}):")
        for r in interesting[:15]:
            rid = r.get("ruleId", "?")
            msg = (r.get("message") or {}).get("text", "")
            first_line = msg.strip().split("\n", 1)[0][:160]
            print(f"  [{rid}] {_location_uri_line(r)}")
            print(f"    {first_line}")

    print("\nDone.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
