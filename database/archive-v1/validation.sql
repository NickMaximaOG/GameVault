-- =====================================================================
--  GameVault: validation.sql   (run after schema.sql)
--  Every check returns: check_name | found | expected | result (PASS/FAIL)
--  Run the whole file; Workbench shows one result tab per section.
--  A correct install shows PASS on every row.
-- =====================================================================
USE gamevault_db;

-- ---------------------------------------------------------------------
-- V1. Row counts against the project minimums
-- ---------------------------------------------------------------------
SELECT t.table_name AS check_name, t.found, t.minimum AS expected,
       IF(t.found >= t.minimum, 'PASS', 'FAIL') AS result
FROM (
    SELECT 'User'             AS table_name, COUNT(*) AS found,   6 AS minimum FROM User
    UNION ALL SELECT 'Developer',        COUNT(*),   8 FROM Developer
    UNION ALL SELECT 'Publisher',        COUNT(*),   8 FROM Publisher
    UNION ALL SELECT 'Genre',            COUNT(*),   8 FROM Genre
    UNION ALL SELECT 'Platform',         COUNT(*),   6 FROM Platform
    UNION ALL SELECT 'Age_Rating',       COUNT(*),   8 FROM Age_Rating
    UNION ALL SELECT 'Game_Mode',        COUNT(*),   5 FROM Game_Mode
    UNION ALL SELECT 'Game',             COUNT(*),  20 FROM Game
    UNION ALL SELECT 'Game_Genre',       COUNT(*),  35 FROM Game_Genre
    UNION ALL SELECT 'Game_Platform',    COUNT(*),  35 FROM Game_Platform
    UNION ALL SELECT 'User_Game',        COUNT(*),  40 FROM User_Game
    UNION ALL SELECT 'Achievement',      COUNT(*),  50 FROM Achievement
    UNION ALL SELECT 'User_Achievement', COUNT(*), 100 FROM User_Achievement
    UNION ALL SELECT 'Rating',           COUNT(*),  25 FROM Rating
    UNION ALL SELECT 'Game_Mode_Map',    COUNT(*),  25 FROM Game_Mode_Map
) t;

-- ---------------------------------------------------------------------
-- V2. Foreign-key integrity: orphan rows (found must be 0)
--     The database already prevents these; the check proves it.
-- ---------------------------------------------------------------------
SELECT check_name, found, 0 AS expected, IF(found = 0, 'PASS', 'FAIL') AS result
FROM (
    SELECT 'Game.developer_id -> Developer' AS check_name, COUNT(*) AS found
      FROM Game g LEFT JOIN Developer d ON d.developer_id = g.developer_id
     WHERE g.developer_id IS NOT NULL AND d.developer_id IS NULL
    UNION ALL SELECT 'Game.publisher_id -> Publisher', COUNT(*)
      FROM Game g LEFT JOIN Publisher p ON p.publisher_id = g.publisher_id
     WHERE g.publisher_id IS NOT NULL AND p.publisher_id IS NULL
    UNION ALL SELECT 'Game.age_rating_id -> Age_Rating', COUNT(*)
      FROM Game g LEFT JOIN Age_Rating a ON a.age_rating_id = g.age_rating_id
     WHERE g.age_rating_id IS NOT NULL AND a.age_rating_id IS NULL
    UNION ALL SELECT 'Game_Genre -> Game', COUNT(*)
      FROM Game_Genre x LEFT JOIN Game g ON g.game_id = x.game_id WHERE g.game_id IS NULL
    UNION ALL SELECT 'Game_Genre -> Genre', COUNT(*)
      FROM Game_Genre x LEFT JOIN Genre g ON g.genre_id = x.genre_id WHERE g.genre_id IS NULL
    UNION ALL SELECT 'Game_Platform -> Game', COUNT(*)
      FROM Game_Platform x LEFT JOIN Game g ON g.game_id = x.game_id WHERE g.game_id IS NULL
    UNION ALL SELECT 'Game_Platform -> Platform', COUNT(*)
      FROM Game_Platform x LEFT JOIN Platform p ON p.platform_id = x.platform_id WHERE p.platform_id IS NULL
    UNION ALL SELECT 'Game_Mode_Map -> Game', COUNT(*)
      FROM Game_Mode_Map x LEFT JOIN Game g ON g.game_id = x.game_id WHERE g.game_id IS NULL
    UNION ALL SELECT 'Game_Mode_Map -> Game_Mode', COUNT(*)
      FROM Game_Mode_Map x LEFT JOIN Game_Mode m ON m.mode_id = x.mode_id WHERE m.mode_id IS NULL
    UNION ALL SELECT 'User_Game -> User', COUNT(*)
      FROM User_Game x LEFT JOIN User u ON u.user_id = x.user_id WHERE u.user_id IS NULL
    UNION ALL SELECT 'User_Game -> Game', COUNT(*)
      FROM User_Game x LEFT JOIN Game g ON g.game_id = x.game_id WHERE g.game_id IS NULL
    UNION ALL SELECT 'Rating -> User', COUNT(*)
      FROM Rating x LEFT JOIN User u ON u.user_id = x.user_id WHERE u.user_id IS NULL
    UNION ALL SELECT 'Rating -> Game', COUNT(*)
      FROM Rating x LEFT JOIN Game g ON g.game_id = x.game_id WHERE g.game_id IS NULL
    UNION ALL SELECT 'Achievement -> Game', COUNT(*)
      FROM Achievement x LEFT JOIN Game g ON g.game_id = x.game_id WHERE g.game_id IS NULL
    UNION ALL SELECT 'User_Achievement -> User_Game', COUNT(*)
      FROM User_Achievement x LEFT JOIN User_Game ug ON ug.user_game_id = x.user_game_id
     WHERE ug.user_game_id IS NULL
    UNION ALL SELECT 'User_Achievement -> Achievement', COUNT(*)
      FROM User_Achievement x LEFT JOIN Achievement a ON a.achievement_id = x.achievement_id
     WHERE a.achievement_id IS NULL
) c;

-- ---------------------------------------------------------------------
-- V3. Platform compatibility: every collection entry sits on a platform
--     the game supports (found must be 0)
-- ---------------------------------------------------------------------
SELECT 'User_Game on an unsupported platform' AS check_name,
       COUNT(*) AS found, 0 AS expected,
       IF(COUNT(*) = 0, 'PASS', 'FAIL') AS result
FROM User_Game ug
LEFT JOIN Game_Platform gp
       ON gp.game_id = ug.game_id AND gp.platform_id = ug.platform_id
WHERE gp.game_id IS NULL;

-- Informational: purchase before the platform's release date (found should be 0)
SELECT 'Purchase dated before platform release' AS check_name,
       COUNT(*) AS found, 0 AS expected,
       IF(COUNT(*) = 0, 'PASS', 'FAIL') AS result
FROM User_Game ug
JOIN Game_Platform gp ON gp.game_id = ug.game_id AND gp.platform_id = ug.platform_id
WHERE ug.purchase_date IS NOT NULL
  AND gp.platform_release_date IS NOT NULL
  AND ug.purchase_date < gp.platform_release_date;

-- ---------------------------------------------------------------------
-- V4. Genre associations
-- ---------------------------------------------------------------------
SELECT check_name, found, expected, IF(ok, 'PASS', 'FAIL') AS result
FROM (
    SELECT 'Games with no genre (expect 0)' AS check_name,
           (SELECT COUNT(*) FROM Game g
             WHERE NOT EXISTS (SELECT 1 FROM Game_Genre gg WHERE gg.game_id = g.game_id)) AS found,
           '0' AS expected,
           (SELECT COUNT(*) FROM Game g
             WHERE NOT EXISTS (SELECT 1 FROM Game_Genre gg WHERE gg.game_id = g.game_id)) = 0 AS ok
    UNION ALL
    SELECT 'Duplicate (game, genre) pairs (expect 0)',
           (SELECT COUNT(*) - COUNT(DISTINCT game_id, genre_id) FROM Game_Genre), '0',
           (SELECT COUNT(*) - COUNT(DISTINCT game_id, genre_id) FROM Game_Genre) = 0
    UNION ALL
    SELECT 'Genres linked to 2+ games (expect >= 4)',
           (SELECT COUNT(*) FROM (SELECT genre_id FROM Game_Genre
                                  GROUP BY genre_id HAVING COUNT(*) > 1) t), '>= 4',
           (SELECT COUNT(*) FROM (SELECT genre_id FROM Game_Genre
                                  GROUP BY genre_id HAVING COUNT(*) > 1) t) >= 4
    UNION ALL
    SELECT 'Games with 2+ genres (expect >= 1)',
           (SELECT COUNT(*) FROM (SELECT game_id FROM Game_Genre
                                  GROUP BY game_id HAVING COUNT(*) > 1) t), '>= 1',
           (SELECT COUNT(*) FROM (SELECT game_id FROM Game_Genre
                                  GROUP BY game_id HAVING COUNT(*) > 1) t) >= 1
    UNION ALL
    SELECT 'Games with 2+ platforms (expect >= 1)',
           (SELECT COUNT(*) FROM (SELECT game_id FROM Game_Platform
                                  GROUP BY game_id HAVING COUNT(*) > 1) t), '>= 1',
           (SELECT COUNT(*) FROM (SELECT game_id FROM Game_Platform
                                  GROUP BY game_id HAVING COUNT(*) > 1) t) >= 1
    UNION ALL
    SELECT 'Games with no game mode (expect 0)',
           (SELECT COUNT(*) FROM Game g
             WHERE NOT EXISTS (SELECT 1 FROM Game_Mode_Map m WHERE m.game_id = g.game_id)), '0',
           (SELECT COUNT(*) FROM Game g
             WHERE NOT EXISTS (SELECT 1 FROM Game_Mode_Map m WHERE m.game_id = g.game_id)) = 0
) c;

-- ---------------------------------------------------------------------
-- V5. Achievement consistency (found must be 0 for every row)
-- ---------------------------------------------------------------------
SELECT check_name, found, 0 AS expected, IF(found = 0, 'PASS', 'FAIL') AS result
FROM (
    SELECT 'Achievement belongs to a different game than the collection entry' AS check_name,
           COUNT(*) AS found
      FROM User_Achievement ua
      JOIN User_Game ug  ON ug.user_game_id  = ua.user_game_id
      JOIN Achievement a ON a.achievement_id = ua.achievement_id
     WHERE a.game_id <> ug.game_id
    UNION ALL SELECT 'User_Achievement.game_id differs from User_Game.game_id', COUNT(*)
      FROM User_Achievement ua JOIN User_Game ug ON ug.user_game_id = ua.user_game_id
     WHERE ua.game_id <> ug.game_id
    UNION ALL SELECT 'Unlocked without timestamp', COUNT(*)
      FROM User_Achievement WHERE is_unlocked = 1 AND unlocked_at IS NULL
    UNION ALL SELECT 'Unlocked with progress below 100', COUNT(*)
      FROM User_Achievement WHERE is_unlocked = 1 AND progress < 100
    UNION ALL SELECT 'Locked with a timestamp', COUNT(*)
      FROM User_Achievement WHERE is_unlocked = 0 AND unlocked_at IS NOT NULL
    UNION ALL SELECT 'Locked with progress of 100', COUNT(*)
      FROM User_Achievement WHERE is_unlocked = 0 AND progress >= 100
    UNION ALL SELECT 'Unlocked before the game was started', COUNT(*)
      FROM User_Achievement ua JOIN User_Game ug ON ug.user_game_id = ua.user_game_id
     WHERE ua.is_unlocked = 1 AND DATE(ua.unlocked_at) < ug.started_at
    UNION ALL SELECT 'Unlocked after the completion date', COUNT(*)
      FROM User_Achievement ua JOIN User_Game ug ON ug.user_game_id = ua.user_game_id
     WHERE ua.is_unlocked = 1 AND ug.completed_at IS NOT NULL
       AND DATE(ua.unlocked_at) > ug.completed_at
    UNION ALL SELECT 'Unlocked in the future', COUNT(*)
      FROM User_Achievement WHERE unlocked_at > NOW()
) c;

-- ---------------------------------------------------------------------
-- V6. Sample-data coverage required by the brief
-- ---------------------------------------------------------------------
SELECT check_name, found, expected, IF(ok, 'PASS', 'FAIL') AS result
FROM (
    SELECT 'Users with no games (>= 1)' AS check_name,
           (SELECT COUNT(*) FROM User u
             WHERE NOT EXISTS (SELECT 1 FROM User_Game ug WHERE ug.user_id = u.user_id)) AS found,
           '>= 1' AS expected,
           (SELECT COUNT(*) FROM User u
             WHERE NOT EXISTS (SELECT 1 FROM User_Game ug WHERE ug.user_id = u.user_id)) >= 1 AS ok
    UNION ALL
    SELECT 'Games with no ratings (>= 1)',
           (SELECT COUNT(*) FROM Game g
             WHERE NOT EXISTS (SELECT 1 FROM Rating r WHERE r.game_id = g.game_id)), '>= 1',
           (SELECT COUNT(*) FROM Game g
             WHERE NOT EXISTS (SELECT 1 FROM Rating r WHERE r.game_id = g.game_id)) >= 1
    UNION ALL
    SELECT 'Games with no achievements (>= 1)',
           (SELECT COUNT(*) FROM Game g
             WHERE NOT EXISTS (SELECT 1 FROM Achievement a WHERE a.game_id = g.game_id)), '>= 1',
           (SELECT COUNT(*) FROM Game g
             WHERE NOT EXISTS (SELECT 1 FROM Achievement a WHERE a.game_id = g.game_id)) >= 1
    UNION ALL
    SELECT 'Partially complete achievements (>= 1)',
           (SELECT COUNT(*) FROM User_Achievement WHERE is_unlocked = 0 AND progress > 0), '>= 1',
           (SELECT COUNT(*) FROM User_Achievement WHERE is_unlocked = 0 AND progress > 0) >= 1
    UNION ALL
    SELECT 'Distinct collection statuses in use (= 5)',
           (SELECT COUNT(DISTINCT status) FROM User_Game), '5',
           (SELECT COUNT(DISTINCT status) FROM User_Game) = 5
    UNION ALL
    SELECT 'Ratings by users who do not own the game (= 0, sample-data property)',
           (SELECT COUNT(*) FROM Rating r
             WHERE NOT EXISTS (SELECT 1 FROM User_Game ug
                                WHERE ug.user_id = r.user_id AND ug.game_id = r.game_id)), '0',
           (SELECT COUNT(*) FROM Rating r
             WHERE NOT EXISTS (SELECT 1 FROM User_Game ug
                                WHERE ug.user_id = r.user_id AND ug.game_id = r.game_id)) = 0
) c;

-- ---------------------------------------------------------------------
-- V7. Aggregates are not inflated by joins: each pre-aggregated query
--     must reconcile with the raw table total (found = expected).
-- ---------------------------------------------------------------------
SELECT check_name, found, expected, IF(found = expected, 'PASS', 'FAIL') AS result
FROM (
    SELECT 'Q6 per-user hours add up to raw total' AS check_name,
           (SELECT SUM(h) FROM (SELECT COALESCE(SUM(ug.playtime_hours),0) AS h
                                  FROM User u LEFT JOIN User_Game ug ON ug.user_id = u.user_id
                                 GROUP BY u.user_id) t) AS found,
           (SELECT SUM(playtime_hours) FROM User_Game) AS expected
    UNION ALL
    SELECT 'Q19 per-platform hours add up to raw total',
           (SELECT SUM(h) FROM (SELECT SUM(ug.playtime_hours) AS h FROM User_Game ug
                                 GROUP BY ug.platform_id) t),
           (SELECT SUM(playtime_hours) FROM User_Game)
    UNION ALL
    SELECT 'Q24 per-mode hours = sum over Game_Mode_Map of per-game hours',
           (SELECT ROUND(COALESCE(SUM(gt.total_hours),0),1)
              FROM Game_Mode_Map gmm
              LEFT JOIN (SELECT game_id, SUM(playtime_hours) AS total_hours
                           FROM User_Game GROUP BY game_id) gt ON gt.game_id = gmm.game_id),
           (SELECT ROUND(SUM(ug.playtime_hours),1)
              FROM User_Game ug JOIN Game_Mode_Map gmm ON gmm.game_id = ug.game_id)
    UNION ALL
    SELECT 'Q18 per-user spending adds up to raw total',
           (SELECT SUM(s) FROM (SELECT COALESCE(SUM(ug.purchase_price),0) AS s
                                  FROM User u LEFT JOIN User_Game ug ON ug.user_id = u.user_id
                                 GROUP BY u.user_id) t),
           (SELECT SUM(purchase_price) FROM User_Game)
    UNION ALL
    SELECT 'Q8 genre counts add up to Game_Genre rows',
           (SELECT SUM(n) FROM (SELECT COUNT(gg.game_id) AS n FROM Genre gn
                                  LEFT JOIN Game_Genre gg ON gg.genre_id = gn.genre_id
                                 GROUP BY gn.genre_id) t),
           (SELECT COUNT(*) FROM Game_Genre)
    UNION ALL
    SELECT 'Q12 per-game achievement counts add up to Achievement rows',
           (SELECT SUM(n) FROM (SELECT COUNT(a.achievement_id) AS n FROM Game g
                                  LEFT JOIN Achievement a ON a.game_id = g.game_id
                                 GROUP BY g.game_id) t),
           (SELECT COUNT(*) FROM Achievement)
    UNION ALL
    SELECT 'Q25 per-user achievement points = raw unlocked points',
           (SELECT SUM(p) FROM (SELECT SUM(ac.points) AS p
                                  FROM User_Achievement ua
                                  JOIN User_Game ug   ON ug.user_game_id  = ua.user_game_id
                                  JOIN Achievement ac ON ac.achievement_id = ua.achievement_id
                                 WHERE ua.is_unlocked = 1 GROUP BY ug.user_id) t),
           (SELECT SUM(ac.points) FROM User_Achievement ua
              JOIN Achievement ac ON ac.achievement_id = ua.achievement_id
             WHERE ua.is_unlocked = 1)
) c;

-- ---------------------------------------------------------------------
-- V8. Constraint inventory (documents what the database enforces)
-- ---------------------------------------------------------------------
-- Foreign keys with their delete/update rules (expect 18 rows)
SELECT rc.table_name, rc.constraint_name, rc.referenced_table_name,
       rc.delete_rule, rc.update_rule
FROM information_schema.referential_constraints rc
WHERE rc.constraint_schema = 'gamevault_db'
ORDER BY rc.table_name, rc.constraint_name;

-- CHECK constraints (expect 11 rows)
SELECT tc.table_name, cc.constraint_name, cc.check_clause
FROM information_schema.check_constraints cc
JOIN information_schema.table_constraints tc
  ON tc.constraint_schema = cc.constraint_schema
 AND tc.constraint_name   = cc.constraint_name
WHERE cc.constraint_schema = 'gamevault_db'
ORDER BY tc.table_name, cc.constraint_name;
