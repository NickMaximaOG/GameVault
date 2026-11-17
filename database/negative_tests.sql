-- =====================================================================
-- GameVault v2: negative_tests.sql
-- Proves the database REJECTS inconsistent data. Every block is one
-- attempt that MUST fail with the error code in its "Expected" line.
-- Each block is wrapped in START TRANSACTION ... ROLLBACK, so nothing is
-- kept even if a test unexpectedly succeeds.
--
-- Workbench: run ONE block at a time (select it, Ctrl+Enter); a whole-file
-- run stops at the first error.
-- Automated: python3 database/tests/run_db_tests.py runs every block and
-- compares the error code with the "Expected" line.
-- Statements use LIMIT or a key so they also work with Workbench's
-- default "Safe Updates" mode.
-- =====================================================================
USE gamevault_db;

-- N1. Platform not supported by the game (Zelda BOTW exists only on Switch).
--     Expected: ERROR 1452 (fk_user_game_supported_platform)
START TRANSACTION;
INSERT INTO User_Game (user_id, game_id, platform_id, status_id)
SELECT u.user_id, g.game_id, p.platform_id, 1
FROM User u, Game g, Platform p
WHERE u.username = 'new_player_07'
  AND g.title = 'The Legend of Zelda: Breath of the Wild'
  AND p.name = 'PlayStation 5';
ROLLBACK;

-- N2. Achievement from a different game than the collection entry.
--     Expected: ERROR 1452 (fk_ua_achievement)
START TRANSACTION;
INSERT INTO User_Achievement (user_game_id, achievement_id, game_id, unlocked_at, progress, is_unlocked)
SELECT ug.user_game_id, a.achievement_id, ug.game_id, NULL, 0, 0
FROM User_Game ug
JOIN User u ON u.user_id = ug.user_id AND u.username = 'aarav_k'
JOIN Game g ON g.game_id = ug.game_id AND g.title = 'God of War Ragnarök'
JOIN Achievement a ON a.name = 'Elden Lord';
ROLLBACK;

-- N3. Unlocked achievement without a timestamp.
--     Expected: ERROR 3819 (chk_ua_unlock_consistency)
START TRANSACTION;
INSERT INTO User_Achievement (user_game_id, achievement_id, game_id, unlocked_at, progress, is_unlocked)
SELECT ug.user_game_id, a.achievement_id, ug.game_id, NULL, 100, 1
FROM User_Game ug
JOIN User u ON u.user_id = ug.user_id AND u.username = 'rohan_v'
JOIN Game g ON g.game_id = ug.game_id AND g.title = 'Baldur''s Gate 3'
JOIN Achievement a ON a.game_id = g.game_id AND a.name = 'Party Assembled';
ROLLBACK;

-- N4. Locked achievement that still carries an unlock timestamp.
--     Expected: ERROR 3819 (chk_ua_unlock_consistency)
START TRANSACTION;
UPDATE User_Achievement SET unlocked_at = NOW() WHERE is_unlocked = 0 LIMIT 1;
ROLLBACK;

-- N5. Achievement progress outside 0..100.
--     Expected: ERROR 3819 (chk_ua_progress)
START TRANSACTION;
UPDATE User_Achievement SET progress = 140 WHERE is_unlocked = 0 LIMIT 1;
ROLLBACK;

-- N6. Rating outside 1..10.
--     Expected: ERROR 3819 (chk_rating_range)
START TRANSACTION;
UPDATE Rating SET rating = 11 LIMIT 1;
ROLLBACK;

-- N7. Second review of the same game by the same user.
--     Expected: ERROR 1062 (uq_rating_user_game)
START TRANSACTION;
INSERT INTO Rating (user_id, game_id, rating, review_text)
SELECT user_id, game_id, 5, 'duplicate' FROM Rating LIMIT 1;
ROLLBACK;

-- N8. Duplicate genre link.
--     Expected: ERROR 1062 (PRIMARY on Game_Genre)
START TRANSACTION;
INSERT INTO Game_Genre (game_id, genre_id) SELECT game_id, genre_id FROM Game_Genre LIMIT 1;
ROLLBACK;

-- N9. Negative baseline hours.
--     Expected: ERROR 3819 (chk_ug_baseline)
START TRANSACTION;
UPDATE User_Game SET baseline_hours = -5 LIMIT 1;
ROLLBACK;

-- N10. 'Completed' status without a completion date.
--      Expected: ERROR 3819 (chk_ug_completed)
START TRANSACTION;
UPDATE User_Game SET completed_at = NULL WHERE status_id = 3 LIMIT 1;
ROLLBACK;

-- N11. Unknown status id.
--      Expected: ERROR 1452 (fk_user_game_status)
START TRANSACTION;
UPDATE User_Game SET status_id = 99 WHERE status_id = 1 LIMIT 1;
ROLLBACK;

-- N12. Deleting a game that sits in someone's collection.
--      Expected: ERROR 1451 (fk_user_game_supported_platform RESTRICT)
START TRANSACTION;
DELETE FROM Game WHERE title = 'Elden Ring' LIMIT 1;
ROLLBACK;

-- N13. Removing platform support that a user's collection relies on.
--      Expected: ERROR 1451 (fk_user_game_supported_platform RESTRICT)
START TRANSACTION;
DELETE FROM Game_Platform
WHERE game_id     = (SELECT game_id     FROM Game     WHERE title = 'Hades')
  AND platform_id = (SELECT platform_id FROM Platform WHERE name  = 'Nintendo Switch');
ROLLBACK;

-- N14. Duplicate (rating_authority, label).
--      Expected: ERROR 1062 (uq_age_rating_authority_label)
START TRANSACTION;
INSERT INTO Age_Rating (label, rating_authority, minimum_age) VALUES ('M', 'ESRB', 17);
ROLLBACK;

-- N15. Minimum age outside the allowed range.
--      Expected: ERROR 3819 (chk_age_rating_min_age)
START TRANSACTION;
INSERT INTO Age_Rating (label, rating_authority, minimum_age) VALUES ('X', 'TEST', 40);
ROLLBACK;

-- N16. Hard-deleting a user who owns games (soft delete is the only way).
--      Expected: ERROR 1451 (fk_user_game_user RESTRICT)
START TRANSACTION;
DELETE FROM User WHERE username = 'meera_s' LIMIT 1;
ROLLBACK;

-- N17. PEGI authority paired with an ESRB rating id (authority mismatch).
--      Expected: ERROR 1452 (fk_gar_rating)
START TRANSACTION;
INSERT INTO Game_Age_Rating (game_id, rating_authority, age_rating_id)
SELECT g.game_id, 'PEGI', ar.age_rating_id
FROM Game g, Age_Rating ar
WHERE g.title = 'Hades' AND ar.rating_authority = 'ESRB' AND ar.label = 'T';
ROLLBACK;

-- N18. Two ratings from the same authority for one game.
--      Expected: ERROR 1062 (PRIMARY on Game_Age_Rating)
START TRANSACTION;
INSERT INTO Game_Age_Rating (game_id, rating_authority, age_rating_id)
SELECT g.game_id, 'ESRB', ar.age_rating_id
FROM Game g, Age_Rating ar
WHERE g.title = 'Hades' AND ar.rating_authority = 'ESRB' AND ar.label = 'E';
ROLLBACK;

-- N19. Play session of 0 minutes.
--      Expected: ERROR 3819 (chk_ps_minutes)
START TRANSACTION;
INSERT INTO Playtime_Session (user_game_id, started_at, duration_minutes)
SELECT MIN(user_game_id), '2024-01-01 10:00:00', 0 FROM User_Game;
ROLLBACK;

-- N20. Play session longer than a day.
--      Expected: ERROR 3819 (chk_ps_minutes)
START TRANSACTION;
INSERT INTO Playtime_Session (user_game_id, started_at, duration_minutes)
SELECT MIN(user_game_id), '2024-01-01 10:00:00', 1441 FROM User_Game;
ROLLBACK;

-- N21. Editing the audit log.
--      Expected: ERROR 1644 (trg_audit_log_no_update)
START TRANSACTION;
UPDATE Game SET release_date = release_date + INTERVAL 1 DAY WHERE game_id = 1;
UPDATE Audit_Log SET changed_by = 99 LIMIT 1;
ROLLBACK;

-- N22. Deleting from the audit log.
--      Expected: ERROR 1644 (trg_audit_log_no_delete)
START TRANSACTION;
UPDATE Game SET release_date = release_date + INTERVAL 1 DAY WHERE game_id = 1;
DELETE FROM Audit_Log LIMIT 1;
ROLLBACK;

-- N23. Duplicate username.
--      Expected: ERROR 1062 (uq_user_username)
START TRANSACTION;
INSERT INTO User (username, email, password_hash)
VALUES ('meera_s', 'another@example.com', 'pbkdf2-sha256$1$AA==$AA==');
ROLLBACK;

-- N24. Malformed e-mail address.
--      Expected: ERROR 3819 (chk_user_email)
START TRANSACTION;
INSERT INTO User (username, email, password_hash)
VALUES ('bad_email_user', 'not-an-email', 'pbkdf2-sha256$1$AA==$AA==');
ROLLBACK;

-- N25. Unknown role id.
--      Expected: ERROR 1452 (fk_user_role)
START TRANSACTION;
UPDATE User SET role_id = 9 WHERE username = 'meera_s' LIMIT 1;
ROLLBACK;

-- N26. Same login token stored twice.
--      Expected: ERROR 1062 (uq_auth_session_token)
START TRANSACTION;
INSERT INTO Auth_Session (user_id, token_hash, expires_at)
VALUES (1, REPEAT('a', 64), NOW() + INTERVAL 1 HOUR), (2, REPEAT('a', 64), NOW() + INTERVAL 1 HOUR);
ROLLBACK;

-- N27. Negative price.
--      Expected: ERROR 3819 (chk_ug_price)
START TRANSACTION;
UPDATE User_Game SET purchase_price = -1 LIMIT 1;
ROLLBACK;

-- N28. Completion before the start date.
--      Expected: ERROR 3819 (chk_ug_dates)
START TRANSACTION;
UPDATE User_Game SET completed_at = started_at - INTERVAL 1 DAY WHERE status_id = 3 LIMIT 1;
ROLLBACK;

-- N29. Negative achievement points.
--      Expected: ERROR 3819 (chk_achievement_points)
START TRANSACTION;
UPDATE Achievement SET points = -10 LIMIT 1;
ROLLBACK;

-- N30. Same achievement name twice in one game.
--      Expected: ERROR 1062 (uq_achievement_game_name)
START TRANSACTION;
INSERT INTO Achievement (game_id, name, points)
SELECT game_id, name, 5 FROM Achievement LIMIT 1;
ROLLBACK;
