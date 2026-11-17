package com.gamevault;

import com.fasterxml.jackson.databind.JsonNode;
import java.math.BigDecimal;
import java.time.LocalDateTime;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.time.format.DateTimeFormatter;
import java.time.format.DateTimeParseException;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/** Everything a signed-in user does with their own data. All writes go through stored procedures. */
final class MeRoutes {
    private MeRoutes() {}

    private static final DateTimeFormatter SQL_DT = DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss");

    static void register(Server s, Db db) {
        String p = "/api/v1/me";
        Server.Access U = Server.Access.USER;

        // ---- collection --------------------------------------------------------------------
        s.route("GET", p + "/collection", U, c -> {
            int status = c.qInt("statusId", 0, 0, 100);
            String ageGuard = " AND NOT EXISTS (SELECT 1 FROM Game_Age_Rating gar JOIN Age_Rating ar ON ar.age_rating_id = gar.age_rating_id "
                    + "WHERE gar.game_id = v_collection.game_id AND ar.minimum_age > COALESCE((SELECT TIMESTAMPDIFF(YEAR, u.date_of_birth, CURDATE()) FROM User u WHERE u.user_id = ?), 99))";
            return status == 0
                    ? db.query("SELECT * FROM v_collection WHERE user_id = ? " + ageGuard + " ORDER BY FIELD(status_id, 2, 4, 1, 3, 5), title", c.user.id(), c.user.id())
                    : db.query("SELECT * FROM v_collection WHERE user_id = ? AND status_id = ? " + ageGuard + " ORDER BY title", c.user.id(), status, c.user.id());
        });

        s.route("POST", p + "/collection", U, c -> {
            JsonNode b = c.body();
            int gameId = Ctx.reqInt(b, "gameId");
            int platformId = Ctx.reqInt(b, "platformId");
            String purchaseDate = Ctx.optDate(b, "purchaseDate");
            BigDecimal price = Ctx.optNum(b, "price", 0, 100_000);
            Integer statusId = Ctx.optInt(b, "statusId");
            long id = db.tx(c.user.id(), con -> {
                Db.update(con, "CALL sp_add_to_collection(?, ?, ?, ?, ?, ?, @gv_out)",
                        c.user.id(), gameId, platformId, purchaseDate, price, statusId);
                return Db.scalarLong(con, "SELECT @gv_out");
            });
            return new Server.Resp(201, entry(db, c.user.id(), id));
        });

        s.route("PATCH", p + "/collection/{id}", U, c -> {
            int id = c.pathInt("id");
            JsonNode b = c.body();
            int statusId = Ctx.reqInt(b, "statusId");
            Integer expected = Ctx.optInt(b, "expectedVersion");
            db.tx(c.user.id(), con -> Db.update(con, "CALL sp_update_collection_entry(?, ?, ?, ?)",
                    c.user.id(), id, statusId, expected));
            return entry(db, c.user.id(), id);
        });

        s.route("DELETE", p + "/collection/{id}", U, c -> {
            int id = c.pathInt("id");
            db.tx(c.user.id(), con -> Db.update(con, "CALL sp_remove_from_collection(?, ?)", c.user.id(), id));
            return new Server.Resp(204, null);
        });

        // ---- play sessions -------------------------------------------------------------------
        s.route("GET", p + "/collection/{id}/sessions", U, c -> {
            int id = c.pathInt("id");
            entry(db, c.user.id(), id);                                   // 404 unless it is yours
            return db.query("SELECT session_id, started_at, duration_minutes, note FROM Playtime_Session "
                    + "WHERE user_game_id = ? ORDER BY started_at DESC LIMIT 100", id);
        });

        s.route("POST", p + "/collection/{id}/sessions", U, c -> {
            int id = c.pathInt("id");
            entry(db, c.user.id(), id);
            JsonNode b = c.body();
            String startedAt = utcDateTime(Ctx.reqStr(b, "startedAt", 40));
            int minutes = Ctx.reqInt(b, "minutes");
            String note = Ctx.optStr(b, "note", 255);
            long sessionId = db.tx(c.user.id(), con -> {
                Db.update(con, "CALL sp_log_playtime(?, ?, ?, ?, ?, @gv_out)", c.user.id(), id, startedAt, minutes, note);
                return Db.scalarLong(con, "SELECT @gv_out");
            });
            Map<String, Object> out = new LinkedHashMap<>();
            out.put("sessionId", sessionId);
            out.put("entry", entry(db, c.user.id(), id));
            return new Server.Resp(201, out);
        });

        // ---- achievements ----------------------------------------------------------------------
        s.route("GET", p + "/collection/{id}/achievements", U, c -> {
            int id = c.pathInt("id");
            entry(db, c.user.id(), id);
            return db.query("SELECT achievement_id, name, description, points, is_hidden, rarity, progress, is_unlocked, unlocked_at "
                    + "FROM v_achievement_progress WHERE user_game_id = ? AND user_id = ? "
                    + "ORDER BY is_unlocked DESC, points, achievement_id", id, c.user.id());
        });

        s.route("PUT", p + "/collection/{id}/achievements/{achievementId}", U, c -> {
            int id = c.pathInt("id");
            entry(db, c.user.id(), id);
            int achievementId = c.pathInt("achievementId");
            BigDecimal progress = Ctx.reqNum(c.body(), "progress", 0, 100);
            Map<String, Object> before = db.one("SELECT is_unlocked FROM v_achievement_progress WHERE user_game_id = ? AND achievement_id = ? AND user_id = ?", id, achievementId, c.user.id());
            db.tx(c.user.id(), con -> Db.update(con, "CALL sp_set_achievement_progress(?, ?, ?, ?)",
                    c.user.id(), id, achievementId, progress));
            Map<String, Object> result = db.one("SELECT achievement_id, name, description, points, is_hidden, rarity, progress, is_unlocked, unlocked_at "
                    + "FROM v_achievement_progress WHERE user_game_id = ? AND achievement_id = ? AND user_id = ?",
                    id, achievementId, c.user.id());
            if (before != null && ((Number) before.get("is_unlocked")).intValue() == 0 && ((Number) result.get("is_unlocked")).intValue() == 1) {
                Map<String, Object> game = db.one("SELECT g.title FROM v_user_game ug JOIN v_game g ON g.game_id = ug.game_id WHERE ug.user_game_id = ?", id);
                db.insert("INSERT INTO Notification (recipient_id, actor_id, notification_type, message) VALUES (?, ?, 'ACHIEVEMENT_UNLOCK', ?)",
                        c.user.id(), c.user.id(), "Achievement unlocked in " + game.get("title"));
            }
            return result;
        });

        // ---- ratings ---------------------------------------------------------------------------
        s.route("GET", p + "/ratings", U, c -> db.query(
                "SELECT r.rating_id, r.game_id, g.title, r.rating, r.review_text, r.review_date, r.row_version "
                + "FROM v_rating r JOIN v_game g ON g.game_id = r.game_id WHERE r.user_id = ? "
                + "ORDER BY r.updated_at DESC", c.user.id()));

        s.route("PUT", p + "/ratings/{gameId}", U, c -> {
            int gameId = c.pathInt("gameId");
            ensureGameAccessible(db, c.user.id(), gameId);
            JsonNode b = c.body();
            int rating = Ctx.reqInt(b, "rating");
            String review = Ctx.optStr(b, "review", 5000);
            Integer expected = Ctx.optInt(b, "expectedVersion");
            db.tx(c.user.id(), con -> {
                Db.update(con, "CALL sp_upsert_rating(?, ?, ?, ?, ?, @gv_out)", c.user.id(), gameId, rating, review, expected);
                return null;
            });
            return db.one("SELECT r.rating_id, r.game_id, g.title, r.rating, r.review_text, r.review_date, r.row_version "
                    + "FROM v_rating r JOIN v_game g ON g.game_id = r.game_id WHERE r.user_id = ? AND r.game_id = ?",
                    c.user.id(), gameId);
        });

        s.route("DELETE", p + "/ratings/{gameId}", U, c -> {
            int gameId = c.pathInt("gameId");
            db.tx(c.user.id(), con -> Db.update(con, "CALL sp_delete_rating(?, ?)", c.user.id(), gameId));
            return new Server.Resp(204, null);
        });

        // ---- dashboard -------------------------------------------------------------------------
        s.route("GET", p + "/dashboard", U, c -> {
            int uid = c.user.id();
            Map<String, Object> out = new LinkedHashMap<>();
            out.put("summary", db.one("SELECT * FROM v_user_dashboard WHERE user_id = ?", uid));
            out.put("byStatus", db.query("SELECT status, COUNT(*) AS games, SUM(playtime_hours) AS hours "
                    + "FROM v_user_game WHERE user_id = ? GROUP BY status_id, status ORDER BY status_id", uid));
            out.put("topGames", db.query("SELECT title, platform, playtime_hours FROM v_collection "
                    + "WHERE user_id = ? ORDER BY playtime_hours DESC, title LIMIT 5", uid));
            out.put("recentUnlocks", db.query(
                    "SELECT ap.name, ap.points, ap.unlocked_at, g.title AS game FROM v_achievement_progress ap "
                    + "JOIN v_user_game ug ON ug.user_game_id = ap.user_game_id "
                    + "JOIN v_game g ON g.game_id = ug.game_id "
                    + "WHERE ap.user_id = ? AND ap.is_unlocked = 1 ORDER BY ap.unlocked_at DESC LIMIT 5", uid));
            return out;
        });

        // ---- friends and shared progress -------------------------------------------------------
        s.route("GET", p + "/friends", U, c -> {
            int uid = c.user.id();
            List<Map<String, Object>> friends = db.query("SELECT u.user_id, u.username, d.games_owned, d.total_playtime_hours, d.achievements_unlocked, d.achievement_points "
                    + "FROM Friendship f JOIN User u ON u.user_id = IF(f.requester_id = ?, f.recipient_id, f.requester_id) "
                    + "JOIN v_user_dashboard d ON d.user_id = u.user_id WHERE f.status = 'ACCEPTED' "
                    + "AND (f.requester_id = ? OR f.recipient_id = ?) ORDER BY u.username", uid, uid, uid);
            for (Map<String, Object> friend : friends) {
                int fid = ((Number) friend.get("user_id")).intValue();
                friend.put("recent_games", db.query("SELECT g.title, ug.playtime_hours, ug.status, "
                        + "(SELECT MAX(ps.started_at) FROM Playtime_Session ps WHERE ps.user_game_id = ug.user_game_id) AS last_played_at, "
                        + "COALESCE(ac.total,0) AS achievements_total, COALESCE(ua.unlocked,0) AS achievements_unlocked "
                        + "FROM v_user_game ug JOIN v_game g ON g.game_id = ug.game_id "
                        + "LEFT JOIN (SELECT game_id, COUNT(*) AS total FROM Achievement GROUP BY game_id) ac ON ac.game_id = ug.game_id "
                        + "LEFT JOIN (SELECT user_game_id, SUM(is_unlocked) AS unlocked FROM v_achievement_progress GROUP BY user_game_id) ua ON ua.user_game_id = ug.user_game_id "
                        + "WHERE ug.user_id = ? AND EXISTS (SELECT 1 FROM Playtime_Session ps WHERE ps.user_game_id = ug.user_game_id) "
                        + "ORDER BY last_played_at DESC LIMIT 4", fid));
            }
            List<Map<String, Object>> requests = db.query("SELECT f.friendship_id, u.user_id, u.username, f.created_at "
                    + "FROM Friendship f JOIN User u ON u.user_id = f.requester_id "
                    + "WHERE f.recipient_id = ? AND f.status = 'PENDING' ORDER BY f.created_at DESC", uid);
            Map<String, Object> out = new LinkedHashMap<>(); out.put("friends", friends); out.put("requests", requests); return out;
        });

        s.route("POST", p + "/friends/requests", U, c -> {
            String username = Ctx.reqStr(c.body(), "username", 50);
            Map<String, Object> target = db.one("SELECT user_id, username FROM User WHERE username = ? AND deleted_at IS NULL", username);
            if (target == null) throw ApiException.notFound("That player was not found");
            int friendId = ((Number) target.get("user_id")).intValue();
            if (friendId == c.user.id()) throw ApiException.badRequest("You cannot send a friend request to yourself");
            Map<String, Object> existing = db.one("SELECT friendship_id, status, requester_id, recipient_id FROM Friendship "
                    + "WHERE (requester_id = ? AND recipient_id = ?) OR (requester_id = ? AND recipient_id = ?) LIMIT 1",
                    c.user.id(), friendId, friendId, c.user.id());
            if (existing != null) {
                if ("ACCEPTED".equals(existing.get("status"))) throw ApiException.conflict("You are already friends");
                if (((Number) existing.get("requester_id")).intValue() == friendId) {
                    db.update("UPDATE Friendship SET status = 'ACCEPTED' WHERE friendship_id = ?", existing.get("friendship_id"));
                    db.insert("INSERT INTO Notification (recipient_id, actor_id, notification_type, message) VALUES (?, ?, 'FRIEND_ACCEPTED', ?)",
                            friendId, c.user.id(), c.user.username() + " accepted your friend request");
                    return Map.of("status", "ACCEPTED", "message", "Friend request accepted");
                }
                throw ApiException.conflict("A friend request is already pending");
            }
            db.insert("INSERT INTO Friendship (requester_id, recipient_id, status) VALUES (?, ?, 'PENDING')", c.user.id(), friendId);
            db.insert("INSERT INTO Notification (recipient_id, actor_id, notification_type, message) VALUES (?, ?, 'FRIEND_REQUEST', ?)",
                    friendId, c.user.id(), c.user.username() + " sent you a friend request");
            return new Server.Resp(201, Map.of("status", "PENDING", "message", "Friend request sent"));
        });

        s.route("POST", p + "/friends/requests/{id}/accept", U, c -> {
            int id = c.pathInt("id");
            Map<String, Object> request = db.one("SELECT requester_id FROM Friendship WHERE friendship_id = ? AND recipient_id = ? AND status = 'PENDING'", id, c.user.id());
            if (request == null) throw ApiException.notFound("Friend request not found");
            int requester = ((Number) request.get("requester_id")).intValue();
            db.update("UPDATE Friendship SET status = 'ACCEPTED' WHERE friendship_id = ?", id);
            db.insert("INSERT INTO Notification (recipient_id, actor_id, notification_type, message) VALUES (?, ?, 'FRIEND_ACCEPTED', ?)",
                    requester, c.user.id(), c.user.username() + " accepted your friend request");
            return Map.of("status", "ACCEPTED");
        });

        // ---- upcoming games wishlist ------------------------------------------------------------
        s.route("GET", p + "/wishlist", U, c -> db.query("SELECT w.wishlist_id, w.created_at, g.game_id, g.title, g.release_date, g.description, g.cover_image, g.is_upcoming "
                + "FROM Wishlist w JOIN v_game g ON g.game_id = w.game_id WHERE w.user_id = ? "
                + "AND NOT EXISTS (SELECT 1 FROM Game_Age_Rating gar JOIN Age_Rating ar ON ar.age_rating_id = gar.age_rating_id "
                + "WHERE gar.game_id = g.game_id AND ar.minimum_age > COALESCE((SELECT TIMESTAMPDIFF(YEAR, u.date_of_birth, CURDATE()) FROM User u WHERE u.user_id = ?),99)) "
                + "ORDER BY g.release_date, g.title", c.user.id(), c.user.id()));
        s.route("POST", p + "/wishlist", U, c -> {
            int gameId = Ctx.reqInt(c.body(), "gameId");
            Map<String, Object> game = db.one("SELECT g.game_id, g.title, g.is_upcoming, COALESCE(MAX(ar.minimum_age),0) AS min_age "
                    + "FROM Game g LEFT JOIN Game_Age_Rating gar ON gar.game_id = g.game_id LEFT JOIN Age_Rating ar ON ar.age_rating_id = gar.age_rating_id "
                    + "WHERE g.game_id = ? AND g.deleted_at IS NULL GROUP BY g.game_id, g.title, g.is_upcoming", gameId);
            if (game == null) throw ApiException.notFound("Game not found");
            if (((Number) game.get("is_upcoming")).intValue() != 1) throw ApiException.badRequest("Only upcoming games can be wishlisted");
            Map<String, Object> age = db.one("SELECT COALESCE(TIMESTAMPDIFF(YEAR, date_of_birth, CURDATE()),99) AS age FROM User WHERE user_id = ?", c.user.id());
            if (((Number) age.get("age")).intValue() < ((Number) game.get("min_age")).intValue()) throw ApiException.forbidden("Age restricted: this upcoming game is not available for your age profile.");
            db.insert("INSERT INTO Wishlist (user_id, game_id) VALUES (?, ?) ON DUPLICATE KEY UPDATE created_at = created_at", c.user.id(), gameId);
            return new Server.Resp(201, Map.of("status", "WISHLISTED", "gameId", gameId));
        });
        s.route("DELETE", p + "/wishlist/{id}", U, c -> {
            int id = c.pathInt("id"); db.update("DELETE FROM Wishlist WHERE wishlist_id = ? AND user_id = ?", id, c.user.id()); return new Server.Resp(204, null);
        });

        // ---- notifications ----------------------------------------------------------------------
        s.route("GET", p + "/notifications", U, c -> db.query("SELECT notification_id, notification_type, message, is_read, created_at "
                + "FROM Notification WHERE recipient_id = ? ORDER BY created_at DESC LIMIT 100", c.user.id()));
        s.route("POST", p + "/notifications/{id}/read", U, c -> {
            int id = c.pathInt("id");
            db.update("UPDATE Notification SET is_read = 1 WHERE notification_id = ? AND recipient_id = ?", id, c.user.id());
            return Map.of("status", "READ");
        });
    }

    private static void ensureGameAccessible(Db db, int userId, int gameId) {
        Map<String, Object> age = db.one("SELECT COALESCE(TIMESTAMPDIFF(YEAR, date_of_birth, CURDATE()),99) AS age FROM User WHERE user_id = ?", userId);
        Map<String, Object> rating = db.one("SELECT MAX(ar.minimum_age) AS min_age FROM Game_Age_Rating gar JOIN Age_Rating ar ON ar.age_rating_id = gar.age_rating_id WHERE gar.game_id = ?", gameId);
        int userAge = age == null ? 99 : ((Number) age.get("age")).intValue();
        int minAge = rating == null || rating.get("min_age") == null ? 0 : ((Number) rating.get("min_age")).intValue();
        if (userAge < minAge) throw ApiException.forbidden("Age restricted: this game requires an age of " + minAge + " or above.");
    }

    private static Map<String, Object> entry(Db db, int userId, long id) {
        Map<String, Object> e = db.one("SELECT * FROM v_collection WHERE user_game_id = ? AND user_id = ?", id, userId);
        if (e == null) throw ApiException.notFound("Collection entry not found");
        ensureGameAccessible(db, userId, ((Number) e.get("game_id")).intValue());
        return e;
    }

    /** Accepts 2026-10-20T18:30, 2026-10-20T18:30:00 or an ISO instant/offset; returns UTC 'yyyy-MM-dd HH:mm:ss'. */
    static String utcDateTime(String s) {
        try {
            return OffsetDateTime.parse(s).withOffsetSameInstant(ZoneOffset.UTC).toLocalDateTime().format(SQL_DT);
        } catch (DateTimeParseException ignored) {
            try {
                return LocalDateTime.parse(s).format(SQL_DT);
            } catch (DateTimeParseException e) {
                throw ApiException.badRequest("'startedAt' must be a date and time like 2026-10-20T18:30");
            }
        }
    }
}
