# DB Comparison Benchmark — Oracle (Local)

**Date**: 2026-03-28
**Platform**: Local Mule Enterprise Standalone 4.11.2
**Java**: OpenJDK 17
**Load Generator**: wrk (4 threads, 10 connections)
**Database**: Oracle Free 23ai (socat tunnel, localhost:11521)
**Duration**: 180s per scenario

---

## Summary

| Scenario | RPS | Avg Latency | P50 | P90 | P99 | Max | Errors |
|---|---|---|---|---|---|---|---|
| **Single Row SELECT** | **12,223** | 761us | 604us | 759us | 2.16ms | 181ms | 0 |
| **Pagination (20 rows)** | **6,472** | 1.25ms | 1.15ms | 1.43ms | 2.97ms | - | 0 |
| **JOIN + Aggregation** | **3,545** | 76.22ms | 1.25ms | 354ms | 567ms | 817ms | 0 |
| **Bulk INSERT (10 rows)** | **2,662** | 20.37ms | 2.23ms | 20.7ms | 540ms | 1.61s | 2 timeout |

---

## Analysis

### 1. Single Row SELECT (T3-A baseline)
- **12,223 RPS** — 最速。PKインデックスルックアップは極めて高速
- P99 = 2.16ms、ほぼ全リクエストが 1ms 以内
- これがOracleの基本性能のベースライン

### 2. Pagination (OFFSET/FETCH)
- **6,472 RPS** — Single SELECTの約53%
- 20行取得 + DataWeave JSON変換のオーバーヘッド
- P99 = 2.97ms、非常に安定した性能
- ORDER BY id + OFFSET/FETCH は Oracleが効率的に最適化

### 3. JOIN + Aggregation Report
- **3,545 RPS** — 集計クエリとしては高いスループット
- JOIN (bench_users × bench_orders) + GROUP BY + COUNT/SUM/AVG
- P50 = 1.25ms だが P90 = 354ms（スパイク発生）
- P99 = 567ms — GC一時停止やI/O待ちの影響と推測
- DataWeave側でさらに groupBy + mapObject を実行

### 4. Bulk INSERT (10 rows/request)
- **2,662 RPS** = **26,620 rows/sec** のInsert throughput
- JDBC バッチ Insert が効果的
- P50 = 2.23ms だが P99 = 540ms（redo log flush の遅延）
- 180秒で約 480万行を挿入（479,401 requests × 10 rows）
- timeout 2件のみ — Oracle のWrite性能は安定

---

## Key Findings

1. **Oracle は Read-Heavy ワークロードに強い** — Single SELECT で 12K RPS
2. **Pagination は性能劣化が小さい** — 20行でも Single の 53% を維持
3. **JOIN+集計は P90+ でスパイクが発生** — 平均は低いが高パーセンタイルは要注意
4. **Bulk INSERT は 26K rows/sec** — バッチ処理に十分な性能
5. **全シナリオでエラーはほぼゼロ** — Oracle の安定性は非常に高い

---

## Environment

```
Mule Runtime: Enterprise Standalone 4.11.2
Java: OpenJDK 17 (Xms=1024m, Xmx=1024m, MaxMetaspace=256m)
DB Connector: Database 1.14.12
Oracle Driver: ojdbc11-23.5.0.24.07
Oracle: Free 23ai (via socat tunnel, LAN)
OS: Linux 6.18.5+deb14-amd64
Wrk: 4 threads, 10 connections, 180s duration
```

## Next Steps

- Clouderby (JDBC-over-HTTP Derby) との比較ベンチマーク
- CloudHub 2 (0.1 vCore) での実行で CH2 固有のオーバーヘッドを測定
- Concurrency を 50, 100 に上げた場合の飽和テスト
