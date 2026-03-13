#!/bin/bash
set -euo pipefail

PERF="https://mule-perf-2jt6tl.pnwfdv.jpn-e1.cloudhub.io"
TARGET="https://bench-target-2jt6tl.pnwfdv.jpn-e1.cloudhub.io"
INTERNAL="http://bench-target.0d0debc2-8327-4e41-b5fb-7911421cc2c5.svc.cluster.local:8081"
DURATION=60
WARMUP=10
VCORE="${1:-0.5}"
RESULTS_DIR="/home/myst/AnypointStudio/mule-perf/benchmark-results/threshold-${VCORE}"
mkdir -p "$RESULTS_DIR"

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
    for id in $(curl -s --max-time 10 "$PERF/api/tests" 2>/dev/null | jq -r '.tests[].id' 2>/dev/null); do
        curl -s -X DELETE "$PERF/api/tests/$id" > /dev/null 2>&1
    done
    sleep 5
}

run_test() {
    local scenario="$1" endpoint="$2" method="$3" concurrency="$4" body="$5"
    local full_url="${INTERNAL}${endpoint}"
    local outfile="$RESULTS_DIR/${scenario}_c${concurrency}.json"

    [ -f "$outfile" ] && { log "SKIP $scenario c=$concurrency"; return 0; }

    stop_all_tests
    sleep 5

    log "━━━ $scenario | c=$concurrency | ${DURATION}s | ${VCORE}vCore ━━━"

    local payload
    if [ -z "$body" ]; then
        payload="{\"targetUrl\":\"$full_url\",\"method\":\"$method\",\"concurrency\":$concurrency,\"duration\":$DURATION,\"warmup\":$WARMUP}"
    else
        payload="{\"targetUrl\":\"$full_url\",\"method\":\"$method\",\"concurrency\":$concurrency,\"duration\":$DURATION,\"warmup\":$WARMUP,\"body\":$body}"
    fi

    local pre_target
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

    # mid-point metrics
    sleep $((WARMUP + DURATION / 2))
    log "  50%..."
    local mid_perf mid_target
    mid_perf=$(curl -s --max-time 10 "$PERF/api/system" 2>/dev/null || echo '{}')
    mid_target=$(curl -s --max-time 10 "$TARGET/api/system" 2>/dev/null || echo '{}')

    sleep $((DURATION / 2 + 10))

    # Poll
    local result status
    for i in 1 2 3 4 5 6 7 8; do
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

    log "  ✓ total=$total avg=${avg}ms rps=$rps err=${errs}% tCPU=${mid_tcpu}%"

    cat > "$outfile" <<ENDJSON
{
  "scenario": "$scenario",
  "concurrency": $concurrency,
  "duration": $DURATION,
  "warmup": $WARMUP,
  "vCore": "$VCORE",
  "result": $result,
  "system": {
    "pre":  {"benchTarget": $pre_target},
    "mid":  {"mulePerf": $mid_perf, "benchTarget": $mid_target}
  }
}
ENDJSON

    sleep 15
}

log "╔═══════════════════════════════════════════════════╗"
log "║  Threshold Test: ${VCORE} vCore (60s)             ║"
log "╚═══════════════════════════════════════════════════╝"

if [ "$VCORE" = "0.5" ]; then
    # Echo: does it degrade at high conc?
    for c in 100 200; do
        run_test "T1-A-Echo" "/api/echo" "GET" "$c" ""
    done

    # Small DW: threshold between c=50 (97%) and c=100 (32%)
    for c in 60 75 90; do
        run_test "T1-B-TransformSmall" "/api/transform/small" "POST" "$c" "$SMALL_BODY"
    done

    # Heavy DW: threshold between c=5 (97%) and c=10 (32%)
    for c in 1 7 8; do
        run_test "T1-C-TransformHeavy" "/api/transform/heavy" "POST" "$c" "$HEAVY_BODY"
    done

    # Single-request latency
    for scenario_args in "T1-A-Echo /api/echo GET 1 " "T1-B-TransformSmall /api/transform/small POST 1 $SMALL_BODY"; do
        run_test $scenario_args
    done

elif [ "$VCORE" = "1" ]; then
    # Echo: threshold between c=50 (97%) and c=100 (40%)
    for c in 60 70 80; do
        run_test "T1-A-Echo" "/api/echo" "GET" "$c" ""
    done
fi

log "═══ THRESHOLD TEST COMPLETE ═══"

# Summary
log ""
printf "%-25s %5s %8s %8s %6s %6s\n" "Scenario" "Conc" "RPS" "Avg(ms)" "Err%" "tCPU%"
echo "--------------------------------------------------------------"
for f in $(ls "$RESULTS_DIR"/T1-*.json 2>/dev/null | sort); do
    [ -f "$f" ] || continue
    scn=$(jq -r '.scenario' "$f")
    c=$(jq '.concurrency' "$f")
    rps=$(jq '.result.throughput.rps // 0 | . * 10 | round / 10' "$f")
    avg=$(jq '.result.responseTime.avg // 0 | . * 100 | round / 100' "$f")
    errs=$(jq '.result.errorRate // 0 | . * 100 | round / 100' "$f")
    tcpu=$(jq '.system.mid.benchTarget.cpuPct // -1' "$f")
    printf "%-25s %5s %8s %8s %6s %6s\n" "$scn" "$c" "$rps" "$avg" "$errs" "$tcpu"
done
