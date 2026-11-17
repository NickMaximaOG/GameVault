package com.gamevault;

import java.util.ArrayDeque;
import java.util.concurrent.ConcurrentHashMap;

/** Sliding-window limiter (per key, e.g. client IP). In-memory: one instance per backend process. */
public final class RateLimiter {
    private final int max;
    private final long windowMillis;
    private final ConcurrentHashMap<String, ArrayDeque<Long>> hits = new ConcurrentHashMap<>();

    public RateLimiter(int maxPerWindow, long windowMillis) {
        this.max = maxPerWindow;
        this.windowMillis = windowMillis;
    }

    public boolean allow(String key) {
        long now = System.currentTimeMillis();
        if (hits.size() > 10_000) hits.clear();          // crude bound on memory
        ArrayDeque<Long> q = hits.computeIfAbsent(key, k -> new ArrayDeque<>());
        synchronized (q) {
            while (!q.isEmpty() && now - q.peekFirst() > windowMillis) q.pollFirst();
            if (q.size() >= max) return false;
            q.addLast(now);
            return true;
        }
    }
}
