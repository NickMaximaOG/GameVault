-- =====================================================================
-- GameVault v2: security.sql  (run as an administrator AFTER schema.sql)
--
-- Creates two least-privilege accounts. The backend connects as gv_app and
-- NEVER as root. CHANGE BOTH PASSWORDS before using this anywhere real, and
-- replace '%' with the backend's host or subnet.
--
--   gv_app     the backend. Reads views, executes stored procedures, and may
--              only touch User and Auth_Session directly (register / login /
--              sessions), with COLUMN-level grants. It cannot read or write
--              User_Game, Rating, Achievement progress, ... except through the
--              procedures, and it cannot change structure (no DDL).
--   gv_report  read-only analytics over the views. No base tables, no
--              credentials, no audit data.
--
-- mysql_native_password is used so every JDBC driver can connect; with
-- MySQL Connector/J 8+ you may use the default caching_sha2_password instead.
-- =====================================================================
CREATE USER IF NOT EXISTS 'gv_app'@'%'
    IDENTIFIED WITH mysql_native_password BY 'change-me-app-Passw0rd'
    WITH MAX_USER_CONNECTIONS 50;
CREATE USER IF NOT EXISTS 'gv_report'@'%'
    IDENTIFIED WITH mysql_native_password BY 'change-me-report-Passw0rd'
    WITH MAX_USER_CONNECTIONS 5;

-- Re-running the script resets privileges to exactly what is listed below.
REVOKE ALL PRIVILEGES, GRANT OPTION FROM 'gv_app'@'%';
REVOKE ALL PRIVILEGES, GRANT OPTION FROM 'gv_report'@'%';

-- ---- gv_app: views -----------------------------------------------------
GRANT SELECT ON gamevault_db.v_user               TO 'gv_app'@'%';
GRANT SELECT ON gamevault_db.v_game               TO 'gv_app'@'%';
GRANT SELECT ON gamevault_db.v_rating             TO 'gv_app'@'%';
GRANT SELECT ON gamevault_db.v_user_game          TO 'gv_app'@'%';
GRANT SELECT ON gamevault_db.v_collection         TO 'gv_app'@'%';
GRANT SELECT ON gamevault_db.v_game_catalog       TO 'gv_app'@'%';
GRANT SELECT ON gamevault_db.v_user_dashboard     TO 'gv_app'@'%';
GRANT SELECT ON gamevault_db.v_achievement_progress TO 'gv_app'@'%';

-- ---- gv_app: reference / catalogue tables (read only) -----------------------
GRANT SELECT ON gamevault_db.Genre             TO 'gv_app'@'%';
GRANT SELECT ON gamevault_db.Platform          TO 'gv_app'@'%';
GRANT SELECT ON gamevault_db.Age_Rating        TO 'gv_app'@'%';
GRANT SELECT ON gamevault_db.Game_Mode         TO 'gv_app'@'%';
GRANT SELECT ON gamevault_db.Collection_Status TO 'gv_app'@'%';
GRANT SELECT ON gamevault_db.Role              TO 'gv_app'@'%';
GRANT SELECT ON gamevault_db.Game_Genre        TO 'gv_app'@'%';
GRANT SELECT ON gamevault_db.Game_Platform     TO 'gv_app'@'%';
GRANT SELECT ON gamevault_db.Game_Mode_Map     TO 'gv_app'@'%';
GRANT SELECT ON gamevault_db.Game_Age_Rating   TO 'gv_app'@'%';
GRANT SELECT ON gamevault_db.Achievement       TO 'gv_app'@'%';
GRANT SELECT ON gamevault_db.Playtime_Session  TO 'gv_app'@'%';
GRANT SELECT ON gamevault_db.Audit_Log         TO 'gv_app'@'%';   -- admin screen; the API checks the role

-- ---- gv_app: accounts and sessions (column-level) ---------------------------
GRANT SELECT (user_id, username, email, password_hash, role_id,
              failed_login_count, locked_until, deleted_at)
      ON gamevault_db.User TO 'gv_app'@'%';
GRANT INSERT (username, email, password_hash)
      ON gamevault_db.User TO 'gv_app'@'%';
GRANT UPDATE (failed_login_count, locked_until, last_login_at, password_hash)
      ON gamevault_db.User TO 'gv_app'@'%';
GRANT SELECT, INSERT, UPDATE ON gamevault_db.Auth_Session TO 'gv_app'@'%';

-- ---- gv_app: every business write goes through a stored procedure -----------
GRANT EXECUTE ON gamevault_db.* TO 'gv_app'@'%';

-- ---- gv_report: analytics only ------------------------------------------------
GRANT SELECT ON gamevault_db.v_game_catalog   TO 'gv_report'@'%';
GRANT SELECT ON gamevault_db.v_user_dashboard TO 'gv_report'@'%';

FLUSH PRIVILEGES;
