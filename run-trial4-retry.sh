#!/bin/bash
set -euo pipefail

PERF="https://mule-perf-2jt6tl.pnwfdv.jpn-e1.cloudhub.io"
TARGET="https://bench-target-2jt6tl.pnwfdv.jpn-e1.cloudhub.io"
INTERNAL="http://bench-target.0d0debc2-8327-4e41-b5fb-7911421cc2c5.svc.cluster.local:8081"
DURATION=180
WARMUP=15
VCORE="0.5"
RESULTS_DIR="/home/myst/AnypointStudio/mule-perf/benchmark-results/trial4"

SMALL_BODY='{"firstName":"Taro","lastName":"Yamada","age":30,"department":"Engineering"}'

log() { echo "[$(date +%H:%M:%S)] $*"; }

run_test() {
    local scenario="$1" endpoint="$2" method="$3" concurrency="$4" body="$5"
    local full_url="${INTERNAL}${endpoint}"
    local outfile="$RESULTS_DIR/${scenario}_c${concurrency}.json"

    [ -f "$outfile" ] && { log "SKIP $scenario c=$concurrency (exists)"; return 0; }

    # Clear any previous tests first
    curl -s -X DELETE "$PERF/api/tests" > /dev/null 2>&1
    sleep 5

    log "━━━ $scenario | c=$concurrency | ${DURATION}s | ${VCORE}vCore ━━━"

    local payload
    if [ -z "$body" ]; then
        payload="{\"targetUrl\":\"$full_url\",\"method\":\"$method\",\"concurrency\":$concurrency,\"duration\":$DURATION,\"warmup\":$WARMUP}"
    else
        payload="{\"targetUrl\":\"$full_url\",\"method\":\"$method\",\"concurrency\":$concurrency,\"duration\":$DURATION,\"warmup\":$WARMUP,\"body\":$body}"
    fi

    local pre_perf pre_target
    pre_perf=$(curl -s --max-time 10 "$PERF/api/system" 2>/dev/null || echo '{}')
    pre_target=$(curl -s --max-time 10 "$TARGET/api/system" 2>/dev/null || echo '{}')

    local resp test_id
    resp=$(curl -s --max-time 15 -X POST "$PERF/api/tests" \
        -H "Content-Type: application/json" -d "$payload")
    test_id=$(echo "$resp" | jq -r '.id // empty')
    if [ -z "$test_id" ]; then
        log "  ERROR: $resp"
        return 1
    fi
    log "  id=${test_id:0:8}..."

    sleep $((WARMUP + DURATION / 4))
    log "  25%..."
    local q1_perf q1_target
    q1_perf=$(curl -s --max-time 10 "$PERF/api/system" 2>/dev/null || echo '{}')
    q1_target=$(curl -s --max-time 10 "$TARGET/api/system" 2>/dev/null || echo '{}')

    sleep $((DURATION / 4))
    log "  50%..."
    local mid_perf mid_target
    mid_perf=$(curl -s --max-time 10 "$PERF/api/system" 2>/dev/null || echo '{}')
    mid_target=$(curl -s --max-time 10 "$TARGET/api/system" 2>/dev/null || echo '{}')

    sleep $((DURATION / 4))
    log "  75%..."
    local q3_perf q3_target
    q3_perf=$(curl -s --max-time 10 "$PERF/api/system" 2>/dev/null || echo '{}')
    q3_target=$(curl -s --max-time 10 "$TARGET/api/system" 2>/dev/null || echo '{}')

    sleep $((DURATION / 4 + 10))
    local post_perf post_target
    post_perf=$(curl -s --max-time 10 "$PERF/api/system" 2>/dev/null || echo '{}')
    post_target=$(curl -s --max-time 10 "$TARGET/api/system" 2>/dev/null || echo '{}')

    # Poll for completion - wait longer
    local result status
    for i in 1 2 3 4 5 6 7 8 9 10; do
        result=$(curl -s --max-time 15 "$PERF/api/tests/$test_id" 2>/dev/null || echo '{}')
        status=$(echo "$result" | jq -r '.status // "unknown"')
        [ "$status" = "completed" ] || [ "$status" = "error" ] && break
        log "  Poll $i: $status... +15s"
        sleep 15
    done

    local avg rps total errs mid_tcpu mid_pcpu
    avg=$(echo "$result" | jq '.responseTime.avg // 0 | . * 100 | round / 100')
    rps=$(echo "$result" | jq '.throughput.rps // 0 | . * 10 | round / 10')
    total=$(echo "$result" | jq '.totalRequests // 0')
    errs=$(echo "$result" | jq '.errorRate // 0 | . * 100 | round / 100')
    mid_tcpu=$(echo "$mid_target" | jq '.cpuPct // -1')
    mid_pcpu=$(echo "$mid_perf" | jq '.cpuPct // -1')

    log "  ✓ status=$status total=$total avg=${avg}ms rps=$rps err=${errs}% tCPU=${mid_tcpu}% pCPU=${mid_pcpu}%"

    if [ "$errs" != "0" ] && [ "$(echo "$errs > 1" | bc)" = "1" ]; then
        log "  WARNING: High error rate ${errs}% - check results"
    fi

    cat > "$outfile" <<ENDJSON
{
  "scenario": "$scenario",
  "concurrency": $concurrency,
  "duration": $DURATION,
  "warmup": $WARMUP,
  "vCore": "$VCORE",
  "result": $result,
  "system": {
    "pre":  {"mulePerf": $pre_perf, "benchTarget": $pre_target},
    "q1":   {"mulePerf": $q1_perf, "benchTarget": $q1_target},
    "mid":  {"mulePerf": $mid_perf, "benchTarget": $mid_target},
    "q3":   {"mulePerf": $q3_perf, "benchTarget": $q3_target},
    "post": {"mulePerf": $post_perf, "benchTarget": $post_target}
  }
}
ENDJSON

    # Longer cooling between tests
    log "  Cooling 30s..."
    sleep 30
}

log "═══ Trial 4 Retry (0.5 vCore) ═══"

# T1-A Echo c=10
run_test "T1-A-Echo" "/api/echo" "GET" 10 ""

# T1-B Transform Small c=5,50,100
for c in 5 50 100; do
    run_test "T1-B-TransformSmall" "/api/transform/small" "POST" "$c" "$SMALL_BODY"
done

log "═══ RETRY COMPLETE ═══"
