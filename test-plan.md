# Mule 4 Performance Benchmark Test Plan

## 環境

| 項目 | 値 |
|------|-----|
| mule-perf (負荷ツール) | T1 Production, ch2:rootps, **1 core** |
| bench-target (対象アプリ) | A1 Production, ch2:rootps, **1 core** |
| Oracle DB | cloud-services.demos.mulesoft.com:32627, muledb |
| 通信経路 | svc.cluster.local:8081 (k8s内部, Ingress経由なし) |

## テストシナリオ

### Tier 1: Pure Mule（外部I/Oなし）

#### T1-A: Echo (ベースライン)
- **Endpoint**: `GET /api/echo`
- **処理**: HTTP Listener → 固定JSON返却
- **Response**: `{"ok":true,"ts":1710000000000}`
- **目的**: Muleランタイムの最低オーバーヘッド測定

#### T1-B: Transform Small
- **Endpoint**: `POST /api/transform/small`
- **Request Body**:
  ```json
  {"firstName":"Taro","lastName":"Yamada","age":30,"department":"Engineering"}
  ```
- **処理**: DataWeave で文字列結合、条件判定、upper、now()
- **Response**:
  ```json
  {"fullName":"Yamada Taro","isAdult":true,"dept":"ENGINEERING","processedAt":"2026-03-11T12:00:00Z"}
  ```
- **比較**: T1-A との差 = DataWeave基本処理コスト

#### T1-C: Transform Heavy
- **Endpoint**: `POST /api/transform/heavy`
- **Request Body**: 100要素の注文配列
  ```json
  {"orders":[{"id":1,"item":"A","qty":3,"price":100,"region":"JP"},... x100]}
  ```
- **処理**: map, filter, groupBy, reduce, orderBy
- **Response**: 集計サマリー + 正規化配列
- **比較**: T1-B との差 = DataWeave重い処理のスケーリングコスト

### Tier 2: DB I/O (Oracle)

#### T2-A: DB Select Single
- **Endpoint**: `GET /api/db/user/{id}`
- **処理**: `SELECT * FROM perf_users WHERE id = :id`
- **Response**: 1ユーザーレコード
- **比較**: T1-A との差 = DB往復コスト

#### T2-B: DB Select + Transform
- **Endpoint**: `GET /api/db/users?region=JP`
- **処理**: `SELECT * FROM perf_users WHERE region = :region` (50件) → DataWeave集計
- **Response**: カウント + サマリー + ユーザーリスト
- **比較**: T2-A との差 = 複数行 + 変換コスト、T1-C との差 = 同等変換でのDB overhead

#### T2-C: DB Write
- **Endpoint**: `POST /api/db/order`
- **Request Body**: `{"item":"Widget","qty":5,"price":200}`
- **処理**: INSERT → SELECT (generated id)
- **Response**: 作成されたレコード
- **比較**: T2-A との差 = WRITE コスト

## DB スキーマ (初期化 endpoint で作成)

```sql
-- GET /api/db/setup で自動作成
CREATE TABLE perf_users (
  id NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  name VARCHAR2(100),
  email VARCHAR2(200),
  region VARCHAR2(10),
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE perf_orders (
  id NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  item VARCHAR2(100),
  qty NUMBER,
  price NUMBER,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- 初期データ: 各region 50件ずつ (JP, US, EU) = 150件
```

## 測定パラメータ

各シナリオで以下の concurrency を段階的に実行:

| Step | Concurrency | Duration | Warmup |
|------|-------------|----------|--------|
| 1    | 1           | 60s      | 10s    |
| 2    | 5           | 60s      | 10s    |
| 3    | 10          | 60s      | 10s    |
| 4    | 50          | 60s      | 10s    |
| 5    | 100         | 60s      | 10s    |

## 実行順序

1. bench-target を A1 Production にデプロイ (1 core)
2. mule-perf を T1 Production にデプロイ (1 core)
3. `GET /api/db/setup` でテーブル作成 + 初期データ投入
4. Tier 1 テスト実行 (T1-A → T1-B → T1-C)
5. Tier 2 テスト実行 (T2-A → T2-B → T2-C)
6. 結果収集・比較

## 期待される結果マトリクス

```
Scenario          | Avg Latency | P95    | P99    | RPS   | CPU%
T1-A Echo         | ~2-5ms      | ~10ms  | ~20ms  | 高    | 低
T1-B Transform S  | ~5-10ms     | ~15ms  | ~30ms  | 中    | 中
T1-C Transform H  | ~15-30ms    | ~50ms  | ~80ms  | 低    | 高
T2-A DB Select 1  | ~10-20ms    | ~30ms  | ~50ms  | 中    | 低(I/O待)
T2-B DB Select+T  | ~20-40ms    | ~60ms  | ~100ms | 低    | 中
T2-C DB Write     | ~15-30ms    | ~40ms  | ~70ms  | 中    | 低(I/O待)
```
