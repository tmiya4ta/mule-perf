#!/bin/bash
# 1 vCore comprehensive benchmark: Echo, DW Small, DW Heavy, Oracle (Page/JOIN/BulkInsert)
set -euo pipefail

PERF_URL="${1:?Usage: $0 <perf-url> <target-url> [internal-target-url]}"
TARGET_URL="${2:?Usage: $0 <perf-url> <target-url> [internal-target-url]}"
INTERNAL_TARGET="${3:-$TARGET_URL}"

DURATION="${DURATION:-180}"
WARMUP="${WARMUP:-15}"
METRICS_INTERVAL="${METRICS_INTERVAL:-5}"
BASE_DIR="${RESULT_DIR:-benchmark-results/17-1vcore-comprehensive-$(date +%Y%m%d)}"

log() { echo "[$(date +%H:%M:%S)] $*"; }

collect_metrics() {
    local test_name="$1" metrics_file="$BASE_DIR/${test_name}_metrics.jsonl"
    : > "$metrics_file"
    while true; do
        local ts; ts=$(date +%s%3N 2>/dev/null || date +%s000)
        local loader_sys target_sys
        loader_sys=$(curl -sf --connect-timeout 3 --max-time 5 "$PERF_URL/api/system" 2>/dev/null | jq -c . 2>/dev/null || echo '{"error":"unreachable"}')
        target_sys=$(curl -sf --connect-timeout 3 --max-time 5 "$TARGET_URL/api/system" 2>/dev/null | jq -c . 2>/dev/null || echo '{"error":"unreachable"}')
        echo "{\"ts\":$ts,\"loader\":$loader_sys,\"target\":$target_sys}" >> "$metrics_file"
        sleep "$METRICS_INTERVAL"
    done
}

run_benchmark() {
    local name="$1" url="$2" conc="$3" method="${4:-GET}" body="${5:-}"
    local full_name="${name}_c${conc}_${DURATION}s"
    echo ""
    echo "════════════════════════════════════════════════════════════════"
    log "START: $full_name"
    log "  URL: $url  Method: $method  Concurrency: $conc  Duration: ${DURATION}s"

    collect_metrics "$full_name" &
    local metrics_pid=$!

    local test_body
    if [ -n "$body" ]; then
        test_body=$(jq -n --arg url "$url" --arg method "$method" --argjson body "$body" \
            --argjson c "$conc" --argjson d "$DURATION" --argjson w "$WARMUP" \
            '{targetUrl: $url, method: $method, body: $body, concurrency: $c, duration: $d, warmup: $w}')
    else
        test_body=$(jq -n --arg url "$url" --arg method "$method" \
            --argjson c "$conc" --argjson d "$DURATION" --argjson w "$WARMUP" \
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
    jq -n --arg scenario "$full_name" --argjson c "$conc" --argjson d "$DURATION" --argjson w "$WARMUP" \
        --argjson result "$result_json" \
        '{scenario: $scenario, concurrency: $c, duration: $d, warmup: $w, result: $result}' > "$BASE_DIR/${full_name}.json"

    local final_rps avg_rt p99 err_rate
    final_rps=$(echo "$result_json" | jq -r '.throughput.rps // 0' | xargs printf "%.1f")
    avg_rt=$(echo "$result_json" | jq -r '.responseTime.avg // 0' | xargs printf "%.1f")
    p99=$(echo "$result_json" | jq -r '.responseTime.p99 // 0')
    err_rate=$(echo "$result_json" | jq -r '.errorRate // 0')
    log "  RESULT: RPS=$final_rps  AvgRT=${avg_rt}ms  P99=${p99}ms  Errors=${err_rate}%"
}

# ══════════════════════════════════════════════════════════════
mkdir -p "$BASE_DIR"
log "═══ 1 vCore Comprehensive Benchmark ═══"
log "  bench-target: 1 vCore, uber=50, pool=50"
log "  mule-perf: 1 vCore"

for CONC in 10 50; do
    log ""
    log "═══════════════════════════════════════════════"
    log "  CONCURRENCY = $CONC"
    log "═══════════════════════════════════════════════"

    # Reset Oracle data
    curl -sf --max-time 120 "$TARGET_URL/api/benchmark/reset" > /dev/null 2>&1

    # T1: CPU tests
    run_benchmark "T1-A-Echo" "$INTERNAL_TARGET/api/echo" "$CONC"

    run_benchmark "T1-B-TransformSmall" "$INTERNAL_TARGET/api/transform/small" "$CONC" "POST" \
        '{"firstName":"John","lastName":"Doe","age":30,"department":"engineering"}'

    run_benchmark "T1-C-TransformHeavy" "$INTERNAL_TARGET/api/transform/heavy" "$CONC" "POST" \
        '{"orders":[{"id":1,"item":"Widget","qty":10,"price":25.50,"region":"US"},{"id":2,"item":"Gadget","qty":5,"price":100.00,"region":"EU"},{"id":3,"item":"Widget","qty":20,"price":25.50,"region":"JP"},{"id":4,"item":"Doohickey","qty":3,"price":500.00,"region":"US"},{"id":5,"item":"Gadget","qty":15,"price":100.00,"region":"JP"},{"id":6,"item":"Widget","qty":8,"price":25.50,"region":"EU"},{"id":7,"item":"Thingamajig","qty":2,"price":750.00,"region":"US"},{"id":8,"item":"Gadget","qty":12,"price":100.00,"region":"EU"}]}'

    # T5: Oracle
    run_benchmark "T5-E-Oracle-Page" "$INTERNAL_TARGET/api/oracle/page?page=1&size=20" "$CONC"
    run_benchmark "T5-A-Oracle-JoinReport" "$INTERNAL_TARGET/api/oracle/join-report" "$CONC"
    run_benchmark "T5-C-Oracle-BulkInsert" "$INTERNAL_TARGET/api/oracle/bulk-insert?count=10" "$CONC" "POST" "{}"
done

# Summary
log ""
log "═══ SUMMARY ═══"
printf "%-30s %8s %8s %8s %6s %6s\n" "Scenario" "RPS" "AvgRT" "P99" "CPU%" "CPUmax"
printf "%-30s %8s %8s %8s %6s %6s\n" "---" "---" "---" "---" "---" "---"
for f in "$BASE_DIR"/*.json; do
    [ -f "$f" ] || continue
    [[ "$f" == *metrics* ]] && continue
    name=$(jq -r '.scenario' "$f")
    rps=$(jq -r '.result.throughput.rps // 0' "$f" | xargs printf "%.1f")
    avg=$(jq -r '.result.responseTime.avg // 0' "$f" | xargs printf "%.1f")
    p99=$(jq -r '.result.responseTime.p99 // 0' "$f" | xargs printf "%d")
    err=$(jq -r '.result.errorRate // 0' "$f")
    printf "%-30s %8s %7sms %5sms %s\n" "$name" "$rps" "$avg" "$p99" ""
done
log "Results: $BASE_DIR/"
