#!/bin/bash
# Mule 4 Performance Benchmark Runner - Tier 1 (Pure Mule)
set -euo pipefail

PERF_URL="https://mule-perf-2jt6tl.pnwfdv.jpn-e1.cloudhub.io"
TARGET_URL="https://bench-target-2jt6tl.pnwfdv.jpn-e1.cloudhub.io"
TARGET_INTERNAL="http://bench-target.0d0debc2-8327-4e41-b5fb-7911421cc2c5.svc.cluster.local:8081"
RESULT_DIR="/home/myst/AnypointStudio/mule-perf/benchmark-results"
mkdir -p "$RESULT_DIR"
TS=$(date +%Y%m%d-%H%M%S)

CONCURRENCIES=(1 5 10 50 100)
DURATION=60
WARMUP=10

log() { echo "[$(date +%H:%M:%S)] $*" >&2; }

# Collect system metrics
collect_metrics() {
    local perf_sys target_sys
    perf_sys=$(curl -s --max-time 10 "$PERF_URL/api/system" 2>/dev/null || echo '{}')
    target_sys=$(curl -s --max-time 10 "$TARGET_URL/api/system" 2>/dev/null || echo '{}')
    echo "{\"ts\":\"$(date -Iseconds)\",\"mulePerf\":$perf_sys,\"benchTarget\":$target_sys}"
}

# Run one test, save result to individual file
run_test() {
    local scenario="$1" endpoint="$2" method="$3" concurrency="$4" body="$5"
    local full_url="${TARGET_INTERNAL}${endpoint}"
    local outfile="${RESULT_DIR}/${scenario}_c${concurrency}_${TS}.json"

    log "━━━ $scenario | c=$concurrency ━━━"

    # Pre-test metrics
    local pre_metrics
    pre_metrics=$(collect_metrics)

    # Build payload
    local payload
    if [ -z "$body" ]; then
        payload="{\"targetUrl\":\"$full_url\",\"method\":\"$method\",\"concurrency\":$concurrency,\"duration\":$DURATION,\"warmup\":$WARMUP}"
    else
        payload="{\"targetUrl\":\"$full_url\",\"method\":\"$method\",\"concurrency\":$concurrency,\"duration\":$DURATION,\"warmup\":$WARMUP,\"body\":$body}"
    fi

    # Start test
    local start_resp test_id
    start_resp=$(curl -s --max-time 15 -X POST "$PERF_URL/api/tests" \
        -H "Content-Type: application/json" -d "$payload")
    test_id=$(echo "$start_resp" | jq -r '.id // empty')

    if [ -z "$test_id" ]; then
        log "  ERROR: $start_resp"
        return 1
    fi
    log "  Started: ${test_id:0:8}..."

    # Wait warmup + half duration → mid metrics
    sleep $((WARMUP + DURATION / 2))
    log "  Collecting mid-point metrics..."
    local mid_metrics
    mid_metrics=$(collect_metrics)

    # Wait remaining
    sleep $((DURATION / 2 + 5))

    # Poll for completion
    local result status
    for attempt in 1 2 3 4 5 6; do
        result=$(curl -s --max-time 15 "$PERF_URL/api/tests/$test_id" 2>/dev/null || echo '{}')
        status=$(echo "$result" | jq -r '.status // "unknown"')
        if [ "$status" = "completed" ] || [ "$status" = "error" ]; then
            break
        fi
        log "  Still $status (poll $attempt)... +10s"
        sleep 10
    done

    # Post-test metrics
    local post_metrics
    post_metrics=$(collect_metrics)

    # Extract summary for log
    local avg rps err total
    avg=$(echo "$result" | jq '(.responseTime.avg // 0) * 100 | round / 100' 2>/dev/null || echo 0)
    rps=$(echo "$result" | jq '(.throughput.rps // 0) * 10 | round / 10' 2>/dev/null || echo 0)
    err=$(echo "$result" | jq '(.errorRate // 0) * 100 | round / 100' 2>/dev/null || echo 0)
    total=$(echo "$result" | jq '.totalRequests // 0' 2>/dev/null || echo 0)

    log "  Done: avg=${avg}ms rps=${rps} err=${err}% total=${total}"

    # Save individual result file
    cat > "$outfile" <<ENDJSON
{
  "scenario": "$scenario",
  "endpoint": "$endpoint",
  "method": "$method",
  "concurrency": $concurrency,
  "duration": $DURATION,
  "warmup": $WARMUP,
  "testId": "$test_id",
  "metrics": {
    "pre": $pre_metrics,
    "mid": $mid_metrics,
    "post": $post_metrics
  },
  "result": $result
}
ENDJSON

    log "  Saved: $(basename $outfile)"
    log "  Cooling 10s..."
    sleep 10
}

# ─── MAIN ───
log "╔══════════════════════════════════════════╗"
log "║  Mule 4 Performance Benchmark - Tier 1  ║"
log "╚══════════════════════════════════════════╝"
log "Duration: ${DURATION}s | Warmup: ${WARMUP}s | Concurrency: ${CONCURRENCIES[*]}"

# Health
log "Health checks..."
curl -s --max-time 10 "$PERF_URL/api/health" 2>/dev/null | jq -c '.' >&2 || echo "FAIL" >&2
curl -s --max-time 10 "$TARGET_URL/api/echo" 2>/dev/null | jq -c '.' >&2 || echo "FAIL" >&2

# Clear previous tests
curl -s --max-time 10 -X DELETE "$PERF_URL/api/tests" >/dev/null 2>&1

# T1-A: Echo
log ""
log "════ T1-A: Echo (Baseline) ════"
for c in "${CONCURRENCIES[@]}"; do
    run_test "T1-A-Echo" "/api/echo" "GET" "$c" ""
done

# T1-B: Transform Small
log ""
log "════ T1-B: Transform Small ════"
SMALL='{"firstName":"Taro","lastName":"Yamada","age":30,"department":"Engineering"}'
for c in "${CONCURRENCIES[@]}"; do
    run_test "T1-B-TransformSmall" "/api/transform/small" "POST" "$c" "$SMALL"
done

# T1-C: Transform Heavy
log ""
log "════ T1-C: Transform Heavy ════"
HEAVY=$(python3 -c "
import json
orders = []
for i in range(100):
    orders.append({'id':i+1,'item':['Widget','Gadget','Doohickey','Gizmo','Thingamajig'][i%5],'qty':(i%10)+1,'price':((i%50)+1)*10,'region':['JP','US','EU','APAC','LATAM'][i%5]})
print(json.dumps({'orders':orders}))
")
for c in "${CONCURRENCIES[@]}"; do
    run_test "T1-C-TransformHeavy" "/api/transform/heavy" "POST" "$c" "$HEAVY"
done

# Generate summary report
log ""
log "Generating report..."
REPORT="${RESULT_DIR}/tier1-report-${TS}.md"

cat > "$REPORT" <<HEADER
# Mule 4 Performance Benchmark Report - Tier 1

**Date**: $(date '+%Y-%m-%d %H:%M')
**Environment**: CloudHub 2 (rootps, JPE1)
**mule-perf**: 1 core (load generator)
**bench-target**: 1 core (target)

## Results

| Scenario | Conc | Total | Avg ms | P50 ms | P95 ms | P99 ms | RPS | Err% | Target CPU% | Target Heap MB |
|----------|------|-------|--------|--------|--------|--------|-----|------|-------------|----------------|
HEADER

# Read all result files and build table rows
for f in "${RESULT_DIR}"/T1-*_${TS}.json; do
    [ -f "$f" ] || continue
    jq -r '
      (.scenario) as $s |
      (.concurrency) as $c |
      (.result.totalRequests // 0) as $t |
      ((.result.responseTime.avg // 0) * 100 | round / 100) as $avg |
      (.result.responseTime.p50 // 0) as $p50 |
      (.result.responseTime.p95 // 0) as $p95 |
      (.result.responseTime.p99 // 0) as $p99 |
      ((.result.throughput.rps // 0) * 10 | round / 10) as $rps |
      ((.result.errorRate // 0) * 100 | round / 100) as $err |
      (.metrics.mid.benchTarget.cpuPct // "-") as $cpu |
      (.metrics.mid.benchTarget.heapUsedMB // "-") as $heap |
      "| \($s) | \($c) | \($t) | \($avg) | \($p50) | \($p95) | \($p99) | \($rps) | \($err) | \($cpu) | \($heap) |"
    ' "$f" >> "$REPORT" 2>/dev/null
done

cat >> "$REPORT" <<'FOOTER'

## Key Comparisons

### DataWeave Processing Cost
- **T1-A vs T1-B**: Echo baseline vs simple DataWeave (string concat, upper, condition)
- **T1-B vs T1-C**: Simple vs heavy DataWeave (groupBy, reduce, orderBy, map, filter on 100 elements)

### Concurrency Scaling
- At what concurrency does RPS plateau?
- How does latency degrade under load?
- 1-core saturation point
FOOTER

log "Report: $REPORT"
log ""
log "╔══════════════════════════════════════════╗"
log "║          TIER 1 COMPLETE                 ║"
log "╚══════════════════════════════════════════╝"
