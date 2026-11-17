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

