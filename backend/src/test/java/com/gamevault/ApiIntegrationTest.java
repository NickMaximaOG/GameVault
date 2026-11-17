package com.gamevault;

import static org.junit.jupiter.api.Assertions.*;
import static org.junit.jupiter.api.Assumptions.assumeTrue;

import com.fasterxml.jackson.databind.JsonNode;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpHeaders;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;
import java.util.UUID;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.MethodOrderer;
import org.junit.jupiter.api.Order;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.TestInstance;
import org.junit.jupiter.api.TestMethodOrder;

/**
 * End-to-end tests: real HTTP requests -> Java server -> MySQL.
 * Needs a freshly seeded database (database/schema.sql + security.sql) and DB_PASSWORD set;
 * otherwise every test is skipped. See ../../../../../../test-all.sh in the project root.
 */
@TestInstance(TestInstance.Lifecycle.PER_CLASS)
@TestMethodOrder(MethodOrderer.OrderAnnotation.class)
class ApiIntegrationTest {
    record R(int status, JsonNode body, HttpHeaders headers) {
        String s(String field) { return body.path(field).asText(); }
    }

    private static final String PW = "Passw0rd-Test1";
    private static final String DEMO_PW = "ChangeMe!2026";

    private Db db;
    private Server server;
    private String base;
    private final HttpClient http = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(5)).build();

    private final String suffix = UUID.randomUUID().toString().substring(0, 6);
    private final String user = "tester_" + suffix;
    private String userToken;
    private int userId;
    private int entryId;
    private int eldenRingId;
    private int ps5, switchId;

    @BeforeAll
    void start() throws Exception {
        String pw = System.getenv("DB_PASSWORD");
        assumeTrue(pw != null && !pw.isBlank(), "DB_PASSWORD not set: skipping integration tests");
        Config cfg = testConfig(pw, 3, 1000);
        db = new Db(cfg);
        server = App.build(cfg, db);
        base = "http://localhost:" + server.start() + "/api/v1";
    }

    private static Config testConfig(String pw, int maxFailed, int ratePerMinute) {
        return new Config(0, System.getenv().getOrDefault("DB_URL", "jdbc:mariadb://localhost:3306/gamevault_db"),
                System.getenv().getOrDefault("DB_USER", "gv_app"), pw, 4, "http://localhost:3000",
                Duration.ofHours(1), maxFailed, Duration.ofMinutes(15), ratePerMinute, false);
    }

    @AfterAll
    void stop() {
        if (server != null) server.stop();
        if (db != null) db.close();
    }

    // ---- helper -----------------------------------------------------------------------------
    private R call(String method, String path, String token, Object body, String... headers) throws Exception {
        HttpRequest.Builder b = HttpRequest.newBuilder(URI.create(base + path)).timeout(Duration.ofSeconds(20));
        if (token != null) b.header("Authorization", "Bearer " + token);
        for (int i = 0; i + 1 < headers.length; i += 2) b.header(headers[i], headers[i + 1]);
        if (body != null) {
            String json = body instanceof String str ? str : new String(Json.write(body));
            b.header("Content-Type", "application/json");
            b.method(method, HttpRequest.BodyPublishers.ofString(json));
        } else {
            b.method(method, HttpRequest.BodyPublishers.noBody());
        }
        HttpResponse<String> r = http.send(b.build(), HttpResponse.BodyHandlers.ofString());
        JsonNode node = r.body().isEmpty() ? Json.MAPPER.nullNode() : Json.MAPPER.readTree(r.body());
        return new R(r.statusCode(), node, r.headers());
    }

    private String login(String username, String password) throws Exception {
        R r = call("POST", "/auth/login", null, java.util.Map.of("username", username, "password", password));
        assertEquals(200, r.status, r.body.toString());
        return r.s("token");
    }

    // ---- infrastructure ------------------------------------------------------------------------
    @Test @Order(1)
    void healthIsUp() throws Exception {
        R r = call("GET", "/health", null, null);
        assertEquals(200, r.status);
        assertEquals("UP", r.s("database"));
    }

    @Test @Order(2)
    void securityHeadersAndErrorShape() throws Exception {
        R r = call("GET", "/nope", null, null);
        assertEquals(404, r.status);
        assertEquals("not_found", r.body.path("error").path("code").asText());
        assertFalse(r.body.path("error").path("requestId").asText().isEmpty());
        assertEquals("nosniff", r.headers.firstValue("X-Content-Type-Options").orElse(""));
        assertEquals("DENY", r.headers.firstValue("X-Frame-Options").orElse(""));
        assertEquals("no-store", r.headers.firstValue("Cache-Control").orElse(""));
        assertTrue(r.headers.firstValue("X-Request-Id").isPresent());
        assertEquals(405, call("DELETE", "/catalog/games", null, null).status);
    }

    @Test @Order(3)
    void corsOnlyForTheConfiguredOrigin() throws Exception {
        R ok = call("GET", "/health", null, null, "Origin", "http://localhost:3000");
        assertEquals("http://localhost:3000", ok.headers.firstValue("Access-Control-Allow-Origin").orElse(""));
        R bad = call("GET", "/health", null, null, "Origin", "http://evil.example");
        assertTrue(bad.headers.firstValue("Access-Control-Allow-Origin").isEmpty());
        R pre = call("OPTIONS", "/me/collection", null, null, "Origin", "http://localhost:3000");
        assertEquals(204, pre.status);
        assertTrue(pre.headers.firstValue("Access-Control-Allow-Headers").orElse("").contains("Authorization"));
    }

    @Test @Order(4)
    void malformedAndOversizedBodiesAreRejected() throws Exception {
        assertEquals(400, call("POST", "/auth/login", null, "{not json").status);
        assertEquals(400, call("POST", "/auth/login", null, "[1,2]").status);
        assertEquals(400, call("POST", "/auth/login", null, "{}").status);
        String huge = "{\"username\":\"" + "a".repeat(1_100_000) + "\"}";
        assertEquals(413, call("POST", "/auth/login", null, huge).status);
    }

    // ---- authentication ----------------------------------------------------------------------
    @Test @Order(10)
    void protectedRoutesNeedAValidToken() throws Exception {
        assertEquals(401, call("GET", "/me/collection", null, null).status);
        assertEquals(401, call("GET", "/me/collection", "garbage-token", null).status);
        assertEquals(401, call("GET", "/admin/audit", null, null).status);
    }

    @Test @Order(11)
    void registrationValidatesAndRejectsDuplicates() throws Exception {
        String e = user + "@example.com";
        assertEquals(400, call("POST", "/auth/register", null, java.util.Map.of("username", "ab", "email", e, "password", PW)).status);
        assertEquals(400, call("POST", "/auth/register", null, java.util.Map.of("username", user, "email", "nope", "password", PW)).status);
        assertEquals(400, call("POST", "/auth/register", null, java.util.Map.of("username", user, "email", e, "password", "short1")).status);
        R ok = call("POST", "/auth/register", null, java.util.Map.of("username", user, "email", e, "password", PW));
        assertEquals(201, ok.status, ok.body.toString());
        assertEquals("USER", ok.s("role"));
        assertFalse(ok.body.has("password_hash"));
        userId = ok.body.path("user_id").asInt();
        assertEquals(409, call("POST", "/auth/register", null, java.util.Map.of("username", user, "email", "other_" + e, "password", PW)).status);
        assertEquals(409, call("POST", "/auth/register", null, java.util.Map.of("username", "other_" + user, "email", e, "password", PW)).status);
    }

    @Test @Order(12)
    void loginAndMe() throws Exception {
        assertEquals(401, call("POST", "/auth/login", null, java.util.Map.of("username", user, "password", "wrong-password-1")).status);
        assertEquals(401, call("POST", "/auth/login", null, java.util.Map.of("username", "nobody_" + suffix, "password", PW)).status);
        userToken = login(user, PW);
        R me = call("GET", "/auth/me", userToken, null);
        assertEquals(user, me.s("username"));
        assertFalse(me.body.toString().contains("pbkdf2"));
        // logging in with the e-mail address works too, case-insensitively
        assertEquals(200, call("POST", "/auth/login", null, java.util.Map.of("username", user.toUpperCase() + "@EXAMPLE.COM", "password", PW)).status);
    }

    @Test @Order(13)
    void accountLocksAfterRepeatedFailures() throws Exception {
        String u = "lock_" + suffix;
        assertEquals(201, call("POST", "/auth/register", null, java.util.Map.of("username", u, "email", u + "@example.com", "password", PW)).status);
        for (int i = 0; i < 3; i++)
            assertEquals(401, call("POST", "/auth/login", null, java.util.Map.of("username", u, "password", "wrong-password-1")).status);
        R locked = call("POST", "/auth/login", null, java.util.Map.of("username", u, "password", PW));
        assertEquals(429, locked.status);
        assertEquals("account_locked", locked.body.path("error").path("code").asText());
    }

    @Test @Order(14)
    void loginIsRateLimitedPerClient() throws Exception {
        Config cfg = testConfig(System.getenv("DB_PASSWORD"), 50, 3);
        Server limited = App.build(cfg, db);
        String url = "http://localhost:" + limited.start() + "/api/v1/auth/login";
        try {
            int last = 0;
            String lastRetry = "";
            for (int i = 0; i < 4; i++) {
                HttpResponse<String> r = http.send(HttpRequest.newBuilder(URI.create(url))
                        .header("Content-Type", "application/json")
                        .POST(HttpRequest.BodyPublishers.ofString("{\"username\":\"x" + suffix + "\",\"password\":\"y\"}")).build(),
                        HttpResponse.BodyHandlers.ofString());
                last = r.statusCode();
                lastRetry = r.headers().firstValue("Retry-After").orElse("");
            }
            assertEquals(429, last);
            assertEquals("60", lastRetry);
        } finally {
            limited.stop();
        }
    }

    // ---- catalogue ------------------------------------------------------------------------------
    @Test @Order(20)
    void lookupsListEverything() throws Exception {
        R r = call("GET", "/catalog/lookups", null, null);
        assertEquals(12, r.body.path("genres").size());
        assertEquals(6, r.body.path("platforms").size());
        assertEquals(9, r.body.path("ageRatings").size());
        assertEquals(5, r.body.path("statuses").size());
        for (JsonNode p : r.body.path("platforms")) {
            if (p.path("name").asText().equals("PlayStation 5")) ps5 = p.path("platform_id").asInt();
            if (p.path("name").asText().equals("Nintendo Switch")) switchId = p.path("platform_id").asInt();
        }
        assertTrue(ps5 > 0 && switchId > 0);
    }

    @Test @Order(21)
    void filterByKeywordGenrePlatformAndAgeRating() throws Exception {
        assertEquals(2, call("GET", "/catalog/games?q=Wild", null, null).body.path("total").asInt());
        assertEquals(4, call("GET", "/catalog/games?genres=1,3&match=all", null, null).body.path("total").asInt());
        assertEquals(15, call("GET", "/catalog/games?genres=1,3&match=any", null, null).body.path("total").asInt());
        assertEquals(10, call("GET", "/catalog/games?platformId=" + switchId, null, null).body.path("total").asInt());
        R lookups = call("GET", "/catalog/lookups", null, null);
        int pegi18 = 0, esrbM = 0;
        for (JsonNode a : lookups.body.path("ageRatings")) {
            if (a.path("rating_authority").asText().equals("PEGI") && a.path("label").asText().equals("18")) pegi18 = a.path("age_rating_id").asInt();
            if (a.path("rating_authority").asText().equals("ESRB") && a.path("label").asText().equals("M")) esrbM = a.path("age_rating_id").asInt();
        }
        assertEquals(6, call("GET", "/catalog/games?ageRatingId=" + pegi18, null, null).body.path("total").asInt());
        assertEquals(10, call("GET", "/catalog/games?ageRatingId=" + esrbM, null, null).body.path("total").asInt());
        assertEquals(1, call("GET", "/catalog/games?genres=1,3&match=all&platformId=" + switchId + "&q=Witcher", null, null).body.path("total").asInt());
    }

    @Test @Order(22)
    void pagingSortingAndInputLimits() throws Exception {
        R p2 = call("GET", "/catalog/games?size=5&page=2&sort=title", null, null);
        assertEquals(5, p2.body.path("items").size());
        assertEquals(20, p2.body.path("total").asInt());
        R byRating = call("GET", "/catalog/games?sort=rating&dir=desc&minRating=9", null, null);
        double prev = 11;
        for (JsonNode g : byRating.body.path("items")) {
            double v = g.path("avg_rating").asDouble();
            assertTrue(v >= 9 && v <= prev);
            prev = v;
        }
        assertEquals(400, call("GET", "/catalog/games?size=500", null, null).status);
        assertEquals(400, call("GET", "/catalog/games?page=abc", null, null).status);
        assertEquals(400, call("GET", "/catalog/games?genres=1,x", null, null).status);
    }

    @Test @Order(23)
    void sqlInjectionAttemptsAreInert() throws Exception {
        for (String evil : new String[] {"x' OR '1'='1", "'; DROP TABLE Game; --", "%27%20OR%201%3D1%20--"}) {
            R r = call("GET", "/catalog/games?q=" + java.net.URLEncoder.encode(evil, "UTF-8"), null, null);
            assertEquals(200, r.status);
            assertEquals(0, r.body.path("total").asInt());
        }
        R r = call("GET", "/catalog/games?sort=title;DROP%20TABLE%20Game&dir=desc;--", null, null);
        assertEquals(200, r.status);
        assertEquals(20, r.body.path("total").asInt());     // table still intact
        assertEquals(0, call("GET", "/catalog/games?q=%25%25%25", null, null).body.path("total").asInt());   // % is literal
    }

    @Test @Order(24)
    void gameDetail() throws Exception {
        R list = call("GET", "/catalog/games?q=Elden", null, null);
        eldenRingId = list.body.path("items").get(0).path("game_id").asInt();
        R d = call("GET", "/catalog/games/" + eldenRingId, null, null);
        assertEquals("Elden Ring", d.s("title"));
        assertEquals(3, d.body.path("genreList").size());
        assertEquals(5, d.body.path("platformList").size());
        assertEquals(2, d.body.path("ageRatingList").size());
        assertEquals(5, d.body.path("achievements").size());
        boolean masked = false;
        for (JsonNode a : d.body.path("achievements"))
            if (a.path("is_hidden").asBoolean()) { masked = true; assertEquals("Hidden achievement", a.path("name").asText()); assertTrue(a.path("description").isNull()); }
        assertTrue(masked);
        assertEquals(404, call("GET", "/catalog/games/99999", null, null).status);
        assertEquals(400, call("GET", "/catalog/games/abc", null, null).status);
    }

    // ---- collection, sessions, achievements, ratings -------------------------------------------------
    @Test @Order(30)
    void addingGamesIsValidated() throws Exception {
        assertEquals(0, call("GET", "/me/collection", userToken, null).body.size());
        int zelda = call("GET", "/catalog/games?q=Breath", null, null).body.path("items").get(0).path("game_id").asInt();
        R wrong = call("POST", "/me/collection", userToken, java.util.Map.of("gameId", zelda, "platformId", ps5));
        assertEquals(400, wrong.status);
        assertTrue(wrong.body.path("error").path("message").asText().contains("not available"));
        assertEquals(404, call("POST", "/me/collection", userToken, java.util.Map.of("gameId", 99999, "platformId", ps5)).status);
        assertEquals(400, call("POST", "/me/collection", userToken, java.util.Map.of("gameId", eldenRingId, "platformId", ps5, "price", -3)).status);
        assertEquals(400, call("POST", "/me/collection", userToken, java.util.Map.of("gameId", eldenRingId)).status);

        R ok = call("POST", "/me/collection", userToken,
                java.util.Map.of("gameId", eldenRingId, "platformId", ps5, "price", 49.99, "purchaseDate", "2026-10-01", "statusId", 2));
        assertEquals(201, ok.status, ok.body.toString());
        assertEquals("Playing", ok.s("status"));
        assertEquals(1, ok.body.path("row_version").asInt());
        entryId = ok.body.path("user_game_id").asInt();
        assertEquals(409, call("POST", "/me/collection", userToken, java.util.Map.of("gameId", eldenRingId, "platformId", ps5)).status);
    }

    @Test @Order(31)
    void playSessionsAddUpToPlaytime() throws Exception {
        R s1 = call("POST", "/me/collection/" + entryId + "/sessions", userToken,
                java.util.Map.of("startedAt", "2026-10-20T18:00", "minutes", 90, "note", "first night"));
        assertEquals(201, s1.status, s1.body.toString());
        assertEquals(1.5, s1.body.path("entry").path("playtime_hours").asDouble());
        R s2 = call("POST", "/me/collection/" + entryId + "/sessions", userToken,
                java.util.Map.of("startedAt", "2026-10-21T20:00:00+05:30", "minutes", 30));
        assertEquals(2.0, s2.body.path("entry").path("playtime_hours").asDouble());
        assertEquals(400, call("POST", "/me/collection/" + entryId + "/sessions", userToken, java.util.Map.of("startedAt", "2026-10-20T18:00", "minutes", 0)).status);
        assertEquals(400, call("POST", "/me/collection/" + entryId + "/sessions", userToken, java.util.Map.of("startedAt", "2999-01-01T00:00", "minutes", 10)).status);
        assertEquals(400, call("POST", "/me/collection/" + entryId + "/sessions", userToken, java.util.Map.of("startedAt", "someday", "minutes", 10)).status);
        R list = call("GET", "/me/collection/" + entryId + "/sessions", userToken, null);
        assertEquals(2, list.body.size());
        assertTrue(list.body.get(0).path("started_at").asText().endsWith("Z"));
    }

    @Test @Order(32)
    void statusChangesUseOptimisticLocking() throws Exception {
        int version = call("GET", "/me/collection", userToken, null).body.get(0).path("row_version").asInt();
        R done = call("PATCH", "/me/collection/" + entryId, userToken, java.util.Map.of("statusId", 3, "expectedVersion", version));
        assertEquals(200, done.status, done.body.toString());
        assertEquals("Completed", done.s("status"));
        assertFalse(done.body.path("completed_at").isNull());
        R stale = call("PATCH", "/me/collection/" + entryId, userToken, java.util.Map.of("statusId", 2, "expectedVersion", version));
        assertEquals(409, stale.status);
        assertTrue(stale.body.path("error").path("message").asText().contains("changed since you loaded it"));
        assertEquals(400, call("PATCH", "/me/collection/" + entryId, userToken, java.util.Map.of("statusId", 99)).status);
    }

    @Test @Order(33)
    void achievementsUnlockAndStayConsistent() throws Exception {
        R list = call("GET", "/me/collection/" + entryId + "/achievements", userToken, null);
        assertEquals(5, list.body.size());
        int first = list.body.get(0).path("achievement_id").asInt();
        int second = list.body.get(1).path("achievement_id").asInt();
        R unlocked = call("PUT", "/me/collection/" + entryId + "/achievements/" + first, userToken, java.util.Map.of("progress", 100));
        assertTrue(unlocked.body.path("is_unlocked").asBoolean());
        assertFalse(unlocked.body.path("unlocked_at").isNull());
        R partial = call("PUT", "/me/collection/" + entryId + "/achievements/" + second, userToken, java.util.Map.of("progress", 55.5));
        assertFalse(partial.body.path("is_unlocked").asBoolean());
        assertEquals(55.5, partial.body.path("progress").asDouble());
        assertTrue(partial.body.path("unlocked_at").isNull());
        assertEquals(400, call("PUT", "/me/collection/" + entryId + "/achievements/" + second, userToken, java.util.Map.of("progress", 150)).status);
        int foreign = call("GET", "/catalog/games?q=Minecraft", null, null).body.path("items").get(0).path("game_id").asInt();
        int foreignAch = call("GET", "/catalog/games/" + foreign, null, null).body.path("achievements").get(0).path("achievement_id").asInt();
        R bad = call("PUT", "/me/collection/" + entryId + "/achievements/" + foreignAch, userToken, java.util.Map.of("progress", 10));
        assertEquals(400, bad.status);
        assertTrue(bad.body.path("error").path("message").asText().contains("different game"));
    }

    @Test @Order(34)
    void ratingsCreateUpdateConflictDelete() throws Exception {
        R created = call("PUT", "/me/ratings/" + eldenRingId, userToken, java.util.Map.of("rating", 9, "review", "Great"));
        assertEquals(200, created.status, created.body.toString());
        int v = created.body.path("row_version").asInt();
        R updated = call("PUT", "/me/ratings/" + eldenRingId, userToken, java.util.Map.of("rating", 10, "review", "Better", "expectedVersion", v));
        assertEquals(10, updated.body.path("rating").asInt());
        assertEquals(409, call("PUT", "/me/ratings/" + eldenRingId, userToken, java.util.Map.of("rating", 7, "expectedVersion", v)).status);
        assertEquals(400, call("PUT", "/me/ratings/" + eldenRingId, userToken, java.util.Map.of("rating", 11)).status);
        assertEquals(1, call("GET", "/me/ratings", userToken, null).body.size());
        R detail = call("GET", "/catalog/games/" + eldenRingId, null, null);
        boolean seen = false;
        for (JsonNode rv : detail.body.path("reviews")) if (rv.path("username").asText().equals(user)) seen = true;
        assertTrue(seen);
        assertEquals(204, call("DELETE", "/me/ratings/" + eldenRingId, userToken, null).status);
        assertEquals(0, call("GET", "/me/ratings", userToken, null).body.size());
        assertEquals(404, call("DELETE", "/me/ratings/" + eldenRingId, userToken, null).status);
    }

    @Test @Order(35)
    void dashboardReflectsTheCollection() throws Exception {
        R d = call("GET", "/me/dashboard", userToken, null);
        JsonNode s = d.body.path("summary");
        assertEquals(1, s.path("games_owned").asInt());
        assertEquals(1, s.path("completed_games").asInt());
        assertEquals(100.0, s.path("completion_pct").asDouble());
        assertEquals(2.0, s.path("total_playtime_hours").asDouble());
        assertEquals(25, s.path("achievement_points").asInt());
        assertEquals(1, d.body.path("recentUnlocks").size());
        assertEquals(49.99, s.path("total_spent").asDouble());
    }

    @Test @Order(36)
    void usersCannotTouchEachOthersData() throws Exception {
        String other = login("meera_s", DEMO_PW);
        assertEquals(404, call("GET", "/me/collection/" + entryId + "/sessions", other, null).status);
        assertEquals(404, call("GET", "/me/collection/" + entryId + "/achievements", other, null).status);
        assertEquals(404, call("PATCH", "/me/collection/" + entryId, other, java.util.Map.of("statusId", 5)).status);
        assertEquals(404, call("DELETE", "/me/collection/" + entryId, other, null).status);
        assertEquals(404, call("POST", "/me/collection/" + entryId + "/sessions", other, java.util.Map.of("startedAt", "2026-10-20T18:00", "minutes", 5)).status);
        assertEquals(404, call("PUT", "/me/collection/" + entryId + "/achievements/1", other, java.util.Map.of("progress", 5)).status);
    }

    @Test @Order(37)
    void removedEntryComesBackWithItsProgress() throws Exception {
        assertEquals(204, call("DELETE", "/me/collection/" + entryId, userToken, null).status);
        assertEquals(0, call("GET", "/me/collection", userToken, null).body.size());
        R again = call("POST", "/me/collection", userToken, java.util.Map.of("gameId", eldenRingId, "platformId", ps5));
        assertEquals(201, again.status);
        assertEquals(entryId, again.body.path("user_game_id").asInt());       // same row re-activated
        assertEquals(1, again.body.path("achievements_unlocked").asInt());    // progress kept
        assertEquals(2.0, again.body.path("playtime_hours").asDouble());      // sessions kept
    }

    // ---- administration -------------------------------------------------------------------------------
    @Test @Order(40)
    void adminAreaIsAdminOnly() throws Exception {
        assertEquals(403, call("GET", "/admin/audit", userToken, null).status);
        assertEquals(403, call("GET", "/admin/users", userToken, null).status);
        assertEquals(403, call("POST", "/admin/users/1/deactivate", userToken, null).status);
    }

    @Test @Order(41)
    void auditTrailRecordsWhoChangedWhat() throws Exception {
        String admin = login("aarav_k", DEMO_PW);
        R audit = call("GET", "/admin/audit?table=User_Game&changedBy=" + userId + "&limit=100", admin, null);
        assertEquals(200, audit.status);
        assertTrue(audit.body.size() >= 3, audit.body.toString());
        JsonNode firstInsert = null;
        for (JsonNode a : audit.body) if (a.path("action").asText().equals("INSERT")) firstInsert = a;
        assertNotNull(firstInsert);
        assertTrue(firstInsert.path("new_values").isObject());
        assertEquals(eldenRingId, firstInsert.path("new_values").path("game_id").asInt());
        assertFalse(audit.body.toString().contains("pbkdf2"));
        assertEquals(400, call("GET", "/admin/audit?limit=9999", admin, null).status);
        R users = call("GET", "/admin/users", admin, null);
        boolean found = false;
        for (JsonNode u : users.body) if (u.path("username").asText().equals(user)) found = true;
        assertTrue(found);
    }

    @Test @Order(42)
    void deactivateThenEraseAUser() throws Exception {
        String admin = login("aarav_k", DEMO_PW);
        assertEquals(400, call("POST", "/admin/users/" + 1 + "/deactivate", admin, null).status);   // not yourself
        assertEquals(404, call("POST", "/admin/users/99999/deactivate", admin, null).status);

        assertEquals(204, call("POST", "/admin/users/" + userId + "/deactivate", admin, null).status);
        assertEquals(401, call("GET", "/me/dashboard", userToken, null).status);                    // token dead at once
        assertEquals(401, call("POST", "/auth/login", null, java.util.Map.of("username", user, "password", PW)).status);

        assertEquals(400, call("POST", "/admin/users/" + userId + "/erase", admin, java.util.Map.of("confirmUsername", "wrong")).status);
        assertEquals(204, call("POST", "/admin/users/" + userId + "/erase", admin, java.util.Map.of("confirmUsername", user)).status);
        R trail = call("GET", "/admin/audit?table=User&recordPk=" + userId, admin, null);
        assertTrue(trail.body.size() >= 1);
        assertFalse(trail.body.toString().contains(user + "@example.com"));                          // personal data scrubbed
        assertTrue(trail.body.toString().contains("erased"));
    }

    @Test @Order(50)
    void logoutKillsTheToken() throws Exception {
        String t = login("ananya_d", DEMO_PW);
        assertEquals(200, call("GET", "/me/dashboard", t, null).status);
        assertEquals(204, call("POST", "/auth/logout", t, null).status);
        assertEquals(401, call("GET", "/me/dashboard", t, null).status);
    }
}
