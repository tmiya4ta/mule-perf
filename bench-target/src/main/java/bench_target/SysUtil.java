package bench_target;

import java.io.*;
import java.lang.management.*;
import java.util.*;

public class SysUtil {

    public static Map<String, Object> systemInfo() {
        Runtime rt = Runtime.getRuntime();
        MemoryMXBean mem = ManagementFactory.getMemoryMXBean();
        MemoryUsage heap = mem.getHeapMemoryUsage();

        Map<String, Object> result = new LinkedHashMap<>();
        long usedMB = heap.getUsed() / 1048576;
        long maxMB = heap.getMax() > 0 ? heap.getMax() / 1048576 : rt.maxMemory() / 1048576;
        result.put("heapUsedMB", usedMB);
        result.put("heapMaxMB", maxMB);
        result.put("heapPct", maxMB > 0 ? Math.round(100.0 * usedMB / maxMB) : 0);
        result.put("processors", rt.availableProcessors());

        try {
            com.sun.management.OperatingSystemMXBean osBean =
                (com.sun.management.OperatingSystemMXBean) ManagementFactory.getOperatingSystemMXBean();
            result.put("cpuPct", Math.round(osBean.getProcessCpuLoad() * 100));
            result.put("systemCpuPct", Math.round(osBean.getCpuLoad() * 100));
        } catch (Exception e) {
            result.put("cpuPct", -1);
        }

        result.put("threadCount", ManagementFactory.getThreadMXBean().getThreadCount());
        result.put("peakThreadCount", ManagementFactory.getThreadMXBean().getPeakThreadCount());
        result.put("uptimeSeconds", ManagementFactory.getRuntimeMXBean().getUptime() / 1000);

        return result;
    }

    public static boolean sleep(long ms) {
        if (ms > 0) {
            try { Thread.sleep(ms); } catch (InterruptedException e) { Thread.currentThread().interrupt(); }
        }
        return true;
    }

    public static Map<String, Object> exec(String command) {
        Map<String, Object> result = new LinkedHashMap<>();
        if (command == null || command.isEmpty()) {
            result.put("error", "No command provided");
            return result;
        }
        try {
            ProcessBuilder pb = new ProcessBuilder("sh", "-c", command);
            pb.redirectErrorStream(true);
            Process p = pb.start();
            StringBuilder sb = new StringBuilder();
            try (BufferedReader br = new BufferedReader(new InputStreamReader(p.getInputStream()))) {
                String line;
                while ((line = br.readLine()) != null) {
                    sb.append(line).append("\n");
                }
            }
            int exitCode = p.waitFor();
            result.put("output", sb.toString().trim());
            result.put("exitCode", exitCode);
        } catch (Exception e) {
            result.put("error", e.getMessage());
        }
        return result;
    }
}
