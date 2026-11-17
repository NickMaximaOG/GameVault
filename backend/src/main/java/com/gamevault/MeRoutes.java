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
            return status == 0
                    ? db.query("SELECT * FROM v_collection WHERE user_id = ? "
                            + "ORDER BY FIELD(status_id, 2, 4, 1, 3, 5), title", c.user.id())
                    : db.query("SELECT * FROM v_collection WHERE user_id = ? AND status_id = ? ORDER BY title",
                            c.user.id(), status);
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
            return db.query("SELECT achievement_id, name, description, points, is_hidden, progress, is_unlocked, unlocked_at "
                    + "FROM v_achievement_progress WHERE user_game_id = ? AND user_id = ? "
                    + "ORDER BY is_unlocked DESC, points, achievement_id", id, c.user.id());
        });

        s.route("PUT", p + "/collection/{id}/achievements/{achievementId}", U, c -> {
            int id = c.pathInt("id");
            int achievementId = c.pathInt("achievementId");
            BigDecimal progress = Ctx.reqNum(c.body(), "progress", 0, 100);
            db.tx(c.user.id(), con -> Db.update(con, "CALL sp_set_achievement_progress(?, ?, ?, ?)",
                    c.user.id(), id, achievementId, progress));
            return db.one("SELECT achievement_id, name, description, points, is_hidden, progress, is_unlocked, unlocked_at "
                    + "FROM v_achievement_progress WHERE user_game_id = ? AND achievement_id = ? AND user_id = ?",
                    id, achievementId, c.user.id());
        });

        // ---- ratings ---------------------------------------------------------------------------
        s.route("GET", p + "/ratings", U, c -> db.query(
                "SELECT r.rating_id, r.game_id, g.title, r.rating, r.review_text, r.review_date, r.row_version "
                + "FROM v_rating r JOIN v_game g ON g.game_id = r.game_id WHERE r.user_id = ? "
                + "ORDER BY r.updated_at DESC", c.user.id()));

        s.route("PUT", p + "/ratings/{gameId}", U, c -> {
            int gameId = c.pathInt("gameId");
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
    }

    private static Map<String, Object> entry(Db db, int userId, long id) {
        Map<String, Object> e = db.one("SELECT * FROM v_collection WHERE user_game_id = ? AND user_id = ?", id, userId);
        if (e == null) throw ApiException.notFound("Collection entry not found");
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
