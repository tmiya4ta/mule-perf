#!/bin/bash
# 3-round DB benchmark with reset between rounds
# Usage: ./run-db-benchmark-3rounds.sh <perf-url> <target-url> [internal-target-url]
set -euo pipefail

PERF_URL="${1:?Usage: $0 <perf-url> <target-url> [internal-target-url]}"
TARGET_URL="${2:?Usage: $0 <perf-url> <target-url> [internal-target-url]}"
INTERNAL_TARGET="${3:-$TARGET_URL}"

ROUNDS=3
BASE_DIR="benchmark-results/14-db-comparison-$(date +%Y%m%d)"

log() { echo "[$(date +%H:%M:%S)] $*"; }

# Initial conditions
log "═══ 3-Round Benchmark ═══"
log "Initial conditions: bench_users=150, bench_orders=500"
log "Reset between each round to restore initial state"
echo ""

for round in $(seq 1 $ROUNDS); do
    log "═══════════════════════════════════════════════"
    log "  ROUND $round / $ROUNDS"
    log "═══════════════════════════════════════════════"

    # Reset data
    log "Resetting benchmark data..."
    reset_result=$(curl -sf --max-time 120 "$TARGET_URL/api/benchmark/reset" 2>/dev/null || echo '{"error":"reset failed"}')
    log "Reset: $(echo "$reset_result" | jq -c .)"

    # Verify initial state
    oracle_join=$(curl -sf --max-time 15 "$TARGET_URL/api/oracle/join-report" 2>/dev/null | jq -r '.grandTotal // "FAIL"')
    clouderby_join=$(curl -sf --max-time 15 "$TARGET_URL/api/clouderby/join-report" 2>/dev/null | jq -r '.grandTotal // "FAIL"')
    log "Verify: Oracle grandTotal=$oracle_join  Clouderby grandTotal=$clouderby_join"

    if [ "$oracle_join" = "FAIL" ] || [ "$clouderby_join" = "FAIL" ]; then
        log "ERROR: Data verification failed, aborting round $round"
        continue
    fi

    # Run benchmark (override RESULT_DIR for each round)
    export RESULT_DIR="${BASE_DIR}/round${round}"
    mkdir -p "$RESULT_DIR"

    DURATION="${DURATION:-180}" CONCURRENCY="${CONCURRENCY:-10}" METRICS_INTERVAL="${METRICS_INTERVAL:-5}" \
        ./run-db-benchmark.sh "$PERF_URL" "$TARGET_URL" "$INTERNAL_TARGET" 2>&1

    log "Round $round complete: $RESULT_DIR/"
    echo ""
done

# ── Cross-round summary ──
log "═══════════════════════════════════════════════"
log "  3-ROUND SUMMARY"
log "═══════════════════════════════════════════════"
echo ""
printf "%-35s  %8s %8s %8s  %8s\n" "Scenario" "R1 RPS" "R2 RPS" "R3 RPS" "Avg RPS"
printf "%-35s  %8s %8s %8s  %8s\n" "---" "---" "---" "---" "---"

for scenario in T5-E-Oracle-Page T5-F-Clouderby-Page T5-A-Oracle-JoinReport T5-B-Clouderby-JoinReport T5-C-Oracle-BulkInsert T5-D-Clouderby-BulkInsert; do
    rps_sum=0
    rps_vals=""
    for round in 1 2 3; do
        f=$(ls "${BASE_DIR}/round${round}/${scenario}"_*.json 2>/dev/null | head -1)
        if [ -n "$f" ] && [ -f "$f" ]; then
            rps=$(jq -r '.result.throughput.rps // 0' "$f")
            rps_fmt=$(printf "%8.1f" "$rps")
            rps_sum=$(echo "$rps_sum + $rps" | bc)
        else
            rps_fmt="     N/A"
            rps=0
        fi
        rps_vals="$rps_vals $rps_fmt"
    done
    avg=$(echo "scale=1; $rps_sum / 3" | bc)
    printf "%-35s %s  %8s\n" "$scenario" "$rps_vals" "$avg"
done
echo ""
log "All results in: $BASE_DIR/"
