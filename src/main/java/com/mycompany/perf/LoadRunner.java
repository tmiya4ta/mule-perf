package com.mycompany.perf;

import zeph.client.HttpClientNio;
import zeph.client.HttpClientRequest;
import zeph.client.HttpClientResponse;

import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;

/**
 * High-performance load runner using Zeph NIO HTTP client.
 * Called from Mule DataWeave via java! syntax.
 *
 * Usage in DataWeave:
 *   java!com::mycompany::perf::LoadRunner::start(url, method, concurrency, duration)
 *   java!com::mycompany::perf::LoadRunner::status(testId)
 *   java!com::mycompany::perf::LoadRunner::stop(testId)
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
        volatile long endTime = 0; // Set when test completes/stops

        // Metrics (lock-free)
        final AtomicLong total = new AtomicLong();
        final AtomicLong success = new AtomicLong();
        final AtomicLong errors = new AtomicLong();
        final ConcurrentHashMap<Integer, AtomicLong> statusCodes = new ConcurrentHashMap<>();

        // Histogram buckets
        final AtomicLong hist0_50 = new AtomicLong();
        final AtomicLong hist50_100 = new AtomicLong();
        final AtomicLong hist100_200 = new AtomicLong();
        final AtomicLong hist200_500 = new AtomicLong();
        final AtomicLong hist500_1s = new AtomicLong();
        final AtomicLong hist1s = new AtomicLong();

        // Samples for percentiles & time series (ring buffer)
        final ConcurrentLinkedQueue<long[]> samples = new ConcurrentLinkedQueue<>();
        final AtomicInteger sampleCount = new AtomicInteger();
        static final int MAX_SAMPLES = 100_000;

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
            if (error) errors.incrementAndGet();
            else success.incrementAndGet();

            statusCodes.computeIfAbsent(statusCode, k -> new AtomicLong()).incrementAndGet();

            if (elapsedMs < 50) hist0_50.incrementAndGet();
            else if (elapsedMs < 100) hist50_100.incrementAndGet();
            else if (elapsedMs < 200) hist100_200.incrementAndGet();
            else if (elapsedMs < 500) hist200_500.incrementAndGet();
            else if (elapsedMs < 1000) hist500_1s.incrementAndGet();
            else hist1s.incrementAndGet();

            // Keep bounded samples
            if (sampleCount.get() < MAX_SAMPLES) {
                samples.add(new long[]{System.currentTimeMillis(), elapsedMs, statusCode, error ? 1 : 0});
                sampleCount.incrementAndGet();
            }
        }

        void markFinished(String newStatus) {
            if (endTime == 0) {
                endTime = System.currentTimeMillis();
            }
            status = newStatus;
        }
    }

    // ── Public API (called from DataWeave) ──────────────────────

    /**
     * Start a load test. Returns test ID.
     */
    public static String start(String url, String method, int concurrency, int durationSec) {
        String testId = UUID.randomUUID().toString();
        TestState state = new TestState(testId, url, method.toUpperCase(), concurrency, durationSec);
        tests.put(testId, state);

        long endTime = state.startTime + (long) durationSec * 1000;

        // Launch worker threads
        List<Thread> workers = new ArrayList<>();
        for (int i = 0; i < concurrency; i++) {
            Thread t = new Thread(() -> runWorker(state, endTime), "perf-" + testId.substring(0, 8) + "-" + i);
            t.setDaemon(true);
            t.start();
            workers.add(t);
        }

        // Monitor thread: wait for completion
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

    /**
     * Get metrics for a test. Returns a Map suitable for JSON serialization.
     */
    public static Map<String, Object> status(String testId) {
        TestState s = tests.get(testId);
        if (s == null) return null;
        return buildMetrics(s);
    }

    /**
     * Stop a running test.
     */
    public static Map<String, Object> stop(String testId) {
        TestState s = tests.get(testId);
        if (s == null) return Map.of("stopped", false, "testId", testId);
        s.running.set(false);
        s.markFinished("stopped");
        return Map.of("stopped", true, "testId", testId);
    }

    /**
     * List all tests (summary).
     */
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
                // Consume body to release connection
                resp.getBody();
                state.record(sc, elapsed, sc >= 400);
            } catch (Exception e) {
                long elapsed = System.currentTimeMillis() - start;
                state.record(0, elapsed, true);
            }
        }
    }

    // ── Metrics builder ─────────────────────────────────────────

    private static Map<String, Object> buildMetrics(TestState s) {
        long totalReqs = s.total.get();
        long successCount = s.success.get();
        long errorCount = s.errors.get();

        // Use endTime if test is finished, otherwise now()
        long nowMs = (s.endTime > 0) ? s.endTime : System.currentTimeMillis();
        long elapsedMs = nowMs - s.startTime;
        double elapsedSec = Math.max(elapsedMs / 1000.0, 0.001);

        // Collect samples for percentiles
        long[][] sampleArray = s.samples.toArray(new long[0][]);
        long[] rts = new long[sampleArray.length];
        for (int i = 0; i < sampleArray.length; i++) rts[i] = sampleArray[i][1];
        Arrays.sort(rts);

        // Status codes
        Map<String, Object> statusCodeMap = new LinkedHashMap<>();
        for (Map.Entry<Integer, AtomicLong> e : s.statusCodes.entrySet()) {
            statusCodeMap.put(String.valueOf(e.getKey()), e.getValue().get());
        }

        // Time series (group by second)
        Map<Long, List<long[]>> buckets = new TreeMap<>();
        for (long[] sample : sampleArray) {
            long bucket = sample[0] - (sample[0] % 1000);
            buckets.computeIfAbsent(bucket, k -> new ArrayList<>()).add(sample);
        }
        List<Map<String, Object>> timeSeries = new ArrayList<>();
        for (Map.Entry<Long, List<long[]>> e : buckets.entrySet()) {
            List<long[]> entries = e.getValue();
            long[] bucketRts = new long[entries.size()];
            int errCount = 0;
            long rtSum = 0;
            for (int i = 0; i < entries.size(); i++) {
                bucketRts[i] = entries.get(i)[1];
                rtSum += bucketRts[i];
                if (entries.get(i)[3] == 1) errCount++;
            }
            Arrays.sort(bucketRts);
            Map<String, Object> point = new LinkedHashMap<>();
            point.put("timestamp", e.getKey());
            point.put("rps", entries.size());
            point.put("avgRt", entries.isEmpty() ? 0 : (double) rtSum / entries.size());
            point.put("p95Rt", percentile(bucketRts, 0.95));
            point.put("p99Rt", percentile(bucketRts, 0.99));
            point.put("errors", errCount);
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
        rt.put("avg", rts.length > 0 ? (double) Arrays.stream(rts).sum() / rts.length : 0);
        rt.put("min", rts.length > 0 ? rts[0] : 0);
        rt.put("max", rts.length > 0 ? rts[rts.length - 1] : 0);
        rt.put("p50", percentile(rts, 0.50));
        rt.put("p95", percentile(rts, 0.95));
        rt.put("p99", percentile(rts, 0.99));
        result.put("responseTime", rt);

        Map<String, Object> throughput = new LinkedHashMap<>();
        throughput.put("rps", totalReqs / elapsedSec);
        throughput.put("totalElapsedSeconds", elapsedSec);
        result.put("throughput", throughput);

        result.put("errorRate", totalReqs > 0 ? 100.0 * errorCount / totalReqs : 0);
        result.put("statusCodes", statusCodeMap);
        result.put("timeSeries", timeSeries);

        List<Map<String, Object>> histogram = new ArrayList<>();
        histogram.add(Map.of("label", "0-50ms", "count", s.hist0_50.get()));
        histogram.add(Map.of("label", "50-100ms", "count", s.hist50_100.get()));
        histogram.add(Map.of("label", "100-200ms", "count", s.hist100_200.get()));
        histogram.add(Map.of("label", "200-500ms", "count", s.hist200_500.get()));
        histogram.add(Map.of("label", "500ms-1s", "count", s.hist500_1s.get()));
        histogram.add(Map.of("label", "1s+", "count", s.hist1s.get()));
        result.put("histogram", histogram);

        return result;
    }

    private static long percentile(long[] sorted, double p) {
        if (sorted.length == 0) return 0;
        int idx = Math.min((int) (sorted.length * p), sorted.length - 1);
        return sorted[idx];
    }
}
