package com.gamevault;

import com.fasterxml.jackson.databind.JsonNode;
import java.time.Instant;
import java.util.LinkedHashMap;
import java.util.Map;

final class AuthRoutes {
    private AuthRoutes() {}

    static void register(Server s, Db db, AuthService auth) {
        String p = "/api/v1";

        s.route("GET", p + "/health", Server.Access.PUBLIC, c -> {
            boolean up = db.ping();
            Map<String, Object> m = new LinkedHashMap<>();
            m.put("status", up ? "UP" : "DOWN");
            m.put("database", up ? "UP" : "DOWN");
            m.put("time", Instant.now().toString());
            return new Server.Resp(up ? 200 : 503, m);
        });

        s.limitedRoute("POST", p + "/auth/register", c -> {
            JsonNode b = c.body();
            Map<String, Object> user = auth.register(
                    Ctx.reqStr(b, "username", 30), Ctx.reqStr(b, "email", 255), Ctx.reqStr(b, "password", 128));
            return new Server.Resp(201, user);
        });

        s.limitedRoute("POST", p + "/auth/login", c -> {
            JsonNode b = c.body();
            return auth.login(Ctx.reqStr(b, "username", 255), Ctx.reqStr(b, "password", 128), c.ip(), c.userAgent());
        });

        s.route("POST", p + "/auth/logout", Server.Access.USER, c -> {
            auth.logout(c.user);
            return new Server.Resp(204, null);
        });

        s.route("GET", p + "/auth/me", Server.Access.USER, c ->
                db.one("SELECT user_id, username, email, role, join_date, last_login_at FROM v_user WHERE user_id = ?",
                        c.user.id()));
    }
}
