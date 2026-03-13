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
HEAVY_BODY=$(python3 -c "
import json
orders = []
for i in range(100):
    orders.append({'id':i+1,'item':['Widget','Gadget','Doohickey','Gizmo','Thingamajig'][i%5],'qty':(i%10)+1,'price':((i%50)+1)*10,'region':['JP','US','EU','APAC','LATAM'][i%5]})
print(json.dumps({'orders':orders}))
")

log() { echo "[$(date +%H:%M:%S)] $*"; }

stop_all_tests() {
    # Fix: DELETE /api/tests doesn't work, must stop individually
    local tests=$(curl -s --max-time 10 "$PERF/api/tests" 2>/dev/null || echo '{"tests":[]}')
    local ids=$(echo "$tests" | jq -r '.tests[].id' 2>/dev/null)
    for id in $ids; do
        curl -s -X DELETE "$PERF/api/tests/$id" > /dev/null 2>&1
    done
    sleep 5
}

run_test() {
    local scenario="$1" endpoint="$2" method="$3" concurrency="$4" body="$5"
    local full_url="${INTERNAL}${endpoint}"
    local outfile="$RESULTS_DIR/${scenario}_c${concurrency}.json"

    [ -f "$outfile" ] && { log "SKIP $scenario c=$concurrency (exists)"; return 0; }

    # Stop all previous tests
    stop_all_tests
    sleep 10

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

    sleep $((DURATION / 4 + 15))
    local post_perf post_target
    post_perf=$(curl -s --max-time 10 "$PERF/api/system" 2>/dev/null || echo '{}')
    post_target=$(curl -s --max-time 10 "$TARGET/api/system" 2>/dev/null || echo '{}')

    # Poll for completion
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

    sleep 30
}

log "═══ Trial 4 Retry3 (fixed DELETE) ═══"

# Missing: T1-B c=100, T1-C c=10,50,100
run_test "T1-B-TransformSmall" "/api/transform/small" "POST" 100 "$SMALL_BODY"

for c in 10 50 100; do
    run_test "T1-C-TransformHeavy" "/api/transform/heavy" "POST" "$c" "$HEAVY_BODY"
done

log "═══ RETRY3 COMPLETE ═══"
