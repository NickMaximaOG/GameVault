package com.gamevault;

import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.util.Base64;
import javax.crypto.SecretKeyFactory;
import javax.crypto.spec.PBEKeySpec;

/**
 * PBKDF2-HMAC-SHA256 password hashing using only the JDK.
 * Stored format: pbkdf2-sha256$iterations$saltBase64$hashBase64
 * (the same format the database seed uses). The iteration count is stored
 * with the hash, so it can be raised later and old hashes upgraded at login.
 */
public final class PasswordHasher {
    public static final int ITERATIONS = 600_000;   // OWASP guidance for PBKDF2-SHA256
    private static final int SALT_BYTES = 16;
    private static final int KEY_BITS = 256;
    private static final SecureRandom RANDOM = new SecureRandom();

    private PasswordHasher() {}

    public static String hash(String password) {
        byte[] salt = new byte[SALT_BYTES];
        RANDOM.nextBytes(salt);
        byte[] dk = derive(password, salt, ITERATIONS);
        Base64.Encoder b64 = Base64.getEncoder();
        return "pbkdf2-sha256$" + ITERATIONS + "$" + b64.encodeToString(salt) + "$" + b64.encodeToString(dk);
    }

    public static boolean verify(String password, String stored) {
        try {
            String[] p = stored.split("\\$");
            if (p.length != 4 || !"pbkdf2-sha256".equals(p[0])) return false;
            int iterations = Integer.parseInt(p[1]);
            if (iterations < 1 || iterations > 5_000_000) return false;
            byte[] salt = Base64.getDecoder().decode(p[2]);
            byte[] expected = Base64.getDecoder().decode(p[3]);
            byte[] actual = derive(password, salt, iterations);
            return MessageDigest.isEqual(expected, actual);   // constant time
        } catch (RuntimeException e) {
            return false;
        }
    }

    /** True when the stored hash uses fewer iterations than today's standard. */
    public static boolean needsRehash(String stored) {
        try {
            return Integer.parseInt(stored.split("\\$")[1]) < ITERATIONS;
        } catch (RuntimeException e) {
            return true;
        }
    }

    private static byte[] derive(String password, byte[] salt, int iterations) {
        PBEKeySpec spec = new PBEKeySpec(password.toCharArray(), salt, iterations, KEY_BITS);
        try {
            return SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256").generateSecret(spec).getEncoded();
        } catch (GeneralSecurityException e) {
            throw new IllegalStateException(e);
        } finally {
            spec.clearPassword();
        }
    }

    public static String sha256Hex(String s) {
        try {
            byte[] d = MessageDigest.getInstance("SHA-256").digest(s.getBytes(StandardCharsets.UTF_8));
            StringBuilder sb = new StringBuilder(64);
            for (byte b : d) sb.append(String.format("%02x", b));
            return sb.toString();
        } catch (GeneralSecurityException e) {
            throw new IllegalStateException(e);
        }
    }
}
