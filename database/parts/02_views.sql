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
SELECT g.game_id, g.title, g.release_date, g.description, g.cover_image,
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
       ug.status_id, ug.status, ug.started_at, ug.completed_at, ug.row_version,
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
LEFT JOIN v_rating r ON r.user_id = ug.user_id AND r.game_id = ug.game_id;

-- Catalogue: one row per active game with every many-to-many list collapsed
CREATE OR REPLACE VIEW v_game_catalog AS
SELECT g.game_id, g.title, g.release_date, g.description, g.cover_image,
       dev.name  AS developer,
       pub.name  AS publisher,
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
       a.points, a.is_hidden,
       COALESCE(ua.progress, 0)    AS progress,
       COALESCE(ua.is_unlocked, 0) AS is_unlocked,
       ua.unlocked_at
FROM v_user_game ug
JOIN Achievement a ON a.game_id = ug.game_id
LEFT JOIN User_Achievement ua
       ON ua.user_game_id = ug.user_game_id AND ua.achievement_id = a.achievement_id;

