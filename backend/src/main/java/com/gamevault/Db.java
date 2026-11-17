package com.gamevault;

import com.zaxxer.hikari.HikariConfig;
import com.zaxxer.hikari.HikariDataSource;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.ResultSetMetaData;
import java.sql.SQLException;
import java.sql.Statement;
import java.sql.Types;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Thin JDBC layer: connection pool, parameterised queries, transactions.
 * Every value reaches SQL through a ? placeholder; SQL text never contains user input.
 */
public final class Db implements AutoCloseable {
    private final HikariDataSource ds;

    public Db(Config cfg) {
        HikariConfig h = new HikariConfig();
        h.setJdbcUrl(cfg.dbUrl());
        h.setUsername(cfg.dbUser());
        h.setPassword(cfg.dbPassword());
        h.setMaximumPoolSize(cfg.dbPoolSize());
        h.setMinimumIdle(1);
        h.setConnectionTimeout(5_000);
        h.setPoolName("gamevault");
        h.setConnectionInitSql("SET time_zone = '+00:00'");
        this.ds = new HikariDataSource(h);
    }

    @FunctionalInterface
    public interface Tx<T> { T run(Connection c) throws SQLException; }

    /** Runs fn in one transaction. actorId tags the audit rows written by DB triggers. */
    public <T> T tx(Integer actorId, Tx<T> fn) {
        try (Connection c = ds.getConnection()) {
            try {
                c.setAutoCommit(false);
                update(c, "SET @app_user_id = ?", actorId);
                T result = fn.run(c);
                c.commit();
                return result;
            } catch (SQLException | RuntimeException e) {
                try { c.rollback(); } catch (SQLException ignored) { }
                if (e instanceof SQLException se) throw translate(se);
                throw (RuntimeException) e;
            } finally {
                try {
                    update(c, "SET @app_user_id = NULL");   // never leak the actor to the next borrower
                    c.setAutoCommit(true);
                } catch (SQLException ignored) { }
            }
        } catch (SQLException e) {
            throw translate(e);
        }
    }

    public List<Map<String, Object>> query(String sql, Object... params) {
        try (Connection c = ds.getConnection()) {
            return query(c, sql, params);
        } catch (SQLException e) {
            throw translate(e);
        }
    }

    public Map<String, Object> one(String sql, Object... params) {
        List<Map<String, Object>> rows = query(sql, params);
        return rows.isEmpty() ? null : rows.get(0);
    }

    /** Single write outside a transaction; returns the generated key (or -1). */
    public long insert(String sql, Object... params) {
        try (Connection c = ds.getConnection();
             PreparedStatement ps = c.prepareStatement(sql, Statement.RETURN_GENERATED_KEYS)) {
            bind(ps, params);
            ps.executeUpdate();
            try (ResultSet k = ps.getGeneratedKeys()) {
                return k.next() ? k.getLong(1) : -1;
            }
        } catch (SQLException e) {
            throw translate(e);
        }
    }

    public int update(String sql, Object... params) {
        try (Connection c = ds.getConnection()) {
            return update(c, sql, params);
        } catch (SQLException e) {
            throw translate(e);
        }
    }

    public boolean ping() {
        try (Connection c = ds.getConnection(); Statement s = c.createStatement()) {
            s.execute("SELECT 1");
            return true;
        } catch (SQLException e) {
            return false;
        }
    }

    // ---- connection-level helpers (used inside tx) -------------------------------------

    public static List<Map<String, Object>> query(Connection c, String sql, Object... params) throws SQLException {
        try (PreparedStatement ps = c.prepareStatement(sql)) {
            bind(ps, params);
            try (ResultSet rs = ps.executeQuery()) {
                return rows(rs);
            }
        }
    }

    public static long insert(Connection c, String sql, Object... params) throws SQLException {
        try (PreparedStatement ps = c.prepareStatement(sql, Statement.RETURN_GENERATED_KEYS)) {
            bind(ps, params);
            ps.executeUpdate();
            try (ResultSet k = ps.getGeneratedKeys()) { return k.next() ? k.getLong(1) : -1; }
        }
    }

    public static int update(Connection c, String sql, Object... params) throws SQLException {
        try (PreparedStatement ps = c.prepareStatement(sql)) {
            bind(ps, params);
            return ps.executeUpdate();
        }
    }

    /** Reads a numeric user variable such as @gv_out after a CALL on the same connection. */
    public static long scalarLong(Connection c, String sql) throws SQLException {
        try (Statement s = c.createStatement(); ResultSet rs = s.executeQuery(sql)) {
            return rs.next() ? rs.getLong(1) : -1;
        }
    }

    private static void bind(PreparedStatement ps, Object[] params) throws SQLException {
        for (int i = 0; i < params.length; i++) {
            if (params[i] == null) ps.setNull(i + 1, Types.NULL);
            else ps.setObject(i + 1, params[i]);
        }
    }

    private static List<Map<String, Object>> rows(ResultSet rs) throws SQLException {
        ResultSetMetaData md = rs.getMetaData();
        int n = md.getColumnCount();
        List<Map<String, Object>> out = new ArrayList<>();
        while (rs.next()) {
            Map<String, Object> row = new LinkedHashMap<>();
            for (int i = 1; i <= n; i++) {
                String name = md.getColumnLabel(i);
                int type = md.getColumnType(i);
                Object v;
                if (type == Types.TIMESTAMP || type == Types.TIMESTAMP_WITH_TIMEZONE) {
                    String s = rs.getString(i);                       // wall time in UTC (session time zone)
                    v = s == null ? null : s.replace(' ', 'T') + "Z";
                } else if (type == Types.DATE) {
                    v = rs.getString(i);                              // yyyy-MM-dd
                } else {
                    v = rs.getObject(i);
                }
                row.put(name, v);
            }
            out.add(row);
        }
        return out;
    }

    // ---- error translation -----------------------------------------------------------------

    private static final Pattern APP_ERROR =
            Pattern.compile("(VALIDATION|NOT_FOUND|CONFLICT|FORBIDDEN): ([^\\n\\r]*?)(?:\\s*\\nQuery is:.*)?$", Pattern.DOTALL);

    /** Maps stored-procedure errors and constraint violations to HTTP errors; anything else is a 500. */
    static RuntimeException translate(SQLException e) {
        for (Throwable t = e; t != null; t = t.getCause()) {
            String msg = t.getMessage();
            if (msg != null) {
                Matcher m = APP_ERROR.matcher(msg.strip());
                if (m.find()) {
                    String text = m.group(2).strip();
                    return switch (m.group(1)) {
                        case "VALIDATION" -> ApiException.badRequest(text);
                        case "NOT_FOUND" -> ApiException.notFound(text);
                        case "CONFLICT" -> ApiException.conflict(text);
                        default -> ApiException.forbidden(text);
                    };
                }
            }
        }
        return switch (e.getErrorCode()) {
            case 1062 -> ApiException.conflict("That value is already in use");
            case 3819 -> ApiException.badRequest("A value is outside the allowed range");
            case 1451, 1452 -> ApiException.conflict("The request conflicts with related data");
            default -> new IllegalStateException("Database error " + e.getErrorCode() + " " + e.getSQLState(), e);
        };
    }

    @Override
    public void close() {
        ds.close();
    }
}
