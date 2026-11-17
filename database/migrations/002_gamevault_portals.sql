-- GameVault portal upgrade for an existing v2 database.
-- Run once as a MySQL administrator after the original schema.sql.
ALTER TABLE User ADD COLUMN date_of_birth DATE NULL AFTER profile_picture;
ALTER TABLE Game ADD COLUMN is_upcoming TINYINT(1) NOT NULL DEFAULT 0 AFTER cover_image;
ALTER TABLE Achievement ADD COLUMN rarity ENUM('COMMON','RARE','EPIC','LEGENDARY') NOT NULL DEFAULT 'COMMON' AFTER is_hidden;

CREATE TABLE Friendship (
  friendship_id INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  requester_id INT NOT NULL,
  recipient_id INT NOT NULL,
  status ENUM('PENDING','ACCEPTED') NOT NULL DEFAULT 'PENDING',
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  UNIQUE KEY uq_friend_request (requester_id, recipient_id),
  CONSTRAINT fk_friend_requester FOREIGN KEY (requester_id) REFERENCES User(user_id) ON DELETE CASCADE,
  CONSTRAINT fk_friend_recipient FOREIGN KEY (recipient_id) REFERENCES User(user_id) ON DELETE CASCADE,
  CONSTRAINT chk_friend_not_self CHECK (requester_id <> recipient_id),
  INDEX idx_friend_recipient_status (recipient_id, status)
) ENGINE=InnoDB;

CREATE TABLE Notification (
  notification_id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  recipient_id INT NOT NULL,
  actor_id INT NULL,
  notification_type VARCHAR(40) NOT NULL,
  message VARCHAR(255) NOT NULL,
  is_read TINYINT(1) NOT NULL DEFAULT 0,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT fk_notification_recipient FOREIGN KEY (recipient_id) REFERENCES User(user_id) ON DELETE CASCADE,
  CONSTRAINT fk_notification_actor FOREIGN KEY (actor_id) REFERENCES User(user_id) ON DELETE SET NULL,
  INDEX idx_notification_recipient (recipient_id, is_read, created_at)
) ENGINE=InnoDB;

CREATE TABLE Wishlist (
  wishlist_id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  user_id INT NOT NULL,
  game_id INT NOT NULL,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE KEY uq_wishlist_user_game (user_id, game_id),
  CONSTRAINT fk_wishlist_user FOREIGN KEY (user_id) REFERENCES User(user_id) ON DELETE CASCADE,
  CONSTRAINT fk_wishlist_game FOREIGN KEY (game_id) REFERENCES Game(game_id) ON DELETE CASCADE
) ENGINE=InnoDB;

CREATE TABLE Game_Screenshot (
  screenshot_id INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  game_id INT NOT NULL,
  image_url VARCHAR(500) NOT NULL,
  caption VARCHAR(180) NULL,
  sort_order SMALLINT NOT NULL DEFAULT 0,
  CONSTRAINT fk_screenshot_game FOREIGN KEY (game_id) REFERENCES Game(game_id) ON DELETE CASCADE,
  INDEX idx_screenshot_game (game_id, sort_order)
) ENGINE=InnoDB;

-- Demo accounts: initial password for each is ChangeMe!2026.
INSERT INTO User (username,email,password_hash,role_id,join_date,date_of_birth) VALUES
('admin','admin@gamevault.local','pbkdf2-sha256$600000$F2wT/0iGA+t3bhEAbOvQtA==$ZWFrgE7NjITS6+N2fmFyVyrFkw9mWKLEYCVS0hANCWU=',2,CURRENT_DATE,NULL),
('NickMaxima','nickmaxima@gamevault.local','pbkdf2-sha256$600000$F2wT/0iGA+t3bhEAbOvQtA==$ZWFrgE7NjITS6+N2fmFyVyrFkw9mWKLEYCVS0hANCWU=',1,CURRENT_DATE,NULL),
('Dibu2007','dibu2007@gamevault.local','pbkdf2-sha256$600000$F2wT/0iGA+t3bhEAbOvQtA==$ZWFrgE7NjITS6+N2fmFyVyrFkw9mWKLEYCVS0hANCWU=',1,CURRENT_DATE,NULL),
('Xlitz','xlitz@gamevault.local','pbkdf2-sha256$600000$F2wT/0iGA+t3bhEAbOvQtA==$ZWFrgE7NjITS6+N2fmFyVyrFkw9mWKLEYCVS0hANCWU=',1,CURRENT_DATE,'2010-01-01');
INSERT INTO Friendship(requester_id,recipient_id,status)
SELECT a.user_id,b.user_id,'ACCEPTED' FROM User a JOIN User b
WHERE a.username='NickMaxima' AND b.username='Dibu2007';

-- Minimal least-privilege extensions for new portal workflows.
GRANT SELECT (date_of_birth) ON gamevault_db.User TO 'gv_app'@'%';
GRANT SELECT ON gamevault_db.Game TO 'gv_app'@'%';
GRANT SELECT ON gamevault_db.Developer TO 'gv_app'@'%';
GRANT SELECT ON gamevault_db.Publisher TO 'gv_app'@'%';
GRANT SELECT ON gamevault_db.Game_Screenshot TO 'gv_app'@'%';
GRANT SELECT, INSERT, UPDATE ON gamevault_db.Friendship TO 'gv_app'@'%';
GRANT SELECT, INSERT, UPDATE ON gamevault_db.Notification TO 'gv_app'@'%';
GRANT SELECT, INSERT, DELETE ON gamevault_db.Wishlist TO 'gv_app'@'%';
GRANT SELECT, INSERT, UPDATE, DELETE ON gamevault_db.Game_Screenshot TO 'gv_app'@'%';
GRANT INSERT, UPDATE ON gamevault_db.Game TO 'gv_app'@'%';
GRANT INSERT, UPDATE, DELETE ON gamevault_db.Game_Genre TO 'gv_app'@'%';
GRANT INSERT, UPDATE, DELETE ON gamevault_db.Game_Platform TO 'gv_app'@'%';
GRANT INSERT, UPDATE, DELETE ON gamevault_db.Game_Age_Rating TO 'gv_app'@'%';
GRANT INSERT, UPDATE, DELETE ON gamevault_db.Achievement TO 'gv_app'@'%';
FLUSH PRIVILEGES;

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

-- Refresh the derived views so the existing database exposes upcoming flags,
-- game metadata IDs, achievement rarity and true last-played timestamps.
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


-- Replace the earlier placeholder cover URLs and seed screenshots for the existing catalogue.
UPDATE Game SET cover_image = 'https://cdn.akamai.steamstatic.com/steam/apps/2322010/library_600x900.jpg' WHERE game_id = 1;
UPDATE Game SET cover_image = 'https://cdn.akamai.steamstatic.com/steam/apps/1888930/library_600x900.jpg' WHERE game_id = 2;
UPDATE Game SET cover_image = 'https://cdn.akamai.steamstatic.com/steam/apps/1245620/library_600x900.jpg' WHERE game_id = 3;
UPDATE Game SET cover_image = 'https://cdn.akamai.steamstatic.com/steam/apps/2358720/library_600x900.jpg' WHERE game_id = 4;
UPDATE Game SET cover_image = 'https://cdn.akamai.steamstatic.com/steam/apps/1091500/library_600x900.jpg' WHERE game_id = 5;
UPDATE Game SET cover_image = 'https://cdn.akamai.steamstatic.com/steam/apps/1145360/library_600x900.jpg' WHERE game_id = 7;
UPDATE Game SET cover_image = 'https://cdn.akamai.steamstatic.com/steam/apps/1086940/library_600x900.jpg' WHERE game_id = 8;
UPDATE Game SET cover_image = 'https://cdn.akamai.steamstatic.com/steam/apps/1551360/library_600x900.jpg' WHERE game_id = 9;
UPDATE Game SET cover_image = 'https://cdn.akamai.steamstatic.com/steam/apps/367520/library_600x900.jpg' WHERE game_id = 10;
UPDATE Game SET cover_image = 'https://cdn.akamai.steamstatic.com/steam/apps/413150/library_600x900.jpg' WHERE game_id = 11;
UPDATE Game SET cover_image = 'https://cdn.akamai.steamstatic.com/steam/apps/504230/library_600x900.jpg' WHERE game_id = 12;
UPDATE Game SET cover_image = 'https://cdn.akamai.steamstatic.com/steam/apps/292030/library_600x900.jpg' WHERE game_id = 13;
UPDATE Game SET cover_image = 'https://cdn.akamai.steamstatic.com/steam/apps/1174180/library_600x900.jpg' WHERE game_id = 14;
UPDATE Game SET cover_image = 'https://cdn.akamai.steamstatic.com/steam/apps/782330/library_600x900.jpg' WHERE game_id = 16;
UPDATE Game SET cover_image = 'https://cdn.akamai.steamstatic.com/steam/apps/553850/library_600x900.jpg' WHERE game_id = 18;
UPDATE Game SET cover_image = 'https://cdn.akamai.steamstatic.com/steam/apps/814380/library_600x900.jpg' WHERE game_id = 19;
UPDATE Game SET cover_image = 'https://cdn.akamai.steamstatic.com/steam/apps/289070/library_600x900.jpg' WHERE game_id = 20;
UPDATE Game SET cover_image = 'https://images.unsplash.com/photo-1607513746994-51f730a44832?w=700&auto=format&fit=crop' WHERE game_id = 6;
UPDATE Game SET cover_image = 'https://images.unsplash.com/photo-1511512578047-dfb367046420?w=700&auto=format&fit=crop' WHERE game_id IN (15,17);
UPDATE Achievement SET rarity = CASE WHEN points >= 100 THEN 'LEGENDARY' WHEN points >= 50 THEN 'EPIC' WHEN points >= 25 THEN 'RARE' ELSE 'COMMON' END;

INSERT INTO Game_Screenshot (game_id, image_url, caption, sort_order)
SELECT game_id, CONCAT('https://cdn.akamai.steamstatic.com/steam/apps/', app_id, '/header.jpg'), 'Official game artwork', 1
FROM (SELECT 1 game_id, 2322010 app_id UNION ALL SELECT 2,1888930 UNION ALL SELECT 3,1245620 UNION ALL SELECT 4,2358720 UNION ALL SELECT 5,1091500 UNION ALL SELECT 7,1145360 UNION ALL SELECT 8,1086940 UNION ALL SELECT 9,1551360 UNION ALL SELECT 10,367520 UNION ALL SELECT 11,413150 UNION ALL SELECT 12,504230 UNION ALL SELECT 13,292030 UNION ALL SELECT 14,1174180 UNION ALL SELECT 16,782330 UNION ALL SELECT 18,553850 UNION ALL SELECT 19,814380 UNION ALL SELECT 20,289070) src
WHERE NOT EXISTS (SELECT 1 FROM Game_Screenshot s WHERE s.game_id = src.game_id);

-- Refresh Game audit triggers so catalogue edits include cover and upcoming metadata.
DELIMITER $$
DROP TRIGGER IF EXISTS trg_game_ai$$
CREATE TRIGGER trg_game_ai AFTER INSERT ON Game FOR EACH ROW
  INSERT INTO Audit_Log (table_name, record_pk, action, changed_by, new_values)
  VALUES ('Game', CAST(NEW.game_id AS CHAR), 'INSERT', @app_user_id,
    JSON_OBJECT('game_id', NEW.game_id, 'title', NEW.title, 'release_date', NEW.release_date,
      'description', NEW.description, 'cover_image', NEW.cover_image, 'is_upcoming', NEW.is_upcoming,
      'developer_id', NEW.developer_id, 'publisher_id', NEW.publisher_id, 'deleted_at', NEW.deleted_at));
DROP TRIGGER IF EXISTS trg_game_au$$
CREATE TRIGGER trg_game_au AFTER UPDATE ON Game FOR EACH ROW
  INSERT INTO Audit_Log (table_name, record_pk, action, changed_by, old_values, new_values)
  SELECT 'Game', CAST(NEW.game_id AS CHAR), 'UPDATE', @app_user_id,
    JSON_OBJECT('game_id', OLD.game_id, 'title', OLD.title, 'release_date', OLD.release_date,
      'description', OLD.description, 'cover_image', OLD.cover_image, 'is_upcoming', OLD.is_upcoming,
      'developer_id', OLD.developer_id, 'publisher_id', OLD.publisher_id, 'deleted_at', OLD.deleted_at),
    JSON_OBJECT('game_id', NEW.game_id, 'title', NEW.title, 'release_date', NEW.release_date,
      'description', NEW.description, 'cover_image', NEW.cover_image, 'is_upcoming', NEW.is_upcoming,
      'developer_id', NEW.developer_id, 'publisher_id', NEW.publisher_id, 'deleted_at', NEW.deleted_at)
  FROM DUAL WHERE NOT (JSON_OBJECT('game_id', OLD.game_id, 'title', OLD.title, 'release_date', OLD.release_date,
      'description', OLD.description, 'cover_image', OLD.cover_image, 'is_upcoming', OLD.is_upcoming,
      'developer_id', OLD.developer_id, 'publisher_id', OLD.publisher_id, 'deleted_at', OLD.deleted_at)
    <=> JSON_OBJECT('game_id', NEW.game_id, 'title', NEW.title, 'release_date', NEW.release_date,
      'description', NEW.description, 'cover_image', NEW.cover_image, 'is_upcoming', NEW.is_upcoming,
      'developer_id', NEW.developer_id, 'publisher_id', NEW.publisher_id, 'deleted_at', NEW.deleted_at));
DELIMITER ;

-- Seed a little demo activity so the two pre-connected friend profiles can compare progress immediately.
INSERT INTO User_Game (user_id, game_id, platform_id, purchase_date, purchase_price, baseline_hours, status_id, started_at)
SELECT user_id, 3, 1, '2026-10-01', 0.00, 34.2, 2, '2026-10-01' FROM User WHERE username = 'NickMaxima';
SET @nick_user_game_id = LAST_INSERT_ID();
INSERT INTO User_Game (user_id, game_id, platform_id, purchase_date, purchase_price, baseline_hours, status_id, started_at)
SELECT user_id, 7, 1, '2026-09-15', 0.00, 24.8, 2, '2026-09-15' FROM User WHERE username = 'Dibu2007';
SET @dibu_user_game_id = LAST_INSERT_ID();
INSERT INTO Playtime_Session (user_game_id, started_at, duration_minutes, note) VALUES
(@nick_user_game_id, '2026-11-15 19:30:00', 85, 'Demo friend progress'),
(@dibu_user_game_id, '2026-11-16 20:00:00', 50, 'Demo friend progress');
INSERT INTO User_Achievement (user_game_id, achievement_id, game_id, unlocked_at, progress, is_unlocked)
SELECT @nick_user_game_id, achievement_id, game_id, '2026-10-20 12:00:00', 100, 1 FROM Achievement WHERE name = 'Lands Between Explorer';
INSERT INTO User_Achievement (user_game_id, achievement_id, game_id, unlocked_at, progress, is_unlocked)
SELECT @nick_user_game_id, achievement_id, game_id, NULL, 70, 0 FROM Achievement WHERE name = 'Shardbearer Slayer';
INSERT INTO User_Achievement (user_game_id, achievement_id, game_id, unlocked_at, progress, is_unlocked)
SELECT @dibu_user_game_id, achievement_id, game_id, '2026-10-01 12:00:00', 100, 1 FROM Achievement WHERE name = 'Out of the Underworld';
