package com.gamevault;

import com.fasterxml.jackson.databind.node.ObjectNode;
import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;
import java.io.IOException;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.time.Instant;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;
import java.util.concurrent.Executors;

/**
 * HTTP server on the JDK's built-in HttpServer with virtual threads.
 * Cross-cutting concerns live here: routing, authentication, role checks, CORS,
 * security headers, rate limiting of auth endpoints, request ids, error mapping
 * (no stack traces to clients) and one structured JSON log line per request.
 */
public final class Server {
    public enum Access { PUBLIC, USER, ADMIN }

    @FunctionalInterface
    public interface Handler { Object handle(Ctx c) throws Exception; }

    /** Wrap a handler result in this to choose the status code. */
    public record Resp(int status, Object body) {}

    private record Route(String method, String[] segs, Access access, boolean limited, Handler handler) {}

    static {
        // After an early error (e.g. 413) the JDK server drains the unread request body so the client can
        // still read our answer. The default drain limit is 64 KB; allow 2 MB (our body limit is 1 MB).
        System.setProperty("sun.net.httpserver.drainAmount", "2097152");
    }

    private final Config cfg;
    private final AuthService auth;
    private final RateLimiter authLimiter;
    private final List<Route> routes = new ArrayList<>();
    private HttpServer http;

    public Server(Config cfg, AuthService auth) {
        this.cfg = cfg;
        this.auth = auth;
        this.authLimiter = new RateLimiter(cfg.authRatePerMinute(), 60_000);
    }

    public void route(String method, String path, Access access, Handler h) { add(method, path, access, false, h); }

    /** For login/register: additionally limited per client address. */
    public void limitedRoute(String method, String path, Handler h) { add(method, path, Access.PUBLIC, true, h); }

    private void add(String method, String path, Access access, boolean limited, Handler h) {
        routes.add(new Route(method, split(path), access, limited, h));
    }

    private static String[] split(String path) {
        return java.util.Arrays.stream(path.split("/")).filter(s -> !s.isEmpty()).toArray(String[]::new);
    }

    public int start() throws IOException {
        http = HttpServer.create(new InetSocketAddress(cfg.port()), 256);
        http.setExecutor(Executors.newVirtualThreadPerTaskExecutor());
        http.createContext("/", this::dispatch);
        http.start();
        return http.getAddress().getPort();
    }

    public void stop() {
        if (http != null) http.stop(2);
    }

    // ---------------------------------------------------------------------------------------------

    private void dispatch(HttpExchange ex) throws IOException {
        long t0 = System.nanoTime();
        String rid = UUID.randomUUID().toString().substring(0, 8);
        int status = 500;
        String who = "-";
        String method = ex.getRequestMethod();
        String path = ex.getRequestURI().getRawPath();
        try {
            securityHeaders(ex, rid);
            if ("OPTIONS".equals(method)) {
                ex.getResponseHeaders().set("Access-Control-Allow-Methods", "GET, POST, PUT, PATCH, DELETE, OPTIONS");
                ex.getResponseHeaders().set("Access-Control-Allow-Headers", "Authorization, Content-Type");
                ex.getResponseHeaders().set("Access-Control-Max-Age", "600");
                status = send(ex, 204, null);
                return;
            }
            Ctx c = new Ctx(ex, rid, cfg.trustProxy());
            Object result = process(c, method, path);
            who = c.user == null ? "-" : c.user.username();
            if (result instanceof Resp r) status = send(ex, r.status(), r.body());
            else status = send(ex, 200, result);
        } catch (ApiException e) {
            status = sendError(ex, e.status, e.code, e.getMessage(), rid);
        } catch (Throwable t) {
            log("ERROR", rid, method, path, 500, who, t.toString());
            status = sendError(ex, 500, "internal_error", "Something went wrong on our side", rid);
        } finally {
            long ms = (System.nanoTime() - t0) / 1_000_000;
            log("INFO", rid, method, path, status, who, ms + "ms");
            ex.close();
        }
    }

    private Object process(Ctx c, String method, String rawPath) throws Exception {
        String[] segs = split(rawPath);
        boolean pathExists = false;
        for (Route r : routes) {
            if (!matches(r.segs, segs, c)) continue;
            pathExists = true;
            if (!r.method.equals(method)) { c.pathParams.clear(); continue; }
            if (r.limited && !authLimiter.allow(c.ip())) {
                c.ex.getResponseHeaders().set("Retry-After", "60");
                throw new ApiException(429, "rate_limited", "Too many attempts. Please wait a minute.");
            }
            if (r.access != Access.PUBLIC) {
                String h = c.ex.getRequestHeaders().getFirst("Authorization");
                if (h == null || !h.regionMatches(true, 0, "Bearer ", 0, 7))
                    throw ApiException.unauthorized("Sign in required");
                c.user = auth.authenticate(h.substring(7).trim())
                        .orElseThrow(() -> ApiException.unauthorized("Your session has expired. Please sign in again."));
                if (r.access == Access.ADMIN && !c.user.isAdmin())
                    throw ApiException.forbidden("Administrator role required");
            }
            return r.handler.handle(c);
        }
        if (pathExists) throw new ApiException(405, "method_not_allowed", "Method not allowed");
        throw ApiException.notFound("No such endpoint");
    }

    private static boolean matches(String[] pattern, String[] actual, Ctx c) {
        if (pattern.length != actual.length) return false;
        for (int i = 0; i < pattern.length; i++) {
            String p = pattern[i];
            if (p.startsWith("{") && p.endsWith("}")) c.pathParams.put(p.substring(1, p.length() - 1), actual[i]);
            else if (!p.equals(actual[i])) { c.pathParams.clear(); return false; }
        }
        return true;
    }

    private void securityHeaders(HttpExchange ex, String rid) {
        var h = ex.getResponseHeaders();
        h.set("X-Request-Id", rid);
        h.set("X-Content-Type-Options", "nosniff");
        h.set("X-Frame-Options", "DENY");
        h.set("Referrer-Policy", "no-referrer");
        h.set("Cache-Control", "no-store");
        h.set("Content-Security-Policy", "default-src 'none'; frame-ancestors 'none'");
        String origin = ex.getRequestHeaders().getFirst("Origin");
        if (origin != null && origin.equals(cfg.corsOrigin())) {
            h.set("Access-Control-Allow-Origin", origin);
            h.set("Vary", "Origin");
        }
    }

    private static int send(HttpExchange ex, int status, Object body) throws IOException {
        if (body == null || status == 204) {
            ex.sendResponseHeaders(204, -1);
            return 204;
        }
        byte[] bytes = Json.write(body);
        ex.getResponseHeaders().set("Content-Type", "application/json; charset=utf-8");
        ex.sendResponseHeaders(status, bytes.length);
        try (OutputStream os = ex.getResponseBody()) {
            os.write(bytes);
        }
        return status;
    }

    private static int sendError(HttpExchange ex, int status, String code, String message, String rid) throws IOException {
        ObjectNode err = Json.MAPPER.createObjectNode();
        err.putObject("error").put("code", code).put("message", message).put("requestId", rid);
        try {
            return send(ex, status, err);
        } catch (IOException e) {
            return status;
        }
    }

    private static void log(String level, String rid, String method, String path, int status, String who, String detail) {
        ObjectNode n = Json.MAPPER.createObjectNode();
        n.put("ts", Instant.now().toString()).put("level", level).put("requestId", rid)
                .put("method", method).put("path", path).put("status", status)
                .put("user", who).put("detail", detail);
        System.out.println(n);
    }
}
