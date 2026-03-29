# DB Benchmark Results — CloudHub 2 (3-Round Average)

**Date**: 2026-03-29
**Platform**: CloudHub 2.0 (JPE1, rootps private space)
**Runtime**: Mule 4.10.1 / Java 17
**bench-target**: 0.1 vCore (486MB heap)
**Clouderby server**: 0.2 vCore (mule-clouderby v1.8.2)
**Load Generator**: mule-perf LoadRunner (0.1 vCore, 同一private space)
**Route**: Internal (svc.cluster.local, Ingress なし)
**Concurrency**: 10
**Duration**: 180s + 15s warmup
**Rounds**: 3 (各ラウンド前にデータリセット)
**Initial Data**: bench_users=150, bench_orders=500
**Errors**: 全シナリオ全ラウンド 0%

---

## Summary (Avg RPS)

### Oracle (6 rounds)

| Scenario | R1 | R2 | R3 | R4 | R5 | R6 | **Avg** |
|---|---|---|---|---|---|---|---|
| Page | 139.0 | 153.3 | 155.4 | 155.9 | 153.2 | 155.8 | **152.1** |
| JOIN | 147.9 | 154.4 | 156.9 | 156.2 | 156.3 | 156.2 | **154.7** |
| Bulk INSERT | 183.0 | 186.7 | 182.8 | 188.4 | 189.9 | 188.1 | **186.5** |

### Clouderby (3 rounds)

| Scenario | R1 | R2 | R3 | **Avg** |
|---|---|---|---|---|
| Page | 85.3 | 87.4 | 88.9 | **87.2** |
| JOIN | 82.2 | 84.5 | 83.7 | **83.5** |
| Bulk INSERT | 93.1 | 95.9 | 97.6 | **95.5** |

---

## Detailed Results (Round 2 — median performance)

### ページング (SELECT 20行 + OFFSET/FETCH)

| DB | RPS | Avg | P50 | P90 | P95 | P99 |
|---|---|---|---|---|---|---|
| **Oracle** | 153.3 | 65ms | 72ms | 92ms | 101ms | 164ms |
| **Clouderby** | 87.4 | 114ms | 105ms | 170ms | 187ms | 223ms |

### JOIN + GROUP BY 集計 (users × orders, 15グループ)

| DB | RPS | Avg | P50 | P90 | P95 | P99 |
|---|---|---|---|---|---|---|
| **Oracle** | 154.4 | 65ms | 74ms | 94ms | 100ms | 152ms |
| **Clouderby** | 84.5 | 118ms | 108ms | 169ms | 191ms | 248ms |

### Bulk INSERT (10行/リクエスト)

| DB | RPS | Avg | P50 | P90 | P95 | P99 |
|---|---|---|---|---|---|---|
| **Oracle** | 186.7 | 54ms | 61ms | 87ms | 95ms | 112ms |
| **Clouderby** | 95.9 | 104ms | 97ms | 147ms | 184ms | 269ms |

---

## Resource Usage (bench-target 0.1 vCore, across all scenarios)

| Round | Heap Min | Heap Avg | Heap Max | Threads |
|---|---|---|---|---|
| R1 | 115 MB | 193 MB | 269 MB | 88–109 |
| R2 | 129 MB | 211 MB | 285 MB | 88–109 |
| R3 | 143 MB | 217 MB | 301 MB | 88–109 |

Heap Max: 486 MB

---

## Environment

```
bench-target (0.1 vCore):
  UBER thread pool: corePoolSize=8, maxPoolSize=8
  DB Connector: Database 1.14.12
  Oracle Driver: ojdbc11-23.5.0.24.07
  Clouderby Driver: clouderby-jdbc-1.4.0 (JDBC-over-HTTPS)
  Oracle: Free 23ai (VPN/IPsec → socat → Docker, 192.168.11.6:11521)
  Clouderby: mule-clouderby v1.8.2 (CH2 0.2 vCore, same private space)

mule-perf (Load Generator, 0.1 vCore):
  LoadRunner: Zeph NIO async HTTP client, CompletableFuture chains

Data (reset before each round):
  bench_users: 150 rows (50 JP + 50 US + 50 EU, 6 columns)
  bench_orders: 500 rows (linked to users, 7 columns)

Network:
  Oracle: CH2 → VPN (IPsec) → socat tunnel → Docker container
  Clouderby: CH2 internal HTTPS (same private space)
```

---

## Notes

- Oracle の接続先は自宅 Docker 上の Oracle Free 23ai で、VPN + socat 経由。ネットワークレイテンシが加算されている
- Clouderby は同じ private space 内だが、JDBC-over-HTTPS プロトコルのため HTTP 往復 + JSON シリアライズのオーバーヘッドがある
- Clouderby server を 0.1→0.2 vCore に増強した結果、前回（22-59 RPS）から大幅に改善（83-95 RPS）
- 0.1 vCore は CPU ~0.11 コア。DataWeave 変換と DB I/O の両方がこのリソース内で処理される
- R1 がやや低いのはウォームアップ効果（JIT、コネクションプール初期化）
- 全シナリオ全ラウンドでエラー 0% — 安定稼働
