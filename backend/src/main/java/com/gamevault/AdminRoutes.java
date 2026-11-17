package com.gamevault;

import com.fasterxml.jackson.databind.JsonNode;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;

/** Administrator-only endpoints. The role is checked here AND inside the stored procedures. */
final class AdminRoutes {
    private AdminRoutes() {}

    static void register(Server s, Db db) {
        String p = "/api/v1/admin";
        Server.Access A = Server.Access.ADMIN;

        s.route("GET", p + "/users", A, c -> db.query(
                "SELECT u.user_id, u.username, u.email, u.role, u.join_date, u.last_login_at, "
                + "d.games_owned, d.total_playtime_hours FROM v_user u "
                + "JOIN v_user_dashboard d ON d.user_id = u.user_id ORDER BY u.user_id"));

        s.route("POST", p + "/users/{id}/deactivate", A, c -> {
            int id = c.pathInt("id");
            db.tx(c.user.id(), con -> Db.update(con, "CALL sp_deactivate_user(?, ?)", c.user.id(), id));
            return new Server.Resp(204, null);
        });

        // Permanent erasure: the caller must repeat the target's username as confirmation.
        s.route("POST", p + "/users/{id}/erase", A, c -> {
            int id = c.pathInt("id");
            String confirm = Ctx.reqStr(c.body(), "confirmUsername", 50);
            Map<String, Object> target = db.one("SELECT username FROM User WHERE user_id = ?", id);
            if (target == null) throw ApiException.notFound("User not found");
            if (!confirm.equals(target.get("username")))
                throw ApiException.badRequest("confirmUsername does not match the user's username");
            db.tx(c.user.id(), con -> Db.update(con, "CALL sp_purge_user(?, ?)", c.user.id(), id));
            return new Server.Resp(204, null);
        });

        s.route("GET", p + "/audit", A, c -> {
            StringBuilder sql = new StringBuilder(
                    "SELECT audit_id, table_name, record_pk, action, changed_by, changed_at, old_values, new_values "
                    + "FROM Audit_Log WHERE 1 = 1");
            List<Object> args = new ArrayList<>();
            String table = c.q("table");
            if (table != null && !table.isBlank()) { sql.append(" AND table_name = ?"); args.add(table); }
            String pk = c.q("recordPk");
            if (pk != null && !pk.isBlank()) { sql.append(" AND record_pk = ?"); args.add(pk); }
            int by = c.qInt("changedBy", 0, 0, Integer.MAX_VALUE);
            if (by > 0) { sql.append(" AND changed_by = ?"); args.add(by); }
            sql.append(" ORDER BY audit_id DESC LIMIT ?");
            args.add(c.qInt("limit", 50, 1, 200));
            List<Map<String, Object>> rows = db.query(sql.toString(), args.toArray());
            for (Map<String, Object> r : rows) {                       // JSON columns come back as text
                for (String k : new String[] {"old_values", "new_values"}) {
                    Object v = r.get(k);
                    if (v instanceof String str) r.put(k, Json.parse(str.getBytes(java.nio.charset.StandardCharsets.UTF_8)));
                }
            }
            return rows;
        });
    }
}
