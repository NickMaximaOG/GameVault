# Changes from v1 to v2

v1 was a correct but simple 15-table schema. v2 keeps its tested core and adds what a production system needs.

| Area | v1 | v2 |
|---|---|---|
| Deleting data | Hard `DELETE` | Soft delete (`deleted_at`) on User, Game, User_Game, Rating; foreign keys are `RESTRICT` |
| History | none | `created_at`/`updated_at` everywhere; append-only `Audit_Log` filled by 22 triggers (who, when, old and new values as JSON) |
| Age ratings | one `Game.age_rating_id` | `Game_Age_Rating`: one rating per authority per game (ESRB and PEGI together), composite FK keeps authority consistent |
| Fixed lists | text/ENUM columns | lookup tables `Role` and `Collection_Status` |
| Playtime | one typed-in number | `Playtime_Session` rows; total = `baseline_hours` + sessions (view `v_user_game`) |
| Concurrent edits | last write wins | `row_version` on User_Game and Rating; stale updates raise CONFLICT (HTTP 409) |
| Reading data | direct table access | views: `v_collection`, `v_game_catalog`, `v_user_dashboard`, `v_achievement_progress` (hides secret achievements) |
| Writing data | direct `INSERT/UPDATE` | stored procedures with a `VALIDATION/NOT_FOUND/CONFLICT/FORBIDDEN` error protocol |
| Accounts | none | `gv_app` (procedures + views only) and `gv_report` (read-only); column-level grants |
| Login | none | `Auth_Session` with hashed tokens, expiry, lockout columns; DB event purges expired sessions |
| Privacy | none | `sp_deactivate_user`, `sp_purge_user` (erases the user and scrubs audit PII) |
| App | Streamlit sketch | Java REST API + Node.js web app |
| Tests | validation SQL | 144 database checks, 38 backend tests, 12 frontend tests, browser walkthrough |

Playtime totals in the sample data reproduce the v1 numbers exactly. Timestamps are now stored in UTC, so times shown
differ from v1 by the time-zone offset. v1 files are kept in `database/archive-v1/`.
