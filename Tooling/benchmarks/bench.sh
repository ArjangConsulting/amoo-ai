#!/usr/bin/env bash
# Usage: bench.sh <label> <amoo-binary> <platform> <device> <flow> [runs]
set -uo pipefail
LABEL="$1"; AMOO="$2"; PLATFORM="$3"; DEVICE="$4"; FLOW="$5"; RUNS="${6:-2}"
OUT="$(cd "$(dirname "$0")" && pwd)/bench-$LABEL"
rm -rf "$OUT"; mkdir -p "$OUT/telemetry" "$OUT/flows"
export AMOO_TELEMETRY_DIR="$OUT/telemetry"
echo "[$LABEL] env up $(date +%T)"
start=$(date +%s)
"$AMOO" env up --platform "$PLATFORM" --device "$DEVICE" --owner "bench-$LABEL" --ttl 60 --json > "$OUT/env-up.json" 2> "$OUT/env-up.err"
status=$?
echo "[$LABEL] env up exit=$status in $(( $(date +%s) - start ))s"
if [ $status -ne 0 ]; then tail -20 "$OUT/env-up.err"; cat "$OUT/env-up.json"; exit $status; fi
RUNTIME=$(python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("runtime_id") or (d.get("runtime") or {}).get("id",""))' "$OUT/env-up.json")
PORT=$(python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("port") or (d.get("runtime") or {}).get("port",""))' "$OUT/env-up.json")
echo "[$LABEL] runtime=$RUNTIME port=$PORT"
for run in $(seq 1 "$RUNS"); do
    start=$(date +%s)
    "$AMOO" flow "$FLOW" --device "$DEVICE" ${PORT:+--port "$PORT"} ${RUNTIME:+--runtime-id "$RUNTIME"} --output-dir "$OUT/flows/$run" > "$OUT/flow-$run.log" 2>&1
    echo "[$LABEL] flow run $run exit=$? in $(( $(date +%s) - start ))s"
done
"$AMOO" env down ${RUNTIME:+--runtime-id "$RUNTIME"} > "$OUT/env-down.log" 2>&1
echo "[$LABEL] env down exit=$?"
"$AMOO" usage report --telemetry-dir "$OUT/telemetry" --transcripts none --json --out "$OUT/report.json" > /dev/null 2>&1
echo "[$LABEL] report: $OUT/report.json"
