-- =====================================================================
--  GameVault v2: queries.sql   (MySQL 8.0, run after schema.sql)
--  26 queries covering SELECT/WHERE, aggregates, GROUP BY/HAVING/ORDER BY,
--  INNER/LEFT/RIGHT joins, subqueries and CTEs.
--  v2: queries read the soft-delete-aware VIEWS (v_game, v_user, v_rating,
--  v_user_game) so deleted rows never appear and playtime is the derived total.
--
--  HOW TO USE IN WORKBENCH
--    * Run the SET block below first (select it, Ctrl+Enter), then run each
--      query on its own: put the cursor inside it and press Ctrl+Enter.
--      Running the whole file also works; Workbench shows one result tab per query.
--    * Change the @variables to try other filters. A Streamlit app would pass
--      the same values as %s parameters instead of hard-coding them.
--    * Aggregates that touch more than one 1:N relationship are pre-aggregated
--      in a derived table/CTE so joins never multiply counts or sums.
-- =====================================================================
USE gamevault_db;

-- Filter inputs (what a UI would supply) -------------------------------
SET @keyword          = 'Wild';
SET @genre_name       = 'RPG';
SET @platform_name    = 'Nintendo Switch';
SET @rating_authority = 'ESRB';
SET @rating_label     = 'M';
SET @username         = 'meera_s';
SET @min_genre_games  = 3;
SET @min_avg_rating   = 9.0;
SET @min_rating_count = 2;
SET @genre_a          = 'Action';
SET @genre_b          = 'RPG';

-- =====================================================================
-- Q1. Filter games by title or keyword
-- Matches the keyword anywhere in the title or description.
-- Expected: 2 rows (The Legend of Zelda: Breath of the Wild, The Witcher 3: Wild Hunt).
-- =====================================================================
SELECT g.game_id,
       g.title,
       g.release_date,
       ar.label AS age_rating
FROM v_game g
LEFT JOIN Game_Age_Rating gar ON gar.game_id = g.game_id AND gar.rating_authority = @rating_authority
LEFT JOIN Age_Rating ar       ON ar.age_rating_id = gar.age_rating_id
WHERE g.title       LIKE CONCAT('%', @keyword, '%')
   OR g.description LIKE CONCAT('%', @keyword, '%')
ORDER BY g.title;

-- =====================================================================
-- Q2. Filter games by genre (Game -> Game_Genre -> Genre)
-- Also shows every genre of each match through a correlated subquery,
-- so a multi-genre game is listed once.
-- Expected: 6 RPG games (Baldur's Gate 3, Black Myth: Wukong, Cyberpunk 2077,
--           Elden Ring, Stardew Valley, The Witcher 3: Wild Hunt).
-- =====================================================================
SELECT g.title,
       g.release_date,
       (SELECT GROUP_CONCAT(gn2.name ORDER BY gn2.name SEPARATOR ', ')
          FROM Game_Genre gg2
          JOIN Genre gn2 ON gn2.genre_id = gg2.genre_id
         WHERE gg2.game_id = g.game_id) AS all_genres
FROM v_game g
JOIN Game_Genre gg ON gg.game_id = g.game_id
JOIN Genre gn      ON gn.genre_id = gg.genre_id
WHERE gn.name = @genre_name
ORDER BY g.title;

-- =====================================================================
-- Q3. Filter games by platform (Game -> Game_Platform -> Platform)
-- Expected: 10 Nintendo Switch games ordered by Switch release date, from
--           The Legend of Zelda: Breath of the Wild (2017-03-03) to DOOM Eternal (2021-12-08).
-- =====================================================================
SELECT g.title,
       p.name AS platform,
       gp.platform_release_date
FROM v_game g
JOIN Game_Platform gp ON gp.game_id = g.game_id
JOIN Platform p       ON p.platform_id = gp.platform_id
WHERE p.name = @platform_name
ORDER BY gp.platform_release_date, g.title;

-- =====================================================================
-- Q4. Filter games by age rating (authority + label)
-- Expected: 10 ESRB "M" games with developer and publisher
--           (Baldur's Gate 3, Cyberpunk 2077, DOOM Eternal, Elden Ring, God of War Ragnarök, ...).
-- =====================================================================
SELECT g.title,
       ar.rating_authority,
       ar.label  AS age_rating,
       ar.minimum_age,
       d.name    AS developer,
       pb.name   AS publisher
FROM v_game g
JOIN Game_Age_Rating gar ON gar.game_id = g.game_id
JOIN Age_Rating ar     ON ar.age_rating_id = gar.age_rating_id
LEFT JOIN Developer d  ON d.developer_id   = g.developer_id
LEFT JOIN Publisher pb ON pb.publisher_id  = g.publisher_id
WHERE ar.rating_authority = @rating_authority
  AND ar.label            = @rating_label
ORDER BY g.title;

-- =====================================================================
-- Q5. A user's collection with completion status
-- Active titles first, completed last.
-- Expected: 7 rows for meera_s: Playing (Elden Ring, Minecraft, Mario Kart 8 Deluxe),
--           then Completed (The Last of Us Part I, God of War Ragnarök, Black Myth: Wukong, Hades).
-- =====================================================================
SELECT u.username,
       g.title,
       p.name AS platform,
       ug.status,
       ug.playtime_hours,
       ug.started_at,
       ug.completed_at
FROM v_user_game ug
JOIN v_user u     ON u.user_id     = ug.user_id
JOIN v_game g     ON g.game_id     = ug.game_id
JOIN Platform p ON p.platform_id = ug.platform_id
WHERE u.username = @username
ORDER BY FIELD(ug.status, 'Playing', 'On Hold', 'Backlog', 'Completed', 'Dropped'), g.title;

-- =====================================================================
-- Q6. Total playtime per user (SUM)
-- LEFT JOIN keeps users with no games and COALESCE turns their NULL sum into 0.
-- Expected: 7 rows; ishita_r has the most hours (~817); new_player_07 shows 0 games / 0 hours.
-- =====================================================================
SELECT u.username,
       COUNT(ug.user_game_id)                      AS games_in_collection,
       COALESCE(SUM(ug.playtime_hours), 0)         AS total_playtime_hours
FROM v_user u
LEFT JOIN v_user_game ug ON ug.user_id = u.user_id
GROUP BY u.user_id, u.username
ORDER BY total_playtime_hours DESC, u.username;

-- =====================================================================
-- Q7. Average rating per game (AVG)
-- LEFT JOIN keeps unrated games (average shows NULL, count 0).
-- Expected: 20 rows; Stardew Valley leads with 9.50; five games show 0 ratings.
-- =====================================================================
SELECT g.title,
       COUNT(r.rating_id)        AS number_of_ratings,
       ROUND(AVG(r.rating), 2)   AS average_rating
FROM v_game g
LEFT JOIN v_rating r ON r.game_id = g.game_id
GROUP BY g.game_id, g.title
ORDER BY average_rating DESC, g.title;

-- =====================================================================
-- Q8. Games per genre (COUNT + GROUP BY)
-- Expected: 12 rows; Action 13, then Adventure/Open World/RPG 6 each, down to 1.
-- =====================================================================
SELECT gn.name               AS genre,
       COUNT(gg.game_id)     AS number_of_games
FROM Genre gn
LEFT JOIN Game_Genre gg ON gg.genre_id = gn.genre_id
GROUP BY gn.genre_id, gn.name
ORDER BY number_of_games DESC, gn.name;

-- =====================================================================
-- Q9. Genres with more than N games (HAVING)
-- Uses @min_genre_games (3).
-- Expected: 4 rows: Action 13, Adventure 6, Open World 6, RPG 6.
-- =====================================================================
SELECT gn.name           AS genre,
       COUNT(gg.game_id) AS number_of_games
FROM Genre gn
JOIN Game_Genre gg ON gg.genre_id = gn.genre_id
GROUP BY gn.genre_id, gn.name
HAVING COUNT(gg.game_id) > @min_genre_games
ORDER BY number_of_games DESC, gn.name;

-- =====================================================================
-- Q10. Five most-played games (ORDER BY ... LIMIT)
-- Playtime summed over all users that own the game.
-- Expected: Civilization VI (453.0), Minecraft (345.0), Stardew Valley (340.0),
--           Elden Ring (313.5), The Witcher 3: Wild Hunt (215.0).
-- =====================================================================
SELECT g.title,
       COUNT(ug.user_game_id)    AS owners,
       SUM(ug.playtime_hours)    AS total_hours_played
FROM v_game g
JOIN v_user_game ug ON ug.game_id = g.game_id
GROUP BY g.game_id, g.title
ORDER BY total_hours_played DESC, g.title
LIMIT 5;

-- =====================================================================
-- Q11a. Minimum and maximum playtime (MIN, MAX)
-- Backlog entries (0 h) are excluded so the minimum is meaningful.
-- Expected: one row: min 6.5, max 420.0, average 76.1, 38 started entries.
-- =====================================================================
SELECT MIN(playtime_hours)          AS min_playtime_hours,
       MAX(playtime_hours)          AS max_playtime_hours,
       ROUND(AVG(playtime_hours),1) AS avg_playtime_hours,
       COUNT(*)                     AS started_entries
FROM v_user_game
WHERE playtime_hours > 0;

-- Q11b. Who holds the minimum and the maximum?
-- Expected: 2 rows: ishita_r / Civilization VI / 420.0 and aarav_k / Sekiro / 6.5.
SELECT u.username, g.title, ug.playtime_hours
FROM v_user_game ug
JOIN v_user u ON u.user_id = ug.user_id
JOIN v_game g ON g.game_id = ug.game_id
WHERE ug.playtime_hours = (SELECT MAX(playtime_hours) FROM v_user_game)
   OR ug.playtime_hours = (SELECT MIN(playtime_hours) FROM v_user_game WHERE playtime_hours > 0)
ORDER BY ug.playtime_hours DESC;

-- =====================================================================
-- Q12. Games with achievement counts (LEFT JOIN)
-- LEFT JOIN keeps games that have no achievements (count 0).
-- Expected: 20 rows; Elden Ring, Hades and Hollow Knight have 5 each;
--           7 games (e.g. Red Dead Redemption 2, DOOM Eternal) show 0.
-- =====================================================================
SELECT g.title,
       COUNT(a.achievement_id)       AS achievements,
       COALESCE(SUM(a.points), 0)    AS total_points
FROM v_game g
LEFT JOIN Achievement a ON a.game_id = g.game_id
GROUP BY g.game_id, g.title
ORDER BY achievements DESC, g.title;

-- =====================================================================
-- Q13. Unlocked achievements with user and game (INNER JOIN, 5 tables)
-- Most recent 20 unlocks.
-- Expected: 20 rows, newest first.
-- =====================================================================
SELECT u.username,
       g.title        AS game,
       a.name         AS achievement,
       a.points,
       ua.unlocked_at
FROM User_Achievement ua
JOIN v_user_game ug   ON ug.user_game_id  = ua.user_game_id
JOIN v_user u         ON u.user_id        = ug.user_id
JOIN v_game g         ON g.game_id        = ug.game_id
JOIN Achievement a  ON a.achievement_id = ua.achievement_id
WHERE ua.is_unlocked = 1
ORDER BY ua.unlocked_at DESC, u.username
LIMIT 20;

-- =====================================================================
-- Q14. Users with no games (LEFT JOIN ... IS NULL)
-- Expected: 1 row: new_player_07.
-- =====================================================================
SELECT u.user_id, u.username, u.join_date
FROM v_user u
LEFT JOIN v_user_game ug ON ug.user_id = u.user_id
WHERE ug.user_game_id IS NULL;

-- =====================================================================
-- Q15. RIGHT JOIN: every age rating, including ones no game uses
-- The right-hand table (Age_Rating) is preserved, so classes no game uses
-- appear with 0 games (PEGI 12).
-- Expected: 9 rows; ESRB E 2, E10+ 6, T 2, M 10; PEGI 3 2, 7 1, 12 0, 16 1, 18 6.
-- =====================================================================
SELECT ar.rating_authority,
       ar.label,
       ar.minimum_age,
       COUNT(g.game_id) AS games_with_this_rating
FROM (Game_Age_Rating gar JOIN v_game g ON g.game_id = gar.game_id)
RIGHT JOIN Age_Rating ar ON ar.age_rating_id = gar.age_rating_id
GROUP BY ar.age_rating_id, ar.rating_authority, ar.label, ar.minimum_age
ORDER BY ar.rating_authority, ar.minimum_age;

-- =====================================================================
-- Q16. Achievement completion percentage per collection entry
-- Totals come from Achievement and unlocked counts from User_Achievement,
-- each pre-aggregated, so neither inflates the other.
-- Expected: 32 rows, one per collection entry whose game has achievements.
--           Most completed runs are 100%; the two Backlog entries show 0.0%.
-- =====================================================================
SELECT u.username,
       g.title,
       ug.status,
       t.total_achievements,
       COALESCE(p.unlocked, 0)                                         AS unlocked,
       ROUND(100 * COALESCE(p.unlocked, 0) / t.total_achievements, 1)  AS completion_pct,
       COALESCE(p.points_earned, 0)                                    AS points_earned
FROM v_user_game ug
JOIN v_user u ON u.user_id = ug.user_id
JOIN v_game g ON g.game_id = ug.game_id
JOIN (SELECT game_id, COUNT(*) AS total_achievements
        FROM Achievement GROUP BY game_id) t ON t.game_id = ug.game_id
LEFT JOIN (SELECT ua.user_game_id,
                  SUM(ua.is_unlocked)                              AS unlocked,
                  SUM(CASE WHEN ua.is_unlocked = 1 THEN a.points ELSE 0 END) AS points_earned
             FROM User_Achievement ua
             JOIN Achievement a ON a.achievement_id = ua.achievement_id
            GROUP BY ua.user_game_id) p ON p.user_game_id = ug.user_game_id
ORDER BY completion_pct DESC, u.username, g.title;

-- =====================================================================
-- Q17. Games with high average ratings (HAVING on AVG and COUNT)
-- Uses @min_avg_rating (9.0) and @min_rating_count (2) so one lone 10 does not qualify.
-- Expected: 4 rows: Stardew Valley 9.50, Hollow Knight 9.33, Celeste 9.00, Hades 9.00.
-- =====================================================================
SELECT g.title,
       COUNT(r.rating_id)      AS number_of_ratings,
       ROUND(AVG(r.rating), 2) AS average_rating
FROM v_game g
JOIN v_rating r ON r.game_id = g.game_id
GROUP BY g.game_id, g.title
HAVING AVG(r.rating) >= @min_avg_rating
   AND COUNT(r.rating_id) >= @min_rating_count
ORDER BY average_rating DESC, g.title;

-- =====================================================================
-- Q18. Total money spent per user (SUM)
-- Free/gifted copies (price 0) are counted separately.
-- Expected: 7 rows; new_player_07 spent 0.00.
-- =====================================================================
SELECT u.username,
       COUNT(ug.user_game_id)                         AS games_owned,
       COALESCE(SUM(ug.purchase_price = 0), 0)        AS free_or_gifted,
       COALESCE(SUM(ug.purchase_price), 0)            AS total_spent_usd,
       ROUND(COALESCE(AVG(ug.purchase_price), 0), 2)  AS avg_price_usd
FROM v_user u
LEFT JOIN v_user_game ug ON ug.user_id = u.user_id
GROUP BY u.user_id, u.username
ORDER BY total_spent_usd DESC, u.username;

-- =====================================================================
-- Q19a. Most frequently used platform (ties are returned too)
-- Expected: 1 row: PC (Windows), 18 collection entries.
-- =====================================================================
WITH platform_usage AS (
    SELECT p.platform_id,
           p.name                  AS platform,
           COUNT(*)                AS collection_entries,
           SUM(ug.playtime_hours)  AS total_hours
    FROM v_user_game ug
    JOIN Platform p ON p.platform_id = ug.platform_id
    GROUP BY p.platform_id, p.name
)
SELECT platform, collection_entries, total_hours
FROM platform_usage
WHERE collection_entries = (SELECT MAX(collection_entries) FROM platform_usage);

-- Q19b. Full platform ranking by entries and by hours (window functions)
-- Expected: PC first by both; PS5 and Switch tie on entries (9 each).
SELECT p.name                                             AS platform,
       COUNT(*)                                           AS collection_entries,
       SUM(ug.playtime_hours)                             AS total_hours,
       RANK() OVER (ORDER BY COUNT(*) DESC)               AS rank_by_entries,
       RANK() OVER (ORDER BY SUM(ug.playtime_hours) DESC) AS rank_by_hours
FROM v_user_game ug
JOIN Platform p ON p.platform_id = ug.platform_id
GROUP BY p.platform_id, p.name
ORDER BY rank_by_entries, rank_by_hours;

-- =====================================================================
-- Q20. Completion rate across genres
-- A multi-genre game counts once under each of its genres (intended).
-- Backlog entries stay in the denominator.
-- Expected: 12 rows; Platformer highest (80.0%), Racing/Sandbox/Strategy lowest (0.0%).
-- =====================================================================
SELECT gn.name                                                  AS genre,
       COUNT(*)                                                 AS collection_entries,
       SUM(ug.status = 'Completed')                             AS completed,
       ROUND(100 * SUM(ug.status = 'Completed') / COUNT(*), 1)  AS completion_rate_pct
FROM Genre gn
JOIN Game_Genre gg ON gg.genre_id = gn.genre_id
JOIN v_user_game ug  ON ug.game_id  = gg.game_id
GROUP BY gn.genre_id, gn.name
ORDER BY completion_rate_pct DESC, gn.name;

-- =====================================================================
-- Q21. Games that belong to more than one genre
-- Expected: 17 rows; six games have 3 genres (The Witcher 3, Cyberpunk 2077,
--           Zelda: BotW, Elden Ring, Red Dead Redemption 2, Hollow Knight), the rest 2.
-- =====================================================================
SELECT g.title,
       COUNT(gg.genre_id)                                          AS genre_count,
       GROUP_CONCAT(gn.name ORDER BY gn.name SEPARATOR ', ')       AS genres
FROM v_game g
JOIN Game_Genre gg ON gg.game_id = g.game_id
JOIN Genre gn      ON gn.genre_id = gg.genre_id
GROUP BY g.game_id, g.title
HAVING COUNT(gg.genre_id) > 1
ORDER BY genre_count DESC, g.title;

-- =====================================================================
-- Q22a. Games matching ALL selected genres (Action AND RPG)
-- Relational division: keep games that matched every selected genre.
-- Expected: 4 rows: Black Myth: Wukong, Cyberpunk 2077, Elden Ring, The Witcher 3: Wild Hunt.
-- =====================================================================
SELECT g.title
FROM v_game g
JOIN Game_Genre gg ON gg.game_id = g.game_id
JOIN Genre gn      ON gn.genre_id = gg.genre_id
WHERE gn.name IN (@genre_a, @genre_b)
GROUP BY g.game_id, g.title
HAVING COUNT(DISTINCT gn.genre_id) = 2
ORDER BY g.title;

-- Q22b. Games matching ANY selected genre (Action OR RPG)
-- Expected: 15 rows; matched_genres is 2 for the games from Q22a, 1 otherwise.
SELECT g.title,
       COUNT(DISTINCT gn.genre_id) AS matched_genres
FROM v_game g
JOIN Game_Genre gg ON gg.game_id = g.game_id
JOIN Genre gn      ON gn.genre_id = gg.genre_id
WHERE gn.name IN (@genre_a, @genre_b)
GROUP BY g.game_id, g.title
ORDER BY matched_genres DESC, g.title;

-- =====================================================================
-- Q23. Games available on multiple platforms
-- Expected: 18 rows; Minecraft lists 6 platforms. Zelda: BotW and Mario Kart 8 Deluxe
--           (Switch only) are not listed.
-- =====================================================================
SELECT g.title,
       COUNT(gp.platform_id)                                     AS platform_count,
       GROUP_CONCAT(p.name ORDER BY p.name SEPARATOR ', ')       AS platforms
FROM v_game g
JOIN Game_Platform gp ON gp.game_id = g.game_id
JOIN Platform p       ON p.platform_id = gp.platform_id
GROUP BY g.game_id, g.title
HAVING COUNT(gp.platform_id) > 1
ORDER BY platform_count DESC, g.title;

-- =====================================================================
-- Q24. Summary by game mode
-- Hours are pre-aggregated per game (derived table gt) before joining,
-- so adding v_user_game does not multiply the game counts.
-- Expected: 5 rows; Single-player 19 games, Online Multiplayer 7, Online Co-op 5,
--           Local Co-op 3, Local Multiplayer 2.
-- =====================================================================
SELECT gm.name                                              AS game_mode,
       COUNT(DISTINCT g.game_id)                            AS games,
       ROUND(COALESCE(SUM(gt.total_hours), 0), 1)           AS total_hours_played,
       GROUP_CONCAT(g.title ORDER BY g.title SEPARATOR '; ') AS titles
FROM Game_Mode gm
LEFT JOIN Game_Mode_Map gmm ON gmm.mode_id = gm.mode_id
LEFT JOIN v_game g            ON g.game_id   = gmm.game_id
LEFT JOIN (SELECT game_id, SUM(playtime_hours) AS total_hours
             FROM v_user_game GROUP BY game_id) gt ON gt.game_id = g.game_id
GROUP BY gm.mode_id, gm.name
ORDER BY games DESC, gm.name;

-- =====================================================================
-- BONUS Q25. Per-user dashboard (feeds the Streamlit analytics page)
-- Four independent aggregates, each pre-aggregated per user and joined once.
-- Expected: 7 rows; new_player_07 shows zeros / NULL rating.
-- =====================================================================
SELECT u.username,
       COALESCE(c.games_owned, 0)                                     AS games_owned,
       COALESCE(c.total_hours, 0)                                     AS total_playtime_hours,
       COALESCE(c.completed, 0)                                       AS completed_games,
       ROUND(100 * COALESCE(c.completed, 0) / NULLIF(c.games_owned, 0), 1) AS completion_pct,
       COALESCE(a.points_earned, 0)                                   AS achievement_points,
       r.avg_rating_given
FROM v_user u
LEFT JOIN (SELECT user_id,
                  COUNT(*)                     AS games_owned,
                  SUM(playtime_hours)          AS total_hours,
                  SUM(status = 'Completed')    AS completed
             FROM v_user_game GROUP BY user_id) c ON c.user_id = u.user_id
LEFT JOIN (SELECT ug.user_id,
                  SUM(ac.points)               AS points_earned
             FROM User_Achievement ua
             JOIN v_user_game ug   ON ug.user_game_id  = ua.user_game_id
             JOIN Achievement ac ON ac.achievement_id = ua.achievement_id
            WHERE ua.is_unlocked = 1
            GROUP BY ug.user_id) a ON a.user_id = u.user_id
LEFT JOIN (SELECT user_id, ROUND(AVG(rating), 2) AS avg_rating_given
             FROM v_rating GROUP BY user_id) r ON r.user_id = u.user_id
ORDER BY achievement_points DESC, u.username;

-- =====================================================================
-- BONUS Q26. Catalogue view for the Streamlit filter page
-- One row per game with genres, platforms, modes and rating average, built
-- from independent pre-aggregated subqueries (no join multiplication).
-- Expected: 20 rows.
-- =====================================================================
SELECT g.title,
       ar.age_ratings,
       gen.genres,
       plat.platforms,
       mode.modes,
       rt.avg_rating
FROM v_game g
LEFT JOIN (SELECT gar.game_id,
                  GROUP_CONCAT(CONCAT(a.rating_authority, ' ', a.label)
                               ORDER BY a.rating_authority SEPARATOR ', ') AS age_ratings
             FROM Game_Age_Rating gar JOIN Age_Rating a ON a.age_rating_id = gar.age_rating_id
            GROUP BY gar.game_id) ar ON ar.game_id = g.game_id
LEFT JOIN (SELECT gg.game_id, GROUP_CONCAT(gn.name ORDER BY gn.name SEPARATOR ', ') AS genres
             FROM Game_Genre gg JOIN Genre gn ON gn.genre_id = gg.genre_id
            GROUP BY gg.game_id) gen ON gen.game_id = g.game_id
LEFT JOIN (SELECT gp.game_id, GROUP_CONCAT(p.name ORDER BY p.name SEPARATOR ', ') AS platforms
             FROM Game_Platform gp JOIN Platform p ON p.platform_id = gp.platform_id
            GROUP BY gp.game_id) plat ON plat.game_id = g.game_id
LEFT JOIN (SELECT gmm.game_id, GROUP_CONCAT(gm.name ORDER BY gm.name SEPARATOR ', ') AS modes
             FROM Game_Mode_Map gmm JOIN Game_Mode gm ON gm.mode_id = gmm.mode_id
            GROUP BY gmm.game_id) mode ON mode.game_id = g.game_id
LEFT JOIN (SELECT game_id, ROUND(AVG(rating), 2) AS avg_rating
             FROM v_rating GROUP BY game_id) rt ON rt.game_id = g.game_id
ORDER BY g.title;
