-- =====================================================================
--  GameVault v2: Game Collection and Achievement Tracker
--  schema.sql  |  MySQL 8.0 (tested on 8.0.46)  |  InnoDB, utf8mb4
--  GENERATED FILE: edit database/parts/*.sql or database/tools/gen_schema.py,
--  then run `python3 database/tools/gen_schema.py` to rebuild it.
-- =====================================================================
--  HOW TO RUN (MySQL Workbench or CLI)
--    Workbench: File > Open SQL Script > schema.sql > run the whole script.
--    CLI:       mysql -u root -p < database/schema.sql
--    Run it ONCE on a clean server. To start over, uncomment section 0.
--    Then run security.sql to create the application accounts.
--
--  WHAT CHANGED FROM v1 (see docs/CHANGES_v1_to_v2.md for the full list)
--    * Soft delete (deleted_at) on User, Game, User_Game, Rating.
--    * created_at / updated_at on every entity table; Audit_Log filled by
--      triggers (who, when, old and new values).
--    * Game_Age_Rating replaces Game.age_rating_id: one rating PER AUTHORITY
--      per game (ESRB and PEGI side by side).
--    * Lookup tables (Role, Collection_Status) replace text/ENUM columns.
--    * Playtime_Session: playtime is derived from sessions, not typed in.
--    * row_version on User_Game and Rating (optimistic locking).
--    * Views for catalogue / collection / dashboard, stored procedures for
--      every business write, an expiring Auth_Session table.
--
--  DESIGN DECISIONS AND TRADE-OFFS
--  D1. Table names follow the project brief (User, Game_Genre, ...).
--      MySQL on Linux is case-sensitive for table names; always use this
--      exact spelling.
--  D2. Genres, platforms, modes and age ratings are never stored in a text
--      column; Game_Genre, Game_Platform, Game_Mode_Map and Game_Age_Rating
--      are the junction tables.
--  D3. Nullable Game.developer_id / publisher_id: a studio may be unknown or
--      removed; ON DELETE SET NULL keeps the game.
--  D4. Game_Age_Rating carries rating_authority as well as age_rating_id.
--      A composite FK to Age_Rating (age_rating_id, rating_authority) makes
--      the redundancy impossible to corrupt, and the primary key
--      (game_id, rating_authority) allows exactly one rating per authority.
--  D5. User_Game has a composite FK (game_id, platform_id) to Game_Platform:
--      a user cannot own a game on a platform the game does not support.
--  D6. User_Achievement.game_id is a deliberate, FK-enforced redundancy so
--      the achievement and the collection entry must be for the SAME game.
--  D7. Soft delete. Rows are hidden, not removed, so history and audit stay
--      intact and a mistake is reversible. The FKs from User to its children
--      are RESTRICT, so a plain DELETE on a user fails by design. Only the
--      admin procedure sp_purge_user (GDPR erasure) removes a user for good.
--      Consequence: a soft-deleted row still occupies its UNIQUE keys, so the
--      stored procedures re-activate it instead of inserting a duplicate.
--  D8. Playtime. User_Game.baseline_hours holds hours imported from before
--      tracking began. Total playtime = baseline_hours + sum of
--      Playtime_Session minutes / 60, exposed by view v_user_game. This
--      removes a redundant, editable total and adds history.
--  D9. Optimistic locking. A BEFORE UPDATE trigger increments row_version on
--      User_Game and Rating. Stored procedures compare the version the client
--      read with the current one and raise CONFLICT if they differ.
--  D10. Audit_Log is append-only: triggers reject UPDATE/DELETE on it. The
--      only exception is sp_purge_user scrubbing a erased person's data.
--      Audit triggers are installed AFTER the sample data so the seed load
--      does not flood the log.
--  D11. Application errors from stored procedures are SQLSTATE '45000' with
--      a message prefix (VALIDATION:, NOT_FOUND:, CONFLICT:, FORBIDDEN:) that
--      the Java backend maps to HTTP 400/404/409/403.
--  D12. CHECK constraints: MySQL forbids CHECK on a column used by an FK with
--      CASCADE / SET NULL actions, so such columns use RESTRICT or have no
--      CHECK.
--  D13. All TIMESTAMP values are stored in UTC (SET time_zone below).
--  D14. Not done (documented future work): table partitioning for the large
--      append-only tables, multi-currency prices, friends/social tables.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0. OPTIONAL RESET  --  DESTRUCTIVE: DROPS THE WHOLE DATABASE
--    Disabled by default. Remove the leading "-- " to enable.
-- ---------------------------------------------------------------------
-- DROP DATABASE IF EXISTS gamevault_db;

-- ---------------------------------------------------------------------
-- 1. DATABASE
-- ---------------------------------------------------------------------
CREATE DATABASE IF NOT EXISTS gamevault_db
    CHARACTER SET utf8mb4
    COLLATE utf8mb4_0900_ai_ci;

USE gamevault_db;
SET NAMES utf8mb4;
SET time_zone = '+00:00';

-- ---------------------------------------------------------------------
-- 2. DDL (tables in dependency order)
-- ---------------------------------------------------------------------

-- Lookup: Role -------------------------------------------------------
CREATE TABLE Role (
    role_id     TINYINT      NOT NULL,
    name        VARCHAR(20)  NOT NULL,
    description VARCHAR(255) NULL,
    CONSTRAINT pk_role      PRIMARY KEY (role_id),
    CONSTRAINT uq_role_name UNIQUE (name)
) ENGINE=InnoDB;

-- Lookup: Collection_Status ------------------------------------------
-- Ids are fixed because chk_ug_completed refers to status 3 (Completed).
CREATE TABLE Collection_Status (
    status_id  TINYINT     NOT NULL,
    name       VARCHAR(20) NOT NULL,
    sort_order TINYINT     NOT NULL,
    CONSTRAINT pk_collection_status      PRIMARY KEY (status_id),
    CONSTRAINT uq_collection_status_name UNIQUE (name)
) ENGINE=InnoDB;

-- Table 1: User ------------------------------------------------------
CREATE TABLE User (
    user_id            INT           NOT NULL AUTO_INCREMENT,
    username           VARCHAR(50)   NOT NULL,
    email              VARCHAR(255)  NOT NULL,
    -- format: pbkdf2-sha256$<iterations>$<salt b64>$<hash b64>, never plaintext
    password_hash      VARCHAR(255)  NOT NULL,
    role_id            TINYINT       NOT NULL DEFAULT 1,
    failed_login_count SMALLINT      NOT NULL DEFAULT 0,
    locked_until       DATETIME      NULL,
    last_login_at      DATETIME      NULL,
    join_date          DATE          NOT NULL DEFAULT (CURRENT_DATE),
    profile_picture    VARCHAR(500)  NULL,
    deleted_at         TIMESTAMP     NULL DEFAULT NULL,
    created_at         TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at         TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    CONSTRAINT pk_user          PRIMARY KEY (user_id),
    CONSTRAINT uq_user_username UNIQUE (username),
    CONSTRAINT uq_user_email    UNIQUE (email),
    CONSTRAINT fk_user_role FOREIGN KEY (role_id) REFERENCES Role (role_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT chk_user_email    CHECK (email LIKE '%_@_%.__%'),
    CONSTRAINT chk_user_failed   CHECK (failed_login_count >= 0)
) ENGINE=InnoDB;

-- Table 2: Developer -------------------------------------------------
CREATE TABLE Developer (
    developer_id INT          NOT NULL AUTO_INCREMENT,
    name         VARCHAR(100) NOT NULL,
    country      VARCHAR(60)  NULL,
    website      VARCHAR(255) NULL,
    created_at   TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at   TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    CONSTRAINT pk_developer      PRIMARY KEY (developer_id),
    CONSTRAINT uq_developer_name UNIQUE (name)
) ENGINE=InnoDB;

-- Table 3: Publisher -------------------------------------------------
CREATE TABLE Publisher (
    publisher_id INT          NOT NULL AUTO_INCREMENT,
    name         VARCHAR(100) NOT NULL,
    country      VARCHAR(60)  NULL,
    website      VARCHAR(255) NULL,
    created_at   TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at   TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    CONSTRAINT pk_publisher      PRIMARY KEY (publisher_id),
    CONSTRAINT uq_publisher_name UNIQUE (name)
) ENGINE=InnoDB;

-- Table 4: Genre -----------------------------------------------------
CREATE TABLE Genre (
    genre_id    INT          NOT NULL AUTO_INCREMENT,
    name        VARCHAR(50)  NOT NULL,
    description VARCHAR(255) NULL,
    created_at  TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at  TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    CONSTRAINT pk_genre      PRIMARY KEY (genre_id),
    CONSTRAINT uq_genre_name UNIQUE (name)
) ENGINE=InnoDB;

-- Table 5: Platform --------------------------------------------------
CREATE TABLE Platform (
    platform_id  INT         NOT NULL AUTO_INCREMENT,
    name         VARCHAR(60) NOT NULL,
    manufacturer VARCHAR(60) NULL,
    release_year SMALLINT    NULL,
    created_at   TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at   TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    CONSTRAINT pk_platform       PRIMARY KEY (platform_id),
    CONSTRAINT uq_platform_name  UNIQUE (name),
    CONSTRAINT chk_platform_year CHECK (release_year IS NULL
                                        OR release_year BETWEEN 1970 AND 2100)
) ENGINE=InnoDB;

-- Table 6: Age_Rating ------------------------------------------------
CREATE TABLE Age_Rating (
    age_rating_id    INT          NOT NULL AUTO_INCREMENT,
    label            VARCHAR(20)  NOT NULL,   -- e.g. 'M', 'PEGI 16'
    rating_authority VARCHAR(20)  NOT NULL,   -- e.g. 'ESRB', 'PEGI'
    description      VARCHAR(255) NULL,
    minimum_age      TINYINT      NOT NULL,
    created_at       TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at       TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    CONSTRAINT pk_age_rating PRIMARY KEY (age_rating_id),
    CONSTRAINT uq_age_rating_authority_label UNIQUE (rating_authority, label),
    -- target of the composite FK from Game_Age_Rating (decision D4)
    CONSTRAINT uq_age_rating_id_authority UNIQUE (age_rating_id, rating_authority),
    CONSTRAINT chk_age_rating_min_age CHECK (minimum_age BETWEEN 0 AND 21)
) ENGINE=InnoDB;

-- Table 7: Game_Mode -------------------------------------------------
CREATE TABLE Game_Mode (
    mode_id     INT          NOT NULL AUTO_INCREMENT,
    name        VARCHAR(50)  NOT NULL,
    description VARCHAR(255) NULL,
    created_at  TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at  TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    CONSTRAINT pk_game_mode      PRIMARY KEY (mode_id),
    CONSTRAINT uq_game_mode_name UNIQUE (name)
) ENGINE=InnoDB;

-- Table 8: Game ------------------------------------------------------
CREATE TABLE Game (
    game_id      INT          NOT NULL AUTO_INCREMENT,
    title        VARCHAR(150) NOT NULL,
    release_date DATE         NULL,
    description  TEXT         NULL,
    cover_image  VARCHAR(500) NULL,
    developer_id INT          NULL,
    publisher_id INT          NULL,
    deleted_at   TIMESTAMP    NULL DEFAULT NULL,
    created_at   TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at   TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    CONSTRAINT pk_game PRIMARY KEY (game_id),
    CONSTRAINT uq_game_title_release UNIQUE (title, release_date),
    CONSTRAINT fk_game_developer FOREIGN KEY (developer_id)
        REFERENCES Developer (developer_id) ON DELETE SET NULL ON UPDATE RESTRICT,
    CONSTRAINT fk_game_publisher FOREIGN KEY (publisher_id)
        REFERENCES Publisher (publisher_id) ON DELETE SET NULL ON UPDATE RESTRICT,
    INDEX idx_game_title (title),
    FULLTEXT INDEX ft_game_search (title, description)
) ENGINE=InnoDB;

-- Table 9: Game_Genre (Game M:N Genre) --------------------------------
CREATE TABLE Game_Genre (
    game_id  INT NOT NULL,
    genre_id INT NOT NULL,
    CONSTRAINT pk_game_genre PRIMARY KEY (game_id, genre_id),
    CONSTRAINT fk_game_genre_game  FOREIGN KEY (game_id)  REFERENCES Game (game_id)
        ON DELETE CASCADE ON UPDATE RESTRICT,
    CONSTRAINT fk_game_genre_genre FOREIGN KEY (genre_id) REFERENCES Genre (genre_id)
        ON DELETE CASCADE ON UPDATE RESTRICT,
    INDEX idx_game_genre_genre (genre_id)
) ENGINE=InnoDB;

-- Table 10: Game_Platform (Game M:N Platform) -------------------------
CREATE TABLE Game_Platform (
    game_id               INT  NOT NULL,
    platform_id           INT  NOT NULL,
    platform_release_date DATE NULL,
    CONSTRAINT pk_game_platform PRIMARY KEY (game_id, platform_id),
    CONSTRAINT fk_game_platform_game     FOREIGN KEY (game_id)     REFERENCES Game (game_id)
        ON DELETE CASCADE ON UPDATE RESTRICT,
    CONSTRAINT fk_game_platform_platform FOREIGN KEY (platform_id) REFERENCES Platform (platform_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
    INDEX idx_game_platform_platform (platform_id)
) ENGINE=InnoDB;

-- Table 11: Game_Mode_Map (Game M:N Game_Mode) -------------------------
CREATE TABLE Game_Mode_Map (
    game_id INT NOT NULL,
    mode_id INT NOT NULL,
    CONSTRAINT pk_game_mode_map PRIMARY KEY (game_id, mode_id),
    CONSTRAINT fk_gmm_game FOREIGN KEY (game_id) REFERENCES Game (game_id)
        ON DELETE CASCADE ON UPDATE RESTRICT,
    CONSTRAINT fk_gmm_mode FOREIGN KEY (mode_id) REFERENCES Game_Mode (mode_id)
        ON DELETE CASCADE ON UPDATE RESTRICT,
    INDEX idx_gmm_mode (mode_id)
) ENGINE=InnoDB;

-- Table 12: Game_Age_Rating (Game M:N Age_Rating, one per authority) ---
CREATE TABLE Game_Age_Rating (
    game_id          INT         NOT NULL,
    rating_authority VARCHAR(20) NOT NULL,
    age_rating_id    INT         NOT NULL,
    CONSTRAINT pk_game_age_rating PRIMARY KEY (game_id, rating_authority),
    CONSTRAINT fk_gar_game FOREIGN KEY (game_id) REFERENCES Game (game_id)
        ON DELETE CASCADE ON UPDATE RESTRICT,
    -- the stored authority must be the authority of the chosen rating (D4)
    CONSTRAINT fk_gar_rating FOREIGN KEY (age_rating_id, rating_authority)
        REFERENCES Age_Rating (age_rating_id, rating_authority)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
    INDEX idx_gar_rating (age_rating_id)
) ENGINE=InnoDB;

-- Table 13: User_Game (a user's collection entry) ----------------------
CREATE TABLE User_Game (
    user_game_id   INT           NOT NULL AUTO_INCREMENT,
    user_id        INT           NOT NULL,
    game_id        INT           NOT NULL,
    platform_id    INT           NOT NULL,
    purchase_date  DATE          NULL,
    purchase_price DECIMAL(8,2)  NOT NULL DEFAULT 0.00,
    baseline_hours DECIMAL(7,1)  NOT NULL DEFAULT 0.0,   -- see D8
    status_id      TINYINT       NOT NULL DEFAULT 1,
    started_at     DATE          NULL,
    completed_at   DATE          NULL,
    deleted_at     TIMESTAMP     NULL DEFAULT NULL,
    row_version    INT           NOT NULL DEFAULT 1,
    created_at     TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at     TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    CONSTRAINT pk_user_game PRIMARY KEY (user_game_id),
    CONSTRAINT uq_user_game_ugp UNIQUE (user_id, game_id, platform_id),
    -- target of the composite FK from User_Achievement (D6)
    CONSTRAINT uq_user_game_id_game UNIQUE (user_game_id, game_id),
    CONSTRAINT fk_user_game_user FOREIGN KEY (user_id) REFERENCES User (user_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
    -- D5: also guarantees the game and the platform exist
    CONSTRAINT fk_user_game_supported_platform FOREIGN KEY (game_id, platform_id)
        REFERENCES Game_Platform (game_id, platform_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT fk_user_game_status FOREIGN KEY (status_id) REFERENCES Collection_Status (status_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT chk_ug_price    CHECK (purchase_price >= 0),
    CONSTRAINT chk_ug_baseline CHECK (baseline_hours >= 0),
    CONSTRAINT chk_ug_dates    CHECK (started_at IS NULL OR completed_at IS NULL
                                      OR completed_at >= started_at),
    -- a completion date exists exactly when the status is 3 (Completed)
    CONSTRAINT chk_ug_completed CHECK ((status_id = 3) = (completed_at IS NOT NULL)),
    INDEX idx_user_game_status (status_id),
    INDEX idx_user_game_game (game_id),
    INDEX idx_user_game_user_active (user_id, deleted_at)
) ENGINE=InnoDB;

-- Table 14: Playtime_Session -------------------------------------------
CREATE TABLE Playtime_Session (
    session_id       BIGINT       NOT NULL AUTO_INCREMENT,
    user_game_id     INT          NOT NULL,
    started_at       DATETIME     NOT NULL,
    duration_minutes INT          NOT NULL,
    note             VARCHAR(255) NULL,
    created_at       TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT pk_playtime_session PRIMARY KEY (session_id),
    CONSTRAINT fk_ps_user_game FOREIGN KEY (user_game_id) REFERENCES User_Game (user_game_id)
        ON DELETE CASCADE ON UPDATE RESTRICT,
    CONSTRAINT chk_ps_minutes CHECK (duration_minutes BETWEEN 1 AND 1440),
    INDEX idx_ps_user_game (user_game_id, started_at)
) ENGINE=InnoDB;

-- Table 15: Rating -----------------------------------------------------
CREATE TABLE Rating (
    rating_id   INT       NOT NULL AUTO_INCREMENT,
    user_id     INT       NOT NULL,
    game_id     INT       NOT NULL,
    rating      TINYINT   NOT NULL,
    review_text TEXT      NULL,
    review_date DATE      NOT NULL DEFAULT (CURRENT_DATE),
    deleted_at  TIMESTAMP NULL DEFAULT NULL,
    row_version INT       NOT NULL DEFAULT 1,
    created_at  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    CONSTRAINT pk_rating PRIMARY KEY (rating_id),
    CONSTRAINT uq_rating_user_game UNIQUE (user_id, game_id),
    CONSTRAINT fk_rating_user FOREIGN KEY (user_id) REFERENCES User (user_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT fk_rating_game FOREIGN KEY (game_id) REFERENCES Game (game_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT chk_rating_range CHECK (rating BETWEEN 1 AND 10),
    INDEX idx_rating_game (game_id, deleted_at)
) ENGINE=InnoDB;

-- Table 16: Achievement ------------------------------------------------
CREATE TABLE Achievement (
    achievement_id INT          NOT NULL AUTO_INCREMENT,
    game_id        INT          NOT NULL,
    name           VARCHAR(100) NOT NULL,
    description    VARCHAR(255) NULL,
    points         INT          NOT NULL DEFAULT 0,
    is_hidden      BOOLEAN      NOT NULL DEFAULT FALSE,
    created_at     TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at     TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    CONSTRAINT pk_achievement PRIMARY KEY (achievement_id),
    CONSTRAINT uq_achievement_game_name UNIQUE (game_id, name),
    CONSTRAINT uq_achievement_id_game UNIQUE (achievement_id, game_id),
    CONSTRAINT fk_achievement_game FOREIGN KEY (game_id) REFERENCES Game (game_id)
        ON DELETE CASCADE ON UPDATE RESTRICT,
    CONSTRAINT chk_achievement_points CHECK (points >= 0)
) ENGINE=InnoDB;

-- Table 17: User_Achievement (User_Game M:N Achievement) ----------------
CREATE TABLE User_Achievement (
    user_game_id   INT           NOT NULL,
    achievement_id INT           NOT NULL,
    game_id        INT           NOT NULL,   -- controlled redundancy (D6)
    unlocked_at    TIMESTAMP     NULL DEFAULT NULL,
    progress       DECIMAL(5,2)  NOT NULL DEFAULT 0.00,
    is_unlocked    BOOLEAN       NOT NULL DEFAULT FALSE,
    created_at     TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at     TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    CONSTRAINT pk_user_achievement PRIMARY KEY (user_game_id, achievement_id),
    CONSTRAINT fk_ua_user_game FOREIGN KEY (user_game_id, game_id)
        REFERENCES User_Game (user_game_id, game_id)
        ON DELETE CASCADE ON UPDATE RESTRICT,
    CONSTRAINT fk_ua_achievement FOREIGN KEY (achievement_id, game_id)
        REFERENCES Achievement (achievement_id, game_id)
        ON DELETE CASCADE ON UPDATE RESTRICT,
    CONSTRAINT chk_ua_progress CHECK (progress BETWEEN 0 AND 100),
    CONSTRAINT chk_ua_unlock_consistency CHECK (
        (is_unlocked = 1 AND unlocked_at IS NOT NULL AND progress = 100)
     OR (is_unlocked = 0 AND unlocked_at IS NULL     AND progress < 100)),
    INDEX idx_ua_achievement (achievement_id, game_id)
) ENGINE=InnoDB;

-- Table 18: Auth_Session (opaque bearer tokens, stored hashed) ----------
CREATE TABLE Auth_Session (
    session_id  BIGINT       NOT NULL AUTO_INCREMENT,
    user_id     INT          NOT NULL,
    token_hash  CHAR(64)     NOT NULL,      -- SHA-256 hex of the token, never the token itself
    created_at  TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    expires_at  DATETIME     NOT NULL,
    revoked_at  DATETIME     NULL,
    ip_address  VARCHAR(45)  NULL,
    user_agent  VARCHAR(255) NULL,
    CONSTRAINT pk_auth_session PRIMARY KEY (session_id),
    CONSTRAINT uq_auth_session_token UNIQUE (token_hash),
    CONSTRAINT fk_auth_session_user FOREIGN KEY (user_id) REFERENCES User (user_id)
        ON DELETE CASCADE ON UPDATE RESTRICT,
    INDEX idx_auth_session_user (user_id),
    INDEX idx_auth_session_expiry (expires_at)
) ENGINE=InnoDB;

-- Table 19: Audit_Log (append-only, filled by triggers) -----------------
CREATE TABLE Audit_Log (
    audit_id   BIGINT       NOT NULL AUTO_INCREMENT,
    table_name VARCHAR(64)  NOT NULL,
    record_pk  VARCHAR(64)  NOT NULL,
    action     ENUM('INSERT','UPDATE','DELETE') NOT NULL,
    changed_by INT          NULL,                 -- user id from @app_user_id, NULL = system
    changed_at TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    old_values JSON         NULL,
    new_values JSON         NULL,
    CONSTRAINT pk_audit_log PRIMARY KEY (audit_id),
    INDEX idx_audit_record (table_name, record_pk),
    INDEX idx_audit_changed_at (changed_at),
    INDEX idx_audit_changed_by (changed_by)
) ENGINE=InnoDB;

