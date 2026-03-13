#!/bin/bash
# Tier 1 Benchmark Runner - automated
set -euo pipefail

PERF="https://mule-perf-2jt6tl.pnwfdv.jpn-e1.cloudhub.io"
TARGET="https://bench-target-2jt6tl.pnwfdv.jpn-e1.cloudhub.io"
INTERNAL="http://bench-target.0d0debc2-8327-4e41-b5fb-7911421cc2c5.svc.cluster.local:8081"
DURATION=60
WARMUP=10
RESULTS_DIR="/home/myst/AnypointStudio/mule-perf/benchmark-results"
mkdir -p "$RESULTS_DIR"

SMALL_BODY='{"firstName":"Taro","lastName":"Yamada","age":30,"department":"Engineering"}'

# Generate heavy body
HEAVY_BODY=$(python3 -c "
import json
orders = []
regions = ['JP', 'US', 'EU', 'APAC', 'LATAM']
items = ['Widget', 'Gadget', 'Doohickey', 'Gizmo', 'Thingamajig']
for i in range(100):
    orders.append({
        'id': i+1,
        'item': items[i % len(items)],
        'qty': (i % 10) + 1,
        'price': ((i % 50) + 1) * 10,
        'region': regions[i % len(regions)]
    })
print(json.dumps({'orders': orders}))
")

log() { echo "[$(date +%H:%M:%S)] $*"; }

run_test() {
    local scenario="$1" endpoint="$2" method="$3" concurrency="$4" body="$5"
    local full_url="${INTERNAL}${endpoint}"
    local wait_sec=$((WARMUP + DURATION + 5))

    log ">>> $scenario c=$concurrency start"

    # Build payload
    local payload
    if [ -z "$body" ]; then
        payload="{\"targetUrl\":\"$full_url\",\"method\":\"$method\",\"concurrency\":$concurrency,\"duration\":$DURATION,\"warmup\":$WARMUP}"
    else
        payload="{\"targetUrl\":\"$full_url\",\"method\":\"$method\",\"concurrency\":$concurrency,\"duration\":$DURATION,\"warmup\":$WARMUP,\"body\":$body}"
    fi

    # Pre-test system metrics
    local pre_perf pre_target
    pre_perf=$(curl -s --max-time 10 "$PERF/api/system" 2>/dev/null || echo '{}')
    pre_target=$(curl -s --max-time 10 "$TARGET/api/system" 2>/dev/null || echo '{}')

    # Start test
    local resp
    resp=$(curl -s --max-time 15 -X POST "$PERF/api/tests" \
        -H "Content-Type: application/json" -d "$payload")

    local test_id
    test_id=$(echo "$resp" | jq -r '.id // empty')
    if [ -z "$test_id" ]; then
        log "  ERROR: $resp"
        return 1
    fi

    log "  id=$test_id, waiting ${wait_sec}s..."

    # Mid-test metrics (at ~50%)
    sleep $((WARMUP + DURATION / 2))
    local mid_perf mid_target
    mid_perf=$(curl -s --max-time 10 "$PERF/api/system" 2>/dev/null || echo '{}')
    mid_target=$(curl -s --max-time 10 "$TARGET/api/system" 2>/dev/null || echo '{}')

    # Wait remaining
    sleep $((DURATION / 2 + 5))

    # Post-test metrics
    local post_perf post_target
    post_perf=$(curl -s --max-time 10 "$PERF/api/system" 2>/dev/null || echo '{}')
    post_target=$(curl -s --max-time 10 "$TARGET/api/system" 2>/dev/null || echo '{}')

    # Get results
    local result
    result=$(curl -s --max-time 15 "$PERF/api/tests/$test_id")

    local status avg p95 p99 rps total errs
    status=$(echo "$result" | jq -r '.status')
    avg=$(echo "$result" | jq '.responseTime.avg // 0 | . * 100 | round / 100')
    p95=$(echo "$result" | jq '.responseTime.p95 // 0')
    p99=$(echo "$result" | jq '.responseTime.p99 // 0')
    rps=$(echo "$result" | jq '.throughput.rps // 0 | . * 10 | round / 10')
    total=$(echo "$result" | jq '.totalRequests // 0')
    errs=$(echo "$result" | jq '.errorCount // 0')

    local mid_tcpu mid_theap mid_pcpu
    mid_tcpu=$(echo "$mid_target" | jq '.cpuPct // -1')
    mid_theap=$(echo "$mid_target" | jq '.heapPct // -1')
    mid_pcpu=$(echo "$mid_perf" | jq '.cpuPct // -1')

    log "  $status: total=$total avg=${avg}ms p95=${p95}ms p99=${p99}ms rps=$rps errs=$errs"
    log "  CPU: perf=${mid_pcpu}% target=${mid_tcpu}% | Heap: target=${mid_theap}%"

    # Save to file
    local fname="${scenario}_c${concurrency}.json"
    cat > "$RESULTS_DIR/$fname" <<ENDJSON
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

    # Cool down
    log "  cooling 10s..."
    sleep 10
}

log "=== TIER 1 BENCHMARK START ==="

# T1-A: Echo (GET, no body)
for c in 1 5 10 50 100; do
    run_test "T1-A-Echo" "/api/echo" "GET" "$c" ""
done

# T1-B: Transform Small (POST with body)
for c in 1 5 10 50 100; do
    run_test "T1-B-TransformSmall" "/api/transform/small" "POST" "$c" "$SMALL_BODY"
done

# T1-C: Transform Heavy (POST with body)
for c in 1 5 10 50 100; do
    run_test "T1-C-TransformHeavy" "/api/transform/heavy" "POST" "$c" "$HEAVY_BODY"
done

log "=== TIER 1 BENCHMARK COMPLETE ==="
log "Results saved to: $RESULTS_DIR/"

# Summary table
log ""
log "SUMMARY:"
printf "%-25s %5s %8s %6s %6s %6s %6s %6s %6s %6s\n" "Scenario" "Conc" "Total" "Avg" "P95" "P99" "RPS" "Errs" "tCPU%" "pCPU%"
printf "%-25s %5s %8s %6s %6s %6s %6s %6s %6s %6s\n" "-------------------------" "-----" "--------" "------" "------" "------" "------" "------" "------" "------"

for f in "$RESULTS_DIR"/T1-*.json; do
    scn=$(jq -r '.scenario' "$f")
    c=$(jq '.concurrency' "$f")
    total=$(jq '.result.totalRequests // 0' "$f")
    avg=$(jq '.result.responseTime.avg // 0 | . * 100 | round / 100' "$f")
    p95=$(jq '.result.responseTime.p95 // 0' "$f")
    p99=$(jq '.result.responseTime.p99 // 0' "$f")
    rps=$(jq '.result.throughput.rps // 0 | . * 10 | round / 10' "$f")
    errs=$(jq '.result.errorCount // 0' "$f")
    tcpu=$(jq '.system.mid.benchTarget.cpuPct // -1' "$f")
    pcpu=$(jq '.system.mid.mulePerf.cpuPct // -1' "$f")
    printf "%-25s %5s %8s %6s %6s %6s %6s %6s %6s %6s\n" "$scn" "$c" "$total" "$avg" "$p95" "$p99" "$rps" "$errs" "$tcpu" "$pcpu"
done
