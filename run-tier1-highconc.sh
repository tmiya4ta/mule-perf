#!/bin/bash
set -euo pipefail

PERF="https://mule-perf-2jt6tl.pnwfdv.jpn-e1.cloudhub.io"
TARGET="https://bench-target-2jt6tl.pnwfdv.jpn-e1.cloudhub.io"
INTERNAL="http://bench-target.0d0debc2-8327-4e41-b5fb-7911421cc2c5.svc.cluster.local:8081"
DURATION=60
WARMUP=10
RESULTS_DIR="/home/myst/AnypointStudio/mule-perf/benchmark-results"
TS="20260311-170431"

SMALL_BODY='{"firstName":"Taro","lastName":"Yamada","age":30,"department":"Engineering"}'
HEAVY_BODY=$(python3 -c "
import json
orders = []
for i in range(100):
    orders.append({'id':i+1,'item':['Widget','Gadget','Doohickey','Gizmo','Thingamajig'][i%5],'qty':(i%10)+1,'price':((i%50)+1)*10,'region':['JP','US','EU','APAC','LATAM'][i%5]})
print(json.dumps({'orders':orders}))
")

log() { echo "[$(date +%H:%M:%S)] $*"; }

run_test() {
    local scenario="$1" endpoint="$2" method="$3" concurrency="$4" body="$5"
    local full_url="${INTERNAL}${endpoint}"
    local outfile="$RESULTS_DIR/${scenario}_c${concurrency}_${TS}.json"

    if [ -f "$outfile" ]; then
        log "SKIP $scenario c=$concurrency"
        return 0
    fi

    log ">>> $scenario c=$concurrency"

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

    log "  id=${test_id:0:8}... waiting..."
    sleep $((WARMUP + DURATION / 2))

    local mid_perf mid_target
    mid_perf=$(curl -s --max-time 10 "$PERF/api/system" 2>/dev/null || echo '{}')
    mid_target=$(curl -s --max-time 10 "$TARGET/api/system" 2>/dev/null || echo '{}')

    sleep $((DURATION / 2 + 5))

    local post_perf post_target
    post_perf=$(curl -s --max-time 10 "$PERF/api/system" 2>/dev/null || echo '{}')
    post_target=$(curl -s --max-time 10 "$TARGET/api/system" 2>/dev/null || echo '{}')

    local result status
    for i in 1 2 3 4 5; do
        result=$(curl -s --max-time 15 "$PERF/api/tests/$test_id" 2>/dev/null || echo '{}')
        status=$(echo "$result" | jq -r '.status // "unknown"')
        [ "$status" = "completed" ] || [ "$status" = "error" ] && break
        log "  Poll $i: $status... +10s"
        sleep 10
    done

    local avg rps total errs mid_tcpu mid_pcpu
    avg=$(echo "$result" | jq '.responseTime.avg // 0 | . * 100 | round / 100')
    rps=$(echo "$result" | jq '.throughput.rps // 0 | . * 10 | round / 10')
    total=$(echo "$result" | jq '.totalRequests // 0')
    errs=$(echo "$result" | jq '.errorRate // 0 | . * 100 | round / 100')
    mid_tcpu=$(echo "$mid_target" | jq '.cpuPct // -1')
    mid_pcpu=$(echo "$mid_perf" | jq '.cpuPct // -1')

    log "  total=$total avg=${avg}ms rps=$rps err=${errs}% tCPU=${mid_tcpu}% pCPU=${mid_pcpu}%"

    cat > "$outfile" <<ENDJSON
{
  "scenario": "$scenario",
  "concurrency": $concurrency,
  "duration": $DURATION,
  "warmup": $WARMUP,
  "result": $result,
  "system": {
    "pre": {"mulePerf": $pre_perf, "benchTarget": $pre_target},
    "mid": {"mulePerf": $mid_perf, "benchTarget": $mid_target},
    "post": {"mulePerf": $post_perf, "benchTarget": $post_target}
  }
}
ENDJSON

    sleep 10
}

curl -s -X DELETE "$PERF/api/tests" > /dev/null 2>&1

log "═══ High Concurrency Tests (T1-B, T1-C) ═══"

for c in 200 500 1000; do
    run_test "T1-B-TransformSmall" "/api/transform/small" "POST" "$c" "$SMALL_BODY"
done

for c in 200 500 1000; do
    run_test "T1-C-TransformHeavy" "/api/transform/heavy" "POST" "$c" "$HEAVY_BODY"
done

log "═══ HIGH CONC COMPLETE ═══"
