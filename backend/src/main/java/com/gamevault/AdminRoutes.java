package com.gamevault;

import com.fasterxml.jackson.databind.JsonNode;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/** Administrator-only catalogue management, analytics and audit endpoints. */
final class AdminRoutes {
    private AdminRoutes() {}

    static void register(Server s, Db db) {
        String p = "/api/v1/admin";
        Server.Access A = Server.Access.ADMIN;

        s.route("GET", p + "/users", A, c -> db.query(
                "SELECT u.user_id, u.username, u.email, u.role, u.join_date, u.last_login_at, "
                + "d.games_owned, d.total_playtime_hours FROM v_user u "
                + "JOIN v_user_dashboard d ON d.user_id = u.user_id ORDER BY u.user_id"));

        s.route("GET", p + "/analytics", A, c -> {
            Map<String, Object> out = new LinkedHashMap<>();
            out.put("total_users", db.one("SELECT COUNT(*) AS n FROM v_user").get("n"));
            out.put("total_games", db.one("SELECT COUNT(*) AS n FROM Game WHERE deleted_at IS NULL").get("n"));
            out.put("total_playtime_hours", db.one("SELECT COALESCE(SUM(total_playtime_hours),0) AS n FROM v_user_dashboard").get("n"));
            out.put("achievements_unlocked", db.one("SELECT COUNT(*) AS n FROM v_achievement_progress WHERE is_unlocked = 1").get("n"));
            out.put("total_achievements", db.one("SELECT COUNT(*) AS n FROM Achievement").get("n"));
            out.put("popular_games", db.query("SELECT g.title, COUNT(DISTINCT ug.user_id) AS players "
                    + "FROM v_user_game ug JOIN v_game g ON g.game_id = ug.game_id "
                    + "GROUP BY g.game_id, g.title ORDER BY players DESC, g.title LIMIT 5"));
            out.put("playtime_leaders", db.query("SELECT username, total_playtime_hours AS hours FROM v_user_dashboard "
                    + "ORDER BY total_playtime_hours DESC, username LIMIT 5"));
            out.put("top_achievements", db.query("SELECT a.name, g.title, COUNT(ap.user_id) AS unlocks "
                    + "FROM Achievement a JOIN Game g ON g.game_id = a.game_id "
                    + "LEFT JOIN v_achievement_progress ap ON ap.achievement_id = a.achievement_id AND ap.is_unlocked = 1 "
                    + "GROUP BY a.achievement_id, a.name, g.title ORDER BY unlocks DESC, a.name LIMIT 5"));
            return out;
        });

        // Create games through a single transaction so the game and all its metadata are atomic.
        s.route("POST", p + "/games", A, c -> {
            JsonNode b = c.body();
            String title = Ctx.reqStr(b, "title", 150);
            String description = Ctx.optStr(b, "description", 10000);
            String cover = Ctx.optStr(b, "coverImage", 500);
            String release = Ctx.optDate(b, "releaseDate");
            Integer developer = Ctx.optInt(b, "developerId");
            Integer publisher = Ctx.optInt(b, "publisherId");
            Integer ageRating = Ctx.optInt(b, "ageRatingId");
            boolean upcoming = b.path("upcoming").asBoolean(false);
            List<Integer> platforms = intArray(b.get("platformIds"), "platformIds", 20);
            List<Integer> genres = intArray(b.get("genreIds"), "genreIds", 20);
            if (platforms.isEmpty()) throw ApiException.badRequest("Select at least one platform");
            List<String> screenshots = stringArray(b.get("screenshots"), "screenshots", 8, 500);
            JsonNode ach = b.get("achievements");
            long id = db.tx(c.user.id(), con -> {
                long gameId = Db.insert(con, "INSERT INTO Game (title, release_date, description, cover_image, is_upcoming, developer_id, publisher_id) VALUES (?, ?, ?, ?, ?, ?, ?)",
                        title, release, description, cover, upcoming ? 1 : 0, developer, publisher);
                for (int platform : platforms) Db.update(con, "INSERT INTO Game_Platform (game_id, platform_id) VALUES (?, ?)", gameId, platform);
                for (int genre : genres) Db.update(con, "INSERT INTO Game_Genre (game_id, genre_id) VALUES (?, ?)", gameId, genre);
                if (ageRating != null) {
                    Map<String, Object> ar = Db.query(con, "SELECT rating_authority FROM Age_Rating WHERE age_rating_id = ?", ageRating).stream().findFirst().orElse(null);
                    if (ar == null) throw ApiException.badRequest("Unknown age rating");
                    Db.update(con, "INSERT INTO Game_Age_Rating (game_id, rating_authority, age_rating_id) VALUES (?, ?, ?)", gameId, ar.get("rating_authority"), ageRating);
                }
                for (int i = 0; i < screenshots.size(); i++) Db.update(con, "INSERT INTO Game_Screenshot (game_id, image_url, sort_order) VALUES (?, ?, ?)", gameId, screenshots.get(i), i);
                if (ach != null && ach.isArray()) {
                    if (ach.size() > 100) throw ApiException.badRequest("A game can have at most 100 achievements");
                    for (JsonNode a : ach) {
                        String name = Ctx.reqStr(a, "name", 120);
                        String desc = Ctx.optStr(a, "description", 500);
                        int points = a.path("points").asInt(10);
                        String rarity = rarity(a.path("rarity").asText("COMMON"));
                        if (points < 1 || points > 500) throw ApiException.badRequest("Achievement points must be between 1 and 500");
                        Db.insert(con, "INSERT INTO Achievement (game_id, name, description, points, is_hidden, rarity) VALUES (?, ?, ?, ?, ?, ?)",
                                gameId, name, desc, points, a.path("hidden").asBoolean(false) ? 1 : 0, rarity);
                    }
                }
                return gameId;
            });
            return new Server.Resp(201, Map.of("gameId", id, "message", "Game created"));
        });

        s.route("PUT", p + "/games/{id}", A, c -> {
            int id = c.pathInt("id");
            JsonNode b = c.body();
            String title = Ctx.reqStr(b, "title", 150);
            String description = Ctx.optStr(b, "description", 10000);
            String cover = Ctx.optStr(b, "coverImage", 500);
            String release = Ctx.optDate(b, "releaseDate");
            boolean upcoming = b.path("upcoming").asBoolean(false);
            Integer developer = Ctx.optInt(b, "developerId");
            Integer publisher = Ctx.optInt(b, "publisherId");
            Integer ageRating = Ctx.optInt(b, "ageRatingId");
            List<Integer> platforms = intArray(b.get("platformIds"), "platformIds", 20);
            List<Integer> genres = intArray(b.get("genreIds"), "genreIds", 20);
            List<String> screenshots = stringArray(b.get("screenshots"), "screenshots", 8, 500);
            db.tx(c.user.id(), con -> {
                if (Db.query(con, "SELECT game_id FROM Game WHERE game_id = ? AND deleted_at IS NULL", id).isEmpty())
                    throw ApiException.notFound("Game not found");
                Db.update(con, "UPDATE Game SET title = ?, description = ?, cover_image = ?, release_date = ?, is_upcoming = ?, developer_id = ?, publisher_id = ? WHERE game_id = ? AND deleted_at IS NULL",
                        title, description, cover, release, upcoming ? 1 : 0, developer, publisher, id);
                // Keep platform mappings already referenced by collection entries; add newly selected platforms.
                for (int platform : platforms) Db.update(con, "INSERT INTO Game_Platform (game_id, platform_id) VALUES (?, ?) ON DUPLICATE KEY UPDATE platform_release_date = platform_release_date", id, platform);
                Db.update(con, "DELETE FROM Game_Genre WHERE game_id = ?", id);
                for (int genre : genres) Db.update(con, "INSERT INTO Game_Genre (game_id, genre_id) VALUES (?, ?)", id, genre);
                Db.update(con, "DELETE FROM Game_Age_Rating WHERE game_id = ?", id);
                if (ageRating != null) {
                    Map<String, Object> ar = Db.query(con, "SELECT rating_authority FROM Age_Rating WHERE age_rating_id = ?", ageRating).stream().findFirst().orElse(null);
                    if (ar == null) throw ApiException.badRequest("Unknown age rating");
                    Db.update(con, "INSERT INTO Game_Age_Rating (game_id, rating_authority, age_rating_id) VALUES (?, ?, ?)", id, ar.get("rating_authority"), ageRating);
                }
                Db.update(con, "DELETE FROM Game_Screenshot WHERE game_id = ?", id);
                for (int i = 0; i < screenshots.size(); i++) Db.update(con, "INSERT INTO Game_Screenshot (game_id, image_url, sort_order) VALUES (?, ?, ?)", id, screenshots.get(i), i);
                return null;
            });
            return db.one("SELECT game_id, title, release_date, description, cover_image, is_upcoming FROM Game WHERE game_id = ?", id);
        });

        s.route("POST", p + "/games/{id}/achievements", A, c -> {
            int gameId = c.pathInt("id");
            JsonNode b = c.body();
            String name = Ctx.reqStr(b, "name", 120);
            String desc = Ctx.optStr(b, "description", 500);
            int points = Ctx.reqInt(b, "points");
            String rarity = rarity(b.path("rarity").asText("COMMON"));
            if (points < 1 || points > 500) throw ApiException.badRequest("Achievement points must be between 1 and 500");
            long id = db.tx(c.user.id(), con -> Db.insert(con, "INSERT INTO Achievement (game_id, name, description, points, is_hidden, rarity) VALUES (?, ?, ?, ?, ?, ?)",
                    gameId, name, desc, points, b.path("hidden").asBoolean(false) ? 1 : 0, rarity));
            return new Server.Resp(201, db.one("SELECT achievement_id, game_id, name, description, points, is_hidden, rarity FROM Achievement WHERE achievement_id = ?", id));
        });

        s.route("PUT", p + "/achievements/{id}", A, c -> {
            int id = c.pathInt("id"); JsonNode b = c.body();
            String name = Ctx.reqStr(b, "name", 120); String desc = Ctx.optStr(b, "description", 500);
            int points = Ctx.reqInt(b, "points");
            String rarity = rarity(b.path("rarity").asText("COMMON"));
            if (points < 1 || points > 500) throw ApiException.badRequest("Achievement points must be between 1 and 500");
            db.tx(c.user.id(), con -> {
                if (Db.query(con, "SELECT achievement_id FROM Achievement WHERE achievement_id = ?", id).isEmpty())
                    throw ApiException.notFound("Achievement not found");
                Db.update(con, "UPDATE Achievement SET name = ?, description = ?, points = ?, is_hidden = ?, rarity = ? WHERE achievement_id = ?",
                        name, desc, points, b.path("hidden").asBoolean(false) ? 1 : 0, rarity, id);
                return null;
            });
            return db.one("SELECT achievement_id, game_id, name, description, points, is_hidden, rarity FROM Achievement WHERE achievement_id = ?", id);
        });

        s.route("POST", p + "/users/{id}/deactivate", A, c -> {
            int id = c.pathInt("id");
            db.tx(c.user.id(), con -> Db.update(con, "CALL sp_deactivate_user(?, ?)", c.user.id(), id));
            return new Server.Resp(204, null);
        });

        s.route("POST", p + "/users/{id}/erase", A, c -> {
            int id = c.pathInt("id");
            String confirm = Ctx.reqStr(c.body(), "confirmUsername", 50);
            Map<String, Object> target = db.one("SELECT username FROM User WHERE user_id = ?", id);
            if (target == null) throw ApiException.notFound("User not found");
            if (!confirm.equals(target.get("username"))) throw ApiException.badRequest("confirmUsername does not match the user's username");
            db.tx(c.user.id(), con -> Db.update(con, "CALL sp_purge_user(?, ?)", c.user.id(), id));
            return new Server.Resp(204, null);
        });

        s.route("GET", p + "/audit", A, c -> {
            StringBuilder sql = new StringBuilder("SELECT audit_id, table_name, record_pk, action, changed_by, changed_at, old_values, new_values FROM Audit_Log WHERE 1 = 1");
            List<Object> args = new ArrayList<>();
            String table = c.q("table"); if (table != null && !table.isBlank()) { sql.append(" AND table_name = ?"); args.add(table); }
            String pk = c.q("recordPk"); if (pk != null && !pk.isBlank()) { sql.append(" AND record_pk = ?"); args.add(pk); }
            int by = c.qInt("changedBy", 0, 0, Integer.MAX_VALUE); if (by > 0) { sql.append(" AND changed_by = ?"); args.add(by); }
            sql.append(" ORDER BY audit_id DESC LIMIT ?"); args.add(c.qInt("limit", 50, 1, 200));
            List<Map<String, Object>> rows = db.query(sql.toString(), args.toArray());
            for (Map<String, Object> r : rows) for (String k : new String[] {"old_values", "new_values"}) {
                Object v = r.get(k); if (v instanceof String str) r.put(k, Json.parse(str.getBytes(java.nio.charset.StandardCharsets.UTF_8)));
            }
            return rows;
        });
    }

    private static String rarity(String value) {
        String r = value == null ? "COMMON" : value.toUpperCase(java.util.Locale.ROOT);
        if (!List.of("COMMON", "RARE", "EPIC", "LEGENDARY").contains(r)) throw ApiException.badRequest("Unknown achievement rarity");
        return r;
    }
    private static List<Integer> intArray(JsonNode n, String field, int max) {
        List<Integer> out = new ArrayList<>(); if (n == null || n.isNull()) return out;
        if (!n.isArray() || n.size() > max) throw ApiException.badRequest("'" + field + "' must be an array with at most " + max + " values");
        for (JsonNode v : n) { if (!v.canConvertToInt() || !v.isIntegralNumber() || v.asInt() < 1) throw ApiException.badRequest("'" + field + "' contains an invalid id"); out.add(v.asInt()); }
        return out;
    }
    private static List<String> stringArray(JsonNode n, String field, int max, int maxLen) {
        List<String> out = new ArrayList<>(); if (n == null || n.isNull()) return out;
        if (!n.isArray() || n.size() > max) throw ApiException.badRequest("'" + field + "' must be an array with at most " + max + " values");
        for (JsonNode v : n) { if (!v.isTextual() || v.asText().isBlank() || v.asText().length() > maxLen) throw ApiException.badRequest("'" + field + "' contains an invalid URL"); out.add(v.asText()); }
        return out;
    }
}
