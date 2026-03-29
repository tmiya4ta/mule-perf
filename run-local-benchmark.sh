#!/bin/bash
# Local DB Benchmark: Oracle (vs Clouderby when available)
# Uses wrk for load generation + /api/system for metrics
set -euo pipefail

TARGET="http://localhost:8891"
DURATION="${DURATION:-180}"
CONCURRENCY="${CONCURRENCY:-10}"
THREADS="${THREADS:-4}"
METRICS_INTERVAL=5

RESULT_DIR="benchmark-results/14-db-comparison-local-$(date +%Y%m%d)"
mkdir -p "$RESULT_DIR"

log() { echo "[$(date +%H:%M:%S)] $*"; }

# Metrics collector
collect_metrics() {
    local name="$1"
    local file="$RESULT_DIR/${name}_metrics.jsonl"
    : > "$file"
    while true; do
        local ts=$(date +%s)
        local sys=$(curl -sf --max-time 3 "$TARGET/api/system" 2>/dev/null || echo '{"error":"unreachable"}')
        echo "{\"ts\":$ts,\"target\":$sys}" >> "$file"
        sleep "$METRICS_INTERVAL"
    done
}

# Run a single wrk benchmark
run_bench() {
    local name="$1"
    local path="$2"
    local method="${3:-GET}"
    local script_file=""

    echo ""
    echo "════════════════════════════════════════════════════════════"
    log "START: $name"
    log "  URL: $TARGET$path  Method: $method  C: $CONCURRENCY  T: ${DURATION}s"

    # Start metrics collection
    collect_metrics "$name" &
    local mpid=$!

    local wrk_args=("-t$THREADS" "-c$CONCURRENCY" "-d${DURATION}s" "--latency")

    if [ "$method" = "POST" ]; then
        # Create a lua script for POST requests
        script_file="/tmp/wrk_post_$$.lua"
        cat > "$script_file" <<'LUA'
wrk.method = "POST"
wrk.body   = "{}"
wrk.headers["Content-Type"] = "application/json"
LUA
        wrk_args+=("-s" "$script_file")
    fi

    # Run wrk
    local wrk_output
    wrk_output=$(wrk "${wrk_args[@]}" "$TARGET$path" 2>&1)

    # Stop metrics
    kill "$mpid" 2>/dev/null; wait "$mpid" 2>/dev/null || true
    [ -n "$script_file" ] && rm -f "$script_file"

    # Save raw wrk output
    echo "$wrk_output" > "$RESULT_DIR/${name}_wrk.txt"

    # Parse wrk output
    local rps=$(echo "$wrk_output" | grep "Requests/sec:" | awk '{print $2}')
    local avg_lat=$(echo "$wrk_output" | grep -E "^\s+Latency" | awk '{print $2}')
    local p99=$(echo "$wrk_output" | grep "99%" | awk '{print $2}')
    local total_req=$(echo "$wrk_output" | grep "requests in" | awk '{print $1}')
    local errors=$(echo "$wrk_output" | grep -E "Socket errors|Non-2xx" | head -1)

    # Create JSON result
    local metrics_count=$(wc -l < "$RESULT_DIR/${name}_metrics.jsonl")
    cat > "$RESULT_DIR/${name}.json" <<EOF
{
  "scenario": "$name",
  "target": "$TARGET$path",
  "method": "$method",
  "concurrency": $CONCURRENCY,
  "threads": $THREADS,
  "duration": $DURATION,
  "rps": ${rps:-0},
  "avgLatency": "$avg_lat",
  "p99Latency": "${p99:-N/A}",
  "totalRequests": ${total_req:-0},
  "errors": "${errors:-none}",
  "metricsFile": "${name}_metrics.jsonl",
  "metricsSamples": $metrics_count
}
EOF

    log "  RESULT: RPS=$rps  AvgLatency=$avg_lat  P99=$p99  Total=$total_req"
    [ -n "$errors" ] && log "  ERRORS: $errors"
    log "  Metrics: $metrics_count samples"

    echo "$wrk_output"
}

# ══════════════════════════════════════════════════════════════
log "Local DB Benchmark"
log "  Target: $TARGET  C: $CONCURRENCY  Duration: ${DURATION}s"
log "  Results: $RESULT_DIR/"

# Warmup
log "Warmup..."
wrk -t2 -c2 -d10s "$TARGET/api/oracle/page?page=1&size=20" > /dev/null 2>&1

# === Oracle Benchmarks ===

# 1. Pagination
run_bench "Oracle-Page_c${CONCURRENCY}_${DURATION}s" \
    "/api/oracle/page?page=1&size=20"

# 2. JOIN + Aggregation
run_bench "Oracle-JoinReport_c${CONCURRENCY}_${DURATION}s" \
    "/api/oracle/join-report"

# 3. Bulk Insert (10 records per request)
run_bench "Oracle-BulkInsert10_c${CONCURRENCY}_${DURATION}s" \
    "/api/oracle/bulk-insert?count=10" "POST"

# === Clouderby Benchmarks (if available) ===
clouderby_ok=$(curl -sf --max-time 5 "$TARGET/api/clouderby/page?page=1&size=1" 2>/dev/null | jq -r '.count // empty' 2>/dev/null || echo "")
if [ -n "$clouderby_ok" ]; then
    log "Clouderby is available, running Clouderby benchmarks..."

    run_bench "Clouderby-Page_c${CONCURRENCY}_${DURATION}s" \
        "/api/clouderby/page?page=1&size=20"

    run_bench "Clouderby-JoinReport_c${CONCURRENCY}_${DURATION}s" \
        "/api/clouderby/join-report"

    run_bench "Clouderby-BulkInsert10_c${CONCURRENCY}_${DURATION}s" \
        "/api/clouderby/bulk-insert?count=10" "POST"
else
    log "Clouderby not available, skipping Clouderby benchmarks"
fi

# === Existing endpoints for comparison ===
run_bench "Oracle-SingleSelect_c${CONCURRENCY}_${DURATION}s" \
    "/api/oracle/user/1"

run_bench "Clouderby-ProductSelect_c${CONCURRENCY}_${DURATION}s" \
    "/api/clouderby/product/P001" 2>/dev/null || log "Clouderby product select failed"

# Summary
echo ""
echo "════════════════════════════════════════════════════════════"
log "ALL BENCHMARKS COMPLETE"
echo ""
printf "%-40s %10s %12s %10s\n" "Scenario" "RPS" "AvgLatency" "P99"
printf "%-40s %10s %12s %10s\n" "────────" "───" "──────────" "───"
for f in "$RESULT_DIR"/*.json; do
    [ -f "$f" ] || continue
    name=$(jq -r '.scenario' "$f")
    rps=$(jq -r '.rps' "$f")
    avg=$(jq -r '.avgLatency' "$f")
    p99=$(jq -r '.p99Latency' "$f")
    printf "%-40s %10s %12s %10s\n" "$name" "$rps" "$avg" "$p99"
done
echo ""
log "Results: $RESULT_DIR/"
