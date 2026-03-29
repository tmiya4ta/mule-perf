#!/bin/bash
# DB Comparison Benchmark: Oracle vs Clouderby
# Usage: ./run-db-benchmark.sh <perf-url> <target-url> [internal-target-url]
#
# Example (CloudHub 2):
#   ./run-db-benchmark.sh \
#     https://mule-perf.xxx.jpn-e1.cloudhub.io \
#     https://bench-target.xxx.jpn-e1.cloudhub.io \
#     http://bench-target.uuid.svc.cluster.local:8081
#
# Example (local):
#   ./run-db-benchmark.sh http://localhost:8890 http://localhost:8891

set -euo pipefail

PERF_URL="${1:?Usage: $0 <perf-url> <target-url> [internal-target-url]}"
TARGET_URL="${2:?Usage: $0 <perf-url> <target-url> [internal-target-url]}"
INTERNAL_TARGET="${3:-$TARGET_URL}"

DURATION="${DURATION:-180}"
WARMUP="${WARMUP:-15}"
CONCURRENCY="${CONCURRENCY:-10}"
METRICS_INTERVAL="${METRICS_INTERVAL:-5}"

RESULT_DIR="${RESULT_DIR:-benchmark-results/14-db-comparison-$(date +%Y%m%d)}"
mkdir -p "$RESULT_DIR"

log() { echo "[$(date +%H:%M:%S)] $*"; }
separator() { echo ""; echo "════════════════════════════════════════════════════════════════"; }

# ── Metrics collector: polls /api/system on both containers every N seconds ──
collect_metrics() {
    local test_name="$1"
    local metrics_file="$RESULT_DIR/${test_name}_metrics.jsonl"
    : > "$metrics_file"

    while true; do
        local ts
        ts=$(date +%s%3N 2>/dev/null || date +%s000)
        local loader_sys target_sys
        loader_sys=$(curl -sf --connect-timeout 3 --max-time 5 "$PERF_URL/api/system" 2>/dev/null | jq -c . 2>/dev/null || echo '{"error":"unreachable"}')
        target_sys=$(curl -sf --connect-timeout 3 --max-time 5 "$TARGET_URL/api/system" 2>/dev/null | jq -c . 2>/dev/null || echo '{"error":"unreachable"}')
        echo "{\"ts\":$ts,\"loader\":$loader_sys,\"target\":$target_sys}" >> "$metrics_file"
        sleep "$METRICS_INTERVAL"
    done
}

# ── Run a single benchmark scenario ──
run_benchmark() {
    local name="$1"
    local url="$2"
    local method="${3:-GET}"
    local body="${4:-}"

    separator
    log "START: $name"
    log "  URL:         $url"
    log "  Method:      $method"
    log "  Concurrency: $CONCURRENCY"
    log "  Duration:    ${DURATION}s + ${WARMUP}s warmup"

    # Start metrics collection in background
    collect_metrics "$name" &
    local metrics_pid=$!

    # Build test request
    local test_body
    if [ -n "$body" ]; then
        test_body=$(jq -n \
            --arg url "$url" \
            --arg method "$method" \
            --arg body "$body" \
            --argjson c "$CONCURRENCY" \
            --argjson d "$DURATION" \
            --argjson w "$WARMUP" \
            '{targetUrl: $url, method: $method, body: $body, concurrency: $c, duration: $d, warmup: $w}')
    else
        test_body=$(jq -n \
            --arg url "$url" \
            --arg method "$method" \
            --argjson c "$CONCURRENCY" \
            --argjson d "$DURATION" \
            --argjson w "$WARMUP" \
            '{targetUrl: $url, method: $method, concurrency: $c, duration: $d, warmup: $w}')
    fi

    # Start test
    local response
    response=$(curl -sf -X POST "$PERF_URL/api/tests" \
        -H "Content-Type: application/json" \
        -d "$test_body")
    local test_id
    test_id=$(echo "$response" | jq -r '.id // .testId')
    log "  Test ID: $test_id"

    # Wait for completion with progress
    local elapsed=0
    local total_wait=$((DURATION + WARMUP + 30))
    while [ $elapsed -lt $total_wait ]; do
        sleep 10
        elapsed=$((elapsed + 10))
        local status rps total_req
        local status_json
        status_json=$(curl -sf "$PERF_URL/api/tests/$test_id" 2>/dev/null || echo '{"status":"polling"}')
        status=$(echo "$status_json" | jq -r '.status // "unknown"')
        rps=$(echo "$status_json" | jq -r '.throughput.rps // "-"' 2>/dev/null)
        total_req=$(echo "$status_json" | jq -r '.totalRequests // "-"' 2>/dev/null)
        log "  [${elapsed}s] status=$status rps=$rps total=$total_req"
        [ "$status" = "completed" ] && break
        [ "$status" = "error" ] && break
    done

    # Stop metrics collection
    kill "$metrics_pid" 2>/dev/null || true
    wait "$metrics_pid" 2>/dev/null || true

    # Save final results
    local result_file="$RESULT_DIR/${name}.json"
    local result_json
    result_json=$(curl -sf "$PERF_URL/api/tests/$test_id")

    # Wrap with scenario metadata
    jq -n \
        --arg scenario "$name" \
        --argjson c "$CONCURRENCY" \
        --argjson d "$DURATION" \
        --argjson w "$WARMUP" \
        --argjson result "$result_json" \
        '{scenario: $scenario, concurrency: $c, duration: $d, warmup: $w, result: $result}' \
        > "$result_file"

    # Print summary
    local final_rps avg_rt err_rate p99
    final_rps=$(echo "$result_json" | jq -r '.throughput.rps // 0' | xargs printf "%.1f")
    avg_rt=$(echo "$result_json" | jq -r '.responseTime.avg // 0' | xargs printf "%.1f")
    p99=$(echo "$result_json" | jq -r '.responseTime.p99 // 0')
    err_rate=$(echo "$result_json" | jq -r '.errorRate // 0')
    log "  RESULT: RPS=$final_rps  AvgRT=${avg_rt}ms  P99=${p99}ms  Errors=${err_rate}%"
    log "  Saved: $result_file"
    log "  Metrics: $RESULT_DIR/${name}_metrics.jsonl ($(wc -l < "$RESULT_DIR/${name}_metrics.jsonl") samples)"
}

# ══════════════════════════════════════════════════════════════
# MAIN
# ══════════════════════════════════════════════════════════════

log "DB Comparison Benchmark"
log "  Loader:   $PERF_URL"
log "  Target:   $TARGET_URL"
log "  Internal: $INTERNAL_TARGET"
log "  Results:  $RESULT_DIR/"

# ── Step 0: Setup ──
separator
log "Setting up benchmark tables..."
setup_result=$(curl -sf "$TARGET_URL/api/benchmark/setup" 2>/dev/null || echo '{"error":"setup failed"}')
log "Setup: $(echo "$setup_result" | jq -c .)"

# ── Step 1: Pagination (read-only, run first) ──
run_benchmark "T5-E-Oracle-Page_c${CONCURRENCY}_${DURATION}s" \
    "$INTERNAL_TARGET/api/oracle/page?page=1&size=20"

run_benchmark "T5-F-Clouderby-Page_c${CONCURRENCY}_${DURATION}s" \
    "$INTERNAL_TARGET/api/clouderby/page?page=1&size=20"

# ── Step 2: JOIN + Aggregation (read-only) ──
run_benchmark "T5-A-Oracle-JoinReport_c${CONCURRENCY}_${DURATION}s" \
    "$INTERNAL_TARGET/api/oracle/join-report"

run_benchmark "T5-B-Clouderby-JoinReport_c${CONCURRENCY}_${DURATION}s" \
    "$INTERNAL_TARGET/api/clouderby/join-report"

# ── Step 3: Bulk Insert (write-heavy, run last) ──
run_benchmark "T5-C-Oracle-BulkInsert_c${CONCURRENCY}_${DURATION}s" \
    "$INTERNAL_TARGET/api/oracle/bulk-insert?count=10" \
    "POST" \
    "{}"

run_benchmark "T5-D-Clouderby-BulkInsert_c${CONCURRENCY}_${DURATION}s" \
    "$INTERNAL_TARGET/api/clouderby/bulk-insert?count=10" \
    "POST" \
    "{}"

# ── Summary ──
separator
log "ALL BENCHMARKS COMPLETE"
echo ""
echo "┌──────────────────────────────────────────────────────────────┐"
echo "│ Scenario                          │   RPS │ AvgRT │  P99   │"
echo "├──────────────────────────────────────────────────────────────┤"
for f in "$RESULT_DIR"/T5-*.json; do
    [ -f "$f" ] || continue
    name=$(jq -r '.scenario' "$f" | sed 's/_c[0-9].*$//')
    rps=$(jq -r '.result.throughput.rps // 0' "$f" | xargs printf "%7.1f")
    avg=$(jq -r '.result.responseTime.avg // 0' "$f" | xargs printf "%5.1f")
    p99=$(jq -r '.result.responseTime.p99 // 0' "$f" | xargs printf "%6d")
    printf "│ %-33s │%s │%sms │%sms │\n" "$name" "$rps" "$avg" "$p99"
done
echo "└──────────────────────────────────────────────────────────────┘"
echo ""
log "Results: $RESULT_DIR/"
ls -la "$RESULT_DIR/"
