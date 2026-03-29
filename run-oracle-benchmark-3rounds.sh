#!/bin/bash
# 3-round Oracle-only benchmark with reset between rounds
# Reuses run-db-benchmark.sh infrastructure by setting SCENARIOS env var
set -euo pipefail

PERF_URL="${1:?Usage: $0 <perf-url> <target-url> [internal-target-url]}"
TARGET_URL="${2:?Usage: $0 <perf-url> <target-url> [internal-target-url]}"
INTERNAL_TARGET="${3:-$TARGET_URL}"

ROUNDS=3
BASE_DIR="benchmark-results/14-db-comparison-$(date +%Y%m%d)"

log() { echo "[$(date +%H:%M:%S)] $*"; }

# Inline the benchmark runner (same as run-db-benchmark.sh)
DURATION="${DURATION:-180}"
WARMUP="${WARMUP:-15}"
CONCURRENCY="${CONCURRENCY:-10}"
METRICS_INTERVAL="${METRICS_INTERVAL:-5}"

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

run_benchmark() {
    local name="$1" url="$2" method="${3:-GET}" body="${4:-}"
    echo ""
    echo "════════════════════════════════════════════════════════════════"
    log "START: $name"
    log "  URL:         $url"
    log "  Method:      $method"
    log "  Concurrency: $CONCURRENCY"
    log "  Duration:    ${DURATION}s + ${WARMUP}s warmup"

    collect_metrics "$name" &
    local metrics_pid=$!

    local test_body
    if [ -n "$body" ]; then
        test_body=$(jq -n --arg url "$url" --arg method "$method" --arg body "$body" \
            --argjson c "$CONCURRENCY" --argjson d "$DURATION" --argjson w "$WARMUP" \
            '{targetUrl: $url, method: $method, body: $body, concurrency: $c, duration: $d, warmup: $w}')
    else
        test_body=$(jq -n --arg url "$url" --arg method "$method" \
            --argjson c "$CONCURRENCY" --argjson d "$DURATION" --argjson w "$WARMUP" \
            '{targetUrl: $url, method: $method, concurrency: $c, duration: $d, warmup: $w}')
    fi

    local response test_id
    response=$(curl -sf -X POST "$PERF_URL/api/tests" -H "Content-Type: application/json" -d "$test_body")
    test_id=$(echo "$response" | jq -r '.id // .testId')
    log "  Test ID: $test_id"

    local elapsed=0 total_wait=$((DURATION + WARMUP + 30))
    while [ $elapsed -lt $total_wait ]; do
        sleep 10; elapsed=$((elapsed + 10))
        local status_json status rps total_req
        status_json=$(curl -sf "$PERF_URL/api/tests/$test_id" 2>/dev/null || echo '{"status":"polling"}')
        status=$(echo "$status_json" | jq -r '.status // "unknown"')
        rps=$(echo "$status_json" | jq -r '.throughput.rps // "-"' 2>/dev/null)
        total_req=$(echo "$status_json" | jq -r '.totalRequests // "-"' 2>/dev/null)
        log "  [${elapsed}s] status=$status rps=$rps total=$total_req"
        [ "$status" = "completed" ] && break
        [ "$status" = "error" ] && break
    done

    kill "$metrics_pid" 2>/dev/null || true; wait "$metrics_pid" 2>/dev/null || true

    local result_json
    result_json=$(curl -sf "$PERF_URL/api/tests/$test_id")
    jq -n --arg scenario "$name" --argjson c "$CONCURRENCY" --argjson d "$DURATION" --argjson w "$WARMUP" \
        --argjson result "$result_json" \
        '{scenario: $scenario, concurrency: $c, duration: $d, warmup: $w, result: $result}' > "$RESULT_DIR/${name}.json"

    local final_rps avg_rt p99 err_rate
    final_rps=$(echo "$result_json" | jq -r '.throughput.rps // 0' | xargs printf "%.1f")
    avg_rt=$(echo "$result_json" | jq -r '.responseTime.avg // 0' | xargs printf "%.1f")
    p99=$(echo "$result_json" | jq -r '.responseTime.p99 // 0')
    err_rate=$(echo "$result_json" | jq -r '.errorRate // 0')
    log "  RESULT: RPS=$final_rps  AvgRT=${avg_rt}ms  P99=${p99}ms  Errors=${err_rate}%"
    log "  Saved: $RESULT_DIR/${name}.json"
}

# ══════════════════════════════════════════════════════════════
log "═══ 3-Round Oracle-Only Benchmark ═══"
log "Initial conditions: bench_users=150, bench_orders=500"
echo ""

for round in $(seq 1 $ROUNDS); do
    ROUND_NUM=$((round + 3))
    log "═══════════════════════════════════════════════"
    log "  ROUND $ROUND_NUM (Oracle extra round $round)"
    log "═══════════════════════════════════════════════"

    log "Resetting benchmark data..."
    reset_result=$(curl -sf --max-time 120 "$TARGET_URL/api/benchmark/reset" 2>/dev/null || echo '{"error":"reset failed"}')
    log "Reset: $(echo "$reset_result" | jq -c .)"

    oracle_join=$(curl -sf --max-time 15 "$TARGET_URL/api/oracle/join-report" 2>/dev/null | jq -r '.grandTotal // "FAIL"')
    log "Verify: Oracle grandTotal=$oracle_join"
    [ "$oracle_join" = "FAIL" ] && { log "ERROR: verification failed, skip"; continue; }

    RESULT_DIR="${BASE_DIR}/round${ROUND_NUM}"
    mkdir -p "$RESULT_DIR"

    run_benchmark "T5-E-Oracle-Page_c${CONCURRENCY}_${DURATION}s" \
        "$INTERNAL_TARGET/api/oracle/page?page=1&size=20"
    run_benchmark "T5-A-Oracle-JoinReport_c${CONCURRENCY}_${DURATION}s" \
        "$INTERNAL_TARGET/api/oracle/join-report"
    run_benchmark "T5-C-Oracle-BulkInsert_c${CONCURRENCY}_${DURATION}s" \
        "$INTERNAL_TARGET/api/oracle/bulk-insert?count=10" "POST" "{}"

    log "Round $ROUND_NUM complete: $RESULT_DIR/"
    echo ""
done

log "═══ ORACLE 6-ROUND SUMMARY (all rounds) ═══"
echo ""
printf "%-25s" "Scenario"
for r in 1 2 3 4 5 6; do printf "  %8s" "R$r"; done
printf "  %8s\n" "Avg"
printf "%-25s" "---"
for r in 1 2 3 4 5 6; do printf "  %8s" "---"; done
printf "  %8s\n" "---"

for scenario in T5-E-Oracle-Page T5-A-Oracle-JoinReport T5-C-Oracle-BulkInsert; do
    rps_sum=0; count=0; rps_vals=""
    for round in 1 2 3 4 5 6; do
        f=$(ls "${BASE_DIR}/round${round}/${scenario}"_*.json 2>/dev/null | head -1)
        if [ -n "$f" ] && [ -f "$f" ]; then
            rps=$(jq -r '.result.throughput.rps // 0' "$f")
            rps_fmt=$(printf "%8.1f" "$rps")
            rps_sum=$(echo "$rps_sum + $rps" | bc)
            count=$((count + 1))
        else
            rps_fmt="     N/A"
        fi
        rps_vals="$rps_vals  $rps_fmt"
    done
    avg=$(echo "scale=1; $rps_sum / $count" | bc)
    printf "%-25s%s  %8s\n" "$scenario" "$rps_vals" "$avg"
done
echo ""
log "Done."
