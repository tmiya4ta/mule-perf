# mule-perf

A high-performance HTTP load testing tool built on MuleSoft Mule 4, featuring a real-time dashboard with Chart.js.

All load generation runs in Java using [Zeph](https://gitlab.com/myst3m/zeph) NIO HTTP client with async `CompletableFuture` chains — zero threads per connection, lock-free metrics, O(1) percentile estimation.

![Dashboard](https://img.shields.io/badge/UI-Dark%20Theme%20Dashboard-1a1a2e)

## Features

- **Async NIO load engine** — N concurrent request chains via CompletableFuture (no thread-per-connection)
- **Real-time dashboard** — 1-second polling, response time / throughput charts, error distribution
- **Warmup support** — exclude initial requests from metrics
- **Error classification** — timeout, connection refused/reset, HTTP 4xx/5xx breakdown
- **Connection monitoring** — in-flight requests, TCP socket count
- **Histogram-based percentiles** — P50/P95/P99 computed in O(1) from 6-bucket histogram
- **Test management** — create, stop, list, clear tests via REST API
- **HTML report generation** — downloadable single-file HTML report with KPIs and charts
- **System metrics** — heap, CPU, threads, file descriptors, TCP sockstat
- **OS command execution** — debug endpoint for runtime inspection

## Architecture

```
Browser (index.html)
  |  1s polling
  v
Mule 4 API Router (api-main.xml)
  |  choice-based routing
  v
Java LoadRunner (static methods called from DataWeave)
  |  CompletableFuture chains
  v
Zeph NIO HTTP Client --> Target System
```

All state lives in Java (`LoadRunner.TestState`). No ObjectStore, no external dependencies beyond HTTP connector.

## Quick Start

### Prerequisites

- Java 17
- Maven 3.x
- Mule Runtime 4.6+ (standalone or CloudHub 2)

### Build

```bash
JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64 \
  mvn clean package -DskipTests -DattachMuleSources
```

### Run

Deploy `target/mule-perf-1.0.0-mule-application.jar` to your Mule runtime, then open:

```
http://localhost:8888/
```

### API

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/` | Dashboard UI |
| `POST` | `/api/tests` | Start a load test |
| `GET` | `/api/tests` | List all tests |
| `GET` | `/api/tests/{id}/metrics` | Get real-time metrics |
| `DELETE` | `/api/tests/{id}` | Stop a test |
| `DELETE` | `/api/tests` | Clear finished tests |
| `POST` | `/api/test-connection` | One-shot connectivity check |
| `GET` | `/api/system` | System metrics (heap, CPU, threads) |
| `POST` | `/api/exec` | Execute OS command |
| `GET` | `/api/health` | Health check |

### Start a test

```bash
curl -X POST http://localhost:8888/api/tests \
  -H "Content-Type: application/json" \
  -d '{
    "targetUrl": "http://localhost:8081/api/health",
    "method": "GET",
    "concurrency": 100,
    "duration": 30,
    "warmup": 5
  }'
```

## Project Structure

```
src/main/
  mule/
    global-config.xml              # HTTP listener/requester config
    api-main.xml                   # API router (choice-based)
    impl/
      test-management.xml          # Create/list/get/stop tests
      load-executor.xml            # Test connection flow
      metrics-collector.xml        # Metrics retrieval
      static-server.xml            # Dashboard HTML serving
  java/com/mycompany/perf/
    LoadRunner.java                # Async load engine + metrics
  resources/
    static/index.html             # Dashboard UI (single file)
    config/config-local.yaml      # Port and timeout config
```

## Metrics Response

```json
{
  "testId": "abc-123",
  "status": "running",
  "totalRequests": 15420,
  "successCount": 15300,
  "errorCount": 120,
  "responseTime": {
    "avg": 62.3, "min": 2, "max": 1450,
    "p50": 25, "p95": 150, "p99": 350
  },
  "throughput": { "rps": 1540.5 },
  "errorRate": 0.78,
  "statusCodes": { "2xx": 15300, "5xx": 120 },
  "errorDetail": { "503": 95, "timeout": 25 },
  "inFlight": 100,
  "connections": { "active": 8, "tcp": 12, "pending": 0 },
  "timeSeries": [
    { "timestamp": 1709856000000, "rps": 1520, "avgRt": 65.2, "errors": 3 }
  ],
  "histogram": [
    { "label": "0-50ms", "count": 8200 },
    { "label": "50-100ms", "count": 4100 }
  ]
}
```

## Dashboard UI

- **Stats cards** — Total requests, RPS, avg response time, error rate + error count + breakdown
- **Connections** — In-flight requests, TCP socket count
- **Percentiles sidebar** — P50, P95, P99, min/max
- **Response time chart** — Per-second average with P95/P99 reference lines
- **Throughput chart** — Requests per second over time
- **Response Distribution** tab — Status code doughnut + response time histogram
- **Errors** tab — Horizontal bar chart of error types (timeout, 503, conn_reset, etc.)
- **Test history** — List of past tests with Report button
- **Time controls** — Elapsed vs absolute time, timezone selector, chart window (30s–10m)
- **Zoom/pan** — Drag to scroll, mouse wheel to zoom on charts

## Tech Stack

| Layer | Technology |
|-------|-----------|
| Runtime | MuleSoft Mule 4.10.1 |
| Load Engine | Java 17 + Zeph 0.3.3 NIO |
| Async Model | CompletableFuture chains |
| Metrics | AtomicLong + ConcurrentHashMap (lock-free) |
| Frontend | Vanilla JS + Chart.js 4.4.7 |
| Styling | CSS custom properties, dark theme |

## License

MIT
