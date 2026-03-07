package com.mycompany.perf;

import zeph.client.HttpClientNio;
import zeph.client.HttpClientRequest;
import zeph.client.HttpClientResponse;

import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;

/**
 * High-performance load runner using Zeph NIO HTTP client.
 * Zero-allocation hot loop: all metrics via atomic counters + histogram.
 * No per-request sample storage, no sorting.
 */
public class LoadRunner {

    private static final ConcurrentHashMap<String, TestState> tests = new ConcurrentHashMap<>();
    private static volatile HttpClientNio sharedClient;

    private static HttpClientNio getClient() throws Exception {
        if (sharedClient == null) {
            synchronized (LoadRunner.class) {
                if (sharedClient == null) {
                    sharedClient = new HttpClientNio();
                }
            }
        }
        return sharedClient;
    }

    // ── Test State ──────────────────────────────────────────────

    static class TestState {
        final String id;
        final String url;
        final String method;
        final int concurrency;
        final int durationSec;
        final long startTime;
        final AtomicBoolean running = new AtomicBoolean(true);
        volatile String status = "running";
        volatile long lastSampleTime = 0;

        // Metrics (lock-free)
        final AtomicLong total = new AtomicLong();
        final AtomicLong success = new AtomicLong();
        final AtomicLong errors = new AtomicLong();
        final AtomicLong totalRt = new AtomicLong();
        final AtomicLong minRt = new AtomicLong(999999);
        final AtomicLong maxRt = new AtomicLong(0);

        // Status code groups
        final AtomicLong s2xx = new AtomicLong();
        final AtomicLong s3xx = new AtomicLong();
        final AtomicLong s4xx = new AtomicLong();
        final AtomicLong s5xx = new AtomicLong();
        final AtomicLong sErr = new AtomicLong();

        // Histogram buckets: 0-50, 50-100, 100-200, 200-500, 500-1000, 1000+
        final AtomicLong hist0_50 = new AtomicLong();
        final AtomicLong hist50_100 = new AtomicLong();
        final AtomicLong hist100_200 = new AtomicLong();
        final AtomicLong hist200_500 = new AtomicLong();
        final AtomicLong hist500_1s = new AtomicLong();
        final AtomicLong hist1s = new AtomicLong();

        // Per-second time series: ConcurrentHashMap<secondBucket, long[4]={count, rtSum, errCount, dummy}>
        final ConcurrentHashMap<Long, long[]> timeSeries = new ConcurrentHashMap<>();

        TestState(String id, String url, String method, int concurrency, int durationSec) {
            this.id = id;
            this.url = url;
            this.method = method;
            this.concurrency = concurrency;
            this.durationSec = durationSec;
            this.startTime = System.currentTimeMillis();
        }

        void record(int statusCode, long elapsedMs, boolean error) {
            total.incrementAndGet();
            totalRt.addAndGet(elapsedMs);
            if (error) errors.incrementAndGet();
            else success.incrementAndGet();

            // Update min/max atomically
            long curMin;
            do { curMin = minRt.get(); } while (elapsedMs < curMin && !minRt.compareAndSet(curMin, elapsedMs));
            long curMax;
            do { curMax = maxRt.get(); } while (elapsedMs > curMax && !maxRt.compareAndSet(curMax, elapsedMs));

            // Status code group
            if (statusCode == 0) sErr.incrementAndGet();
            else if (statusCode < 300) s2xx.incrementAndGet();
            else if (statusCode < 400) s3xx.incrementAndGet();
            else if (statusCode < 500) s4xx.incrementAndGet();
            else s5xx.incrementAndGet();

            // Histogram
            if (elapsedMs < 50) hist0_50.incrementAndGet();
            else if (elapsedMs < 100) hist50_100.incrementAndGet();
            else if (elapsedMs < 200) hist100_200.incrementAndGet();
            else if (elapsedMs < 500) hist200_500.incrementAndGet();
            else if (elapsedMs < 1000) hist500_1s.incrementAndGet();
            else hist1s.incrementAndGet();

            // Per-second time series bucket
            long now = System.currentTimeMillis();
            lastSampleTime = now;
            long bucket = now - (now % 1000);
            long[] ts = timeSeries.computeIfAbsent(bucket, k -> new long[3]);
            synchronized (ts) {
                ts[0]++; // count
                ts[1] += elapsedMs; // rtSum
                if (error) ts[2]++; // errCount
            }
        }

        void markFinished(String newStatus) {
            status = newStatus;
        }
    }

    // ── Public API (called from DataWeave) ──────────────────────

    public static String start(String url, String method, int concurrency, int durationSec) {
        String testId = UUID.randomUUID().toString();
        TestState state = new TestState(testId, url, method.toUpperCase(), concurrency, durationSec);
        tests.put(testId, state);

        long endTime = state.startTime + (long) durationSec * 1000;

        List<Thread> workers = new ArrayList<>();
        for (int i = 0; i < concurrency; i++) {
            Thread t = new Thread(() -> runWorker(state, endTime), "perf-" + testId.substring(0, 8) + "-" + i);
            t.setDaemon(true);
            t.start();
            workers.add(t);
        }

        Thread monitor = new Thread(() -> {
            for (Thread w : workers) {
                try { w.join(); } catch (InterruptedException ignored) {}
            }
            if (state.running.get()) {
                state.running.set(false);
                state.markFinished("completed");
            }
        }, "perf-mon-" + testId.substring(0, 8));
        monitor.setDaemon(true);
        monitor.start();

        return testId;
    }

    public static Map<String, Object> status(String testId) {
        TestState s = tests.get(testId);
        if (s == null) return null;
        return buildMetrics(s);
    }

    public static Map<String, Object> stop(String testId) {
        TestState s = tests.get(testId);
        if (s == null) return Map.of("stopped", false, "testId", testId);
        s.running.set(false);
        s.markFinished("stopped");
        return Map.of("stopped", true, "testId", testId);
    }

    public static List<Map<String, Object>> list() {
        List<Map<String, Object>> result = new ArrayList<>();
        for (TestState s : tests.values()) {
            Map<String, Object> m = new LinkedHashMap<>();
            m.put("id", s.id);
            m.put("status", s.status);
            m.put("targetUrl", s.url);
            m.put("method", s.method);
            m.put("concurrency", s.concurrency);
            m.put("totalRequests", s.total.get());
            result.add(m);
        }
        return result;
    }

    // ── Worker loop ─────────────────────────────────────────────

    private static void runWorker(TestState state, long endTime) {
        HttpClientNio client;
        try {
            client = getClient();
        } catch (Exception e) {
            return;
        }

        while (state.running.get() && System.currentTimeMillis() < endTime) {
            long start = System.currentTimeMillis();
            try {
                HttpClientRequest req = new HttpClientRequest();
                req.url(state.url);
                req.method(state.method);
                req.timeout(30000);
                req.followRedirects(true);

                HttpClientResponse resp = client.request(req).get(30, TimeUnit.SECONDS);
                int sc = resp.getStatus();
                long elapsed = System.currentTimeMillis() - start;
                resp.getBody();
                state.record(sc, elapsed, sc >= 400);
            } catch (Exception e) {
                long elapsed = System.currentTimeMillis() - start;
                state.record(0, elapsed, true);
            }
        }
    }

    // ── Metrics builder (O(1) — no sorting, no sample iteration) ──

    private static Map<String, Object> buildMetrics(TestState s) {
        long totalReqs = s.total.get();
        long successCount = s.success.get();
        long errorCount = s.errors.get();

        // Elapsed time from last sample
        long lastMs = s.lastSampleTime > 0 ? s.lastSampleTime : System.currentTimeMillis();
        long elapsedMs = lastMs - s.startTime;
        double elapsedSec = Math.max(elapsedMs / 1000.0, 0.001);

        // Status codes
        Map<String, Object> statusCodeMap = new LinkedHashMap<>();
        if (s.s2xx.get() > 0) statusCodeMap.put("2xx", s.s2xx.get());
        if (s.s3xx.get() > 0) statusCodeMap.put("3xx", s.s3xx.get());
        if (s.s4xx.get() > 0) statusCodeMap.put("4xx", s.s4xx.get());
        if (s.s5xx.get() > 0) statusCodeMap.put("5xx", s.s5xx.get());
        if (s.sErr.get() > 0) statusCodeMap.put("err", s.sErr.get());

        // Histogram-based percentile estimation
        long[] hist = {s.hist0_50.get(), s.hist50_100.get(), s.hist100_200.get(),
                       s.hist200_500.get(), s.hist500_1s.get(), s.hist1s.get()};
        long[] bucketMid = {25, 75, 150, 350, 750, 1500};

        // Time series
        TreeMap<Long, long[]> sorted = new TreeMap<>(s.timeSeries);
        List<Map<String, Object>> timeSeries = new ArrayList<>();
        for (Map.Entry<Long, long[]> e : sorted.entrySet()) {
            long[] ts;
            synchronized (e.getValue()) {
                ts = e.getValue().clone();
            }
            Map<String, Object> point = new LinkedHashMap<>();
            point.put("timestamp", e.getKey());
            point.put("rps", ts[0]);
            point.put("avgRt", ts[0] > 0 ? (double) ts[1] / ts[0] : 0);
            point.put("errors", ts[2]);
            timeSeries.add(point);
        }

        // Build result
        Map<String, Object> result = new LinkedHashMap<>();
        result.put("testId", s.id);
        result.put("status", s.status);
        result.put("targetUrl", s.url);
        result.put("method", s.method);
        result.put("concurrency", s.concurrency);
        result.put("totalRequests", totalReqs);
        result.put("successCount", successCount);
        result.put("errorCount", errorCount);

        Map<String, Object> rt = new LinkedHashMap<>();
        rt.put("avg", totalReqs > 0 ? (double) s.totalRt.get() / totalReqs : 0);
        rt.put("min", totalReqs > 0 ? s.minRt.get() : 0);
        rt.put("max", s.maxRt.get());
        rt.put("p50", pctFromHist(hist, bucketMid, totalReqs, 0.50));
        rt.put("p95", pctFromHist(hist, bucketMid, totalReqs, 0.95));
        rt.put("p99", pctFromHist(hist, bucketMid, totalReqs, 0.99));
        result.put("responseTime", rt);

        Map<String, Object> throughput = new LinkedHashMap<>();
        throughput.put("rps", totalReqs / elapsedSec);
        throughput.put("totalElapsedSeconds", elapsedSec);
        result.put("throughput", throughput);

        result.put("errorRate", totalReqs > 0 ? 100.0 * errorCount / totalReqs : 0);
        result.put("statusCodes", statusCodeMap);
        result.put("timeSeries", timeSeries);

        List<Map<String, Object>> histogram = new ArrayList<>();
        histogram.add(Map.of("label", "0-50ms", "count", hist[0]));
        histogram.add(Map.of("label", "50-100ms", "count", hist[1]));
        histogram.add(Map.of("label", "100-200ms", "count", hist[2]));
        histogram.add(Map.of("label", "200-500ms", "count", hist[3]));
        histogram.add(Map.of("label", "500ms-1s", "count", hist[4]));
        histogram.add(Map.of("label", "1s+", "count", hist[5]));
        result.put("histogram", histogram);

        return result;
    }

    private static long pctFromHist(long[] hist, long[] mid, long total, double pct) {
        if (total == 0) return 0;
        long target = (long) (total * pct);
        long cumulative = 0;
        for (int i = 0; i < hist.length; i++) {
            cumulative += hist[i];
            if (cumulative >= target) return mid[i];
        }
        return mid[mid.length - 1];
    }
}
