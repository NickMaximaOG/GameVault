---
title: "GameVault v2: Normalization Report"
---

# GameVault v2: Normalization Report

Database `gamevault_db`, MySQL 8.0. 21 base tables. Column lists below match the live schema.

## 1. Method

For each table I list its candidate keys and functional dependencies (FDs), then check:

- **1NF**: every column holds one atomic value, there are no repeating groups, and each table has a primary key.
- **2NF**: 1NF, and no non-key column depends on only part of a composite key.
- **3NF**: 2NF, and every non-key column depends on the key, the whole key, and nothing but the key. Formally, for each FD X → A, either X is a superkey or A is part of some candidate key.

Two places depart from the strict textbook form on purpose. They are explained in section 5, and the database enforces both.

## 2. First normal form

| Concern in a game catalogue | How v2 stores it |
|---|---|
| A game has several genres, platforms, modes and age ratings | Junction tables `Game_Genre`, `Game_Platform`, `Game_Mode_Map`, `Game_Age_Rating`; no comma-separated lists in any column |
| A user owns a game on a platform | One `User_Game` row per (user, game, platform); no repeating columns such as `game1`, `game2` |
| Play history | One `Playtime_Session` row per session, not a running total |
| Audit values | `Audit_Log.old_values/new_values` are JSON documents. They are a log payload that the application never queries by field, so they are treated as opaque atomic values and are not part of the business model |

Every table has a primary key (single surrogate key, or a composite key for the junction tables).
Views such as `v_game_catalog` use `GROUP_CONCAT` for display only; nothing is stored that way.

## 3. Functional dependencies and second normal form

| Table | Primary key | Other candidate keys | Main FDs |
|---|---|---|---|
| Role | role_id | name | role_id → name, description |
| Collection_Status | status_id | name | status_id → name, sort_order |
| User | user_id | username, email | user_id → all other columns |
| Developer, Publisher | developer_id / publisher_id | name | id → name, country, website |
| Genre, Platform, Game_Mode | id | name | id → name and descriptive columns |
| Age_Rating | age_rating_id | (rating_authority, label), (age_rating_id, rating_authority) | age_rating_id → label, rating_authority, description, minimum_age |
| Game | game_id | (title, release_date) | game_id → title, release_date, description, cover_image, developer_id, publisher_id |
| Game_Genre | (game_id, genre_id) | | none beyond the key (all-key table) |
| Game_Mode_Map | (game_id, mode_id) | | none beyond the key |
| Game_Platform | (game_id, platform_id) | | (game_id, platform_id) → platform_release_date |
| Game_Age_Rating | (game_id, rating_authority) | (game_id, age_rating_id), by FD closure (not declared) | age_rating_id → rating_authority |
| User_Game | user_game_id | (user_id, game_id, platform_id) | user_game_id → purchase_date, purchase_price, baseline_hours, status_id, started_at, completed_at |
| Playtime_Session | session_id | | session_id → user_game_id, started_at, duration_minutes, note |
| Rating | rating_id | (user_id, game_id) | rating_id → rating, review_text, review_date |
| Achievement | achievement_id | (game_id, name) | achievement_id → game_id, name, description, points, is_hidden |
| User_Achievement | (user_game_id, achievement_id) | | key → unlocked_at, progress, is_unlocked; user_game_id → game_id; achievement_id → game_id |
| Auth_Session | session_id | token_hash | session_id → user_id, expires_at, revoked_at, ip_address, user_agent |
| Audit_Log | audit_id | | audit_id → all columns |

**2NF.** Every table with a single-column key is automatically in 2NF. The tables with composite keys are:

- `Game_Genre`, `Game_Mode_Map`: no non-key columns, so no partial dependency is possible.
- `Game_Platform`: `platform_release_date` depends on the whole pair (a game can launch on different platforms on different dates), not on `game_id` or `platform_id` alone. 2NF holds.
- `Game_Age_Rating`: the only non-key column is `age_rating_id`, which depends on the whole key. 2NF holds.
- `User_Achievement`: `unlocked_at`, `progress` and `is_unlocked` depend on both parts. The column `game_id` depends on only part of the key, which is the deliberate exception in section 5.

## 4. Third normal form, table by table

- **Lookup data** that would otherwise repeat is split out: roles and statuses (`Role`, `Collection_Status`), genres, platforms, modes, developers, publishers, age ratings. In v1, some of these were free text or ENUM columns, which repeats values and invites typos.
- **`User`**: contains no data about roles other than `role_id`. Role name and description live in `Role`. 3NF holds.
- **`Game`**: developer and publisher attributes (country, website) live in `Developer` and `Publisher`, not in `Game`.
- **`User_Game`**: `status_id` points to `Collection_Status`. There is **no stored total playtime**: the total (`baseline_hours` plus the sum of session minutes) is computed in view `v_user_game`. Storing the total would create a derived, editable column that could disagree with the sessions.
- **`Age_Rating`**: within one authority, `label` determines `minimum_age`. The candidate key (rating_authority, label) is a superkey, so this is not a violation.
- **`Game_Age_Rating`**: the FD `age_rating_id → rating_authority` has a non-superkey determinant. Because `rating_authority` is part of the candidate key (game_id, rating_authority), 3NF still holds (the exception clause: the dependent is a prime attribute). The table is therefore in 3NF but not in BCNF. This is intended: the composite key (game_id, rating_authority) is what lets the database allow **one rating per authority per game**, and the composite foreign key to `Age_Rating (age_rating_id, rating_authority)` stops the two columns from ever disagreeing.
- **`Rating`**: a user's rating of a game; `(user_id, game_id)` is unique. No attribute of the user or the game is copied in.
- **`Auth_Session`, `Audit_Log`**: each row is one event; every column depends on the event key only. `Audit_Log.record_pk` is a text key reference to any table and is intentionally not a foreign key, so audit rows survive when the record is erased.

Result: **all tables are in 3NF; all but `Game_Age_Rating` are also in BCNF, and `User_Achievement` has one documented 2NF exception.**

## 5. Deliberate exceptions

| Exception | Why | How it is made safe |
|---|---|---|
| `User_Achievement.game_id` repeats a value that is already implied by `user_game_id` and by `achievement_id` | Without it, a row could link a user's copy of game A to an achievement of game B, and a plain foreign key cannot detect that | Two composite foreign keys, `(user_game_id, game_id)` → `User_Game` and `(achievement_id, game_id)` → `Achievement`, force the copy to match both parents. The database rejects any mismatch (see database/negative_tests.sql) |
| `Game_Age_Rating.rating_authority` repeats `Age_Rating.rating_authority` | Lets the primary key express "one rating per authority" | Composite foreign key to `Age_Rating (age_rating_id, rating_authority)` |

Both are redundancy that the database itself guards, so no update anomaly can occur.

## 6. Anomaly check

| Anomaly | Example in a poorly normalised design | Why v2 avoids it |
|---|---|---|
| Update | Developer's country stored on every game | Stored once in `Developer` |
| Insert | Cannot add a genre until a game uses it | `Genre` is its own table |
| Delete | Removing a user's last game deletes the user's details | `User` is separate; soft delete keeps history either way |
| Derived-value drift | Total hours typed in and disagreeing with sessions | Total is computed from sessions |

## 7. Evidence

`database/validation.sql` has 80 checks that all report PASS, including orphan checks, the invariants
above, and derived-value checks. `database/negative_tests.sql` has 30 statements that must fail, such as an achievement from the wrong game,
a platform the game does not support, and a second age rating from the same authority.
