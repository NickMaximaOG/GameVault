-- =====================================================================
--  GameVault: Game Collection and Achievement Tracker
--  schema.sql  |  MySQL 8.0 CE (tested on 8.0.46)  |  InnoDB, utf8mb4
-- =====================================================================
--  HOW TO RUN (MySQL Workbench)
--    File > Open SQL Script > schema.sql > run the whole script
--    (lightning-bolt icon, or Ctrl+Shift+Enter). Run it ONCE on a clean
--    server. To start over, uncomment the reset line in section 0.
--
--  CONTENTS
--    0. Optional reset (destructive, disabled by default)
--    1. Database creation
--    2. DDL: 15 tables in dependency-safe order
--    3. DML: sample data, parents before children
--
--  DESIGN DECISIONS AND TRADE-OFFS (read before the evaluation)
--
--  D1. Table-name case. Names are written exactly as in the project brief
--      (User, Game_Genre, ...). On Linux/macOS servers MySQL treats table
--      names as case-sensitive, so every script uses the same spelling.
--
--  D2. Genres, platforms and modes are never stored in a text column.
--      Game_Genre, Game_Platform and Game_Mode_Map are the junction tables.
--
--  D3. Nullable Game.developer_id / Game.publisher_id. A studio may be
--      unknown, may not yet exist in the catalogue, or may be deleted. A
--      game record should survive that, so these FKs are NULLable and use
--      ON DELETE SET NULL. Game.age_rating_id is also nullable (unrated
--      games) but uses ON DELETE RESTRICT: a rating class that is in use
--      must not silently vanish.
--
--  D4. One age rating per game (as specified). A real catalogue has one
--      rating per authority per game (ESRB *and* PEGI). The sample data
--      therefore uses ESRB ratings only; the PEGI rows exist so that
--      authority filtering and the RIGHT JOIN query have something to show.
--      A Game_Age_Rating junction table is the natural extension.
--
--  D5. "User's platform must be supported by the game" is enforced in the
--      database: User_Game has a composite FK (game_id, platform_id) ->
--      Game_Platform(game_id, platform_id).
--
--  D6. "Achievement must belong to the user's game" is enforced with two
--      composite FKs on User_Achievement. This needs a game_id column in
--      User_Achievement. That column is a deliberate, FK-enforced
--      redundancy (game_id is determined by user_game_id). It can never
--      disagree with User_Game or Achievement because both FKs check it.
--      This is the one place where strict 2NF/3NF is traded for
--      declarative integrity; see normalization_report.md section 7.
--
--  D7. Foreign-key policy
--        ON UPDATE: RESTRICT everywhere. All keys are surrogate
--                   AUTO_INCREMENT values that are never edited.
--        ON DELETE: CASCADE when the child row has no meaning without the
--                   parent (a user's collection, a game's genre links, a
--                   game's achievements, per-user achievement progress).
--                   RESTRICT when deleting would destroy other users'
--                   data (Platform, Age_Rating, a Game that is in someone's
--                   collection, a Game_Platform row that is in use).
--                   SET NULL for optional parents (Developer, Publisher).
--
--  D8. CHECK constraints (enforced from MySQL 8.0.16). MySQL forbids CHECK
--      on columns that take part in a foreign-key referential action, so no
--      CHECK is placed on any FK column.
--
--  D9. A rating may exist without ownership (a user can review a game they
--      played elsewhere). Ownership is not forced because the brief keeps
--      Rating independent of User_Game.
--
--  D10. Prices are in USD. Sample data is fictional for users/activity;
--      game metadata (titles, dates, studios, platforms, ESRB class) is
--      real as best verified. Achievement names are illustrative, not the
--      official trophy lists. Cover URLs are placeholders.
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

-- ---------------------------------------------------------------------
-- 2. DDL
-- ---------------------------------------------------------------------

-- Table 1: User ------------------------------------------------------
CREATE TABLE User (
    user_id         INT           NOT NULL AUTO_INCREMENT,
    username        VARCHAR(50)   NOT NULL,
    email           VARCHAR(255)  NOT NULL,
    password_hash   VARCHAR(255)  NOT NULL,   -- fictional hash, never plaintext
    join_date       DATE          NOT NULL DEFAULT (CURRENT_DATE),
    profile_picture VARCHAR(500)  NULL,       -- optional URL
    CONSTRAINT pk_user          PRIMARY KEY (user_id),
    CONSTRAINT uq_user_username UNIQUE (username),
    CONSTRAINT uq_user_email    UNIQUE (email),
    CONSTRAINT chk_user_email   CHECK (email LIKE '%_@_%.__%')
) ENGINE=InnoDB;

-- Table 2: Developer -------------------------------------------------
CREATE TABLE Developer (
    developer_id INT          NOT NULL AUTO_INCREMENT,
    name         VARCHAR(100) NOT NULL,
    country      VARCHAR(60)  NULL,
    website      VARCHAR(255) NULL,
    CONSTRAINT pk_developer      PRIMARY KEY (developer_id),
    CONSTRAINT uq_developer_name UNIQUE (name)
) ENGINE=InnoDB;

-- Table 3: Publisher -------------------------------------------------
CREATE TABLE Publisher (
    publisher_id INT          NOT NULL AUTO_INCREMENT,
    name         VARCHAR(100) NOT NULL,
    country      VARCHAR(60)  NULL,
    website      VARCHAR(255) NULL,
    CONSTRAINT pk_publisher      PRIMARY KEY (publisher_id),
    CONSTRAINT uq_publisher_name UNIQUE (name)
) ENGINE=InnoDB;

-- Table 4: Genre -----------------------------------------------------
CREATE TABLE Genre (
    genre_id    INT          NOT NULL AUTO_INCREMENT,
    name        VARCHAR(50)  NOT NULL,
    description VARCHAR(255) NULL,
    CONSTRAINT pk_genre      PRIMARY KEY (genre_id),
    CONSTRAINT uq_genre_name UNIQUE (name)
) ENGINE=InnoDB;

-- Table 5: Platform --------------------------------------------------
CREATE TABLE Platform (
    platform_id  INT         NOT NULL AUTO_INCREMENT,
    name         VARCHAR(60) NOT NULL,
    manufacturer VARCHAR(60) NULL,
    release_year SMALLINT    NULL,
    CONSTRAINT pk_platform      PRIMARY KEY (platform_id),
    CONSTRAINT uq_platform_name UNIQUE (name),
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
    CONSTRAINT pk_age_rating PRIMARY KEY (age_rating_id),
    CONSTRAINT uq_age_rating_authority_label UNIQUE (rating_authority, label),
    CONSTRAINT chk_age_rating_min_age CHECK (minimum_age BETWEEN 0 AND 21)
) ENGINE=InnoDB;

-- Table 7: Game_Mode -------------------------------------------------
CREATE TABLE Game_Mode (
    mode_id     INT          NOT NULL AUTO_INCREMENT,
    name        VARCHAR(50)  NOT NULL,
    description VARCHAR(255) NULL,
    CONSTRAINT pk_game_mode      PRIMARY KEY (mode_id),
    CONSTRAINT uq_game_mode_name UNIQUE (name)
) ENGINE=InnoDB;

-- Table 8: Game ------------------------------------------------------
CREATE TABLE Game (
    game_id       INT          NOT NULL AUTO_INCREMENT,
    title         VARCHAR(150) NOT NULL,
    release_date  DATE         NULL,
    description   TEXT         NULL,
    cover_image   VARCHAR(500) NULL,
    developer_id  INT          NULL,
    publisher_id  INT          NULL,
    age_rating_id INT          NULL,
    CONSTRAINT pk_game PRIMARY KEY (game_id),
    CONSTRAINT uq_game_title_release UNIQUE (title, release_date),
    CONSTRAINT fk_game_developer FOREIGN KEY (developer_id)
        REFERENCES Developer (developer_id)
        ON DELETE SET NULL ON UPDATE RESTRICT,
    CONSTRAINT fk_game_publisher FOREIGN KEY (publisher_id)
        REFERENCES Publisher (publisher_id)
        ON DELETE SET NULL ON UPDATE RESTRICT,
    CONSTRAINT fk_game_age_rating FOREIGN KEY (age_rating_id)
        REFERENCES Age_Rating (age_rating_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
    INDEX idx_game_title (title)
) ENGINE=InnoDB;

-- Table 9: Game_Genre (Game M:N Genre) --------------------------------
CREATE TABLE Game_Genre (
    game_id  INT NOT NULL,
    genre_id INT NOT NULL,
    CONSTRAINT pk_game_genre PRIMARY KEY (game_id, genre_id),
    CONSTRAINT fk_game_genre_game FOREIGN KEY (game_id)
        REFERENCES Game (game_id)
        ON DELETE CASCADE ON UPDATE RESTRICT,
    CONSTRAINT fk_game_genre_genre FOREIGN KEY (genre_id)
        REFERENCES Genre (genre_id)
        ON DELETE CASCADE ON UPDATE RESTRICT,
    INDEX idx_game_genre_genre (genre_id)
) ENGINE=InnoDB;

-- Table 10: Game_Platform (Game M:N Platform) -------------------------
CREATE TABLE Game_Platform (
    game_id               INT  NOT NULL,
    platform_id           INT  NOT NULL,
    platform_release_date DATE NULL,
    CONSTRAINT pk_game_platform PRIMARY KEY (game_id, platform_id),
    CONSTRAINT fk_game_platform_game FOREIGN KEY (game_id)
        REFERENCES Game (game_id)
        ON DELETE CASCADE ON UPDATE RESTRICT,
    CONSTRAINT fk_game_platform_platform FOREIGN KEY (platform_id)
        REFERENCES Platform (platform_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
    INDEX idx_game_platform_platform (platform_id)
) ENGINE=InnoDB;

-- Table 11: User_Game (a user's collection entry) ---------------------
CREATE TABLE User_Game (
    user_game_id   INT           NOT NULL AUTO_INCREMENT,
    user_id        INT           NOT NULL,
    game_id        INT           NOT NULL,
    platform_id    INT           NOT NULL,
    purchase_date  DATE          NULL,
    purchase_price DECIMAL(8,2)  NOT NULL DEFAULT 0.00,
    playtime_hours DECIMAL(7,1)  NOT NULL DEFAULT 0.0,
    status         ENUM('Backlog','Playing','Completed','On Hold','Dropped')
                                 NOT NULL DEFAULT 'Backlog',
    started_at     DATE          NULL,
    completed_at   DATE          NULL,
    CONSTRAINT pk_user_game PRIMARY KEY (user_game_id),
    -- one collection entry per user + game + platform
    CONSTRAINT uq_user_game_ugp UNIQUE (user_id, game_id, platform_id),
    -- target of the composite FK from User_Achievement (decision D6)
    CONSTRAINT uq_user_game_id_game UNIQUE (user_game_id, game_id),
    CONSTRAINT fk_user_game_user FOREIGN KEY (user_id)
        REFERENCES User (user_id)
        ON DELETE CASCADE ON UPDATE RESTRICT,
    CONSTRAINT fk_user_game_game FOREIGN KEY (game_id)
        REFERENCES Game (game_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT fk_user_game_platform FOREIGN KEY (platform_id)
        REFERENCES Platform (platform_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
    -- decision D5: the chosen platform must be one the game supports
    CONSTRAINT fk_user_game_supported_platform FOREIGN KEY (game_id, platform_id)
        REFERENCES Game_Platform (game_id, platform_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT chk_ug_price    CHECK (purchase_price >= 0),
    CONSTRAINT chk_ug_playtime CHECK (playtime_hours >= 0),
    CONSTRAINT chk_ug_dates    CHECK (started_at IS NULL OR completed_at IS NULL
                                      OR completed_at >= started_at),
    -- a completion date exists exactly when the status is 'Completed'
    CONSTRAINT chk_ug_completed CHECK ((status = 'Completed') = (completed_at IS NOT NULL)),
    INDEX idx_user_game_status (status),
    INDEX idx_user_game_game (game_id)
) ENGINE=InnoDB;

-- Table 12: Rating ---------------------------------------------------
CREATE TABLE Rating (
    rating_id   INT      NOT NULL AUTO_INCREMENT,
    user_id     INT      NOT NULL,
    game_id     INT      NOT NULL,
    rating      TINYINT  NOT NULL,
    review_text TEXT     NULL,
    review_date DATE     NOT NULL DEFAULT (CURRENT_DATE),
    CONSTRAINT pk_rating PRIMARY KEY (rating_id),
    CONSTRAINT uq_rating_user_game UNIQUE (user_id, game_id),
    CONSTRAINT fk_rating_user FOREIGN KEY (user_id)
        REFERENCES User (user_id)
        ON DELETE CASCADE ON UPDATE RESTRICT,
    CONSTRAINT fk_rating_game FOREIGN KEY (game_id)
        REFERENCES Game (game_id)
        ON DELETE CASCADE ON UPDATE RESTRICT,
    CONSTRAINT chk_rating_range CHECK (rating BETWEEN 1 AND 10),
    INDEX idx_rating_game (game_id)
) ENGINE=InnoDB;

-- Table 13: Achievement ----------------------------------------------
CREATE TABLE Achievement (
    achievement_id INT          NOT NULL AUTO_INCREMENT,
    game_id        INT          NOT NULL,
    name           VARCHAR(100) NOT NULL,
    description    VARCHAR(255) NULL,
    points         INT          NOT NULL DEFAULT 0,
    is_hidden      BOOLEAN      NOT NULL DEFAULT FALSE,
    CONSTRAINT pk_achievement PRIMARY KEY (achievement_id),
    CONSTRAINT uq_achievement_game_name UNIQUE (game_id, name),
    -- target of the composite FK from User_Achievement (decision D6)
    CONSTRAINT uq_achievement_id_game UNIQUE (achievement_id, game_id),
    CONSTRAINT fk_achievement_game FOREIGN KEY (game_id)
        REFERENCES Game (game_id)
        ON DELETE CASCADE ON UPDATE RESTRICT,
    CONSTRAINT chk_achievement_points CHECK (points >= 0)
) ENGINE=InnoDB;

-- Table 14: User_Achievement (User_Game M:N Achievement) ---------------
CREATE TABLE User_Achievement (
    user_game_id   INT           NOT NULL,
    achievement_id INT           NOT NULL,
    game_id        INT           NOT NULL,  -- controlled redundancy, see D6
    unlocked_at    TIMESTAMP     NULL DEFAULT NULL,
    progress       DECIMAL(5,2)  NOT NULL DEFAULT 0.00,
    is_unlocked    BOOLEAN       NOT NULL DEFAULT FALSE,
    CONSTRAINT pk_user_achievement PRIMARY KEY (user_game_id, achievement_id),
    -- the collection entry and the achievement must refer to the SAME game
    CONSTRAINT fk_ua_user_game FOREIGN KEY (user_game_id, game_id)
        REFERENCES User_Game (user_game_id, game_id)
        ON DELETE CASCADE ON UPDATE RESTRICT,
    CONSTRAINT fk_ua_achievement FOREIGN KEY (achievement_id, game_id)
        REFERENCES Achievement (achievement_id, game_id)
        ON DELETE CASCADE ON UPDATE RESTRICT,
    CONSTRAINT chk_ua_progress CHECK (progress BETWEEN 0 AND 100),
    -- unlocked  => timestamp present and progress = 100
    -- locked    => no timestamp and progress below 100
    CONSTRAINT chk_ua_unlock_consistency CHECK (
        (is_unlocked = 1 AND unlocked_at IS NOT NULL AND progress = 100)
     OR (is_unlocked = 0 AND unlocked_at IS NULL     AND progress < 100)),
    INDEX idx_ua_achievement (achievement_id, game_id)
) ENGINE=InnoDB;

-- Table 15 (additional): Game_Mode_Map (Game M:N Game_Mode) ------------
CREATE TABLE Game_Mode_Map (
    game_id INT NOT NULL,
    mode_id INT NOT NULL,
    CONSTRAINT pk_game_mode_map PRIMARY KEY (game_id, mode_id),
    CONSTRAINT fk_gmm_game FOREIGN KEY (game_id)
        REFERENCES Game (game_id)
        ON DELETE CASCADE ON UPDATE RESTRICT,
    CONSTRAINT fk_gmm_mode FOREIGN KEY (mode_id)
        REFERENCES Game_Mode (mode_id)
        ON DELETE CASCADE ON UPDATE RESTRICT,
    INDEX idx_gmm_mode (mode_id)
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- 3. SAMPLE DATA (parents first, then children)
--    Users, hashes and activity are fictional. Hashes are random strings
--    shaped like bcrypt output and do not correspond to any password.
-- ---------------------------------------------------------------------

-- User (7 rows; user 7 deliberately owns no games)
INSERT INTO User (user_id, username, email, password_hash, join_date, profile_picture) VALUES
  (1, 'aarav_k', 'aarav.k@example.com', '$2b$12$REOWWyKbBB9zzDI1b9YevUX8nyOftmJ/NZglWgIkRvnsKvvnr1iQC', '2023-08-02', 'https://avatars.example.com/aarav_k.png'),
  (2, 'meera_s', 'meera.s@example.com', '$2b$12$dupkXFFaB6OOdkWga5InpvxxpMxqi8.HMa5r6CTjFpPaHcbY4jPur', '2022-09-05', 'https://avatars.example.com/meera_s.png'),
  (3, 'rohan_v', 'rohan.v@example.com', '$2b$12$WCeOozSb/YntIUy6.RMrwL/nPgTdV4TsFfiU8URuOSQwTVJv3lKAN', '2023-01-17', NULL),
  (4, 'ananya_d', 'ananya.d@example.com', '$2b$12$mULgJKnzXSXnjK363S41JMOIJ9a6CUU1UyqnbDYqVAhDwO6kql13y', '2022-03-21', 'https://avatars.example.com/ananya_d.png'),
  (5, 'kabir_m', 'kabir.m@example.com', '$2b$12$V95NXA4SCTAa3xRXAQqrMq4A3BICkAIvmEeBjvVs3uWxvi8dD5fic', '2023-02-11', NULL),
  (6, 'ishita_r', 'ishita.r@example.com', '$2b$12$OqftxcZWKwpbMS5EN.yxWCOrJZEanzD1JNL33fw4WSLjSpXy50F5g', '2021-11-30', 'https://avatars.example.com/ishita_r.png'),
  (7, 'new_player_07', 'new.player07@example.com', '$2b$12$66dzXPHgFmx1b.aLfeALsYiuM130rx8dTMoJU/N3Ep.h.lXtXH3ea', '2026-10-20', NULL);

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

-- Age_Rating (8 rows: 4 ESRB + 4 PEGI)
-- Sample games use ESRB only (decision D4); PEGI rows stay unused on purpose.
INSERT INTO Age_Rating (age_rating_id, label, rating_authority, description, minimum_age) VALUES
  (1, 'E', 'ESRB', 'Everyone: content is generally suitable for all ages.', 0),
  (2, 'E10+', 'ESRB', 'Everyone 10+: may contain mild violence or mild language.', 10),
  (3, 'T', 'ESRB', 'Teen: may contain violence, crude humor or suggestive themes.', 13),
  (4, 'M', 'ESRB', 'Mature 17+: may contain intense violence, blood and strong language.', 17),
  (5, 'PEGI 3', 'PEGI', 'Suitable for all age groups.', 3),
  (6, 'PEGI 12', 'PEGI', 'Moderate violence and mild bad language.', 12),
  (7, 'PEGI 16', 'PEGI', 'Realistic violence and stronger language.', 16),
  (8, 'PEGI 18', 'PEGI', 'Graphic violence and adult content.', 18);

-- Game_Mode (5 rows)
INSERT INTO Game_Mode (mode_id, name, description) VALUES
  (1, 'Single-player', 'One player, offline or online.'),
  (2, 'Online Co-op', 'Players cooperate over the internet.'),
  (3, 'Online Multiplayer', 'Players compete or share a world over the internet.'),
  (4, 'Local Co-op', 'Players cooperate on the same device or screen.'),
  (5, 'Local Multiplayer', 'Players compete on the same device or screen.');

-- Game (20 rows)
-- ESRB classes were checked against esrb.org for Black Myth: Wukong, Hades, Hollow Knight, Civilization VI and Helldivers 2; the rest are from general knowledge. Cover URLs are placeholders.
INSERT INTO Game (game_id, title, release_date, description, cover_image, developer_id, publisher_id, age_rating_id) VALUES
  (1, 'God of War Ragnarök', '2022-11-09', 'Kratos and Atreus travel the Nine Realms as Ragnarök approaches.', 'https://covers.example.com/god-of-war-ragnarök.jpg', 1, 1, 4),
  (2, 'The Last of Us Part I', '2022-09-02', 'A rebuilt version of the post-pandemic story of Joel and Ellie.', 'https://covers.example.com/the-last-of-us-part-i.jpg', 2, 1, 4),
  (3, 'Elden Ring', '2022-02-25', 'A huge open-world action RPG set in the Lands Between.', 'https://covers.example.com/elden-ring.jpg', 3, 2, 4),
  (4, 'Black Myth: Wukong', '2024-08-20', 'An action RPG inspired by Journey to the West.', NULL, 4, 3, 3),
  (5, 'Cyberpunk 2077', '2020-12-10', 'An open-world action RPG set in the dystopian Night City.', 'https://covers.example.com/cyberpunk-2077.jpg', 5, 4, 4),
  (6, 'Minecraft', '2011-11-18', 'A block-based sandbox about mining, building and survival.', 'https://covers.example.com/minecraft.jpg', 6, 5, 2),
  (7, 'Hades', '2020-09-17', 'A roguelike dungeon crawler about escaping the Underworld.', 'https://covers.example.com/hades.jpg', 7, 6, 3),
  (8, 'Baldur''s Gate 3', '2023-08-03', 'A turn-based, party-driven RPG built on Dungeons & Dragons rules.', 'https://covers.example.com/baldur-s-gate-3.jpg', 8, 7, 4),
  (9, 'Forza Horizon 5', '2021-11-09', 'An open-world racing festival set in Mexico.', 'https://covers.example.com/forza-horizon-5.jpg', 9, 5, 1),
  (10, 'Hollow Knight', '2017-02-24', 'A hand-drawn metroidvania set in the ruined insect kingdom of Hallownest.', 'https://covers.example.com/hollow-knight.jpg', 10, 8, 2),
  (11, 'Stardew Valley', '2016-02-26', 'A farming and life simulation with a deep social system.', 'https://covers.example.com/stardew-valley.jpg', 11, 9, 2),
  (12, 'Celeste', '2018-01-25', 'A tight precision platformer about climbing a mountain.', 'https://covers.example.com/celeste.jpg', 12, 10, 2),
  (13, 'The Witcher 3: Wild Hunt', '2015-05-19', 'A story-rich open-world RPG following the monster hunter Geralt.', 'https://covers.example.com/the-witcher-3--wild-hunt.jpg', 5, 4, 4),
  (14, 'Red Dead Redemption 2', '2018-10-26', 'A western epic about the decline of the Van der Linde gang.', 'https://covers.example.com/red-dead-redemption-2.jpg', 13, 11, 4),
  (15, 'The Legend of Zelda: Breath of the Wild', '2017-03-03', 'An open-air Zelda adventure built around exploration and physics.', 'https://covers.example.com/the-legend-of-zelda--breath-of-the-wild.jpg', 14, 12, 2),
  (16, 'DOOM Eternal', '2020-03-20', 'A fast first-person shooter about ripping through demonic invasions.', 'https://covers.example.com/doom-eternal.jpg', 15, 13, 4),
  (17, 'Mario Kart 8 Deluxe', '2017-04-28', 'Arcade kart racing with items, 48 tracks and split-screen play.', 'https://covers.example.com/mario-kart-8-deluxe.jpg', 14, 12, 1),
  (18, 'Helldivers 2', '2024-02-08', 'A cooperative third-person shooter about spreading managed democracy.', 'https://covers.example.com/helldivers-2.jpg', 16, 1, 4),
  (19, 'Sekiro: Shadows Die Twice', '2019-03-22', 'A posture-based action adventure set in sengoku-era Japan.', NULL, 3, 14, 4),
  (20, 'Sid Meier''s Civilization VI', '2016-10-21', 'A turn-based 4X strategy game about leading a civilization through history.', 'https://covers.example.com/sid-meier-s-civilization-vi.jpg', 17, 15, 2);

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
-- Every (game_id, platform_id) pair exists in Game_Platform (enforced by fk_user_game_supported_platform).
INSERT INTO User_Game (user_game_id, user_id, game_id, platform_id, purchase_date, purchase_price, playtime_hours, status, started_at, completed_at) VALUES
  (1, 1, 1, 1, '2024-09-25', 59.99, 41.5, 'Completed', '2024-09-26', '2024-11-02'),
  (2, 1, 3, 1, '2022-03-01', 59.99, 132.5, 'Completed', '2022-03-02', '2022-06-20'),
  (3, 1, 7, 1, '2021-01-10', 24.99, 58.0, 'Completed', '2021-01-11', '2021-03-14'),
  (4, 1, 10, 1, '2020-05-20', 14.99, 31.0, 'Playing', '2020-05-21', NULL),
  (5, 1, 8, 1, '2023-08-03', 59.99, 87.5, 'Playing', '2023-08-04', NULL),
  (6, 1, 5, 1, '2022-11-24', 29.99, 22.0, 'On Hold', '2022-11-25', NULL),
  (7, 1, 19, 1, '2023-01-15', 39.99, 6.5, 'Dropped', '2023-01-16', NULL),
  (8, 2, 2, 2, '2022-09-02', 69.99, 24.0, 'Completed', '2022-09-03', '2022-09-20'),
  (9, 2, 1, 2, '2022-11-09', 69.99, 38.5, 'Completed', '2022-11-10', '2022-12-15'),
  (10, 2, 3, 2, '2022-04-02', 59.99, 65.0, 'Playing', '2022-04-03', NULL),
  (11, 2, 4, 2, '2024-08-20', 59.99, 44.0, 'Completed', '2024-08-21', '2024-09-14'),
  (12, 2, 6, 6, '2019-06-01', 29.99, 120.0, 'Playing', '2019-06-02', NULL),
  (13, 2, 17, 6, '2020-03-10', 59.99, 75.5, 'Playing', '2020-03-11', NULL),
  (14, 2, 7, 6, '2021-02-14', 24.99, 49.0, 'Completed', '2021-02-15', '2021-04-03'),
  (15, 3, 5, 1, '2021-01-05', 59.99, 78.0, 'Completed', '2021-01-06', '2021-03-02'),
  (16, 3, 13, 1, '2019-12-01', 39.99, 160.0, 'Completed', '2019-12-02', '2020-04-18'),
  (17, 3, 9, 4, '2021-11-09', 59.99, 95.0, 'Playing', '2021-11-09', NULL),
  (18, 3, 3, 4, '2022-02-25', 59.99, 18.0, 'Dropped', '2022-02-26', NULL),
  (19, 3, 16, 1, '2020-04-01', 39.99, 21.5, 'Completed', '2020-04-02', '2020-04-20'),
  (20, 3, 8, 4, '2023-12-07', 59.99, 0.0, 'Backlog', NULL, NULL),
  (21, 3, 6, 1, '2018-07-01', 26.95, 210.0, 'Playing', '2018-07-02', NULL),
  (22, 4, 15, 6, '2017-03-03', 59.99, 110.0, 'Completed', '2017-03-04', '2017-09-10'),
  (23, 4, 10, 6, '2018-06-12', 14.99, 42.0, 'Completed', '2018-06-13', '2018-08-01'),
  (24, 4, 12, 6, '2018-02-01', 19.99, 11.5, 'Completed', '2018-02-02', '2018-02-20'),
  (25, 4, 11, 6, '2017-10-05', 14.99, 140.0, 'Playing', '2017-10-06', NULL),
  (26, 4, 6, 6, '2018-12-24', 0.0, 15.0, 'Playing', '2018-12-26', NULL),
  (27, 4, 7, 1, '2022-07-20', 24.99, 12.0, 'On Hold', '2022-07-21', NULL),
  (28, 4, 20, 6, '2019-01-12', 59.99, 33.0, 'Playing', '2019-01-13', NULL),
  (29, 5, 1, 2, '2023-01-10', 49.99, 9.0, 'Dropped', '2023-01-11', NULL),
  (30, 5, 2, 2, '2023-03-01', 59.99, 0.0, 'Backlog', NULL, NULL),
  (31, 5, 18, 2, '2024-02-08', 39.99, 150.0, 'Playing', '2024-02-08', NULL),
  (32, 5, 14, 3, '2019-01-20', 59.99, 68.0, 'Completed', '2019-01-21', '2019-04-12'),
  (33, 5, 13, 2, '2023-02-02', 19.99, 55.0, 'Playing', '2023-02-03', NULL),
  (34, 5, 5, 2, '2022-03-05', 39.99, 52.0, 'Completed', '2022-03-06', '2022-05-01'),
  (35, 6, 11, 1, '2016-04-01', 14.99, 200.0, 'Completed', '2016-04-02', '2016-09-30'),
  (36, 6, 12, 1, '2018-02-10', 19.99, 14.0, 'Completed', '2018-02-11', '2018-03-01'),
  (37, 6, 10, 1, '2018-03-05', 14.99, 55.0, 'Completed', '2018-03-06', '2018-05-20'),
  (38, 6, 20, 1, '2017-01-15', 59.99, 420.0, 'Playing', '2017-01-16', NULL),
  (39, 6, 8, 1, '2023-08-03', 59.99, 30.0, 'On Hold', '2023-08-04', NULL),
  (40, 6, 3, 1, '2022-02-25', 59.99, 98.0, 'Completed', '2022-02-26', '2022-05-10');

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

-- User_Achievement (122 rows)
-- Unlocked => timestamp + 100%. Locked => no timestamp + progress below 100 (partial progress included).
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

-- End of schema.sql
