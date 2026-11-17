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
    date_of_birth      DATE          NULL,
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

-- Friend relationships and in-app notifications ----------------------
CREATE TABLE Friendship (
    friendship_id INT NOT NULL AUTO_INCREMENT,
    requester_id INT NOT NULL,
    recipient_id INT NOT NULL,
    status ENUM('PENDING','ACCEPTED') NOT NULL DEFAULT 'PENDING',
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (friendship_id),
    UNIQUE KEY uq_friend_request (requester_id, recipient_id),
    CONSTRAINT fk_friend_requester FOREIGN KEY (requester_id) REFERENCES User(user_id) ON DELETE CASCADE,
    CONSTRAINT fk_friend_recipient FOREIGN KEY (recipient_id) REFERENCES User(user_id) ON DELETE CASCADE,
    CONSTRAINT chk_friend_not_self CHECK (requester_id <> recipient_id),
    INDEX idx_friend_recipient_status (recipient_id, status)
) ENGINE=InnoDB;

CREATE TABLE Notification (
    notification_id BIGINT NOT NULL AUTO_INCREMENT,
    recipient_id INT NOT NULL,
    actor_id INT NULL,
    notification_type VARCHAR(40) NOT NULL,
    message VARCHAR(255) NOT NULL,
    is_read TINYINT(1) NOT NULL DEFAULT 0,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (notification_id),
    CONSTRAINT fk_notification_recipient FOREIGN KEY (recipient_id) REFERENCES User(user_id) ON DELETE CASCADE,
    CONSTRAINT fk_notification_actor FOREIGN KEY (actor_id) REFERENCES User(user_id) ON DELETE SET NULL,
    INDEX idx_notification_recipient (recipient_id, is_read, created_at)
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
    is_upcoming  TINYINT(1) NOT NULL DEFAULT 0,
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

-- Game screenshots (URLs can point to Steam/CDN or admin-managed media) --
CREATE TABLE Game_Screenshot (
    screenshot_id INT NOT NULL AUTO_INCREMENT,
    game_id INT NOT NULL,
    image_url VARCHAR(500) NOT NULL,
    caption VARCHAR(180) NULL,
    sort_order SMALLINT NOT NULL DEFAULT 0,
    PRIMARY KEY (screenshot_id),
    CONSTRAINT fk_screenshot_game FOREIGN KEY (game_id) REFERENCES Game(game_id) ON DELETE CASCADE,
    INDEX idx_screenshot_game (game_id, sort_order)
) ENGINE=InnoDB;

CREATE TABLE Wishlist (
    wishlist_id BIGINT NOT NULL AUTO_INCREMENT,
    user_id INT NOT NULL,
    game_id INT NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (wishlist_id),
    UNIQUE KEY uq_wishlist_user_game (user_id, game_id),
    CONSTRAINT fk_wishlist_user FOREIGN KEY (user_id) REFERENCES User(user_id) ON DELETE CASCADE,
    CONSTRAINT fk_wishlist_game FOREIGN KEY (game_id) REFERENCES Game(game_id) ON DELETE CASCADE
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
    rarity         ENUM('COMMON','RARE','EPIC','LEGENDARY') NOT NULL DEFAULT 'COMMON',
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


-- ---------------------------------------------------------------------
-- 3. VIEWS
--    Views hide soft-deleted rows, never expose password hashes, and
--    pre-aggregate 1:N relationships so joins cannot inflate counts.
--    The application reads through views; it never needs SELECT on the
--    base tables User_Game, Rating or Audit_Log's JSON beyond its grants.
-- ---------------------------------------------------------------------

-- Active users, without credentials
CREATE OR REPLACE VIEW v_user AS
SELECT u.user_id, u.username, u.email, r.name AS role, u.join_date,
       u.profile_picture, u.last_login_at, u.created_at
FROM User u
JOIN Role r ON r.role_id = u.role_id
WHERE u.deleted_at IS NULL;

-- Active games
CREATE OR REPLACE VIEW v_game AS
SELECT g.game_id, g.title, g.release_date, g.description, g.cover_image, g.is_upcoming,
       g.developer_id, g.publisher_id
FROM Game g
WHERE g.deleted_at IS NULL;

-- Active ratings of active games
CREATE OR REPLACE VIEW v_rating AS
SELECT r.rating_id, r.user_id, r.game_id, r.rating, r.review_text,
       r.review_date, r.row_version, r.updated_at
FROM Rating r
JOIN Game g ON g.game_id = r.game_id AND g.deleted_at IS NULL
WHERE r.deleted_at IS NULL;

-- Active collection entries with DERIVED playtime (decision D8)
CREATE OR REPLACE VIEW v_user_game AS
SELECT ug.user_game_id, ug.user_id, ug.game_id, ug.platform_id,
       ug.purchase_date, ug.purchase_price,
       ROUND(ug.baseline_hours + COALESCE(s.total_minutes, 0) / 60, 1) AS playtime_hours,
       ug.status_id, cs.name AS status,
       ug.started_at, ug.completed_at, ug.row_version, ug.created_at, ug.updated_at
FROM User_Game ug
JOIN Collection_Status cs ON cs.status_id = ug.status_id
LEFT JOIN (SELECT user_game_id, SUM(duration_minutes) AS total_minutes
             FROM Playtime_Session GROUP BY user_game_id) s
       ON s.user_game_id = ug.user_game_id
WHERE ug.deleted_at IS NULL;

-- A user's collection as the UI shows it (one row per entry)
CREATE OR REPLACE VIEW v_collection AS
SELECT ug.user_game_id, ug.user_id, ug.game_id, g.title, g.cover_image,
       ug.platform_id, p.name AS platform,
       ug.purchase_date, ug.purchase_price, ug.playtime_hours,
       ug.status_id, ug.status, ug.started_at, ug.completed_at, ug.row_version, ug.created_at, ug.updated_at, lp.last_played_at,
       COALESCE(t.total, 0)        AS achievements_total,
       COALESCE(d.unlocked, 0)     AS achievements_unlocked,
       COALESCE(d.points, 0)       AS points_earned,
       r.rating                    AS my_rating
FROM v_user_game ug
JOIN v_game g   ON g.game_id = ug.game_id
JOIN Platform p ON p.platform_id = ug.platform_id
LEFT JOIN (SELECT game_id, COUNT(*) AS total FROM Achievement GROUP BY game_id) t
       ON t.game_id = ug.game_id
LEFT JOIN (SELECT ua.user_game_id,
                  SUM(ua.is_unlocked) AS unlocked,
                  SUM(CASE WHEN ua.is_unlocked = 1 THEN a.points ELSE 0 END) AS points
             FROM User_Achievement ua
             JOIN Achievement a ON a.achievement_id = ua.achievement_id
            GROUP BY ua.user_game_id) d
       ON d.user_game_id = ug.user_game_id
LEFT JOIN v_rating r ON r.user_id = ug.user_id AND r.game_id = ug.game_id
LEFT JOIN (SELECT user_game_id, MAX(started_at) AS last_played_at FROM Playtime_Session GROUP BY user_game_id) lp ON lp.user_game_id = ug.user_game_id;

-- Catalogue: one row per active game with every many-to-many list collapsed
CREATE OR REPLACE VIEW v_game_catalog AS
SELECT g.game_id, g.title, g.release_date, g.description, g.cover_image, g.is_upcoming,
       dev.developer_id, dev.name AS developer,
       pub.publisher_id, pub.name AS publisher,
       ar.age_ratings,
       gen.genres,
       plat.platforms,
       md.modes,
       COALESCE(rt.rating_count, 0) AS rating_count,
       rt.avg_rating,
       COALESCE(ac.achievement_count, 0) AS achievement_count
FROM v_game g
LEFT JOIN Developer dev ON dev.developer_id = g.developer_id
LEFT JOIN Publisher pub ON pub.publisher_id = g.publisher_id
LEFT JOIN (SELECT gar.game_id,
                  GROUP_CONCAT(CONCAT(a.rating_authority, ' ', a.label)
                               ORDER BY a.rating_authority SEPARATOR ', ') AS age_ratings
             FROM Game_Age_Rating gar
             JOIN Age_Rating a ON a.age_rating_id = gar.age_rating_id
            GROUP BY gar.game_id) ar ON ar.game_id = g.game_id
LEFT JOIN (SELECT gg.game_id,
                  GROUP_CONCAT(gn.name ORDER BY gn.name SEPARATOR ', ') AS genres
             FROM Game_Genre gg JOIN Genre gn ON gn.genre_id = gg.genre_id
            GROUP BY gg.game_id) gen ON gen.game_id = g.game_id
LEFT JOIN (SELECT gp.game_id,
                  GROUP_CONCAT(p.name ORDER BY p.name SEPARATOR ', ') AS platforms
             FROM Game_Platform gp JOIN Platform p ON p.platform_id = gp.platform_id
            GROUP BY gp.game_id) plat ON plat.game_id = g.game_id
LEFT JOIN (SELECT gmm.game_id,
                  GROUP_CONCAT(gm.name ORDER BY gm.name SEPARATOR ', ') AS modes
             FROM Game_Mode_Map gmm JOIN Game_Mode gm ON gm.mode_id = gmm.mode_id
            GROUP BY gmm.game_id) md ON md.game_id = g.game_id
LEFT JOIN (SELECT game_id, COUNT(*) AS rating_count, ROUND(AVG(rating), 2) AS avg_rating
             FROM v_rating GROUP BY game_id) rt ON rt.game_id = g.game_id
LEFT JOIN (SELECT game_id, COUNT(*) AS achievement_count
             FROM Achievement GROUP BY game_id) ac ON ac.game_id = g.game_id;

-- Per-user analytics (games, hours, completion, points, average rating given)
CREATE OR REPLACE VIEW v_user_dashboard AS
SELECT u.user_id, u.username,
       COALESCE(c.games_owned, 0)       AS games_owned,
       COALESCE(c.total_hours, 0)       AS total_playtime_hours,
       COALESCE(c.completed, 0)         AS completed_games,
       ROUND(100 * COALESCE(c.completed, 0) / NULLIF(c.games_owned, 0), 1) AS completion_pct,
       COALESCE(a.points_earned, 0)     AS achievement_points,
       COALESCE(a.unlocked, 0)          AS achievements_unlocked,
       COALESCE(sp.total_spent, 0)      AS total_spent,
       r.avg_rating_given,
       COALESCE(r.ratings_given, 0)     AS ratings_given
FROM v_user u
LEFT JOIN (SELECT user_id, COUNT(*) AS games_owned, SUM(playtime_hours) AS total_hours,
                  SUM(status = 'Completed') AS completed
             FROM v_user_game GROUP BY user_id) c ON c.user_id = u.user_id
LEFT JOIN (SELECT ug.user_id, SUM(ac.points) AS points_earned, COUNT(*) AS unlocked
             FROM User_Achievement ua
             JOIN v_user_game ug ON ug.user_game_id = ua.user_game_id
             JOIN Achievement ac ON ac.achievement_id = ua.achievement_id
            WHERE ua.is_unlocked = 1 GROUP BY ug.user_id) a ON a.user_id = u.user_id
LEFT JOIN (SELECT user_id, SUM(purchase_price) AS total_spent
             FROM v_user_game GROUP BY user_id) sp ON sp.user_id = u.user_id
LEFT JOIN (SELECT user_id, ROUND(AVG(rating), 2) AS avg_rating_given, COUNT(*) AS ratings_given
             FROM v_rating GROUP BY user_id) r ON r.user_id = u.user_id;

-- Every achievement of a collection entry's game, locked or not.
-- Hidden achievements are masked until unlocked.
CREATE OR REPLACE VIEW v_achievement_progress AS
SELECT ug.user_game_id, ug.user_id, a.achievement_id,
       CASE WHEN a.is_hidden = 1 AND COALESCE(ua.is_unlocked, 0) = 0
            THEN 'Hidden achievement' ELSE a.name END        AS name,
       CASE WHEN a.is_hidden = 1 AND COALESCE(ua.is_unlocked, 0) = 0
            THEN NULL ELSE a.description END                 AS description,
       a.points, a.is_hidden, a.rarity,
       COALESCE(ua.progress, 0)    AS progress,
       COALESCE(ua.is_unlocked, 0) AS is_unlocked,
       ua.unlocked_at
FROM v_user_game ug
JOIN Achievement a ON a.game_id = ug.game_id
LEFT JOIN User_Achievement ua
       ON ua.user_game_id = ug.user_game_id AND ua.achievement_id = a.achievement_id;


-- ---------------------------------------------------------------------
-- 4. STORED PROCEDURES (every business write goes through one of these)
--    * Each procedure validates input, checks ownership, and runs as ONE
--      transaction at the caller's level (the backend wraps the call).
--    * SET @app_user_id tags the Audit_Log rows written by the triggers.
--    * Errors are SQLSTATE '45000' with a prefix the backend maps to HTTP:
--        VALIDATION: -> 400   NOT_FOUND: -> 404
--        CONFLICT:   -> 409   FORBIDDEN: -> 403
--    The scripts use DELIMITER $$; MySQL Workbench and the mysql CLI both
--    understand it.
-- ---------------------------------------------------------------------
DELIMITER $$

-- Add a game to a user's collection (re-activates a removed entry) --------
CREATE PROCEDURE sp_add_to_collection(
    IN  p_user_id       INT,
    IN  p_game_id       INT,
    IN  p_platform_id   INT,
    IN  p_purchase_date DATE,
    IN  p_price         DECIMAL(8,2),
    IN  p_status_id     TINYINT,
    OUT p_user_game_id  INT)
BEGIN
    DECLARE v_found    TINYINT DEFAULT 1;
    DECLARE v_existing INT DEFAULT NULL;
    DECLARE v_deleted  TIMESTAMP DEFAULT NULL;
    DECLARE v_started  DATE;
    DECLARE v_completed DATE;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_found = 0;

    SET @app_user_id = p_user_id;
    SET p_price = COALESCE(p_price, 0);
    SET p_status_id = COALESCE(p_status_id, 1);

    IF NOT EXISTS (SELECT 1 FROM User WHERE user_id = p_user_id AND deleted_at IS NULL) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'NOT_FOUND: user does not exist';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM Game WHERE game_id = p_game_id AND deleted_at IS NULL) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'NOT_FOUND: game does not exist';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM Game_Platform
                    WHERE game_id = p_game_id AND platform_id = p_platform_id) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'VALIDATION: this game is not available on that platform';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM Collection_Status WHERE status_id = p_status_id) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'VALIDATION: unknown status';
    END IF;
    IF p_price < 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'VALIDATION: price cannot be negative';
    END IF;
    IF p_purchase_date IS NOT NULL AND p_purchase_date > CURDATE() THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'VALIDATION: purchase date cannot be in the future';
    END IF;

    SET v_started   = IF(p_status_id = 1, NULL, CURDATE());
    SET v_completed = IF(p_status_id = 3, CURDATE(), NULL);

    SET v_found = 1;
    SELECT user_game_id, deleted_at INTO v_existing, v_deleted
      FROM User_Game
     WHERE user_id = p_user_id AND game_id = p_game_id AND platform_id = p_platform_id
       FOR UPDATE;

    IF v_found = 1 AND v_existing IS NOT NULL THEN
        IF v_deleted IS NULL THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'CONFLICT: this game is already in your collection on that platform';
        END IF;
        UPDATE User_Game
           SET deleted_at     = NULL,
               purchase_date  = p_purchase_date,
               purchase_price = p_price,
               status_id      = p_status_id,
               started_at     = IF(p_status_id = 1, started_at, COALESCE(started_at, v_started)),
               completed_at   = IF(p_status_id = 3, COALESCE(completed_at, v_completed), NULL)
         WHERE user_game_id = v_existing;
        SET p_user_game_id = v_existing;
    ELSE
        INSERT INTO User_Game (user_id, game_id, platform_id, purchase_date, purchase_price,
                               status_id, started_at, completed_at)
        VALUES (p_user_id, p_game_id, p_platform_id, p_purchase_date, p_price,
                p_status_id, v_started, v_completed);
        SET p_user_game_id = LAST_INSERT_ID();
    END IF;
END$$

-- Change the status of a collection entry (optimistic locking) --------------
CREATE PROCEDURE sp_update_collection_entry(
    IN p_user_id          INT,
    IN p_user_game_id     INT,
    IN p_status_id        TINYINT,
    IN p_expected_version INT)
BEGIN
    DECLARE v_found     TINYINT DEFAULT 1;
    DECLARE v_version   INT;
    DECLARE v_started   DATE;
    DECLARE v_completed DATE;
    DECLARE v_msg       VARCHAR(120);
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_found = 0;

    SET @app_user_id = p_user_id;
    IF NOT EXISTS (SELECT 1 FROM Collection_Status WHERE status_id = p_status_id) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'VALIDATION: unknown status';
    END IF;

    SELECT started_at, completed_at, row_version INTO v_started, v_completed, v_version
      FROM User_Game
     WHERE user_game_id = p_user_game_id AND user_id = p_user_id AND deleted_at IS NULL
       FOR UPDATE;
    IF v_found = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'NOT_FOUND: collection entry not found';
    END IF;
    IF p_expected_version IS NOT NULL AND p_expected_version <> v_version THEN
        SET v_msg = CONCAT('CONFLICT: entry changed since you loaded it (yours v', p_expected_version, ', current v', v_version, ')');
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_msg;
    END IF;

    UPDATE User_Game
       SET status_id    = p_status_id,
           started_at   = IF(p_status_id <> 1, COALESCE(v_started, CURDATE()), v_started),
           completed_at = IF(p_status_id = 3, COALESCE(v_completed, CURDATE()), NULL)
     WHERE user_game_id = p_user_game_id;
END$$

-- Remove an entry from a collection (soft delete; progress is kept) ---------
CREATE PROCEDURE sp_remove_from_collection(
    IN p_user_id      INT,
    IN p_user_game_id INT)
BEGIN
    SET @app_user_id = p_user_id;
    UPDATE User_Game SET deleted_at = CURRENT_TIMESTAMP
     WHERE user_game_id = p_user_game_id AND user_id = p_user_id AND deleted_at IS NULL;
    IF ROW_COUNT() = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'NOT_FOUND: collection entry not found';
    END IF;
END$$

-- Record a play session; moves a Backlog entry to Playing ---------------------
CREATE PROCEDURE sp_log_playtime(
    IN  p_user_id      INT,
    IN  p_user_game_id INT,
    IN  p_started_at   DATETIME,
    IN  p_minutes      INT,
    IN  p_note         VARCHAR(255),
    OUT p_session_id   BIGINT)
BEGIN
    DECLARE v_found  TINYINT DEFAULT 1;
    DECLARE v_status TINYINT;
    DECLARE v_start  DATE;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_found = 0;

    SET @app_user_id = p_user_id;
    IF p_minutes IS NULL OR p_minutes < 1 OR p_minutes > 1440 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'VALIDATION: minutes must be between 1 and 1440';
    END IF;
    IF p_started_at IS NULL OR p_started_at > DATE_ADD(UTC_TIMESTAMP(), INTERVAL 5 MINUTE) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'VALIDATION: session start must be a past date and time';
    END IF;

    SELECT status_id, started_at INTO v_status, v_start
      FROM User_Game
     WHERE user_game_id = p_user_game_id AND user_id = p_user_id AND deleted_at IS NULL
       FOR UPDATE;
    IF v_found = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'NOT_FOUND: collection entry not found';
    END IF;

    INSERT INTO Playtime_Session (user_game_id, started_at, duration_minutes, note)
    VALUES (p_user_game_id, p_started_at, p_minutes, p_note);
    SET p_session_id = LAST_INSERT_ID();

    IF v_status = 1 THEN
        UPDATE User_Game
           SET status_id = 2, started_at = COALESCE(started_at, DATE(p_started_at))
         WHERE user_game_id = p_user_game_id;
    END IF;
END$$

-- Create or change a user's rating of a game (re-activates a removed one) ------
CREATE PROCEDURE sp_upsert_rating(
    IN  p_user_id          INT,
    IN  p_game_id          INT,
    IN  p_rating           TINYINT,
    IN  p_review           TEXT,
    IN  p_expected_version INT,
    OUT p_rating_id        INT)
BEGIN
    DECLARE v_found    TINYINT DEFAULT 1;
    DECLARE v_existing INT DEFAULT NULL;
    DECLARE v_deleted  TIMESTAMP DEFAULT NULL;
    DECLARE v_version  INT DEFAULT NULL;
    DECLARE v_msg      VARCHAR(120);
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_found = 0;

    SET @app_user_id = p_user_id;
    IF p_rating IS NULL OR p_rating < 1 OR p_rating > 10 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'VALIDATION: rating must be between 1 and 10';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM User WHERE user_id = p_user_id AND deleted_at IS NULL) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'NOT_FOUND: user does not exist';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM Game WHERE game_id = p_game_id AND deleted_at IS NULL) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'NOT_FOUND: game does not exist';
    END IF;

    SELECT rating_id, deleted_at, row_version INTO v_existing, v_deleted, v_version
      FROM Rating WHERE user_id = p_user_id AND game_id = p_game_id FOR UPDATE;

    IF v_found = 1 AND v_existing IS NOT NULL THEN
        IF v_deleted IS NULL AND p_expected_version IS NOT NULL AND p_expected_version <> v_version THEN
            SET v_msg = CONCAT('CONFLICT: rating changed since you loaded it (yours v', p_expected_version, ', current v', v_version, ')');
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_msg;
        END IF;
        UPDATE Rating
           SET rating = p_rating, review_text = p_review,
               review_date = CURDATE(), deleted_at = NULL
         WHERE rating_id = v_existing;
        SET p_rating_id = v_existing;
    ELSE
        INSERT INTO Rating (user_id, game_id, rating, review_text)
        VALUES (p_user_id, p_game_id, p_rating, p_review);
        SET p_rating_id = LAST_INSERT_ID();
    END IF;
END$$

-- Remove a rating (soft delete) ------------------------------------------------
CREATE PROCEDURE sp_delete_rating(
    IN p_user_id INT,
    IN p_game_id INT)
BEGIN
    SET @app_user_id = p_user_id;
    UPDATE Rating SET deleted_at = CURRENT_TIMESTAMP
     WHERE user_id = p_user_id AND game_id = p_game_id AND deleted_at IS NULL;
    IF ROW_COUNT() = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'NOT_FOUND: rating not found';
    END IF;
END$$

-- Set progress on one achievement (>= 100 unlocks it, < 100 keeps/relocks it) ---
CREATE PROCEDURE sp_set_achievement_progress(
    IN p_user_id        INT,
    IN p_user_game_id   INT,
    IN p_achievement_id INT,
    IN p_progress       DECIMAL(5,2))
BEGIN
    DECLARE v_found INT DEFAULT 1;
    DECLARE v_game  INT;
    DECLARE v_ach_game INT;
    DECLARE v_unlock TINYINT;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_found = 0;

    SET @app_user_id = p_user_id;
    IF p_progress IS NULL OR p_progress < 0 OR p_progress > 100 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'VALIDATION: progress must be between 0 and 100';
    END IF;

    SELECT game_id INTO v_game FROM User_Game
     WHERE user_game_id = p_user_game_id AND user_id = p_user_id AND deleted_at IS NULL;
    IF v_found = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'NOT_FOUND: collection entry not found';
    END IF;

    SET v_found = 1;
    SELECT game_id INTO v_ach_game FROM Achievement WHERE achievement_id = p_achievement_id;
    IF v_found = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'NOT_FOUND: achievement not found';
    END IF;
    IF v_ach_game <> v_game THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'VALIDATION: achievement belongs to a different game';
    END IF;

    SET v_unlock = IF(p_progress >= 100, 1, 0);
    INSERT INTO User_Achievement (user_game_id, achievement_id, game_id, unlocked_at, progress, is_unlocked)
    VALUES (p_user_game_id, p_achievement_id, v_game,
            IF(v_unlock = 1, UTC_TIMESTAMP(), NULL),
            IF(v_unlock = 1, 100, p_progress), v_unlock)
    AS new_row
    ON DUPLICATE KEY UPDATE
        unlocked_at = IF(new_row.is_unlocked = 1, COALESCE(User_Achievement.unlocked_at, new_row.unlocked_at), NULL),
        progress    = new_row.progress,
        is_unlocked = new_row.is_unlocked;
END$$

-- Admin: hide a user and everything they own (reversible by hand) ---------------
CREATE PROCEDURE sp_deactivate_user(
    IN p_actor_id  INT,
    IN p_target_id INT)
BEGIN
    DECLARE v_role VARCHAR(20) DEFAULT NULL;
    SET @app_user_id = p_actor_id;

    SELECT r.name INTO v_role FROM User u JOIN Role r ON r.role_id = u.role_id
     WHERE u.user_id = p_actor_id AND u.deleted_at IS NULL;
    IF v_role IS NULL OR v_role <> 'ADMIN' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'FORBIDDEN: administrator role required';
    END IF;
    IF p_actor_id = p_target_id THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'VALIDATION: you cannot deactivate your own account';
    END IF;

    UPDATE User SET deleted_at = CURRENT_TIMESTAMP
     WHERE user_id = p_target_id AND deleted_at IS NULL;
    IF ROW_COUNT() = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'NOT_FOUND: user not found';
    END IF;
    UPDATE User_Game SET deleted_at = CURRENT_TIMESTAMP
     WHERE user_id = p_target_id AND deleted_at IS NULL;
    UPDATE Rating SET deleted_at = CURRENT_TIMESTAMP
     WHERE user_id = p_target_id AND deleted_at IS NULL;
    UPDATE Auth_Session SET revoked_at = UTC_TIMESTAMP()
     WHERE user_id = p_target_id AND revoked_at IS NULL;
END$$

-- Admin: permanent erasure of a user (GDPR "right to be forgotten") -------------
-- Removes the user and everything they own, then scrubs personal data that the
-- audit trigger copied into Audit_Log. The erasure itself stays on record.
CREATE PROCEDURE sp_purge_user(
    IN p_actor_id  INT,
    IN p_target_id INT)
BEGIN
    DECLARE v_role VARCHAR(20) DEFAULT NULL;
    SET @app_user_id = p_actor_id;

    SELECT r.name INTO v_role FROM User u JOIN Role r ON r.role_id = u.role_id
     WHERE u.user_id = p_actor_id AND u.deleted_at IS NULL;
    IF v_role IS NULL OR v_role <> 'ADMIN' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'FORBIDDEN: administrator role required';
    END IF;
    IF p_actor_id = p_target_id THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'VALIDATION: you cannot erase your own account';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM User WHERE user_id = p_target_id) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'NOT_FOUND: user not found';
    END IF;

    DELETE FROM Auth_Session WHERE user_id = p_target_id;
    DELETE FROM User_Game    WHERE user_id = p_target_id;   -- cascades sessions + achievement progress
    DELETE FROM Rating       WHERE user_id = p_target_id;
    DELETE FROM User         WHERE user_id = p_target_id;

    SET @gv_allow_audit_scrub = 1;
    UPDATE Audit_Log
       SET old_values = JSON_OBJECT('erased', TRUE), new_values = NULL
     WHERE table_name = 'User' AND record_pk = CAST(p_target_id AS CHAR);
    SET @gv_allow_audit_scrub = NULL;
END$$

DELIMITER ;


-- ---------------------------------------------------------------------
-- 5. SAMPLE DATA (parents first, then children)
--    Every demo account uses the password  ChangeMe!2026  (change it!).
--    Hashes are PBKDF2-HMAC-SHA256, 600000 iterations, random 16-byte salts.
--    aarav_k is the ADMIN demo account. Activity data is fictional.
-- ---------------------------------------------------------------------

-- Role
INSERT INTO Role (role_id, name, description) VALUES
  (1, 'USER', 'Normal member: manages only their own data.'),
  (2, 'ADMIN', 'Administrator: may deactivate or erase users and read the audit log.');

-- Collection_Status
INSERT INTO Collection_Status (status_id, name, sort_order) VALUES
  (1, 'Backlog', 3),
  (2, 'Playing', 1),
  (3, 'Completed', 5),
  (4, 'On Hold', 2),
  (5, 'Dropped', 4);

-- User (7 rows; user 7 deliberately owns no games)
INSERT INTO User (user_id, username, email, password_hash, role_id, join_date, profile_picture) VALUES
  (1, 'aarav_k', 'aarav.k@example.com', 'pbkdf2-sha256$600000$F2wT/0iGA+t3bhEAbOvQtA==$ZWFrgE7NjITS6+N2fmFyVyrFkw9mWKLEYCVS0hANCWU=', 2, '2023-08-02', 'https://avatars.example.com/aarav_k.png'),
  (2, 'meera_s', 'meera.s@example.com', 'pbkdf2-sha256$600000$aG3tLGsTKmT5HLFPT0jJWg==$eXLeFFVfh63wmdktZrqnserrT8/PCq2GeiTW8ev/yII=', 1, '2022-09-05', 'https://avatars.example.com/meera_s.png'),
  (3, 'rohan_v', 'rohan.v@example.com', 'pbkdf2-sha256$600000$fvxXeZXF1Zy8U3aqM6v41A==$xoV10boGOqsQ4qAExv4kBjK6VV9Q1D42dA8nuacv8XE=', 1, '2023-01-17', NULL),
  (4, 'ananya_d', 'ananya.d@example.com', 'pbkdf2-sha256$600000$OyP8nEQbDZlftEWYBjiFzg==$YiuvRQWPAWL1D/8qi1N5un4JWzx6hhH1eCKoZQSWcp0=', 1, '2022-03-21', 'https://avatars.example.com/ananya_d.png'),
  (5, 'kabir_m', 'kabir.m@example.com', 'pbkdf2-sha256$600000$1qjDjXGzTga1T8znPZwTHg==$TsYFD3eYN54AcEp5kT5r6o9tggZVLOR3YE6jCF930t0=', 1, '2023-02-11', NULL),
  (6, 'ishita_r', 'ishita.r@example.com', 'pbkdf2-sha256$600000$NyBgw2m1j82P5YVDx3huNw==$2XlFd2xkx4OPJYg6j5Mia4hgBKZMFgE2ssMuTgmWyDc=', 1, '2021-11-30', 'https://avatars.example.com/ishita_r.png'),
  (7, 'new_player_07', 'new.player07@example.com', 'pbkdf2-sha256$600000$cKI9AsYxmE1rKYnnaAgBMQ==$Wz7C8Rp0MsqEl+/eKZC4M7PH9aN6KjvC20Cr4/DKN6c=', 1, '2026-10-20', NULL);

-- Portal demo accounts; all initially use the documented demo password.
INSERT INTO User (user_id, username, email, password_hash, role_id, join_date, date_of_birth) VALUES
  (8, 'admin', 'admin@gamevault.local', 'pbkdf2-sha256$600000$R1ZkZW1vU2FsdDAwMDAwMQ==$VPwxfHrmgP05WcnvbSbhfgIvNv5CNyW0zJen1qgaO4c=', 2, CURRENT_DATE, NULL),
  (9, 'NickMaxima', 'nickmaxima@gamevault.local', 'pbkdf2-sha256$600000$R1ZkZW1vU2FsdDAwMDAwMQ==$VPwxfHrmgP05WcnvbSbhfgIvNv5CNyW0zJen1qgaO4c=', 1, CURRENT_DATE, NULL),
  (10, 'Dibu2007', 'dibu2007@gamevault.local', 'pbkdf2-sha256$600000$R1ZkZW1vU2FsdDAwMDAwMQ==$VPwxfHrmgP05WcnvbSbhfgIvNv5CNyW0zJen1qgaO4c=', 1, CURRENT_DATE, NULL),
  (11, 'Xlitz', 'xlitz@gamevault.local', 'pbkdf2-sha256$600000$R1ZkZW1vU2FsdDAwMDAwMQ==$VPwxfHrmgP05WcnvbSbhfgIvNv5CNyW0zJen1qgaO4c=', 1, CURRENT_DATE, '2010-01-01');
INSERT INTO Friendship (requester_id, recipient_id, status) SELECT a.user_id, b.user_id, 'ACCEPTED' FROM User a JOIN User b WHERE a.username = 'NickMaxima' AND b.username = 'Dibu2007';

-- Developer (17 rows)
INSERT INTO Developer (developer_id, name, country, website) VALUES
  (1, 'Santa Monica Studio', 'United States', 'https://sms.playstation.com'),
  (2, 'Naughty Dog', 'United States', 'https://www.naughtydog.com'),
  (3, 'FromSoftware', 'Japan', 'https://www.fromsoftware.jp'),
  (4, 'Game Science', 'China', NULL),
  (5, 'CD Projekt Red', 'Poland', 'https://www.cdprojektred.com'),
  (6, 'Mojang Studios', 'Sweden', 'https://www.mojang.com'),
  (7, 'Supergiant Games', 'United States', 'https://www.supergiantgames.com'),
  (8, 'Larian Studios', 'Belgium', 'https://larian.com'),
  (9, 'Playground Games', 'United Kingdom', 'https://playground-games.com'),
  (10, 'Team Cherry', 'Australia', 'https://www.teamcherry.com.au'),
  (11, 'ConcernedApe', 'United States', 'https://www.stardewvalley.net'),
  (12, 'Maddy Makes Games', 'Canada', 'https://www.celestegame.com'),
  (13, 'Rockstar Games', 'United States', 'https://www.rockstargames.com'),
  (14, 'Nintendo EPD', 'Japan', 'https://www.nintendo.com'),
  (15, 'id Software', 'United States', 'https://www.idsoftware.com'),
  (16, 'Arrowhead Game Studios', 'Sweden', 'https://www.arrowheadgamestudios.com'),
  (17, 'Firaxis Games', 'United States', 'https://firaxis.com');

-- Publisher (15 rows)
-- Self-published studios appear in both Developer and Publisher: the roles are separate entities.
INSERT INTO Publisher (publisher_id, name, country, website) VALUES
  (1, 'Sony Interactive Entertainment', 'United States', 'https://www.playstation.com'),
  (2, 'Bandai Namco Entertainment', 'Japan', 'https://www.bandainamcoent.com'),
  (3, 'Game Science', 'China', NULL),
  (4, 'CD Projekt', 'Poland', 'https://www.cdprojekt.com'),
  (5, 'Xbox Game Studios', 'United States', 'https://www.xbox.com'),
  (6, 'Supergiant Games', 'United States', 'https://www.supergiantgames.com'),
  (7, 'Larian Studios', 'Belgium', 'https://larian.com'),
  (8, 'Team Cherry', 'Australia', 'https://www.teamcherry.com.au'),
  (9, 'ConcernedApe', 'United States', 'https://www.stardewvalley.net'),
  (10, 'Maddy Makes Games', 'Canada', 'https://www.celestegame.com'),
  (11, 'Rockstar Games', 'United States', 'https://www.rockstargames.com'),
  (12, 'Nintendo', 'Japan', 'https://www.nintendo.com'),
  (13, 'Bethesda Softworks', 'United States', 'https://bethesda.net'),
  (14, 'Activision', 'United States', 'https://www.activision.com'),
  (15, '2K', 'United States', 'https://2k.com');

-- Genre (12 rows)
INSERT INTO Genre (genre_id, name, description) VALUES
  (1, 'Action', 'Gameplay centred on reflexes, combat and physical challenges.'),
  (2, 'Adventure', 'Story-driven exploration and discovery.'),
  (3, 'RPG', 'Character progression, builds and narrative choices.'),
  (4, 'Open World', 'Large explorable maps with non-linear objectives.'),
  (5, 'Roguelike', 'Procedurally varied runs with permadeath and meta-progression.'),
  (6, 'Metroidvania', 'Interconnected maps gated by abilities and backtracking.'),
  (7, 'Racing', 'Competitive or free-roam driving.'),
  (8, 'Sandbox', 'Open-ended creation and player-defined goals.'),
  (9, 'Platformer', 'Precision jumping and traversal.'),
  (10, 'Simulation', 'Systems that model real or fictional activities.'),
  (11, 'Strategy', 'Planning, tactics and resource management.'),
  (12, 'Shooter', 'Ranged combat from first- or third-person view.');

-- Platform (6 rows)
-- PC has no manufacturer or release year, which demonstrates the nullable columns.
INSERT INTO Platform (platform_id, name, manufacturer, release_year) VALUES
  (1, 'PC (Windows)', NULL, NULL),
  (2, 'PlayStation 5', 'Sony', 2020),
  (3, 'PlayStation 4', 'Sony', 2013),
  (4, 'Xbox Series X|S', 'Microsoft', 2020),
  (5, 'Xbox One', 'Microsoft', 2013),
  (6, 'Nintendo Switch', 'Nintendo', 2017);

-- Age_Rating (9 rows: 4 ESRB + 5 PEGI)
INSERT INTO Age_Rating (age_rating_id, label, rating_authority, description, minimum_age) VALUES
  (1, 'E', 'ESRB', 'Everyone: content is generally suitable for all ages.', 0),
  (2, 'E10+', 'ESRB', 'Everyone 10+: may contain mild violence or mild language.', 10),
  (3, 'T', 'ESRB', 'Teen: may contain violence, crude humor or suggestive themes.', 13),
  (4, 'M', 'ESRB', 'Mature 17+: may contain intense violence, blood and strong language.', 17),
  (5, '3', 'PEGI', 'Suitable for all age groups.', 3),
  (6, '7', 'PEGI', 'Mild fantasy violence or frightening scenes.', 7),
  (7, '12', 'PEGI', 'Moderate violence and mild bad language.', 12),
  (8, '16', 'PEGI', 'Realistic violence and stronger language.', 16),
  (9, '18', 'PEGI', 'Graphic violence and adult content.', 18);

-- Game_Mode (5 rows)
INSERT INTO Game_Mode (mode_id, name, description) VALUES
  (1, 'Single-player', 'One player, offline or online.'),
  (2, 'Online Co-op', 'Players cooperate over the internet.'),
  (3, 'Online Multiplayer', 'Players compete or share a world over the internet.'),
  (4, 'Local Co-op', 'Players cooperate on the same device or screen.'),
  (5, 'Local Multiplayer', 'Players compete on the same device or screen.');

-- Game (20 rows)
-- Cover art uses Steam CDN library artwork where available; fallback art is illustrative.
INSERT INTO Game (game_id, title, release_date, description, cover_image, developer_id, publisher_id) VALUES
  (1, 'God of War Ragnarök', '2022-11-09', 'Kratos and Atreus travel the Nine Realms as Ragnarök approaches.', 'https://cdn.akamai.steamstatic.com/steam/apps/2322010/library_600x900.jpg', 1, 1),
  (2, 'The Last of Us Part I', '2022-09-02', 'A rebuilt version of the post-pandemic story of Joel and Ellie.', 'https://cdn.akamai.steamstatic.com/steam/apps/1888930/library_600x900.jpg', 2, 1),
  (3, 'Elden Ring', '2022-02-25', 'A huge open-world action RPG set in the Lands Between.', 'https://cdn.akamai.steamstatic.com/steam/apps/1245620/library_600x900.jpg', 3, 2),
  (4, 'Black Myth: Wukong', '2024-08-20', 'An action RPG inspired by Journey to the West.', 'https://cdn.akamai.steamstatic.com/steam/apps/2358720/library_600x900.jpg', 4, 3),
  (5, 'Cyberpunk 2077', '2020-12-10', 'An open-world action RPG set in the dystopian Night City.', 'https://cdn.akamai.steamstatic.com/steam/apps/1091500/library_600x900.jpg', 5, 4),
  (6, 'Minecraft', '2011-11-18', 'A block-based sandbox about mining, building and survival.', 'https://images.unsplash.com/photo-1607513746994-51f730a44832?w=700&auto=format&fit=crop', 6, 5),
  (7, 'Hades', '2020-09-17', 'A roguelike dungeon crawler about escaping the Underworld.', 'https://cdn.akamai.steamstatic.com/steam/apps/1145360/library_600x900.jpg', 7, 6),
  (8, 'Baldur''s Gate 3', '2023-08-03', 'A turn-based, party-driven RPG built on Dungeons & Dragons rules.', 'https://cdn.akamai.steamstatic.com/steam/apps/1086940/library_600x900.jpg', 8, 7),
  (9, 'Forza Horizon 5', '2021-11-09', 'An open-world racing festival set in Mexico.', 'https://cdn.akamai.steamstatic.com/steam/apps/1551360/library_600x900.jpg', 9, 5),
  (10, 'Hollow Knight', '2017-02-24', 'A hand-drawn metroidvania set in the ruined insect kingdom of Hallownest.', 'https://cdn.akamai.steamstatic.com/steam/apps/367520/library_600x900.jpg', 10, 8),
  (11, 'Stardew Valley', '2016-02-26', 'A farming and life simulation with a deep social system.', 'https://cdn.akamai.steamstatic.com/steam/apps/413150/library_600x900.jpg', 11, 9),
  (12, 'Celeste', '2018-01-25', 'A tight precision platformer about climbing a mountain.', 'https://cdn.akamai.steamstatic.com/steam/apps/504230/library_600x900.jpg', 12, 10),
  (13, 'The Witcher 3: Wild Hunt', '2015-05-19', 'A story-rich open-world RPG following the monster hunter Geralt.', 'https://cdn.akamai.steamstatic.com/steam/apps/292030/library_600x900.jpg', 5, 4),
  (14, 'Red Dead Redemption 2', '2018-10-26', 'A western epic about the decline of the Van der Linde gang.', 'https://cdn.akamai.steamstatic.com/steam/apps/1174180/library_600x900.jpg', 13, 11),
  (15, 'The Legend of Zelda: Breath of the Wild', '2017-03-03', 'An open-air Zelda adventure built around exploration and physics.', 'https://images.unsplash.com/photo-1511512578047-dfb367046420?w=700&auto=format&fit=crop', 14, 12),
  (16, 'DOOM Eternal', '2020-03-20', 'A fast first-person shooter about ripping through demonic invasions.', 'https://cdn.akamai.steamstatic.com/steam/apps/782330/library_600x900.jpg', 15, 13),
  (17, 'Mario Kart 8 Deluxe', '2017-04-28', 'Arcade kart racing with items, 48 tracks and split-screen play.', 'https://images.unsplash.com/photo-1511512578047-dfb367046420?w=700&auto=format&fit=crop', 14, 12),
  (18, 'Helldivers 2', '2024-02-08', 'A cooperative third-person shooter about spreading managed democracy.', 'https://cdn.akamai.steamstatic.com/steam/apps/553850/library_600x900.jpg', 16, 1),
  (19, 'Sekiro: Shadows Die Twice', '2019-03-22', 'A posture-based action adventure set in sengoku-era Japan.', 'https://cdn.akamai.steamstatic.com/steam/apps/814380/library_600x900.jpg', 3, 14),
  (20, 'Sid Meier''s Civilization VI', '2016-10-21', 'A turn-based 4X strategy game about leading a civilization through history.', 'https://cdn.akamai.steamstatic.com/steam/apps/289070/library_600x900.jpg', 17, 15);

-- Game_Screenshot (sample screenshots)
INSERT INTO Game_Screenshot (game_id, image_url, caption, sort_order) VALUES
  (1, 'https://cdn.akamai.steamstatic.com/steam/apps/2322010/header.jpg', 'Official game artwork', 1),
  (2, 'https://cdn.akamai.steamstatic.com/steam/apps/1888930/header.jpg', 'Official game artwork', 1),
  (3, 'https://cdn.akamai.steamstatic.com/steam/apps/1245620/header.jpg', 'Official game artwork', 1),
  (4, 'https://cdn.akamai.steamstatic.com/steam/apps/2358720/header.jpg', 'Official game artwork', 1),
  (5, 'https://cdn.akamai.steamstatic.com/steam/apps/1091500/header.jpg', 'Official game artwork', 1),
  (7, 'https://cdn.akamai.steamstatic.com/steam/apps/1145360/header.jpg', 'Official game artwork', 1),
  (8, 'https://cdn.akamai.steamstatic.com/steam/apps/1086940/header.jpg', 'Official game artwork', 1),
  (9, 'https://cdn.akamai.steamstatic.com/steam/apps/1551360/header.jpg', 'Official game artwork', 1),
  (10, 'https://cdn.akamai.steamstatic.com/steam/apps/367520/header.jpg', 'Official game artwork', 1),
  (11, 'https://cdn.akamai.steamstatic.com/steam/apps/413150/header.jpg', 'Official game artwork', 1),
  (12, 'https://cdn.akamai.steamstatic.com/steam/apps/504230/header.jpg', 'Official game artwork', 1),
  (13, 'https://cdn.akamai.steamstatic.com/steam/apps/292030/header.jpg', 'Official game artwork', 1);

-- Game_Age_Rating (30 rows)
-- ESRB classes checked against esrb.org for Black Myth: Wukong, Hades, Hollow Knight, Civilization VI and Helldivers 2; the others and all PEGI classes are from general knowledge.
INSERT INTO Game_Age_Rating (game_id, rating_authority, age_rating_id) VALUES
  (1, 'ESRB', 4),
  (1, 'PEGI', 9),
  (2, 'ESRB', 4),
  (2, 'PEGI', 9),
  (3, 'ESRB', 4),
  (3, 'PEGI', 8),
  (4, 'ESRB', 3),
  (5, 'ESRB', 4),
  (5, 'PEGI', 9),
  (6, 'ESRB', 2),
  (6, 'PEGI', 6),
  (7, 'ESRB', 3),
  (8, 'ESRB', 4),
  (9, 'ESRB', 1),
  (9, 'PEGI', 5),
  (10, 'ESRB', 2),
  (11, 'ESRB', 2),
  (12, 'ESRB', 2),
  (13, 'ESRB', 4),
  (13, 'PEGI', 9),
  (14, 'ESRB', 4),
  (14, 'PEGI', 9),
  (15, 'ESRB', 2),
  (16, 'ESRB', 4),
  (16, 'PEGI', 9),
  (17, 'ESRB', 1),
  (17, 'PEGI', 5),
  (18, 'ESRB', 4),
  (19, 'ESRB', 4),
  (20, 'ESRB', 2);

-- Game_Genre (43 rows)
INSERT INTO Game_Genre (game_id, genre_id) VALUES
  (1, 1),
  (1, 2),
  (2, 1),
  (2, 2),
  (3, 1),
  (3, 3),
  (3, 4),
  (4, 1),
  (4, 3),
  (5, 3),
  (5, 4),
  (5, 1),
  (6, 8),
  (6, 2),
  (7, 5),
  (7, 1),
  (8, 3),
  (8, 11),
  (9, 7),
  (9, 4),
  (10, 6),
  (10, 9),
  (10, 1),
  (11, 10),
  (11, 3),
  (12, 9),
  (13, 3),
  (13, 4),
  (13, 1),
  (14, 1),
  (14, 2),
  (14, 4),
  (15, 1),
  (15, 2),
  (15, 4),
  (16, 12),
  (16, 1),
  (17, 7),
  (18, 12),
  (18, 1),
  (19, 1),
  (19, 2),
  (20, 11);

-- Game_Platform (71 rows)
-- NULL dates mean the release date on that platform is not recorded.
INSERT INTO Game_Platform (game_id, platform_id, platform_release_date) VALUES
  (1, 3, '2022-11-09'),
  (1, 2, '2022-11-09'),
  (1, 1, '2024-09-19'),
  (2, 2, '2022-09-02'),
  (2, 1, '2023-03-28'),
  (3, 1, '2022-02-25'),
  (3, 3, '2022-02-25'),
  (3, 2, '2022-02-25'),
  (3, 4, '2022-02-25'),
  (3, 5, '2022-02-25'),
  (4, 1, '2024-08-20'),
  (4, 2, '2024-08-20'),
  (4, 4, '2025-08-20'),
  (5, 1, '2020-12-10'),
  (5, 3, '2020-12-10'),
  (5, 5, '2020-12-10'),
  (5, 2, '2022-02-15'),
  (5, 4, '2022-02-15'),
  (6, 1, '2011-11-18'),
  (6, 3, '2014-09-04'),
  (6, 5, '2014-09-05'),
  (6, 6, '2017-05-11'),
  (6, 2, NULL),
  (6, 4, NULL),
  (7, 1, '2020-09-17'),
  (7, 6, '2020-09-17'),
  (7, 3, '2021-08-13'),
  (7, 2, '2021-08-13'),
  (7, 4, '2021-08-13'),
  (8, 1, '2023-08-03'),
  (8, 2, '2023-09-06'),
  (8, 4, '2023-12-07'),
  (9, 4, '2021-11-09'),
  (9, 5, '2021-11-09'),
  (9, 1, '2021-11-09'),
  (9, 2, '2025-04-29'),
  (10, 1, '2017-02-24'),
  (10, 6, '2018-06-12'),
  (10, 3, '2018-09-25'),
  (10, 5, '2018-09-25'),
  (11, 1, '2016-02-26'),
  (11, 3, '2016-12-13'),
  (11, 5, '2016-12-14'),
  (11, 6, '2017-10-05'),
  (12, 1, '2018-01-25'),
  (12, 6, '2018-01-25'),
  (12, 3, '2018-01-25'),
  (12, 5, '2018-01-25'),
  (13, 1, '2015-05-19'),
  (13, 3, '2015-05-19'),
  (13, 5, '2015-05-19'),
  (13, 6, '2019-10-15'),
  (13, 2, '2022-12-14'),
  (14, 3, '2018-10-26'),
  (14, 5, '2018-10-26'),
  (14, 1, '2019-11-05'),
  (15, 6, '2017-03-03'),
  (16, 1, '2020-03-20'),
  (16, 3, '2020-03-20'),
  (16, 5, '2020-03-20'),
  (16, 6, '2021-12-08'),
  (17, 6, '2017-04-28'),
  (18, 1, '2024-02-08'),
  (18, 2, '2024-02-08'),
  (19, 1, '2019-03-22'),
  (19, 3, '2019-03-22'),
  (19, 5, '2019-03-22'),
  (20, 1, '2016-10-21'),
  (20, 6, '2018-11-15'),
  (20, 3, '2019-11-22'),
  (20, 5, '2019-11-22');

-- Game_Mode_Map (36 rows)
INSERT INTO Game_Mode_Map (game_id, mode_id) VALUES
  (1, 1),
  (2, 1),
  (3, 1),
  (3, 2),
  (3, 3),
  (4, 1),
  (5, 1),
  (6, 1),
  (6, 2),
  (6, 3),
  (6, 4),
  (7, 1),
  (8, 1),
  (8, 2),
  (8, 4),
  (9, 1),
  (9, 3),
  (10, 1),
  (11, 1),
  (11, 2),
  (11, 4),
  (12, 1),
  (13, 1),
  (14, 1),
  (14, 3),
  (15, 1),
  (16, 1),
  (16, 3),
  (17, 1),
  (17, 3),
  (17, 5),
  (18, 2),
  (19, 1),
  (20, 1),
  (20, 3),
  (20, 5);

-- User_Game (40 rows)
-- Every (game_id, platform_id) pair exists in Game_Platform (enforced by fk_user_game_supported_platform). Playtime = baseline_hours + sessions.
INSERT INTO User_Game (user_game_id, user_id, game_id, platform_id, purchase_date, purchase_price, baseline_hours, status_id, started_at, completed_at) VALUES
  (1, 1, 1, 1, '2024-09-25', 59.99, 35.3, 3, '2024-09-26', '2024-11-02'),
  (2, 1, 3, 1, '2022-03-01', 59.99, 112.6, 3, '2022-03-02', '2022-06-20'),
  (3, 1, 7, 1, '2021-01-10', 24.99, 49.3, 3, '2021-01-11', '2021-03-14'),
  (4, 1, 10, 1, '2020-05-20', 14.99, 26.4, 2, '2020-05-21', NULL),
  (5, 1, 8, 1, '2023-08-03', 59.99, 74.4, 2, '2023-08-04', NULL),
  (6, 1, 5, 1, '2022-11-24', 29.99, 18.7, 4, '2022-11-25', NULL),
  (7, 1, 19, 1, '2023-01-15', 39.99, 5.5, 5, '2023-01-16', NULL),
  (8, 2, 2, 2, '2022-09-02', 69.99, 20.4, 3, '2022-09-03', '2022-09-20'),
  (9, 2, 1, 2, '2022-11-09', 69.99, 32.7, 3, '2022-11-10', '2022-12-15'),
  (10, 2, 3, 2, '2022-04-02', 59.99, 55.2, 2, '2022-04-03', NULL),
  (11, 2, 4, 2, '2024-08-20', 59.99, 37.4, 3, '2024-08-21', '2024-09-14'),
  (12, 2, 6, 6, '2019-06-01', 29.99, 102.0, 2, '2019-06-02', NULL),
  (13, 2, 17, 6, '2020-03-10', 59.99, 64.2, 2, '2020-03-11', NULL),
  (14, 2, 7, 6, '2021-02-14', 24.99, 41.6, 3, '2021-02-15', '2021-04-03'),
  (15, 3, 5, 1, '2021-01-05', 59.99, 66.3, 3, '2021-01-06', '2021-03-02'),
  (16, 3, 13, 1, '2019-12-01', 39.99, 136.0, 3, '2019-12-02', '2020-04-18'),
  (17, 3, 9, 4, '2021-11-09', 59.99, 80.8, 2, '2021-11-09', NULL),
  (18, 3, 3, 4, '2022-02-25', 59.99, 15.3, 5, '2022-02-26', NULL),
  (19, 3, 16, 1, '2020-04-01', 39.99, 18.3, 3, '2020-04-02', '2020-04-20'),
  (20, 3, 8, 4, '2023-12-07', 59.99, 0.0, 1, NULL, NULL),
  (21, 3, 6, 1, '2018-07-01', 26.95, 178.5, 2, '2018-07-02', NULL),
  (22, 4, 15, 6, '2017-03-03', 59.99, 93.5, 3, '2017-03-04', '2017-09-10'),
  (23, 4, 10, 6, '2018-06-12', 14.99, 35.7, 3, '2018-06-13', '2018-08-01'),
  (24, 4, 12, 6, '2018-02-01', 19.99, 9.8, 3, '2018-02-02', '2018-02-20'),
  (25, 4, 11, 6, '2017-10-05', 14.99, 119.0, 2, '2017-10-06', NULL),
  (26, 4, 6, 6, '2018-12-24', 0.0, 12.8, 2, '2018-12-26', NULL),
  (27, 4, 7, 1, '2022-07-20', 24.99, 10.2, 4, '2022-07-21', NULL),
  (28, 4, 20, 6, '2019-01-12', 59.99, 28.0, 2, '2019-01-13', NULL),
  (29, 5, 1, 2, '2023-01-10', 49.99, 7.6, 5, '2023-01-11', NULL),
  (30, 5, 2, 2, '2023-03-01', 59.99, 0.0, 1, NULL, NULL),
  (31, 5, 18, 2, '2024-02-08', 39.99, 127.5, 2, '2024-02-08', NULL),
  (32, 5, 14, 3, '2019-01-20', 59.99, 57.8, 3, '2019-01-21', '2019-04-12'),
  (33, 5, 13, 2, '2023-02-02', 19.99, 46.8, 2, '2023-02-03', NULL),
  (34, 5, 5, 2, '2022-03-05', 39.99, 44.2, 3, '2022-03-06', '2022-05-01'),
  (35, 6, 11, 1, '2016-04-01', 14.99, 170.0, 3, '2016-04-02', '2016-09-30'),
  (36, 6, 12, 1, '2018-02-10', 19.99, 11.9, 3, '2018-02-11', '2018-03-01'),
  (37, 6, 10, 1, '2018-03-05', 14.99, 46.8, 3, '2018-03-06', '2018-05-20'),
  (38, 6, 20, 1, '2017-01-15', 59.99, 357.0, 2, '2017-01-16', NULL),
  (39, 6, 8, 1, '2023-08-03', 59.99, 25.5, 4, '2023-08-04', NULL),
  (40, 6, 3, 1, '2022-02-25', 59.99, 83.3, 3, '2022-02-26', '2022-05-10');

-- Shared-progress demo entries for NickMaxima and Dibu2007.
INSERT INTO User_Game (user_game_id, user_id, game_id, platform_id, purchase_date, purchase_price, baseline_hours, status_id, started_at, completed_at) VALUES
  (41, 9, 3, 1, '2026-10-01', 0.00, 34.2, 2, '2026-10-01', NULL),
  (42, 10, 7, 1, '2026-09-15', 0.00, 24.8, 2, '2026-09-15', NULL);

-- Playtime_Session (82 rows)
INSERT INTO Playtime_Session (user_game_id, started_at, duration_minutes, note) VALUES
  (1, '2024-10-20 17:30:00', 36, NULL),
  (1, '2024-10-22 14:00:00', 336, 'Co-op night'),
  (2, '2022-03-21 21:45:00', 402, NULL),
  (2, '2022-05-04 12:45:00', 792, NULL),
  (3, '2021-01-19 20:15:00', 24, NULL),
  (3, '2021-02-01 13:15:00', 498, 'Evening session'),
  (4, '2021-01-26 16:30:00', 6, NULL),
  (4, '2026-10-10 22:15:00', 270, 'Short break session'),
  (5, '2024-07-13 20:30:00', 492, 'Boss attempts'),
  (5, '2025-10-19 18:30:00', 294, 'Weekend marathon'),
  (6, '2024-10-30 21:45:00', 66, 'Weekend marathon'),
  (6, '2025-05-15 13:45:00', 132, 'Weekend marathon'),
  (7, '2024-08-06 13:00:00', 42, 'Co-op night'),
  (7, '2026-06-20 14:30:00', 18, 'Short break session'),
  (8, '2022-09-10 13:45:00', 48, 'Co-op night'),
  (8, '2022-09-17 19:15:00', 168, 'Short break session'),
  (9, '2022-11-23 20:45:00', 138, NULL),
  (9, '2022-12-06 15:15:00', 210, 'Boss attempts'),
  (10, '2024-08-17 12:00:00', 348, 'Finally got past it'),
  (10, '2026-09-01 12:15:00', 240, NULL),
  (11, '2024-09-09 22:15:00', 330, 'Weekend marathon'),
  (11, '2024-09-12 18:45:00', 66, 'Evening session'),
  (12, '2023-05-13 15:15:00', 654, 'Co-op night'),
  (12, '2025-01-11 12:45:00', 426, NULL),
  (13, '2024-05-20 22:30:00', 12, NULL),
  (13, '2025-08-16 21:15:00', 666, 'Short break session'),
  (14, '2021-02-26 12:45:00', 30, NULL),
  (14, '2021-03-21 14:00:00', 414, NULL),
  (15, '2021-01-20 17:30:00', 162, NULL),
  (15, '2021-01-26 13:15:00', 540, 'Short break session'),
  (16, '2019-12-06 16:30:00', 708, 'Evening session'),
  (16, '2020-03-01 13:15:00', 732, NULL),
  (17, '2025-01-26 17:00:00', 636, NULL),
  (17, '2025-09-10 13:15:00', 216, NULL),
  (18, '2023-04-11 20:15:00', 18, 'Evening session'),
  (18, '2024-08-11 14:30:00', 144, 'Co-op night'),
  (19, '2020-04-06 19:00:00', 30, NULL),
  (19, '2020-04-19 21:45:00', 162, 'Co-op night'),
  (21, '2021-05-01 14:00:00', 1080, 'Short break session'),
  (21, '2022-11-13 21:45:00', 66, NULL),
  (21, '2024-02-09 18:00:00', 744, 'Weekend marathon'),
  (22, '2017-04-06 14:30:00', 924, 'Co-op night'),
  (22, '2017-05-27 19:45:00', 66, NULL),
  (23, '2018-06-27 22:15:00', 264, 'Boss attempts'),
  (23, '2018-07-14 13:30:00', 114, 'Finally got past it'),
  (24, '2018-02-07 19:00:00', 54, 'Short break session'),
  (24, '2018-02-08 16:30:00', 48, NULL),
  (25, '2018-10-17 14:00:00', 600, 'Evening session'),
  (25, '2025-10-28 14:30:00', 660, NULL),
  (26, '2020-07-23 21:00:00', 48, 'Boss attempts'),
  (26, '2025-04-20 21:45:00', 84, NULL),
  (27, '2022-11-15 21:45:00', 24, 'Finally got past it'),
  (27, '2024-10-13 14:30:00', 84, 'Finally got past it'),
  (28, '2020-01-08 12:15:00', 180, 'Short break session'),
  (28, '2021-04-12 16:30:00', 120, 'Weekend marathon'),
  (29, '2023-01-29 15:30:00', 60, 'Co-op night'),
  (29, '2025-06-23 18:30:00', 24, 'Finally got past it'),
  (31, '2024-03-02 17:00:00', 342, 'Weekend marathon'),
  (31, '2024-06-11 21:45:00', 1008, 'Short break session'),
  (32, '2019-01-27 17:45:00', 402, 'Boss attempts'),
  (32, '2019-02-20 17:45:00', 210, 'Short break session'),
  (33, '2025-01-01 14:15:00', 384, NULL),
  (33, '2026-08-22 22:30:00', 108, 'Weekend marathon'),
  (34, '2022-03-07 12:30:00', 348, NULL),
  (34, '2022-04-27 18:00:00', 120, NULL),
  (35, '2016-05-03 14:30:00', 780, 'Finally got past it'),
  (35, '2016-05-04 21:15:00', 834, NULL),
  (35, '2016-06-14 22:00:00', 186, NULL),
  (36, '2018-02-12 15:15:00', 24, 'Short break session'),
  (36, '2018-02-26 19:00:00', 102, 'Finally got past it'),
  (37, '2018-04-13 22:00:00', 318, 'Finally got past it'),
  (37, '2018-05-16 19:30:00', 174, 'Co-op night'),
  (38, '2019-07-08 17:30:00', 240, 'Weekend marathon'),
  (38, '2021-10-16 17:00:00', 696, 'Short break session'),
  (38, '2022-02-05 13:00:00', 888, 'Boss attempts'),
  (38, '2023-02-19 12:45:00', 72, NULL),
  (38, '2023-07-22 17:00:00', 1062, 'Evening session'),
  (38, '2024-02-18 18:15:00', 822, 'Short break session'),
  (39, '2024-04-23 16:45:00', 48, 'Short break session'),
  (39, '2026-05-02 17:45:00', 222, 'Short break session'),
  (40, '2022-04-03 13:15:00', 120, 'Short break session'),
  (40, '2022-04-19 22:30:00', 762, NULL);

INSERT INTO Playtime_Session (user_game_id, started_at, duration_minutes, note) VALUES
  (41, '2026-11-15 19:30:00', 85, 'Demo friend progress'),
  (42, '2026-11-16 20:00:00', 50, 'Demo friend progress');

-- Rating (25 rows)
-- Black Myth: Wukong, Sekiro, Mario Kart 8 Deluxe, DOOM Eternal and Civilization VI have no ratings on purpose.
INSERT INTO Rating (rating_id, user_id, game_id, rating, review_text, review_date) VALUES
  (1, 1, 1, 9, 'Great combat and a satisfying end to the saga. A few pacing dips in the middle.', '2024-11-04'),
  (2, 1, 3, 10, 'Exploration at its best. Every direction hides something worth finding.', '2022-06-22'),
  (3, 1, 7, 9, 'Each run feels different and the story rewards failing. Endlessly replayable.', '2021-03-16'),
  (4, 1, 10, 9, 'Atmospheric and generous in content. The map takes some getting used to.', '2020-08-12'),
  (5, 1, 8, 10, 'Reactive writing and tactical combat that rewards experimenting.', '2023-12-20'),
  (6, 2, 2, 10, 'The remake keeps everything that made the original land so hard.', '2022-09-22'),
  (7, 2, 1, 9, 'Strong performances and a world that is a pleasure to travel through.', '2022-12-17'),
  (8, 2, 6, 9, 'Still the best creative sandbox. Better with friends.', '2021-06-10'),
  (9, 2, 7, 9, 'Excellent on Switch. The runs are short enough for a commute.', '2021-04-05'),
  (10, 3, 5, 8, 'Rough at launch, but the world and quests are strong after the patches.', '2021-03-05'),
  (11, 3, 13, 10, 'Side quests with real stakes. A benchmark for open-world RPGs.', '2020-04-20'),
  (12, 3, 9, 9, 'Beautiful, varied and always something to chase.', '2022-01-15'),
  (13, 3, 3, 5, 'Impressive world, but the difficulty was not for me and I bounced off.', '2022-03-20'),
  (14, 4, 15, 10, 'Freedom in every direction. Made exploring feel new again.', '2017-09-12'),
  (15, 4, 10, 10, 'Huge amount of game for the price. The boss fights are superb.', '2018-08-03'),
  (16, 4, 12, 9, 'Tough but fair, with assist options that respect the player.', '2018-02-22'),
  (17, 4, 11, 9, 'Relaxing and bottomless. Always one more day to play.', '2018-01-10'),
  (18, 5, 1, 6, 'Looks great but the combat did not hold me, so I dropped it.', '2023-02-02'),
  (19, 5, 18, 8, 'Chaotic co-op fun. Even better with a coordinated squad.', '2024-05-18'),
  (20, 5, 14, 9, 'Slow-burn story and astonishing detail.', '2019-04-14'),
  (21, 5, 5, 7, 'Strong ending and great atmosphere, with some leftover rough edges.', '2022-05-03'),
  (22, 6, 11, 10, 'My comfort game. Two hundred hours and counting.', '2016-10-02'),
  (23, 6, 12, 9, 'Excellent level design and a story that means something.', '2018-03-02'),
  (24, 6, 10, 9, 'A world you want to get lost in.', '2018-05-22'),
  (25, 6, 3, 9, 'Brutal and beautiful. Several boss fights are unforgettable.', '2022-05-12');

-- Achievement (50 rows)
-- 13 games have achievements; the other 7 have none on purpose. Names are illustrative.
INSERT INTO Achievement (achievement_id, game_id, name, description, points, is_hidden) VALUES
  (1, 1, 'Fimbulwinter Survivor', 'Finish the opening chapters of the story.', 10, 0),
  (2, 1, 'Realm Traveler', 'Visit every one of the Nine Realms.', 25, 0),
  (3, 1, 'Valkyrie Slayer', 'Defeat every Valkyrie.', 50, 0),
  (4, 1, 'Ragnarök Complete', 'Finish the main story.', 100, 0),
  (5, 2, 'Crafty Survivor', 'Craft 50 items during one playthrough.', 25, 0),
  (6, 2, 'Collector', 'Find every artifact.', 50, 0),
  (7, 2, 'Endurance', 'Finish the main story.', 100, 0),
  (8, 3, 'Lands Between Explorer', 'Discover 100 map locations.', 25, 0),
  (9, 3, 'Shardbearer Slayer', 'Defeat your first Shardbearer.', 25, 0),
  (10, 3, 'Great Rune Restored', 'Restore a Great Rune.', 25, 0),
  (11, 3, 'Elden Lord', 'Reach the main ending.', 100, 0),
  (12, 3, 'Hidden Ending Seeker', 'Reach a secret ending.', 50, 1),
  (13, 4, 'Destined One', 'Finish the first chapter.', 10, 0),
  (14, 4, 'Yaoguai Hunter', 'Defeat 50 yaoguai.', 25, 0),
  (15, 4, 'Transformation Master', 'Use every transformation.', 25, 0),
  (16, 4, 'Journey Complete', 'Finish the main story.', 100, 0),
  (17, 5, 'Nomad Beginnings', 'Complete the prologue.', 10, 0),
  (18, 5, 'Cyberware Collector', 'Install 10 cyberware pieces.', 25, 0),
  (19, 5, 'Street Legend', 'Reach maximum Street Cred.', 50, 0),
  (20, 5, 'Night City Legend', 'Reach any ending.', 100, 1),
  (21, 6, 'Taking Inventory', 'Open your inventory.', 10, 0),
  (22, 6, 'Getting an Upgrade', 'Craft a better pickaxe.', 10, 0),
  (23, 6, 'Diamonds!', 'Mine your first diamond.', 25, 0),
  (24, 6, 'The End?', 'Enter the End dimension.', 50, 0),
  (25, 7, 'Out of the Underworld', 'Escape the Underworld once.', 25, 0),
  (26, 7, 'Weapon Master', 'Clear a run with every weapon.', 50, 0),
  (27, 7, 'Heat Seeker', 'Escape with 10 Heat or more.', 50, 0),
  (28, 7, 'Pact of Punishment', 'Clear a run with 15 Heat or more.', 50, 0),
  (29, 7, 'Full House', 'Meet every major character.', 25, 1),
  (30, 8, 'Party Assembled', 'Recruit your first three companions.', 10, 0),
  (31, 8, 'Tadpole Resolved', 'Resolve the tadpole problem.', 25, 0),
  (32, 8, 'Camp Secrets', 'Find every hidden camp scene.', 25, 1),
  (33, 8, 'Honour Mode Clear', 'Finish the game on Honour Mode.', 100, 0),
  (34, 9, 'Festival Starter', 'Complete the opening races.', 10, 0),
  (35, 9, 'Mexico Explorer', 'Discover every biome.', 25, 0),
  (36, 9, 'Hot Lap Collector', 'Earn gold in every road race.', 50, 0),
  (37, 10, 'Kingdom Traveller', 'Reach the City of Tears.', 10, 0),
  (38, 10, 'Charm Collector', 'Collect 20 charms.', 25, 0),
  (39, 10, 'Pantheon Challenger', 'Clear a Pantheon of Hallownest.', 50, 0),
  (40, 10, 'True Ending', 'Reach the true ending.', 100, 0),
  (41, 10, 'Dream Seeker', 'Find every Dream Nail secret.', 50, 1),
  (42, 11, 'First Harvest', 'Harvest your first crop.', 10, 0),
  (43, 11, 'Community Hero', 'Restore the Community Center.', 50, 0),
  (44, 11, 'Perfection', 'Reach 100% Perfection.', 100, 0),
  (45, 12, 'Strawberry Collector', 'Collect 20 strawberries.', 25, 0),
  (46, 12, 'Summit Reached', 'Reach the summit.', 50, 0),
  (47, 12, 'B-Side Climber', 'Clear every B-Side.', 50, 1),
  (48, 13, 'Wolf School Initiate', 'Complete the first contract.', 10, 0),
  (49, 13, 'Gwent Champion', 'Win 20 Gwent matches.', 50, 0),
  (50, 13, 'End of Journey', 'Finish the main story.', 100, 0);

UPDATE Achievement SET rarity = CASE WHEN points >= 100 THEN 'LEGENDARY' WHEN points >= 50 THEN 'EPIC' WHEN points >= 25 THEN 'RARE' ELSE 'COMMON' END;

-- User_Achievement (122 rows)
-- Unlocked => timestamp + 100%. Locked => no timestamp + progress below 100.
INSERT INTO User_Achievement (user_game_id, achievement_id, game_id, unlocked_at, progress, is_unlocked) VALUES
  (1, 1, 1, '2024-10-04 11:30:02', 100.0, 1),
  (1, 2, 1, '2024-10-12 12:23:03', 100.0, 1),
  (1, 3, 1, '2024-10-20 13:16:04', 100.0, 1),
  (1, 4, 1, '2024-10-28 14:09:05', 100.0, 1),
  (2, 8, 3, '2022-03-22 18:18:10', 100.0, 1),
  (2, 9, 3, '2022-04-11 10:11:11', 100.0, 1),
  (2, 10, 3, '2022-05-01 11:04:12', 100.0, 1),
  (2, 11, 3, '2022-05-21 11:57:13', 100.0, 1),
  (2, 12, 3, NULL, 61.3, 0),
  (3, 25, 7, '2021-01-22 15:56:28', 100.0, 1),
  (3, 26, 7, '2021-02-02 16:49:29', 100.0, 1),
  (3, 27, 7, '2021-02-13 17:42:30', 100.0, 1),
  (3, 28, 7, '2021-02-25 18:35:31', 100.0, 1),
  (3, 29, 7, '2021-03-08 10:28:32', 100.0, 1),
  (4, 37, 10, '2020-08-01 18:09:41', 100.0, 1),
  (4, 38, 10, '2020-10-13 10:02:42', 100.0, 1),
  (4, 39, 10, NULL, 25.77, 0),
  (4, 40, 10, NULL, 0.0, 0),
  (4, 41, 10, NULL, 0.0, 0),
  (5, 30, 8, '2023-10-31 12:35:35', 100.0, 1),
  (5, 31, 8, '2024-01-28 13:28:36', 100.0, 1),
  (5, 32, 8, NULL, 16.17, 0),
  (5, 33, 8, NULL, 0.0, 0),
  (6, 17, 5, '2023-02-21 10:43:23', 100.0, 1),
  (6, 18, 5, NULL, 64.0, 0),
  (6, 19, 5, NULL, 0.0, 0),
  (6, 20, 5, NULL, 0.0, 0),
  (8, 5, 2, '2022-09-07 10:21:13', 100.0, 1),
  (8, 6, 2, '2022-09-12 11:14:14', 100.0, 1),
  (8, 7, 2, '2022-09-17 12:07:15', 100.0, 1),
  (9, 1, 1, '2022-11-17 16:26:10', 100.0, 1),
  (9, 2, 1, '2022-11-25 17:19:11', 100.0, 1),
  (9, 3, 1, '2022-12-03 18:12:12', 100.0, 1),
  (9, 4, 1, '2022-12-11 10:05:13', 100.0, 1),
  (10, 8, 3, '2022-06-14 14:14:18', 100.0, 1),
  (10, 9, 3, '2022-08-26 15:07:19', 100.0, 1),
  (10, 10, 3, NULL, 25.58, 0),
  (10, 11, 3, NULL, 0.0, 0),
  (10, 12, 3, NULL, 0.0, 0),
  (11, 13, 4, '2024-08-26 10:16:24', 100.0, 1),
  (11, 14, 4, '2024-08-31 11:09:25', 100.0, 1),
  (11, 15, 4, '2024-09-06 12:02:26', 100.0, 1),
  (11, 16, 4, '2024-09-11 12:55:27', 100.0, 1),
  (12, 21, 6, '2019-08-29 17:57:33', 100.0, 1),
  (12, 22, 6, '2019-11-26 18:50:34', 100.0, 1),
  (12, 23, 6, NULL, 77.64, 0),
  (12, 24, 6, NULL, 0.0, 0),
  (14, 25, 7, '2021-02-23 13:43:39', 100.0, 1),
  (14, 26, 7, '2021-03-04 14:36:40', 100.0, 1),
  (14, 27, 7, '2021-03-12 15:29:41', 100.0, 1),
  (14, 28, 7, '2021-03-21 16:22:42', 100.0, 1),
  (14, 29, 7, NULL, 33.4, 0),
  (15, 17, 5, '2021-01-18 16:16:32', 100.0, 1),
  (15, 18, 5, '2021-01-30 17:09:33', 100.0, 1),
  (15, 19, 5, '2021-02-11 18:02:34', 100.0, 1),
  (15, 20, 5, '2021-02-23 18:55:35', 100.0, 1),
  (16, 48, 13, '2020-01-10 17:16:04', 100.0, 1),
  (16, 49, 13, '2020-02-18 18:09:05', 100.0, 1),
  (16, 50, 13, '2020-03-29 10:02:06', 100.0, 1),
  (17, 34, 9, '2022-03-03 14:31:51', 100.0, 1),
  (17, 35, 9, NULL, 18.34, 0),
  (17, 36, 9, NULL, 0.0, 0),
  (18, 8, 3, '2022-05-09 10:10:26', 100.0, 1),
  (18, 9, 3, NULL, 55.69, 0),
  (18, 10, 3, NULL, 0.0, 0),
  (18, 11, 3, NULL, 0.0, 0),
  (18, 12, 3, NULL, 0.0, 0),
  (21, 21, 6, '2018-09-28 14:30:42', 100.0, 1),
  (21, 22, 6, '2018-12-26 15:23:43', 100.0, 1),
  (21, 23, 6, NULL, 85.76, 0),
  (21, 24, 6, NULL, 0.0, 0),
  (23, 37, 10, '2018-06-21 11:52:00', 100.0, 1),
  (23, 38, 10, '2018-06-30 12:45:01', 100.0, 1),
  (23, 39, 10, '2018-07-09 13:38:02', 100.0, 1),
  (23, 40, 10, '2018-07-18 14:31:03', 100.0, 1),
  (23, 41, 10, NULL, 70.73, 0),
  (24, 45, 12, '2018-02-07 10:33:09', 100.0, 1),
  (24, 46, 12, '2018-02-12 11:26:10', 100.0, 1),
  (24, 47, 12, '2018-02-17 12:19:11', 100.0, 1),
  (25, 42, 11, '2018-01-28 17:31:07', 100.0, 1),
  (25, 43, 11, NULL, 40.47, 0),
  (25, 44, 11, NULL, 0.0, 0),
  (26, 21, 6, '2019-03-24 17:35:47', 100.0, 1),
  (26, 22, 6, '2019-06-21 18:28:48', 100.0, 1),
  (26, 23, 6, NULL, 63.11, 0),
  (26, 24, 6, NULL, 0.0, 0),
  (27, 25, 7, '2022-10-01 12:44:52', 100.0, 1),
  (27, 26, 7, NULL, 61.88, 0),
  (27, 27, 7, NULL, 0.0, 0),
  (27, 28, 7, NULL, 0.0, 0),
  (27, 29, 7, NULL, 0.0, 0),
  (29, 1, 1, '2023-04-09 10:46:30', 100.0, 1),
  (29, 2, 1, NULL, 25.77, 0),
  (29, 3, 1, NULL, 0.0, 0),
  (29, 4, 1, NULL, 0.0, 0),
  (33, 48, 13, '2023-05-28 18:45:21', 100.0, 1),
  (33, 49, 13, NULL, 18.38, 0),
  (33, 50, 13, NULL, 0.0, 0),
  (34, 17, 5, '2022-03-18 18:59:51', 100.0, 1),
  (34, 18, 5, '2022-03-30 10:52:52', 100.0, 1),
  (34, 19, 5, '2022-04-12 11:45:53', 100.0, 1),
  (34, 20, 5, NULL, 72.38, 0),
  (35, 42, 11, '2016-05-23 14:41:17', 100.0, 1),
  (35, 43, 11, '2016-07-14 15:34:18', 100.0, 1),
  (35, 44, 11, '2016-09-04 16:27:19', 100.0, 1),
  (36, 45, 12, '2018-02-16 17:57:21', 100.0, 1),
  (36, 46, 12, '2018-02-21 18:50:22', 100.0, 1),
  (36, 47, 12, '2018-02-26 10:43:23', 100.0, 1),
  (37, 37, 10, '2018-03-19 11:30:14', 100.0, 1),
  (37, 38, 10, '2018-04-02 12:23:15', 100.0, 1),
  (37, 39, 10, '2018-04-15 13:16:16', 100.0, 1),
  (37, 40, 10, '2018-04-29 14:09:17', 100.0, 1),
  (37, 41, 10, NULL, 30.4, 0),
  (39, 30, 8, '2023-10-31 15:33:09', 100.0, 1),
  (39, 31, 8, NULL, 88.93, 0),
  (39, 32, 8, NULL, 0.0, 0),
  (39, 33, 8, NULL, 0.0, 0),
  (40, 8, 3, '2022-03-11 14:44:48', 100.0, 1),
  (40, 9, 3, '2022-03-24 15:37:49', 100.0, 1),
  (40, 10, 3, '2022-04-06 16:30:50', 100.0, 1),
  (40, 11, 3, '2022-04-20 17:23:51', 100.0, 1),
  (40, 12, 3, NULL, 47.97, 0);

INSERT INTO User_Achievement (user_game_id, achievement_id, game_id, unlocked_at, progress, is_unlocked)
SELECT 41, achievement_id, game_id, '2026-10-20 12:00:00', 100, 1 FROM Achievement WHERE name = 'Lands Between Explorer';
INSERT INTO User_Achievement (user_game_id, achievement_id, game_id, unlocked_at, progress, is_unlocked)
SELECT 41, achievement_id, game_id, NULL, 70, 0 FROM Achievement WHERE name = 'Shardbearer Slayer';
INSERT INTO User_Achievement (user_game_id, achievement_id, game_id, unlocked_at, progress, is_unlocked)
SELECT 42, achievement_id, game_id, '2026-10-01 12:00:00', 100, 1 FROM Achievement WHERE name = 'Out of the Underworld';

-- ---------------------------------------------------------------------
-- 6. TRIGGERS (installed after the seed data on purpose, see D10)
--    a) optimistic-locking version bump   b) audit trail   c) Audit_Log guard
-- ---------------------------------------------------------------------

CREATE TRIGGER trg_user_game_bv BEFORE UPDATE ON User_Game
FOR EACH ROW SET NEW.row_version = OLD.row_version + 1;

CREATE TRIGGER trg_rating_bv BEFORE UPDATE ON Rating
FOR EACH ROW SET NEW.row_version = OLD.row_version + 1;

CREATE TRIGGER trg_user_ai AFTER INSERT ON User FOR EACH ROW
  INSERT INTO Audit_Log (table_name, record_pk, action, changed_by, new_values)
  VALUES ('User', CAST(NEW.user_id AS CHAR), 'INSERT', @app_user_id, JSON_OBJECT('user_id', NEW.user_id, 'username', NEW.username, 'email', NEW.email, 'role_id', NEW.role_id, 'join_date', NEW.join_date, 'profile_picture', NEW.profile_picture, 'deleted_at', NEW.deleted_at));

-- UPDATE is logged only when an audited column really changed
CREATE TRIGGER trg_user_au AFTER UPDATE ON User FOR EACH ROW
  INSERT INTO Audit_Log (table_name, record_pk, action, changed_by, old_values, new_values)
  SELECT 'User', CAST(NEW.user_id AS CHAR), 'UPDATE', @app_user_id, JSON_OBJECT('user_id', OLD.user_id, 'username', OLD.username, 'email', OLD.email, 'role_id', OLD.role_id, 'join_date', OLD.join_date, 'profile_picture', OLD.profile_picture, 'deleted_at', OLD.deleted_at), JSON_OBJECT('user_id', NEW.user_id, 'username', NEW.username, 'email', NEW.email, 'role_id', NEW.role_id, 'join_date', NEW.join_date, 'profile_picture', NEW.profile_picture, 'deleted_at', NEW.deleted_at)
  FROM DUAL WHERE NOT (JSON_OBJECT('user_id', OLD.user_id, 'username', OLD.username, 'email', OLD.email, 'role_id', OLD.role_id, 'join_date', OLD.join_date, 'profile_picture', OLD.profile_picture, 'deleted_at', OLD.deleted_at) <=> JSON_OBJECT('user_id', NEW.user_id, 'username', NEW.username, 'email', NEW.email, 'role_id', NEW.role_id, 'join_date', NEW.join_date, 'profile_picture', NEW.profile_picture, 'deleted_at', NEW.deleted_at));

CREATE TRIGGER trg_user_ad AFTER DELETE ON User FOR EACH ROW
  INSERT INTO Audit_Log (table_name, record_pk, action, changed_by, old_values)
  VALUES ('User', CAST(OLD.user_id AS CHAR), 'DELETE', @app_user_id, JSON_OBJECT('user_id', OLD.user_id, 'username', OLD.username, 'email', OLD.email, 'role_id', OLD.role_id, 'join_date', OLD.join_date, 'profile_picture', OLD.profile_picture, 'deleted_at', OLD.deleted_at));

CREATE TRIGGER trg_game_ai AFTER INSERT ON Game FOR EACH ROW
  INSERT INTO Audit_Log (table_name, record_pk, action, changed_by, new_values)
  VALUES ('Game', CAST(NEW.game_id AS CHAR), 'INSERT', @app_user_id, JSON_OBJECT('game_id', NEW.game_id, 'title', NEW.title, 'release_date', NEW.release_date, 'description', NEW.description, 'cover_image', NEW.cover_image, 'is_upcoming', NEW.is_upcoming, 'developer_id', NEW.developer_id, 'publisher_id', NEW.publisher_id, 'deleted_at', NEW.deleted_at));

-- UPDATE is logged only when an audited column really changed
CREATE TRIGGER trg_game_au AFTER UPDATE ON Game FOR EACH ROW
  INSERT INTO Audit_Log (table_name, record_pk, action, changed_by, old_values, new_values)
  SELECT 'Game', CAST(NEW.game_id AS CHAR), 'UPDATE', @app_user_id, JSON_OBJECT('game_id', OLD.game_id, 'title', OLD.title, 'release_date', OLD.release_date, 'description', OLD.description, 'cover_image', OLD.cover_image, 'is_upcoming', OLD.is_upcoming, 'developer_id', OLD.developer_id, 'publisher_id', OLD.publisher_id, 'deleted_at', OLD.deleted_at), JSON_OBJECT('game_id', NEW.game_id, 'title', NEW.title, 'release_date', NEW.release_date, 'description', NEW.description, 'cover_image', NEW.cover_image, 'is_upcoming', NEW.is_upcoming, 'developer_id', NEW.developer_id, 'publisher_id', NEW.publisher_id, 'deleted_at', NEW.deleted_at)
  FROM DUAL WHERE NOT (JSON_OBJECT('game_id', OLD.game_id, 'title', OLD.title, 'release_date', OLD.release_date, 'description', OLD.description, 'cover_image', OLD.cover_image, 'is_upcoming', OLD.is_upcoming, 'developer_id', OLD.developer_id, 'publisher_id', OLD.publisher_id, 'deleted_at', OLD.deleted_at) <=> JSON_OBJECT('game_id', NEW.game_id, 'title', NEW.title, 'release_date', NEW.release_date, 'description', NEW.description, 'cover_image', NEW.cover_image, 'is_upcoming', NEW.is_upcoming, 'developer_id', NEW.developer_id, 'publisher_id', NEW.publisher_id, 'deleted_at', NEW.deleted_at));

CREATE TRIGGER trg_game_ad AFTER DELETE ON Game FOR EACH ROW
  INSERT INTO Audit_Log (table_name, record_pk, action, changed_by, old_values)
  VALUES ('Game', CAST(OLD.game_id AS CHAR), 'DELETE', @app_user_id, JSON_OBJECT('game_id', OLD.game_id, 'title', OLD.title, 'release_date', OLD.release_date, 'description', OLD.description, 'cover_image', OLD.cover_image, 'is_upcoming', OLD.is_upcoming, 'developer_id', OLD.developer_id, 'publisher_id', OLD.publisher_id, 'deleted_at', OLD.deleted_at));

CREATE TRIGGER trg_user_game_ai AFTER INSERT ON User_Game FOR EACH ROW
  INSERT INTO Audit_Log (table_name, record_pk, action, changed_by, new_values)
  VALUES ('User_Game', CAST(NEW.user_game_id AS CHAR), 'INSERT', @app_user_id, JSON_OBJECT('user_game_id', NEW.user_game_id, 'user_id', NEW.user_id, 'game_id', NEW.game_id, 'platform_id', NEW.platform_id, 'purchase_date', NEW.purchase_date, 'purchase_price', NEW.purchase_price, 'baseline_hours', NEW.baseline_hours, 'status_id', NEW.status_id, 'started_at', NEW.started_at, 'completed_at', NEW.completed_at, 'deleted_at', NEW.deleted_at, 'row_version', NEW.row_version));

-- UPDATE is logged only when an audited column really changed
CREATE TRIGGER trg_user_game_au AFTER UPDATE ON User_Game FOR EACH ROW
  INSERT INTO Audit_Log (table_name, record_pk, action, changed_by, old_values, new_values)
  SELECT 'User_Game', CAST(NEW.user_game_id AS CHAR), 'UPDATE', @app_user_id, JSON_OBJECT('user_game_id', OLD.user_game_id, 'user_id', OLD.user_id, 'game_id', OLD.game_id, 'platform_id', OLD.platform_id, 'purchase_date', OLD.purchase_date, 'purchase_price', OLD.purchase_price, 'baseline_hours', OLD.baseline_hours, 'status_id', OLD.status_id, 'started_at', OLD.started_at, 'completed_at', OLD.completed_at, 'deleted_at', OLD.deleted_at, 'row_version', OLD.row_version), JSON_OBJECT('user_game_id', NEW.user_game_id, 'user_id', NEW.user_id, 'game_id', NEW.game_id, 'platform_id', NEW.platform_id, 'purchase_date', NEW.purchase_date, 'purchase_price', NEW.purchase_price, 'baseline_hours', NEW.baseline_hours, 'status_id', NEW.status_id, 'started_at', NEW.started_at, 'completed_at', NEW.completed_at, 'deleted_at', NEW.deleted_at, 'row_version', NEW.row_version)
  FROM DUAL WHERE NOT (JSON_OBJECT('user_game_id', OLD.user_game_id, 'user_id', OLD.user_id, 'game_id', OLD.game_id, 'platform_id', OLD.platform_id, 'purchase_date', OLD.purchase_date, 'purchase_price', OLD.purchase_price, 'baseline_hours', OLD.baseline_hours, 'status_id', OLD.status_id, 'started_at', OLD.started_at, 'completed_at', OLD.completed_at, 'deleted_at', OLD.deleted_at, 'row_version', OLD.row_version) <=> JSON_OBJECT('user_game_id', NEW.user_game_id, 'user_id', NEW.user_id, 'game_id', NEW.game_id, 'platform_id', NEW.platform_id, 'purchase_date', NEW.purchase_date, 'purchase_price', NEW.purchase_price, 'baseline_hours', NEW.baseline_hours, 'status_id', NEW.status_id, 'started_at', NEW.started_at, 'completed_at', NEW.completed_at, 'deleted_at', NEW.deleted_at, 'row_version', NEW.row_version));

CREATE TRIGGER trg_user_game_ad AFTER DELETE ON User_Game FOR EACH ROW
  INSERT INTO Audit_Log (table_name, record_pk, action, changed_by, old_values)
  VALUES ('User_Game', CAST(OLD.user_game_id AS CHAR), 'DELETE', @app_user_id, JSON_OBJECT('user_game_id', OLD.user_game_id, 'user_id', OLD.user_id, 'game_id', OLD.game_id, 'platform_id', OLD.platform_id, 'purchase_date', OLD.purchase_date, 'purchase_price', OLD.purchase_price, 'baseline_hours', OLD.baseline_hours, 'status_id', OLD.status_id, 'started_at', OLD.started_at, 'completed_at', OLD.completed_at, 'deleted_at', OLD.deleted_at, 'row_version', OLD.row_version));

CREATE TRIGGER trg_rating_ai AFTER INSERT ON Rating FOR EACH ROW
  INSERT INTO Audit_Log (table_name, record_pk, action, changed_by, new_values)
  VALUES ('Rating', CAST(NEW.rating_id AS CHAR), 'INSERT', @app_user_id, JSON_OBJECT('rating_id', NEW.rating_id, 'user_id', NEW.user_id, 'game_id', NEW.game_id, 'rating', NEW.rating, 'review_text', NEW.review_text, 'review_date', NEW.review_date, 'deleted_at', NEW.deleted_at, 'row_version', NEW.row_version));

-- UPDATE is logged only when an audited column really changed
CREATE TRIGGER trg_rating_au AFTER UPDATE ON Rating FOR EACH ROW
  INSERT INTO Audit_Log (table_name, record_pk, action, changed_by, old_values, new_values)
  SELECT 'Rating', CAST(NEW.rating_id AS CHAR), 'UPDATE', @app_user_id, JSON_OBJECT('rating_id', OLD.rating_id, 'user_id', OLD.user_id, 'game_id', OLD.game_id, 'rating', OLD.rating, 'review_text', OLD.review_text, 'review_date', OLD.review_date, 'deleted_at', OLD.deleted_at, 'row_version', OLD.row_version), JSON_OBJECT('rating_id', NEW.rating_id, 'user_id', NEW.user_id, 'game_id', NEW.game_id, 'rating', NEW.rating, 'review_text', NEW.review_text, 'review_date', NEW.review_date, 'deleted_at', NEW.deleted_at, 'row_version', NEW.row_version)
  FROM DUAL WHERE NOT (JSON_OBJECT('rating_id', OLD.rating_id, 'user_id', OLD.user_id, 'game_id', OLD.game_id, 'rating', OLD.rating, 'review_text', OLD.review_text, 'review_date', OLD.review_date, 'deleted_at', OLD.deleted_at, 'row_version', OLD.row_version) <=> JSON_OBJECT('rating_id', NEW.rating_id, 'user_id', NEW.user_id, 'game_id', NEW.game_id, 'rating', NEW.rating, 'review_text', NEW.review_text, 'review_date', NEW.review_date, 'deleted_at', NEW.deleted_at, 'row_version', NEW.row_version));

CREATE TRIGGER trg_rating_ad AFTER DELETE ON Rating FOR EACH ROW
  INSERT INTO Audit_Log (table_name, record_pk, action, changed_by, old_values)
  VALUES ('Rating', CAST(OLD.rating_id AS CHAR), 'DELETE', @app_user_id, JSON_OBJECT('rating_id', OLD.rating_id, 'user_id', OLD.user_id, 'game_id', OLD.game_id, 'rating', OLD.rating, 'review_text', OLD.review_text, 'review_date', OLD.review_date, 'deleted_at', OLD.deleted_at, 'row_version', OLD.row_version));

CREATE TRIGGER trg_user_achievement_ai AFTER INSERT ON User_Achievement FOR EACH ROW
  INSERT INTO Audit_Log (table_name, record_pk, action, changed_by, new_values)
  VALUES ('User_Achievement', CONCAT_WS('-', NEW.user_game_id, NEW.achievement_id), 'INSERT', @app_user_id, JSON_OBJECT('user_game_id', NEW.user_game_id, 'achievement_id', NEW.achievement_id, 'unlocked_at', NEW.unlocked_at, 'progress', NEW.progress, 'is_unlocked', NEW.is_unlocked));

-- UPDATE is logged only when an audited column really changed
CREATE TRIGGER trg_user_achievement_au AFTER UPDATE ON User_Achievement FOR EACH ROW
  INSERT INTO Audit_Log (table_name, record_pk, action, changed_by, old_values, new_values)
  SELECT 'User_Achievement', CONCAT_WS('-', NEW.user_game_id, NEW.achievement_id), 'UPDATE', @app_user_id, JSON_OBJECT('user_game_id', OLD.user_game_id, 'achievement_id', OLD.achievement_id, 'unlocked_at', OLD.unlocked_at, 'progress', OLD.progress, 'is_unlocked', OLD.is_unlocked), JSON_OBJECT('user_game_id', NEW.user_game_id, 'achievement_id', NEW.achievement_id, 'unlocked_at', NEW.unlocked_at, 'progress', NEW.progress, 'is_unlocked', NEW.is_unlocked)
  FROM DUAL WHERE NOT (JSON_OBJECT('user_game_id', OLD.user_game_id, 'achievement_id', OLD.achievement_id, 'unlocked_at', OLD.unlocked_at, 'progress', OLD.progress, 'is_unlocked', OLD.is_unlocked) <=> JSON_OBJECT('user_game_id', NEW.user_game_id, 'achievement_id', NEW.achievement_id, 'unlocked_at', NEW.unlocked_at, 'progress', NEW.progress, 'is_unlocked', NEW.is_unlocked));

CREATE TRIGGER trg_user_achievement_ad AFTER DELETE ON User_Achievement FOR EACH ROW
  INSERT INTO Audit_Log (table_name, record_pk, action, changed_by, old_values)
  VALUES ('User_Achievement', CONCAT_WS('-', OLD.user_game_id, OLD.achievement_id), 'DELETE', @app_user_id, JSON_OBJECT('user_game_id', OLD.user_game_id, 'achievement_id', OLD.achievement_id, 'unlocked_at', OLD.unlocked_at, 'progress', OLD.progress, 'is_unlocked', OLD.is_unlocked));

CREATE TRIGGER trg_playtime_session_ai AFTER INSERT ON Playtime_Session FOR EACH ROW
  INSERT INTO Audit_Log (table_name, record_pk, action, changed_by, new_values)
  VALUES ('Playtime_Session', CAST(NEW.session_id AS CHAR), 'INSERT', @app_user_id, JSON_OBJECT('session_id', NEW.session_id, 'user_game_id', NEW.user_game_id, 'started_at', NEW.started_at, 'duration_minutes', NEW.duration_minutes, 'note', NEW.note));

-- UPDATE is logged only when an audited column really changed
CREATE TRIGGER trg_playtime_session_au AFTER UPDATE ON Playtime_Session FOR EACH ROW
  INSERT INTO Audit_Log (table_name, record_pk, action, changed_by, old_values, new_values)
  SELECT 'Playtime_Session', CAST(NEW.session_id AS CHAR), 'UPDATE', @app_user_id, JSON_OBJECT('session_id', OLD.session_id, 'user_game_id', OLD.user_game_id, 'started_at', OLD.started_at, 'duration_minutes', OLD.duration_minutes, 'note', OLD.note), JSON_OBJECT('session_id', NEW.session_id, 'user_game_id', NEW.user_game_id, 'started_at', NEW.started_at, 'duration_minutes', NEW.duration_minutes, 'note', NEW.note)
  FROM DUAL WHERE NOT (JSON_OBJECT('session_id', OLD.session_id, 'user_game_id', OLD.user_game_id, 'started_at', OLD.started_at, 'duration_minutes', OLD.duration_minutes, 'note', OLD.note) <=> JSON_OBJECT('session_id', NEW.session_id, 'user_game_id', NEW.user_game_id, 'started_at', NEW.started_at, 'duration_minutes', NEW.duration_minutes, 'note', NEW.note));

CREATE TRIGGER trg_playtime_session_ad AFTER DELETE ON Playtime_Session FOR EACH ROW
  INSERT INTO Audit_Log (table_name, record_pk, action, changed_by, old_values)
  VALUES ('Playtime_Session', CAST(OLD.session_id AS CHAR), 'DELETE', @app_user_id, JSON_OBJECT('session_id', OLD.session_id, 'user_game_id', OLD.user_game_id, 'started_at', OLD.started_at, 'duration_minutes', OLD.duration_minutes, 'note', OLD.note));

DELIMITER $$
CREATE TRIGGER trg_audit_log_no_update BEFORE UPDATE ON Audit_Log FOR EACH ROW
BEGIN
    IF COALESCE(@gv_allow_audit_scrub, 0) <> 1 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'FORBIDDEN: Audit_Log is append-only';
    END IF;
END$$
CREATE TRIGGER trg_audit_log_no_delete BEFORE DELETE ON Audit_Log FOR EACH ROW
BEGIN
    IF COALESCE(@gv_allow_audit_scrub, 0) <> 1 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'FORBIDDEN: Audit_Log is append-only';
    END IF;
END$$
DELIMITER ;

-- Server-side age guard: block age-ineligible collection entries even if UI checks are bypassed.
DELIMITER $$
CREATE TRIGGER trg_user_game_age_guard_bi BEFORE INSERT ON User_Game FOR EACH ROW
BEGIN
  DECLARE v_age INT DEFAULT 99; DECLARE v_min_age INT DEFAULT 0;
  SELECT COALESCE(TIMESTAMPDIFF(YEAR,date_of_birth,CURDATE()),99) INTO v_age FROM User WHERE user_id=NEW.user_id;
  SELECT COALESCE(MAX(ar.minimum_age),0) INTO v_min_age FROM Game_Age_Rating gar JOIN Age_Rating ar ON ar.age_rating_id=gar.age_rating_id WHERE gar.game_id=NEW.game_id;
  IF v_age < v_min_age THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='FORBIDDEN: this game is restricted by your age profile'; END IF;
END$$
CREATE TRIGGER trg_user_game_age_guard_bu BEFORE UPDATE ON User_Game FOR EACH ROW
BEGIN
  DECLARE v_age INT DEFAULT 99; DECLARE v_min_age INT DEFAULT 0;
  SELECT COALESCE(TIMESTAMPDIFF(YEAR,date_of_birth,CURDATE()),99) INTO v_age FROM User WHERE user_id=NEW.user_id;
  SELECT COALESCE(MAX(ar.minimum_age),0) INTO v_min_age FROM Game_Age_Rating gar JOIN Age_Rating ar ON ar.age_rating_id=gar.age_rating_id WHERE gar.game_id=NEW.game_id;
  IF v_age < v_min_age THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='FORBIDDEN: this game is restricted by your age profile'; END IF;
END$$
DELIMITER ;

-- ---------------------------------------------------------------------
-- 7. SCHEDULED MAINTENANCE
--    Needs event_scheduler=ON (the MySQL 8.0 default).
-- ---------------------------------------------------------------------
CREATE EVENT ev_purge_expired_sessions
  ON SCHEDULE EVERY 1 DAY
  COMMENT 'Deletes login sessions that expired more than 7 days ago'
  DO DELETE FROM Auth_Session WHERE expires_at < UTC_TIMESTAMP() - INTERVAL 7 DAY;

-- End of schema.sql
