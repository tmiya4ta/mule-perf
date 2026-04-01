---
title: "MuleSoft CloudHub 2.0 パフォーマンスベンチマーク"
author: "MuleSoft Performance Testing"
---

# MuleSoft CloudHub 2.0 パフォーマンスベンチマーク

## はじめに

MuleSoft Mule 4 アプリケーションを CloudHub 2.0 (CH2) 上で実行した場合の性能特性を、複数の観点から体系的に計測した結果をまとめます。

本ベンチマークでは以下の問いに答えることを目的としています。

- Muleアプリケーションは1リクエストあたり何ミリ秒で処理できるのか
- vCoreのサイズを変えるとスループットはどう変化するのか
- 同時接続数やDBコネクションプールの最適な組み合わせは何か
- レスポンスサイズやDBデータ量がどの程度影響するのか

## テスト環境とパラメータ

Duration: 5:00

### プラットフォーム

| 項目 | 値 |
|---|---|
| Platform | CloudHub 2.0 (JPE1 リージョン, rootps Private Space) |
| Runtime | Mule 4.10.1 / Java 17 |
| Load Generator | mule-perf LoadRunner (1 vCore, 同一Private Space) |
| Route | Internal (svc.cluster.local, Ingress なし) |
| Test Duration | 180秒 + 15秒ウォームアップ |
| Error Rate | 全シナリオ **0%** |

### ロードジェネレータ

CH2環境では外部からIngress経由でリクエストを送ると、Ingressのオーバーヘッドやインターネット経由のレイテンシが計測値に混入します。そのため、**ロードジェネレータ自体もCH2にデプロイし、クラスタ内部URL（svc.cluster.local）経由でリクエストを送信**することで、純粋なMuleアプリの性能のみを計測しています。

mule-perf LoadRunner は Zeph NIO 非同期HTTPクライアントを使用した完全非同期ロードジェネレータで、CompletableFuture チェーンによりN本の同時リクエストを維持します。ベンチマーク中のLoadRunner自身のCPU使用率は **3〜9%** であり、ロードジェネレータがボトルネックになっていないことを確認しています。

### 用語説明

| 用語 | 説明 |
|---|---|
| **RPS** (Requests Per Second) | 1秒あたりに処理したリクエスト数。スループットの指標 |
| **AvgRT** (Average Response Time) | 平均レスポンスタイム（ミリ秒） |
| **P99** (99th Percentile) | 全リクエストの99%がこの時間以内に完了 |
| **vCore** | CH2 のコンピュートリソース単位。1 vCore ≒ 1 CPUコア相当。メモリは vCore に比例して自動割当 |
| **C** (Concurrency) | ロードジェネレータが同時に維持するHTTPリクエスト数 |
| **UBER Pool** | Mule 4 のスレッドプール。全フローが単一プールを共有。デフォルトではCPUコア数とメモリから自動計算 |
| **DB Pool** | JDBC コネクションプールの最大接続数（C3P0） |

### ベンチマークパラメータ

各テストで変化させたパラメータと固定値を以下に示します。

| パラメータ | テストした値 | 備考 |
|---|---|---|
| **vCore** | 0.1, 0.2, 0.5, 1.0 | bench-target のコンピュートリソース |
| **C** (Concurrency) | 10, 20, 50, 100 | 同時接続数 |
| **DB Pool** | 10, 20, 50 | Oracle JDBC コネクションプール上限 |
| **UBER Pool** | デフォルト（明示指定なし） | 全テスト共通 |
| **レスポンスサイズ** | 1KB, 10KB, 100KB, 1MB | Mule単体の転送性能 |
| **DBデータ量** | 500行, 10K行, 100K行 | bench_orders テーブル |

> [!NOTE]
> UBER Thread Pool はデフォルト設定（明示指定なし）を全テストで使用しています。デフォルトの maxPoolSize は `max(2, cores + (mem - 245760KB) / 5120)` で自動計算され、0.1 vCore で約50スレッド、1.0 vCore で約450スレッドが割り当てられます。明示指定は**デフォルトより小さい値を設定するとスレッド数を制限してしまう**ため、通常は不要です。

### テストシナリオ

| ID | シナリオ | 内容 | 種別 |
|---|---|---|---|
| T1-A | Echo | パススルー。Mule基盤のオーバーヘッドのみ | CPU |
| T1-B | TransformSmall | 小規模DataWeave変換（4フィールド加工） | CPU |
| T1-C | TransformHeavy | 重いDataWeave変換（groupBy, orderBy, filter, reduce） | CPU |
| T5-E | Oracle Page | SELECT 20行 + OFFSET/FETCH ページング | DB |
| T5-A | Oracle JOIN | JOIN + GROUP BY 集計（15グループ） | DB |
| T5-C | Oracle BulkInsert | INSERT 10行/リクエスト | DB |

### DBデータ（初期条件、各ラウンド前にリセット）

| テーブル | 行数 | 内容 |
|---|---|---|
| bench_users | 150行 | 50 JP + 50 US + 50 EU, 6カラム |
| bench_orders | 500行 | users に紐づく注文データ, 7カラム |

> [!NOTE]
> DBのデータ量は意図的に小さくし、Muleランタイムのオーバーヘッドを測定することを目的としています。データ量の影響は「5. DBデータ量の影響」で別途検証しています。


## 1. 1 vCore 最適設定での性能（3ラウンド検証）

Duration: 3:00

**パラメータ: vCore=1.0 / C=20 / UBER=default / DB pool=10**

3ラウンド実施し、安定性を検証した結果です。

| シナリオ | R1 | R2 | R3 | **Avg RPS** | AvgRT | P99 |
|---|---|---|---|---|---|---|
| **Echo** | 1,963 | 2,088 | 2,076 | **2,042** | 9.8ms | 76ms |
| **TransformSmall** | 1,830 | 1,815 | 1,817 | **1,821** | 11.0ms | 76ms |
| **TransformHeavy** | 1,281 | 1,259 | 1,264 | **1,268** | 15.8ms | 80ms |
| **Oracle Page** | 424 | 464 | 456 | **448** | 44.7ms | 89ms |
| **Oracle JOIN** | 451 | 470 | 466 | **462** | 43.3ms | 88ms |
| **Oracle BulkInsert** | 567 | 580 | 576 | **574** | 34.8ms | 83ms |

> [!NOTE]
> 3ラウンドのばらつきは **±3% 以内**で安定しています。Muleの基盤オーバーヘッド（HTTPリスナー → DataWeave → レスポンス）は Echo の AvgRT から **約10ms** と読み取れます。


## 2. vCore別スループット比較

Duration: 5:00

**パラメータ: C=10 / UBER=default / DB pool=10 / vCore=変数**

vCoreサイズを 0.1 / 0.2 / 0.5 / 1.0 と変えて同一シナリオを実行し、スケーリング特性を計測しました。

### CPU処理シナリオ

| シナリオ | 0.1 vCore | 0.2 vCore | 0.5 vCore | 1.0 vCore |
|---|---|---|---|---|
| **Echo** | 701 | 1,077 | 1,408 | 1,857 |
| **TransformSmall** | 631 | 967 | 1,250 | 1,607 |
| **TransformHeavy** | 225 | 513 | 789 | 1,118 |

### Oracle DB シナリオ

| シナリオ | 0.1 vCore | 0.2 vCore | 0.5 vCore | 1.0 vCore |
|---|---|---|---|---|
| **Page** (RPS / RT) | 132 / 76ms | 215 / 47ms | 285 / 35ms | 322 / 31ms |
| **JOIN** (RPS / RT) | 153 / 65ms | 241 / 42ms | 316 / 32ms | 387 / 26ms |
| **BulkInsert** (RPS / RT) | 190 / 53ms | 293 / 34ms | 380 / 26ms | 512 / 20ms |

```chart
{
  "type": "bar",
  "title": "vCore別スループット (RPS, C=10)",
  "labels": ["0.1 vCore", "0.2 vCore", "0.5 vCore", "1.0 vCore"],
  "datasets": [
    {"label": "Echo", "data": [701, 1077, 1408, 1857]},
    {"label": "TransformHeavy", "data": [225, 513, 789, 1118]},
    {"label": "Oracle Page", "data": [132, 215, 285, 322]},
    {"label": "Oracle BulkInsert", "data": [190, 293, 380, 512]}
  ]
}
```

> [!NOTE]
> CPU処理・DB処理ともに vCore に比例してスループットが向上しています。0.1 → 1.0 vCore で Echo は約2.6倍、TransformHeavy は約5倍、Oracle BulkInsert は約2.7倍の向上です。なお、ここでの TransformHeavy は入力データ8件での結果です。より現実的な件数での検証は「6. DataWeave処理量の影響」を参照してください。


## 3. 同時接続数の最適化

Duration: 5:00

**パラメータ: UBER=default / DB pool=10 / C=変数**

同時接続数（Concurrency）を変えた場合のスループットの変化です。

### 1.0 vCore

| シナリオ | C=10 | C=20 | C=50 | C=100 |
|---|---|---|---|---|
| **Echo** | 1,783 | 1,961 | 2,123 | **2,235** |
| **TransformHeavy** | 1,158 | 1,229 | 1,315 | **1,329** |
| **Oracle Page** | **381** | 371 | 331 | 290 |
| **Oracle BulkInsert** | **485** | 469 | 449 | 411 |

### 0.1 vCore

| シナリオ | C=10 | C=20 | C=50 | C=100 |
|---|---|---|---|---|
| **Echo** | 458 | 740 | 831 | **896** |
| **TransformHeavy** | 428 | 470 | 536 | **558** |
| **Oracle Page** | 131 | 177 | 208 | **217** |
| **Oracle BulkInsert** | 191 | 223 | 262 | **276** |

```chart
{
  "type": "bar",
  "title": "同時接続数別スループット — 1.0 vCore (RPS)",
  "labels": ["C=10", "C=20", "C=50", "C=100"],
  "datasets": [
    {"label": "Echo", "data": [1783, 1961, 2123, 2235]},
    {"label": "TransformHeavy", "data": [1158, 1229, 1315, 1329]},
    {"label": "Oracle Page", "data": [381, 371, 331, 290]},
    {"label": "Oracle BulkInsert", "data": [485, 469, 449, 411]}
  ]
}
```

> [!NOTE]
> **CPU処理（Echo, TransformHeavy）**: Concurrency を上げるほど RPS が向上します。UBER Pool のデフォルトスレッド数が十分大きいため、C=100 まで頭打ちしません。
>
> **DB処理（Oracle）**: 1.0 vCore では C=10 が最高 RPS。DB pool=10 が上限になっているためです。0.1 vCore では C を上げても緩やかに向上します（CPU がボトルネックのため）。


## 4. DBコネクションプールの影響

Duration: 5:00

**パラメータ: vCore=1.0 / UBER=default / C=変数 / DB pool=変数**

DB pool size を変えた場合のOracle性能への影響です。

### Oracle Page (RPS)

| | C=10 | C=20 | C=50 |
|---|---|---|---|
| **pool=10** | 381 | 371 | 331 |
| **pool=20** | 292 | **474** | 446 |
| **pool=50** | 67 | 172 | 232 |

### Oracle BulkInsert (RPS)

| | C=10 | C=20 | C=50 |
|---|---|---|---|
| **pool=10** | 485 | 469 | 449 |
| **pool=20** | 504 | **593** | **593** |
| **pool=50** | 86 | 246 | 271 |

> [!NOTE]
> **pool size = concurrency のとき最も高いスループット**が出ます。pool=20 / C=20 の組み合わせで BulkInsert **593 RPS** が本ベンチマーク全体の最高値です。

> [!WARNING]
> **pool size を大きくしすぎると逆効果**です。pool=50 では C=10 のとき 67 RPS まで低下しました。これは minPoolSize=2 から 50 まで接続を拡張するコストと、多数のJDBCコネクションを維持するオーバーヘッドが原因です。pool size は想定される同時接続数に合わせて設定してください。


## 5. レスポンスサイズの影響

Duration: 3:00

**パラメータ: vCore=1.0 / C=10 / UBER=default（DB未使用）**

DBを使わず、Mule単体で異なるサイズのJSONレスポンスを生成した場合のスループットです。

| レスポンスサイズ | RPS | AvgRT | P99 |
|---|---|---|---|
| **1 KB** | 1,583 | 6.3ms | 72ms |
| **10 KB** | 1,412 | 7.1ms | 72ms |
| **100 KB** | 735 | 14ms | 76ms |
| **1 MB** | 121 | 83ms | 191ms |

```chart
{
  "type": "bar",
  "title": "レスポンスサイズ別スループット (RPS)",
  "labels": ["1 KB", "10 KB", "100 KB", "1 MB"],
  "datasets": [
    {"label": "RPS", "data": [1583, 1412, 735, 121]}
  ]
}
```

> [!NOTE]
> 100KB までは高スループットを維持しますが、1MB になるとネットワーク転送とメモリコピーのコストが支配的になり **121 RPS** まで低下します。レスポンスサイズが大きい API では、ページングやフィールド選択で応答サイズを制御することが重要です。


## 6. DataWeave処理量の影響

Duration: 5:00

**パラメータ: C=10 / UBER=default / vCore=変数 / 入力データ件数=変数**

TransformHeavy シナリオの入力データ件数を 8件 / 100件 / 1000件 に変えて、DataWeave変換の処理量がスループットに与える影響を計測しました。100件は日次ダッシュボード等の集計API、1000件は月次レポート等を想定した件数です。

### vCore × 入力データ件数 マトリクス (RPS)

| 入力件数 | 0.1 vCore | 0.2 vCore | 0.5 vCore | 1.0 vCore |
|---|---|---|---|---|
| **8件** | 225 / 44ms | 505 / 20ms | 811 / 12ms | 1,146 / 9ms |
| **100件** | 152 / 66ms | 249 / 40ms | 321 / 31ms | 414 / 24ms |
| **1000件** | 19 / 525ms | 30 / 339ms | 38 / 263ms | 52 / 191ms |

```chart
{
  "type": "bar",
  "title": "DataWeave処理量 × vCore別スループット (RPS)",
  "labels": ["0.1 vCore", "0.2 vCore", "0.5 vCore", "1.0 vCore"],
  "datasets": [
    {"label": "8件", "data": [225, 505, 811, 1146]},
    {"label": "100件", "data": [152, 249, 321, 414]},
    {"label": "1000件", "data": [19, 30, 38, 52]}
  ]
}
```

### 負荷中のリソース使用（0.1 vCore）

| 入力件数 | RPS | CPU avg | Heap avg | Heap max | Heap% |
|---|---|---|---|---|---|
| **100件** | 154 | **95%** | 211 MB | 273 MB | 27-56% |
| **1000件** | 20 | **96%** | 150 MB | 290 MB | 28-60% |

> [!NOTE]
> 入力件数の増加に対してRPSはほぼ反比例して低下します。8件→100件で約3倍、100件→1000件で約8倍遅くなります。CPU使用率は95-99%で張り付いており、**純粋なCPU律速**です。メモリ（Heap）は486MB中 最大290MB（60%）で余裕があります。

> [!WARNING]
> DataWeave の groupBy, reduce, orderBy, filter を組み合わせた処理は入力件数に対して計算量が増加します。1000件の集計を0.1 vCoreで処理すると 525ms/リクエスト（19 RPS）になるため、大量データの変換が必要な場合は vCore の増強または水平スケールを検討してください。


## 7. DBデータ量の影響

Duration: 3:00

**パラメータ: vCore=1.0 / C=10 / UBER=default / DB pool=10 / bench_orders行数=変数**

bench_orders テーブルの行数を変えて、同一クエリの性能変化を計測しました。

| 行数 | Page (20行取得) RPS | Page RT | JOIN集計 RPS | JOIN RT |
|---|---|---|---|---|
| **500** | 297 | 34ms | 371 | 27ms |
| **10,000** | 313 | 32ms | 367 | 27ms |
| **100,000** | 318 | 31ms | **167** | **60ms** |

```chart
{
  "type": "bar",
  "title": "DBデータ量別スループット (RPS)",
  "labels": ["500行", "10,000行", "100,000行"],
  "datasets": [
    {"label": "Page (20行取得)", "data": [297, 313, 318]},
    {"label": "JOIN + GROUP BY集計", "data": [371, 367, 167]}
  ]
}
```

> [!NOTE]
> **Page（OFFSET/FETCH）**: PKインデックスによるアクセスのため、データ量が増えても性能はほぼ変わりません。500行 → 100,000行でも 297 → 318 RPS と安定しています。
>
> **JOIN + GROUP BY集計**: 全行を走査して集計するため、データ量に比例して遅くなります。100,000行では 371 → 167 RPS に半減しました。user_id にインデックスを追加しても GROUP BY の全行走査は避けられないため、効果はありませんでした。

> [!WARNING]
> 集計クエリの性能はデータ量に強く依存します。大量データの集計が必要な場合は、マテリアライズドビューや事前集計テーブルの活用を検討してください。


## 8. スケールアウト効果（0.1 vCore × 5 replicas）

Duration: 3:00

**パラメータ: vCore=0.1 / replicas=1 vs 5 / C=50 / UBER=default**

0.1 vCore 1台と 0.1 vCore 5台（合計0.5 vCore相当）の比較です。

| シナリオ | 1 replica | 5 replicas | 倍率 |
|---|---|---|---|
| Echo | 745 RPS | **2,775 RPS** | 3.7x |
| TransformSmall | 657 RPS | **2,453 RPS** | 3.7x |
| TransformHeavy | 180 RPS | **749 RPS** | 4.2x |

一方、0.5 vCore 1台の結果は：

| シナリオ | 0.5vCore × 1 | 0.1vCore × 5 | 効率比 |
|---|---|---|---|
| Echo | 836 RPS | **2,775 RPS** | 3.3x |
| TransformSmall | 742 RPS | **2,453 RPS** | 3.3x |
| TransformHeavy | 167 RPS | **749 RPS** | 4.5x |

> [!NOTE]
> **0.1 vCore × 5台は 0.5 vCore × 1台の 3.3〜4.5倍** のスループットを達成。CH2のロードバランサーが均等に分散するため、ほぼリニアにスケールします。コスト同等（0.5 vCore分）でスループットが大幅に向上するため、水平スケールが推奨されます。


## まとめと推奨事項

Duration: 3:00

### 性能の目安（1 vCore, C=20, uber=default, 3ラウンド平均）

| ワークロード | RPS | レスポンスタイム |
|---|---|---|
| パススルー（Echo） | **2,042** | 10ms |
| 軽量DW変換 | **1,821** | 11ms |
| 重いDW変換（集計・ソート・フィルタ） | **1,268** | 16ms |
| DB SELECT + ページング | **448** | 45ms |
| DB JOIN + 集計 | **462** | 43ms |
| DB Bulk INSERT (10行) | **574** | 35ms |

### 推奨事項

**vCore サイジング**

- CPU処理・DB処理ともに vCore に比例してスループットが向上
- ただし **0.1 vCore × 複数台** の水平スケールの方が同コストで3〜4倍のスループットを達成可能
- まず **0.1 vCore** で開始し、CPU使用率を見ながらスケールアウトが最もコスト効率が良い

**UBER Thread Pool**

- デフォルト設定（明示指定なし）が推奨
- 明示指定する場合、**設定値がデフォルトより小さいとスレッド数を制限してしまう**ため注意

**同時接続数（Concurrency）**

- CPU bound ワークロード → Concurrency を上げるほど RPS が向上
- I/O bound ワークロード（DB） → **C = DB pool size** を目安に設定

**DBコネクションプール**

- **pool size = 想定同時接続数** が最適。過大なプールは逆効果
- DBの応答時間はネットワークレイテンシに大きく依存
- CH2とDBは **同一リージョン** に配置することが最重要

**レスポンスサイズ**

- 100KB以下であればスループットへの影響は小さい
- 1MB超のレスポンスは大幅にRPSが低下するため、ページングで制御する


## APPENDIX A: DB接続先による性能差

Duration: 3:00

**パラメータ: vCore=1.0 / C=20 / UBER=default / DB pool=10**

同一のMuleフロー・同一のSQLで、接続先DBだけを変えた比較です。

| DB | 接続方式 | ネットワーク |
|---|---|---|
| Oracle Free 23ai | JDBC (ojdbc11) | CH2 → IPsec VPN → Docker (RTT ~5ms) |
| Oracle SE Cloud | JDBC (ojdbc11) | CH2 JPE1 → US Cloud (RTT ~200ms) |

| シナリオ | Oracle (RTT 5ms) | Oracle SE Cloud (RTT 200ms) |
|---|---|---|
| **Page** | **377** RPS / 53ms | 29 RPS / 682ms |
| **JOIN** | **456** RPS / 44ms | 45 RPS / 446ms |
| **BulkInsert** | **559** RPS / 36ms | 66 RPS / 301ms |

> [!WARNING]
> **DBの性能はネットワークレイテンシに大きく依存します。** 同じOracle SEでも、接続先の地理的距離によって10倍以上の差が出ます。CH2のリージョンとDB設置場所は同一リージョンにすることが重要です。


## APPENDIX B: ベンチマーク用Muleフロー

Duration: 5:00

ベンチマーク対象アプリ（bench-target）は、単一の Mule アプリケーション内に全テストシナリオのエンドポイントを実装しています。HTTP Listener で受けた全リクエストを choice ルーターでパス別に振り分ける構成です。

| ファイル | 役割 |
|---|---|
| global-config.xml | グローバル設定（UBER Pool、DB接続、プロパティ） |
| bench-target.xml | 全エンドポイントのフロー定義 |

### global-config.xml

UBER Thread Pool はデフォルト（タグなし）、Oracle JDBC コネクションプールは maxPoolSize=10 を基本設定としています。`mule.env` プロパティで環境別の config YAML を切り替えます。

```xml
<?xml version="1.0" encoding="UTF-8"?>
<mule xmlns="http://www.mulesoft.org/schema/mule/core"
      xmlns:ee="http://www.mulesoft.org/schema/mule/ee/core"
      xmlns:http="http://www.mulesoft.org/schema/mule/http"
      xmlns:db="http://www.mulesoft.org/schema/mule/db"
      xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
      xsi:schemaLocation="
        http://www.mulesoft.org/schema/mule/core http://www.mulesoft.org/schema/mule/core/current/mule.xsd
        http://www.mulesoft.org/schema/mule/ee/core http://www.mulesoft.org/schema/mule/ee/core/current/mule-ee.xsd
        http://www.mulesoft.org/schema/mule/http http://www.mulesoft.org/schema/mule/http/current/mule-http.xsd
        http://www.mulesoft.org/schema/mule/db http://www.mulesoft.org/schema/mule/db/current/mule-db.xsd">

    <global-property name="mule.env" value="local"/>
    <configuration-properties file="config/config-${mule.env}.yaml"/>

    <!-- UBER Thread Pool: デフォルト（明示指定なし）推奨 -->

    <db:config name="oracle-config">
        <db:oracle-connection host="${oracle.host}" port="${oracle.port}"
                             user="${oracle.user}" password="${oracle.password}"
                             serviceName="${oracle.serviceId}">
            <db:pooling-profile maxPoolSize="10" minPoolSize="2"
                                acquireIncrement="2"
                                maxWait="60" maxWaitUnit="SECONDS"/>
        </db:oracle-connection>
    </db:config>
</mule>
```

### T1-A: Echo

Muleの最小オーバーヘッドを測定するパススルーエンドポイント。HTTPリスナー → DataWeave（タイムスタンプ生成のみ）→ レスポンスの最短パスです。このシナリオのレスポンスタイムがMule基盤自体のオーバーヘッド（約10ms）を示します。

```xml
<when expression="#[vars.method == 'GET' and vars.path == '/api/echo']">
    <ee:transform>
        <ee:message>
            <ee:set-payload><![CDATA[%dw 2.0
output application/json
---
{ok: true, ts: now() as Number {unit: "milliseconds"}}]]></ee:set-payload>
        </ee:message>
    </ee:transform>
</when>
```

### T1-B: TransformSmall

POSTリクエストのJSONボディを受け取り、4フィールドの軽量な変換を行います。文字列連結、型変換、大文字変換、日時フォーマットなど、典型的なAPIレスポンス加工を想定したシナリオです。

```xml
<when expression="#[vars.method == 'POST' and vars.path == '/api/transform/small']">
    <ee:transform>
        <ee:message>
            <ee:set-payload><![CDATA[%dw 2.0
output application/json
---
{
  fullName: payload.lastName ++ " " ++ payload.firstName,
  isAdult: (payload.age default 0) >= 18,
  dept: upper(payload.department default ""),
  processedAt: now() as String {format: "yyyy-MM-dd'T'HH:mm:ss'Z'"}
}]]></ee:set-payload>
        </ee:message>
    </ee:transform>
</when>
```

### T1-C: TransformHeavy

注文データに対して、groupBy（リージョン別・商品別集計）、reduce（合計算出）、orderBy（ソート）、filter（大口注文抽出）を組み合わせたDataWeave変換です。vCore別比較では8件の入力データで基本性能を測定し、「6. DataWeave処理量の影響」では100件・1000件に拡大して、入力データ件数がスループットに与える影響を検証しています。

```xml
<when expression="#[vars.method == 'POST' and vars.path == '/api/transform/heavy']">
    <ee:transform>
        <ee:message>
            <ee:set-payload><![CDATA[%dw 2.0
output application/json
var orders = payload.orders default []
var totalAmount = orders reduce ((o, acc = 0) -> acc + (o.qty * o.price))
var byRegion = orders groupBy $.region mapObject ((items, region) ->
    (region): items reduce ((o, acc = 0) -> acc + (o.qty * o.price))
)
var itemTotals = orders groupBy $.item mapObject ((items, item) ->
    (item): items reduce ((o, acc = 0) -> acc + (o.qty * o.price))
)
var topItems = itemTotals pluck ((v, k) -> {item: k as String, total: v})
    orderBy -$.total
---
{
  summary: {
    totalAmount: totalAmount,
    orderCount: sizeOf(orders),
    avgPrice: if (sizeOf(orders) > 0) totalAmount / sizeOf(orders) else 0,
    byRegion: byRegion,
    topItems: topItems[0 to 4]
  },
  normalized: orders map ((o) -> {
    orderId: o.id, product: upper(o.item default ""),
    quantity: o.qty, unitPrice: o.price,
    lineTotal: o.qty * o.price, region: o.region,
    isLargeOrder: (o.qty * o.price) > 500
  }) filter $.isLargeOrder
}]]></ee:set-payload>
        </ee:message>
    </ee:transform>
</when>
```

### T5-E: Oracle Pagination

OFFSET/FETCH による標準的なページング SELECT です。PKインデックスで ORDER BY した上で、指定ページの20行を取得します。データ量が増えてもPKインデックスにより性能が安定するパターンを確認できます。

```xml
<when expression="#[vars.method == 'GET' and vars.path == '/api/oracle/page']">
    <set-variable variableName="page"
        value="#[(attributes.queryParams.page default '1') as Number]"/>
    <set-variable variableName="pageSize"
        value="#[(attributes.queryParams['size'] default '20') as Number]"/>
    <db:select config-ref="oracle-config">
        <db:sql>SELECT id, name, email, region, department, salary
            FROM bench_users ORDER BY id
            OFFSET :offset ROWS FETCH NEXT :pageSize ROWS ONLY</db:sql>
        <db:input-parameters>#[{
            offset: (vars.page - 1) * vars.pageSize,
            pageSize: vars.pageSize
        }]</db:input-parameters>
    </db:select>
    <ee:transform>
        <ee:message>
            <ee:set-payload><![CDATA[%dw 2.0
output application/json
---
{page: vars.page, pageSize: vars.pageSize,
 count: sizeOf(payload), users: payload}]]></ee:set-payload>
        </ee:message>
    </ee:transform>
</when>
```

### T5-A: Oracle JOIN + Aggregation

bench_users と bench_orders を INNER JOIN し、リージョン×部門でGROUP BYした集計レポートです。COUNT, SUM, AVG, 条件付きCOUNT（CASE WHEN）を含みます。DB側で集計した結果をさらにDataWeaveでリージョン別に再構造化するため、DB処理とCPU処理の両方の負荷がかかります。データ量が増えるとGROUP BYの全行走査コストに比例して遅くなります。

```xml
<when expression="#[vars.method == 'GET' and vars.path == '/api/oracle/join-report']">
    <db:select config-ref="oracle-config">
        <db:sql><![CDATA[SELECT u.region, u.department,
            COUNT(o.id) AS order_count,
            SUM(o.qty * o.unit_price) AS total_amount,
            AVG(o.qty * o.unit_price) AS avg_amount,
            COUNT(CASE WHEN o.status = 'delivered' THEN 1 END) AS delivered_count,
            COUNT(CASE WHEN o.status = 'cancelled' THEN 1 END) AS cancelled_count
        FROM bench_users u
        INNER JOIN bench_orders o ON u.id = o.user_id
        GROUP BY u.region, u.department
        ORDER BY total_amount DESC]]></db:sql>
    </db:select>
    <ee:transform>
        <ee:message>
            <ee:set-payload><![CDATA[%dw 2.0
output application/json
var rows = payload
var byRegion = rows groupBy $.REGION
---
{
  totalGroups: sizeOf(rows),
  grandTotal: rows reduce ((r, acc=0) -> acc + (r.TOTAL_AMOUNT default 0)),
  byRegion: byRegion mapObject ((items, region) -> (region): {
    departments: sizeOf(items),
    totalAmount: items reduce ((r, acc=0) -> acc + (r.TOTAL_AMOUNT default 0)),
    totalOrders: items reduce ((r, acc=0) -> acc + (r.ORDER_COUNT default 0))
  }),
  details: rows
}]]></ee:set-payload>
        </ee:message>
    </ee:transform>
</when>
```

### T5-C: Oracle Bulk Insert

DataWeaveで10件の注文レコードを生成し、db:bulk-insert で一括INSERTします。JDBCバッチ処理の性能を測定するシナリオです。1リクエストで10行をINSERTするため、RPS × 10 が実際の行挿入レートになります（例: 574 RPS = 5,740 rows/sec）。

```xml
<when expression="#[vars.method == 'POST' and vars.path == '/api/oracle/bulk-insert']">
    <set-variable variableName="insertCount"
        value="#[(attributes.queryParams['count'] default '10') as Number]"/>
    <ee:transform>
        <ee:message>
            <ee:set-payload><![CDATA[%dw 2.0
output application/java
var count = vars.insertCount
var items = ["Widget", "Gadget", "Gizmo", "Doohickey", "Thingamajig"]
var statuses = ["pending", "shipped", "delivered", "cancelled"]
---
(1 to count) map ((i) -> {
    user_id: ((i - 1) mod 150) + 1,
    item: items[(i - 1) mod 5],
    qty: ((i * 3) mod 20) + 1,
    unit_price: (100 + ((i * 13) mod 9900)) / 100,
    status: statuses[(i - 1) mod 4]
})]]></ee:set-payload>
        </ee:message>
    </ee:transform>
    <set-variable variableName="recordCount" value="#[sizeOf(payload)]"/>
    <db:bulk-insert config-ref="oracle-config">
        <db:sql>INSERT INTO bench_orders (user_id, item, qty, unit_price, status)
            VALUES (:user_id, :item, :qty, :unit_price, :status)</db:sql>
    </db:bulk-insert>
    <ee:transform>
        <ee:message>
            <ee:set-payload><![CDATA[%dw 2.0
output application/json
---
{ok: true, inserted: vars.recordCount}]]></ee:set-payload>
        </ee:message>
    </ee:transform>
</when>
```
