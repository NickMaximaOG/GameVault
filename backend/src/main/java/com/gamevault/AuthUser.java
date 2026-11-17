package com.gamevault;

/** The authenticated caller, resolved from the bearer token. */
public record AuthUser(int id, String username, String role, long sessionId) {
    public boolean isAdmin() { return "ADMIN".equals(role); }
}
