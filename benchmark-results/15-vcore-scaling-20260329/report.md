# vCore Scaling Benchmark — CloudHub 2

**Date**: 2026-03-29
**Platform**: CloudHub 2.0 (JPE1, rootps private space)
**Runtime**: Mule 4.10.1 / Java 17
**Load Generator**: mule-perf LoadRunner (0.5 vCore)
**Clouderby Server**: 0.5 vCore (mule-clouderby v1.8.2)
**Route**: Internal (svc.cluster.local)
**Concurrency**: 10
**Duration**: 180s + 15s warmup
**Rounds**: 3 per vCore size (reset before each round)
**Initial Data**: bench_users=150, bench_orders=500
**Errors**: 全シナリオ全ラウンド 0%

---

## Oracle (VPN経由, Oracle Free 23ai)

| Scenario | vCore | R1 | R2 | R3 | **Avg RPS** | AvgRT | P99 | CPU avg | CPU max |
|---|---|---|---|---|---|---|---|---|---|
| Page (20行) | 0.1 | 139 | 153 | 155 | **149** | 67ms | 172ms | - | - |
| | 0.2 | 150 | 238 | 246 | **211** | 50ms | 129ms | 85% | 100% |
| | 0.5 | 202 | 278 | 280 | **253** | 40ms | 114ms | 85% | 100% |
| JOIN集計 | 0.1 | 148 | 154 | 157 | **153** | 65ms | 161ms | - | - |
| | 0.2 | 237 | 242 | 246 | **241** | 41ms | 92ms | 84% | 100% |
| | 0.5 | 282 | 288 | 278 | **283** | 35ms | 80ms | 84% | 100% |
| Bulk INSERT (10行) | 0.1 | 183 | 187 | 183 | **184** | 54ms | 119ms | - | - |
| | 0.2 | 291 | 307 | 312 | **303** | 33ms | 87ms | 84% | 100% |
| | 0.5 | 347 | 339 | 333 | **340** | 30ms | 76ms | 83% | 99% |

## Clouderby (JDBC-over-HTTPS, same private space)

| Scenario | vCore | R1 | R2 | R3 | **Avg RPS** | AvgRT | P99 | CPU avg | CPU max |
|---|---|---|---|---|---|---|---|---|---|
| Page (20行) | 0.1 | 85 | 87 | 89 | **87** | 115ms | 248ms | - | - |
| | 0.2 | 72 | 133 | 134 | **113** | 97ms | 249ms | 71% | 94% |
| | 0.5 | 123 | 134 | 137 | **131** | 76ms | 156ms | 75% | 98% |
| JOIN集計 | 0.1 | 82 | 85 | 84 | **84** | 120ms | 265ms | - | - |
| | 0.2 | 100 | 106 | 106 | **104** | 96ms | 183ms | 64% | 91% |
| | 0.5 | 107 | 106 | 104 | **106** | 95ms | 176ms | 58% | 78% |
| Bulk INSERT (10行) | 0.1 | 93 | 96 | 98 | **96** | 105ms | 264ms | - | - |
| | 0.2 | 108 | 114 | 112 | **111** | 90ms | 194ms | 54% | 67% |
| | 0.5 | 106 | 109 | 111 | **108** | 92ms | 173ms | 48% | 67% |

---

## スケーリング効率 (RPS/vCore)

| Scenario | 0.1 vCore | 0.2 vCore | 0.5 vCore | ボトルネック |
|---|---|---|---|---|
| Oracle Page | 1,492 | 1,057 | 506 | VPNレイテンシ |
| Oracle JOIN | 1,531 | 1,208 | 566 | VPNレイテンシ |
| Oracle Bulk INSERT | 1,842 | 1,516 | 679 | VPNレイテンシ |
| Clouderby Page | 872 | 565 | 263 | JDBC-over-HTTPS I/O |
| Clouderby JOIN | 835 | 520 | 211 | JDBC-over-HTTPS I/O |
| Clouderby Bulk INSERT | 955 | 556 | 216 | JDBC-over-HTTPS I/O |

**RPS/vCore は 0.1 が最も効率的。** vCoreを増やしてもI/O待ちが支配的になり、CPU追加分が活かせない。

---

## 分析

### Oracle
- 0.1→0.2: **1.4-1.6x** 向上（CPU 85-100% で律速だったのが解放）
- 0.2→0.5: **1.1-1.2x** 微増（VPN RTT ~5ms がボトルネック化、CPUは84-85%で飽和せず）
- C=10 では 0.5 vCore の CPU を使い切れていない

### Clouderby
- 0.1→0.2: **1.2-1.3x** 向上
- 0.2→0.5: **ほぼ横ばい**（JOIN/BulkInsert は 0.2 と同等）
- CPU 48-75% — CPUではなく JDBC-over-HTTPS の HTTP往復がボトルネック
- Concurrency を上げればさらに伸びる可能性あり

### コスト効率
- **0.1 vCore が RPS/vCore 最高効率**
- I/O bound なワークロードでは vCore を上げるより **レプリカを増やす** 方が効果的
- CPU bound なワークロード（DW変換等）では vCore 増強が有効

---

## Environment

```
bench-target:
  0.1 vCore: Heap Max 486 MB
  0.2 vCore: Heap Max 972 MB
  0.5 vCore: Heap Max 1265 MB
  UBER thread pool: corePoolSize=8, maxPoolSize=8
  DB Connector: Database 1.14.12
  Oracle: Free 23ai via VPN/IPsec + socat (RTT ~5ms)
  Clouderby: mule-clouderby v1.8.2 (0.5 vCore, JDBC-over-HTTPS)

mule-perf (Load Generator): 0.5 vCore
```
