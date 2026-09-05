#!/usr/bin/env python3
"""Summarize Amoo JSONL telemetry without retaining tool arguments or UI contents."""
import argparse
import json
import math
from collections import defaultdict
from pathlib import Path


def percentile(values, fraction):
    ordered = sorted(values)
    return ordered[max(0, math.ceil(len(ordered) * fraction) - 1)] if ordered else None


def summarize(lines):
    groups = defaultdict(list)
    for line in lines:
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue  # Other stderr diagnostics are not benchmark samples.
        if not isinstance(event, dict) or event.get("event") != "amoo.performance":
            continue
        duration = event.get("duration_ms")
        if not isinstance(duration, (int, float)) or not math.isfinite(duration) or duration < 0:
            raise ValueError("Invalid telemetry duration")
        groups[(event["category"], event["operation"])].append(event)
    output = []
    for (category, operation), events in sorted(groups.items()):
        durations = [event["duration_ms"] for event in events]
        failures = sum(event.get("success") == "false" for event in events)
        output.append({
            "category": category, "operation": operation, "samples": len(events),
            "failures": failures, "p50_ms": percentile(durations, .5),
            "p95_ms": percentile(durations, .95),
            "response_text_bytes": sum(int(event.get("response_text_bytes", 0)) for event in events),
            "image_bytes": sum(int(event.get("image_bytes", 0)) for event in events),
        })
    return output


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=Path)
    args = parser.parse_args()
    with args.log.open() as stream:
        print(json.dumps(summarize(stream), indent=2))
