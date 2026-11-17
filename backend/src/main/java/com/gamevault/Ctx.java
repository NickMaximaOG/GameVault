package com.gamevault;

import com.fasterxml.jackson.databind.JsonNode;
import com.sun.net.httpserver.HttpExchange;
import java.io.IOException;
import java.math.BigDecimal;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.time.LocalDate;
import java.time.format.DateTimeParseException;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/** Everything a handler needs about one request, plus input-validation helpers. */
public final class Ctx {
    static final int MAX_BODY_BYTES = 1_000_000;

    public final HttpExchange ex;
    public final String requestId;
    final Map<String, String> pathParams = new HashMap<>();
    private final Map<String, String> query = new HashMap<>();
    private final boolean trustProxy;
    private JsonNode body;
    public AuthUser user;

    Ctx(HttpExchange ex, String requestId, boolean trustProxy) {
        this.ex = ex;
        this.requestId = requestId;
        this.trustProxy = trustProxy;
        String raw = ex.getRequestURI().getRawQuery();
        if (raw != null && !raw.isEmpty()) {
            for (String pair : raw.split("&")) {
                if (pair.isEmpty()) continue;
                int eq = pair.indexOf('=');
                String k = decode(eq < 0 ? pair : pair.substring(0, eq));
                String v = eq < 0 ? "" : decode(pair.substring(eq + 1));
                query.put(k, v);
            }
        }
    }

    private static String decode(String s) {
        try {
            return URLDecoder.decode(s, StandardCharsets.UTF_8);
        } catch (IllegalArgumentException e) {
            throw ApiException.badRequest("Malformed query string");
        }
    }

    public String ip() {
        if (trustProxy) {
            String xff = ex.getRequestHeaders().getFirst("X-Forwarded-For");
            if (xff != null && !xff.isBlank()) return xff.split(",")[0].trim();
        }
        return ex.getRemoteAddress().getAddress().getHostAddress();
    }

    public String userAgent() {
        String ua = ex.getRequestHeaders().getFirst("User-Agent");
        return ua == null ? null : (ua.length() > 255 ? ua.substring(0, 255) : ua);
    }

    // ---- path and query ---------------------------------------------------------------------

    public int pathInt(String name) {
        try {
            return Integer.parseInt(pathParams.get(name));
        } catch (NumberFormatException e) {
            throw ApiException.badRequest("'" + name + "' must be a whole number");
        }
    }

    public String q(String name) { return query.get(name); }

    public int qInt(String name, int def, int min, int max) {
        String v = query.get(name);
        if (v == null || v.isBlank()) return def;
        try {
            int i = Integer.parseInt(v.trim());
            if (i < min || i > max) throw ApiException.badRequest("'" + name + "' must be between " + min + " and " + max);
            return i;
        } catch (NumberFormatException e) {
            throw ApiException.badRequest("'" + name + "' must be a whole number");
        }
    }

    public List<Integer> qIntList(String name, int maxItems) {
        String v = query.get(name);
        List<Integer> out = new ArrayList<>();
        if (v == null || v.isBlank()) return out;
        String[] parts = v.split(",");
        if (parts.length > maxItems) throw ApiException.badRequest("'" + name + "' has too many values");
        for (String p : parts) {
            try {
                out.add(Integer.parseInt(p.trim()));
            } catch (NumberFormatException e) {
                throw ApiException.badRequest("'" + name + "' must be a comma-separated list of numbers");
            }
        }
        return out;
    }

    // ---- body ---------------------------------------------------------------------------------

    public JsonNode body() {
        if (body == null) {
            try {
                byte[] bytes = ex.getRequestBody().readNBytes(MAX_BODY_BYTES + 1);
                if (bytes.length > MAX_BODY_BYTES) throw new ApiException(413, "payload_too_large", "Request body is too large");
                if (bytes.length == 0) throw ApiException.badRequest("A JSON body is required");
                body = Json.parse(bytes);
                if (!body.isObject()) throw ApiException.badRequest("The JSON body must be an object");
            } catch (IOException e) {
                throw ApiException.badRequest("Could not read the request body");
            }
        }
        return body;
    }

    public static String reqStr(JsonNode b, String f, int maxLen) {
        JsonNode n = b.get(f);
        if (n == null || n.isNull() || !n.isTextual() || n.asText().isBlank())
            throw ApiException.badRequest("'" + f + "' is required");
        String s = n.asText().strip();
        if (s.length() > maxLen) throw ApiException.badRequest("'" + f + "' is too long (max " + maxLen + ")");
        return s;
    }

    public static String optStr(JsonNode b, String f, int maxLen) {
        JsonNode n = b.get(f);
        if (n == null || n.isNull()) return null;
        if (!n.isTextual()) throw ApiException.badRequest("'" + f + "' must be text");
        String s = n.asText().strip();
        if (s.isEmpty()) return null;
        if (s.length() > maxLen) throw ApiException.badRequest("'" + f + "' is too long (max " + maxLen + ")");
        return s;
    }

    public static int reqInt(JsonNode b, String f) {
        Integer v = optInt(b, f);
        if (v == null) throw ApiException.badRequest("'" + f + "' is required");
        return v;
    }

    public static Integer optInt(JsonNode b, String f) {
        JsonNode n = b.get(f);
        if (n == null || n.isNull()) return null;
        if (!n.isIntegralNumber() || !n.canConvertToInt()) throw ApiException.badRequest("'" + f + "' must be a whole number");
        return n.asInt();
    }

    public static BigDecimal reqNum(JsonNode b, String f, double min, double max) {
        BigDecimal v = optNum(b, f, min, max);
        if (v == null) throw ApiException.badRequest("'" + f + "' is required");
        return v;
    }

    public static BigDecimal optNum(JsonNode b, String f, double min, double max) {
        JsonNode n = b.get(f);
        if (n == null || n.isNull()) return null;
        if (!n.isNumber()) throw ApiException.badRequest("'" + f + "' must be a number");
        BigDecimal v = n.decimalValue();
        if (v.doubleValue() < min || v.doubleValue() > max)
            throw ApiException.badRequest("'" + f + "' must be between " + min + " and " + max);
        return v;
    }

    /** Returns yyyy-MM-dd or null. */
    public static String optDate(JsonNode b, String f) {
        String s = optStr(b, f, 10);
        if (s == null) return null;
        try {
            return LocalDate.parse(s).toString();
        } catch (DateTimeParseException e) {
            throw ApiException.badRequest("'" + f + "' must be a date like 2026-10-31");
        }
    }
}
