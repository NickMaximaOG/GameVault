-- =====================================================================
-- negative_tests.sql : proves the database REJECTS inconsistent data
-- Each test is one statement that MUST fail. Run them ONE AT A TIME
-- (select the statement, Ctrl+Enter); a script run stops at the first error.
-- Every statement is shown inside START TRANSACTION ... ROLLBACK so nothing
-- is kept even if a test unexpectedly succeeds.
-- =====================================================================
USE gamevault_db;

-- NOTE: statements use LIMIT or a key column so they also work with Workbench's
-- default "Safe Updates" mode (otherwise MySQL answers error 1175 instead).

-- N1. Platform not supported by the game (Zelda BOTW exists only on Switch).
--     Expected: ERROR 1452 (fk_user_game_supported_platform)
START TRANSACTION;
INSERT INTO User_Game (user_id, game_id, platform_id, status)
SELECT u.user_id, g.game_id, p.platform_id, 'Backlog'
FROM User u, Game g, Platform p
WHERE u.username = 'new_player_07'
  AND g.title = 'The Legend of Zelda: Breath of the Wild'
  AND p.name = 'PlayStation 5';
ROLLBACK;

-- N2. Achievement from a different game than the collection entry.
--     aarav_k's God of War entry paired with an Elden Ring achievement.
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
--     Uses rohan_v's Baldur's Gate 3 entry (Backlog, so it has no progress rows yet).
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
UPDATE User_Achievement SET unlocked_at = NOW()
WHERE is_unlocked = 0 LIMIT 1;
ROLLBACK;

-- N5. Progress outside 0..100.
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

-- N9. Negative playtime.
--     Expected: ERROR 3819 (chk_ug_playtime)
START TRANSACTION;
UPDATE User_Game SET playtime_hours = -5 LIMIT 1;
ROLLBACK;

-- N10. 'Completed' status without a completion date.
--      Expected: ERROR 3819 (chk_ug_completed)
START TRANSACTION;
UPDATE User_Game SET completed_at = NULL WHERE status = 'Completed' LIMIT 1;
ROLLBACK;

-- N11. Invalid status text.
--      Expected: ERROR 1265 (Data truncated for column 'status')
START TRANSACTION;
UPDATE User_Game SET status = 'Finished' LIMIT 1;
ROLLBACK;

-- N12. Deleting a game that sits in someone's collection.
--      Expected: ERROR 1451 (fk_user_game_game RESTRICT)
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

-- N15. Age outside the allowed range.
--      Expected: ERROR 3819 (chk_age_rating_min_age)
START TRANSACTION;
INSERT INTO Age_Rating (label, rating_authority, minimum_age) VALUES ('X', 'TEST', 40);
ROLLBACK;

-- ---------------------------------------------------------------------
-- POSITIVE cascade demo (safe, rolled back): deleting a user removes
-- their collection, ratings and achievement progress; the game stays.
-- Expected inside the transaction: 0, 0 and 33 (the other 6 users' rows remain); ROLLBACK restores all 40.
-- ---------------------------------------------------------------------
START TRANSACTION;
DELETE FROM User WHERE username = 'ananya_d' LIMIT 1;
SELECT (SELECT COUNT(*) FROM User_Game ug JOIN User u USING (user_id) WHERE u.username='ananya_d') AS remaining_collection_rows,
       (SELECT COUNT(*) FROM Rating r JOIN User u USING (user_id) WHERE u.username='ananya_d')     AS remaining_ratings,
       (SELECT COUNT(*) FROM User_Game) AS user_game_rows_remaining;
ROLLBACK;
