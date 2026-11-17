package com.gamevault;

import java.time.Duration;

/** All settings come from environment variables; nothing secret is hard-coded. */
public record Config(
        int port,
        String dbUrl,
        String dbUser,
        String dbPassword,
        int dbPoolSize,
        String corsOrigin,
        Duration sessionTtl,
        int maxFailedLogins,
        Duration lockDuration,
        int authRatePerMinute,
        boolean trustProxy) {

    public static Config fromEnv() {
        String pw = env("DB_PASSWORD", null);
        if (pw == null || pw.isBlank()) {
            throw new IllegalStateException("DB_PASSWORD is not set (see .env.example)");
        }
        return new Config(
                Integer.parseInt(env("PORT", "8080")),
                env("DB_URL", "jdbc:mariadb://localhost:3306/gamevault_db"),
                env("DB_USER", "gv_app"),
                pw,
                Integer.parseInt(env("DB_POOL_SIZE", "10")),
                env("CORS_ORIGIN", "http://localhost:3000"),
                Duration.ofHours(Long.parseLong(env("SESSION_TTL_HOURS", "8"))),
                Integer.parseInt(env("MAX_FAILED_LOGINS", "5")),
                Duration.ofMinutes(Long.parseLong(env("LOCK_MINUTES", "15"))),
                Integer.parseInt(env("AUTH_RATE_PER_MINUTE", "20")),
                Boolean.parseBoolean(env("TRUST_PROXY", "false")));
    }

    private static String env(String name, String def) {
        String v = System.getenv(name);
        return (v == null || v.isEmpty()) ? def : v;
    }
}
