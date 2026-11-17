package com.gamevault;

import java.security.SecureRandom;
import java.util.Base64;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Optional;
import java.util.regex.Pattern;

/**
 * Registration, login, lockout and session tokens.
 *  - Passwords: PBKDF2-HMAC-SHA256, per-user salt, upgraded at login when the iteration count rises.
 *  - Tokens: 256 random bits, only their SHA-256 is stored, so a database leak does not leak sessions.
 *  - Lockout: N failed logins lock the account for a while (counters live in the User table).
 *  - Unknown users still cost one hash computation, so timing does not reveal which accounts exist.
 */
public final class AuthService {
    private static final Pattern USERNAME = Pattern.compile("^[A-Za-z0-9_]{3,30}$");
    private static final Pattern EMAIL = Pattern.compile("^[^@\\s]{1,64}@[^@\\s]{1,190}\\.[^@\\s]{2,}$");
    private static final SecureRandom RANDOM = new SecureRandom();

    private final Db db;
    private final Config cfg;
    private final String dummyHash = PasswordHasher.hash("not-a-real-password");

    public AuthService(Db db, Config cfg) {
        this.db = db;
        this.cfg = cfg;
    }

    public Map<String, Object> register(String username, String email, String password) {
        if (!USERNAME.matcher(username).matches())
            throw ApiException.badRequest("Username must be 3-30 letters, digits or underscores");
        if (email.length() > 255 || !EMAIL.matcher(email).matches())
            throw ApiException.badRequest("Enter a valid e-mail address");
        validatePassword(password);
        long id;
        try {
            id = db.insert("INSERT INTO User (username, email, password_hash) VALUES (?, ?, ?)",
                    username, email.toLowerCase(), PasswordHasher.hash(password));
        } catch (ApiException e) {
            if (e.status == 409) throw ApiException.conflict("That username or e-mail is already registered");
            throw e;
        }
        return db.one("SELECT user_id, username, email, role, join_date FROM v_user WHERE user_id = ?", id);
    }

    static void validatePassword(String password) {
        if (password.length() < 10 || password.length() > 128)
            throw ApiException.badRequest("Password must be 10-128 characters");
        boolean letter = password.chars().anyMatch(Character::isLetter);
        boolean digit = password.chars().anyMatch(Character::isDigit);
        if (!letter || !digit) throw ApiException.badRequest("Password must contain letters and digits");
    }

    public Map<String, Object> login(String identifier, String password, String ip, String userAgent) {
        Map<String, Object> u = db.one(
                "SELECT user_id, username, password_hash, role_id, "
                + "(locked_until IS NOT NULL AND locked_until > UTC_TIMESTAMP()) AS is_locked "
                + "FROM User WHERE (username = ? OR email = ?) AND deleted_at IS NULL",
                identifier, identifier.toLowerCase());
        if (u == null) {
            PasswordHasher.verify(password, dummyHash);                // equalise timing
            throw ApiException.unauthorized("Invalid username or password");
        }
        int userId = ((Number) u.get("user_id")).intValue();
        if (truthy(u.get("is_locked")))
            throw new ApiException(429, "account_locked", "Too many failed attempts. Try again later.");

        String stored = (String) u.get("password_hash");
        if (!PasswordHasher.verify(password, stored)) {
            db.update("UPDATE User SET "
                    + "locked_until = IF(failed_login_count + 1 >= ?, DATE_ADD(UTC_TIMESTAMP(), INTERVAL ? SECOND), locked_until), "
                    + "failed_login_count = IF(failed_login_count + 1 >= ?, 0, failed_login_count + 1) "
                    + "WHERE user_id = ?",
                    cfg.maxFailedLogins(), cfg.lockDuration().toSeconds(), cfg.maxFailedLogins(), userId);
            throw ApiException.unauthorized("Invalid username or password");
        }

        db.update("UPDATE User SET failed_login_count = 0, locked_until = NULL, last_login_at = UTC_TIMESTAMP() "
                + "WHERE user_id = ?", userId);
        if (PasswordHasher.needsRehash(stored))
            db.update("UPDATE User SET password_hash = ? WHERE user_id = ?", PasswordHasher.hash(password), userId);

        byte[] raw = new byte[32];
        RANDOM.nextBytes(raw);
        String token = Base64.getUrlEncoder().withoutPadding().encodeToString(raw);
        long ttl = cfg.sessionTtl().toSeconds();
        db.insert("INSERT INTO Auth_Session (user_id, token_hash, expires_at, ip_address, user_agent) "
                + "VALUES (?, ?, DATE_ADD(UTC_TIMESTAMP(), INTERVAL ? SECOND), ?, ?)",
                userId, PasswordHasher.sha256Hex(token), ttl, ip, userAgent);

        Map<String, Object> role = db.one("SELECT name FROM Role WHERE role_id = ?", u.get("role_id"));
        Map<String, Object> user = new LinkedHashMap<>();
        user.put("id", userId);
        user.put("username", u.get("username"));
        user.put("role", role.get("name"));
        Map<String, Object> out = new LinkedHashMap<>();
        out.put("token", token);
        out.put("expiresInSeconds", ttl);
        out.put("user", user);
        return out;
    }

    public Optional<AuthUser> authenticate(String token) {
        if (token.isEmpty() || token.length() > 100) return Optional.empty();
        Map<String, Object> r = db.one(
                "SELECT s.session_id, u.user_id, u.username, ro.name AS role "
                + "FROM Auth_Session s JOIN User u ON u.user_id = s.user_id JOIN Role ro ON ro.role_id = u.role_id "
                + "WHERE s.token_hash = ? AND s.revoked_at IS NULL AND s.expires_at > UTC_TIMESTAMP() "
                + "AND u.deleted_at IS NULL", PasswordHasher.sha256Hex(token));
        if (r == null) return Optional.empty();
        return Optional.of(new AuthUser(((Number) r.get("user_id")).intValue(), (String) r.get("username"),
                (String) r.get("role"), ((Number) r.get("session_id")).longValue()));
    }

    public void logout(AuthUser u) {
        db.update("UPDATE Auth_Session SET revoked_at = UTC_TIMESTAMP() WHERE session_id = ?", u.sessionId());
    }

    private static boolean truthy(Object o) {
        return o instanceof Boolean b ? b : o instanceof Number n && n.intValue() != 0;
    }
}
