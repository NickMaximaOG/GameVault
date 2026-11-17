#!/usr/bin/env python3
"""Database test suite for GameVault v2.

    python3 database/tests/run_db_tests.py

Needs a MySQL 8.0 server and the `mysql` client. Connection comes from the
MYSQL_CLI environment variable, default "mysql -uroot" (examples:
MYSQL_CLI="mysql -h127.0.0.1 -uroot -psecret").

It DROPS and recreates gamevault_db, then runs:
  1. schema.sql loads without errors
  2. validation.sql          every check must be PASS
  3. negative_tests.sql      every block must fail with its expected error code
  4. queries.sql             every query must run and return rows
  5. stored-procedure and trigger scenarios (below)
Exit code 0 = all passed.
"""
import os
import re
import shlex
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DB = os.path.dirname(HERE)
CLI = shlex.split(os.environ.get("MYSQL_CLI", "mysql -uroot"))
passed, failed = 0, []


def run(sql, db=True, table=False):
    cmd = CLI + ["--default-character-set=utf8mb4", "-B", "-N"] + (["gamevault_db"] if db else [])
    r = subprocess.run(cmd + ["-e", sql], capture_output=True, text=True)
    return r.returncode, r.stdout.strip(), r.stderr.strip()


def run_file(path, db=True):
    cmd = CLI + ["--default-character-set=utf8mb4", "-B"] + (["gamevault_db"] if db else [])
    with open(path, encoding="utf-8") as f:
        r = subprocess.run(cmd, stdin=f, capture_output=True, text=True)
    return r.returncode, r.stdout, r.stderr.strip()


def check(name, ok, detail=""):
    global passed
    if ok:
        passed += 1
    else:
        failed.append(name)
        print(f"  FAIL  {name}  {detail}")


def val(sql):
    rc, out, err = run(sql)
    assert rc == 0, (sql, err)
    return out


def expect_error(name, sql, needle):
    rc, out, err = run(sql)
    check(name, rc != 0 and needle in err, f"expected '{needle}', got rc={rc} err={err[:160]!r}")


# ------------------------------------------------------------ 1. load schema
print("1. loading schema.sql")
run("DROP DATABASE IF EXISTS gamevault_db", db=False)
rc, _, err = run_file(os.path.join(DB, "schema.sql"), db=False)
check("schema.sql loads without errors", rc == 0, err[:300])
if rc != 0:
    sys.exit(1)
check("seed load wrote no audit rows", val("SELECT COUNT(*) FROM Audit_Log") == "0")

# ------------------------------------------------------------ 2. validation
print("2. validation.sql")
rc, out, err = run_file(os.path.join(DB, "validation.sql"))
check("validation.sql runs", rc == 0, err[:300])
n_pass = len(re.findall(r"\tPASS$", out, re.M))
n_fail = re.findall(r"^.*\tFAIL$", out, re.M)
check("validation: no FAIL rows", not n_fail, str(n_fail[:3]))
check("validation: at least 70 PASS rows", n_pass >= 70, f"only {n_pass}")

# ------------------------------------------------------------ 3. negative tests
print("3. negative_tests.sql")
src = open(os.path.join(DB, "negative_tests.sql"), encoding="utf-8").read()
blocks = re.findall(r"(-- N\d+\..*?START TRANSACTION;.*?ROLLBACK;)", src, flags=re.S)
check("30 negative blocks found", len(blocks) == 30, f"found {len(blocks)}")
for blk in blocks:
    label = re.match(r"-- (N\d+)\.", blk).group(1)
    code = re.search(r"Expected: ERROR (\d+)", blk).group(1)
    stmts = "\n".join(l for l in blk.splitlines() if not l.startswith("--"))
    rc, out, err = run("SET SQL_SAFE_UPDATES=1;\n" + stmts)
    check(f"{label} rejected with {code}", rc != 0 and f"ERROR {code}" in err, err[:140])

# ------------------------------------------------------------ 4. queries.sql
print("4. queries.sql")
qsrc = open(os.path.join(DB, "queries.sql"), encoding="utf-8").read()
setup = qsrc[:qsrc.index("-- ====", qsrc.index("SET @genre_b"))]
chunks = re.split(r"(?m)^(?=-- =+\n-- (?:BONUS )?Q\d+|-- Q\d+[ab]\.)", qsrc[len(setup):])
nq = 0
for ch in chunks:
    m = re.search(r"(?:BONUS )?(Q\d+[ab]?)\.", ch)
    if not m:
        continue
    body = "\n".join(l for l in ch.splitlines() if not l.startswith("--"))
    rc, out, err = run(setup + "\n" + body)
    nq += 1
    check(f"{m.group(1)} runs and returns rows", rc == 0 and out != "", err[:140])
check("26+ query statements exercised", nq >= 26, f"{nq}")

# ------------------------------------------------------------ 5. procedures
print("5. stored procedures and triggers")
NEW_USER, ADMIN = 7, 1


def call(stmt):
    return run(stmt)


# add to collection
rc, out, err = call("CALL sp_add_to_collection(7, 3, 2, '2026-10-01', 59.99, 2, @id); SELECT @id;")
check("P1 add Elden Ring (PS5) to user 7", rc == 0 and out.isdigit(), err)
ugid = val("SELECT user_game_id FROM User_Game WHERE user_id = 7 AND game_id = 3")
check("P1 entry is Playing with started_at today",
      val(f"SELECT status FROM v_user_game WHERE user_game_id = {ugid}") == "Playing")
check("P1 audit row written with changed_by = 7",
      val(f"SELECT COUNT(*) FROM Audit_Log WHERE table_name = 'User_Game' AND record_pk = '{ugid}' "
          f"AND action = 'INSERT' AND changed_by = 7") == "1")
expect_error("P2 unsupported platform rejected", "CALL sp_add_to_collection(7, 15, 2, NULL, 0, 1, @id)",
             "VALIDATION: this game is not available on that platform")
expect_error("P3 duplicate entry rejected", "CALL sp_add_to_collection(7, 3, 2, NULL, 0, 1, @id)",
             "CONFLICT: this game is already in your collection")
expect_error("P3b negative price rejected", "CALL sp_add_to_collection(7, 1, 2, NULL, -5, 1, @id)",
             "VALIDATION: price cannot be negative")
expect_error("P3c future purchase date rejected",
             "CALL sp_add_to_collection(7, 1, 2, '2999-01-01', 5, 1, @id)", "VALIDATION: purchase date")
expect_error("P3d unknown game rejected", "CALL sp_add_to_collection(7, 999, 2, NULL, 0, 1, @id)",
             "NOT_FOUND: game")

# playtime
rc, out, err = call(f"CALL sp_log_playtime(7, {ugid}, '2026-10-20 18:00:00', 90, 'test', @s); SELECT @s;")
check("P4 log 90 minutes", rc == 0, err)
check("P4 playtime view = 1.5 h", val(f"SELECT playtime_hours FROM v_user_game WHERE user_game_id = {ugid}") == "1.5")
expect_error("P4b zero minutes rejected", f"CALL sp_log_playtime(7, {ugid}, '2026-10-20 18:00:00', 0, NULL, @s)",
             "VALIDATION: minutes")
expect_error("P4c future session rejected", f"CALL sp_log_playtime(7, {ugid}, '2999-01-01 18:00:00', 30, NULL, @s)",
             "VALIDATION: session start")
expect_error("P4d another user's entry hidden", f"CALL sp_log_playtime(2, {ugid}, '2026-10-20 18:00:00', 30, NULL, @s)",
             "NOT_FOUND: collection entry")
call("CALL sp_add_to_collection(7, 6, 6, NULL, 0, 1, @b)")      # Minecraft on Switch, Backlog
bl = val("SELECT user_game_id FROM User_Game WHERE user_id = 7 AND game_id = 6")
call(f"CALL sp_log_playtime(7, {bl}, '2026-10-21 10:00:00', 30, NULL, @s)")
check("P4e first session moves Backlog -> Playing",
      val(f"SELECT status FROM v_user_game WHERE user_game_id = {bl}") == "Playing")

# optimistic locking on the entry
ver = val(f"SELECT row_version FROM v_user_game WHERE user_game_id = {ugid}")
rc, out, err = call(f"CALL sp_update_collection_entry(7, {ugid}, 3, {ver})")
check("P5 mark Completed with the current version", rc == 0, err)
check("P5 completed_at set and version bumped",
      val(f"SELECT CONCAT(completed_at IS NOT NULL, ',', row_version) FROM User_Game WHERE user_game_id = {ugid}")
      == f"1,{int(ver) + 1}")
expect_error("P5b stale version rejected", f"CALL sp_update_collection_entry(7, {ugid}, 4, {ver})",
             "CONFLICT: entry changed since you loaded it")
rc, out, err = call(f"CALL sp_update_collection_entry(7, {ugid}, 2, NULL)")
check("P5c status back to Playing clears completed_at",
      rc == 0 and val(f"SELECT IFNULL(completed_at,'none') FROM User_Game WHERE user_game_id = {ugid}") == "none", err)
expect_error("P5d another user cannot edit it", f"CALL sp_update_collection_entry(2, {ugid}, 3, NULL)",
             "NOT_FOUND: collection entry")

# ratings
rc, out, err = call("CALL sp_upsert_rating(7, 3, 8, 'Great', NULL, @r); SELECT @r;")
check("P6 create rating", rc == 0 and out.isdigit(), err)
rid = out
rc, out, err = call("CALL sp_upsert_rating(7, 3, 9, 'Even better', 1, @r)")
check("P6b update with current version", rc == 0, err)
expect_error("P6c stale rating version rejected", "CALL sp_upsert_rating(7, 3, 5, 'x', 1, @r)",
             "CONFLICT: rating changed since you loaded it")
expect_error("P6d rating 11 rejected", "CALL sp_upsert_rating(7, 3, 11, 'x', NULL, @r)", "VALIDATION: rating")
check("P6e catalogue average reflects the new rating (10, 5, 9 and ours 9 -> 8.25)",
      float(val("SELECT avg_rating FROM v_game_catalog WHERE game_id = 3")) == 8.25)
check("P6f Elden Ring rating_count is 4", val("SELECT rating_count FROM v_game_catalog WHERE game_id = 3") == "4")
call("CALL sp_delete_rating(7, 3)")
check("P6g deleted rating hidden", val("SELECT COUNT(*) FROM v_rating WHERE user_id = 7 AND game_id = 3") == "0")
check("P6h deleted rating kept in table", val("SELECT COUNT(*) FROM Rating WHERE user_id = 7 AND game_id = 3") == "1")
expect_error("P6i deleting twice -> not found", "CALL sp_delete_rating(7, 3)", "NOT_FOUND: rating")
call("CALL sp_upsert_rating(7, 3, 7, 'Back again', NULL, @r)")
check("P6j re-rating re-activates the same row", val(f"SELECT COUNT(*) FROM v_rating WHERE rating_id = {rid}") == "1")

# achievements
ach = val("SELECT achievement_id FROM Achievement WHERE name = 'Lands Between Explorer'")
foreign = val("SELECT achievement_id FROM Achievement WHERE name = 'Taking Inventory'")
call(f"CALL sp_set_achievement_progress(7, {ugid}, {ach}, 50)")
check("P7 partial progress stays locked",
      val(f"SELECT CONCAT(progress, ',', is_unlocked, ',', unlocked_at IS NULL) FROM User_Achievement "
          f"WHERE user_game_id = {ugid} AND achievement_id = {ach}") == "50.00,0,1")
call(f"CALL sp_set_achievement_progress(7, {ugid}, {ach}, 100)")
check("P7b 100% unlocks with timestamp",
      val(f"SELECT CONCAT(progress, ',', is_unlocked, ',', unlocked_at IS NOT NULL) FROM User_Achievement "
          f"WHERE user_game_id = {ugid} AND achievement_id = {ach}") == "100.00,1,1")
call(f"CALL sp_set_achievement_progress(7, {ugid}, {ach}, 30)")
check("P7c lowering progress re-locks",
      val(f"SELECT CONCAT(is_unlocked, ',', unlocked_at IS NULL) FROM User_Achievement "
          f"WHERE user_game_id = {ugid} AND achievement_id = {ach}") == "0,1")
expect_error("P7d achievement of another game rejected",
             f"CALL sp_set_achievement_progress(7, {ugid}, {foreign}, 10)", "VALIDATION: achievement belongs to a different game")
expect_error("P7e progress 101 rejected", f"CALL sp_set_achievement_progress(7, {ugid}, {ach}, 101)",
             "VALIDATION: progress")
check("P7f progress view lists every achievement of the game",
      val(f"SELECT COUNT(*) FROM v_achievement_progress WHERE user_game_id = {ugid}") == "5")
check("P7g hidden achievement is masked while locked",
      val(f"SELECT COUNT(*) FROM v_achievement_progress WHERE user_game_id = {ugid} "
          f"AND name = 'Hidden achievement' AND description IS NULL") == "1")

# remove + re-add keeps progress
call(f"CALL sp_remove_from_collection(7, {ugid})")
check("P8 removed entry hidden from view", val(f"SELECT COUNT(*) FROM v_user_game WHERE user_game_id = {ugid}") == "0")
check("P8b soft-deleted row and progress still stored",
      val(f"SELECT COUNT(*) FROM User_Game ug JOIN User_Achievement ua USING (user_game_id) "
          f"WHERE ug.user_game_id = {ugid} AND ug.deleted_at IS NOT NULL") == "1")
expect_error("P8c removing twice -> not found", f"CALL sp_remove_from_collection(7, {ugid})", "NOT_FOUND")
rc, out, err = call("CALL sp_add_to_collection(7, 3, 2, NULL, 0, 2, @id); SELECT @id;")
check("P8d re-adding re-activates the SAME entry id", rc == 0 and out == ugid, f"{out} vs {ugid}")

# triggers
check("T1 no-op update is not audited",
      (call("UPDATE User SET last_login_at = UTC_TIMESTAMP() WHERE user_id = 2") and
       val("SELECT COUNT(*) FROM Audit_Log WHERE table_name = 'User' AND record_pk = '2'")) == "0")
before = val("SELECT row_version FROM Rating WHERE rating_id = 1")
call("UPDATE Rating SET rating = 8 WHERE rating_id = 1")
check("T2 direct UPDATE also bumps row_version", int(val("SELECT row_version FROM Rating WHERE rating_id = 1")) == int(before) + 1)
check("T3 audit row has old and new values",
      val("SELECT JSON_EXTRACT(old_values,'$.rating') <> JSON_EXTRACT(new_values,'$.rating') FROM Audit_Log "
          "WHERE table_name = 'Rating' AND record_pk = '1' AND action = 'UPDATE' LIMIT 1") == "1")
check("T4 audit JSON never contains password data",
      val("SELECT COUNT(*) FROM Audit_Log WHERE CAST(COALESCE(old_values,'') AS CHAR) LIKE '%password%'") == "0")

# admin operations
expect_error("A1 non-admin cannot deactivate", "CALL sp_deactivate_user(2, 7)", "FORBIDDEN")
expect_error("A1b admin cannot deactivate self", "CALL sp_deactivate_user(1, 1)", "VALIDATION: you cannot deactivate your own account")
expect_error("A1c unknown target", "CALL sp_deactivate_user(1, 999)", "NOT_FOUND: user")
call("INSERT INTO Auth_Session (user_id, token_hash, expires_at) VALUES (7, REPEAT('b', 64), UTC_TIMESTAMP() + INTERVAL 1 HOUR)")
rc, out, err = call("CALL sp_deactivate_user(1, 7)")
check("A2 admin deactivates user 7", rc == 0, err)
check("A2b user hidden from v_user", val("SELECT COUNT(*) FROM v_user WHERE user_id = 7") == "0")
check("A2c their entries and ratings hidden",
      val("SELECT COUNT(*) FROM v_user_game WHERE user_id = 7") == "0"
      and val("SELECT COUNT(*) FROM v_rating WHERE user_id = 7") == "0")
check("A2d their sessions revoked",
      val("SELECT COUNT(*) FROM Auth_Session WHERE user_id = 7 AND revoked_at IS NULL") == "0")
check("A2e dashboard no longer lists them", val("SELECT COUNT(*) FROM v_user_dashboard WHERE user_id = 7") == "0")
expect_error("A3 non-admin cannot purge", "CALL sp_purge_user(2, 7)", "FORBIDDEN")
rc, out, err = call("CALL sp_purge_user(1, 7)")
check("A4 admin purges user 7", rc == 0, err)
check("A4b user row and children gone",
      val("SELECT (SELECT COUNT(*) FROM User WHERE user_id = 7) + (SELECT COUNT(*) FROM User_Game WHERE user_id = 7)"
          " + (SELECT COUNT(*) FROM Rating WHERE user_id = 7)") == "0")
check("A4c audit rows for the user are scrubbed of personal data",
      val("SELECT COUNT(*) FROM Audit_Log WHERE CAST(COALESCE(old_values,'') AS CHAR) LIKE '%new.player07%' "
          "OR CAST(COALESCE(new_values,'') AS CHAR) LIKE '%new.player07%'") == "0")
check("A4d the erasure itself stays on record",
      int(val("SELECT COUNT(*) FROM Audit_Log WHERE table_name = 'User' AND record_pk = '7' AND action = 'DELETE'")) == 1)
expect_error("A4e audit log is still append-only afterwards", "DELETE FROM Audit_Log LIMIT 1", "append-only")

# metadata
check("M1 maintenance event exists",
      val("SELECT COUNT(*) FROM information_schema.events WHERE event_schema = 'gamevault_db'") == "1")
check("M2 9 stored procedures",
      val("SELECT COUNT(*) FROM information_schema.routines WHERE routine_schema = 'gamevault_db' AND routine_type = 'PROCEDURE'") == "9")
check("M3 every table uses InnoDB",
      val("SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'gamevault_db' "
          "AND table_type = 'BASE TABLE' AND engine <> 'InnoDB'") == "0")

# ------------------------------------------------------------ 6. privileges
print("6. security.sql (least privilege)")
rc, _, err = run_file(os.path.join(DB, "security.sql"), db=False)
check("security.sql runs", rc == 0, err[:300])
APP = CLI[:1] + [a for a in CLI[1:] if not a.startswith(("-u", "-p"))] + \
      ["-ugv_app", "-pchange-me-app-Passw0rd", "--default-character-set=utf8mb4", "-B", "-N", "gamevault_db"]
REP = APP[:-1][:-0 or None]
REP = [a if not a.startswith(("-ugv_app", "-pchange-me-app")) else
       ("-ugv_report" if a.startswith("-ugv_app") else "-pchange-me-report-Passw0rd") for a in APP]


def as_user(cmd, sql):
    r = subprocess.run(cmd + ["-e", sql], capture_output=True, text=True)
    return r.returncode, r.stdout.strip(), r.stderr.strip()


rc, out, err = as_user(APP, "SELECT COUNT(*) FROM v_game_catalog")
check("S1 gv_app reads views", rc == 0 and out == "20", err[:150])
for tbl in ("User_Game", "Rating", "User_Achievement"):
    rc, out, err = as_user(APP, f"SELECT * FROM {tbl} LIMIT 1")
    check(f"S2 gv_app cannot read {tbl} directly", rc != 0 and "denied" in err, err[:120])
rc, out, err = as_user(APP, "DELETE FROM Rating")
check("S3 gv_app cannot delete from Rating", rc != 0 and "denied" in err, err[:120])
rc, out, err = as_user(APP, "DROP TABLE Genre")
check("S4 gv_app cannot run DDL", rc != 0 and "denied" in err, err[:120])
rc, out, err = as_user(APP, "SELECT email FROM User WHERE user_id = 2")
check("S5 gv_app can read login columns of User", rc == 0 and "@" in out, err[:120])
rc, out, err = as_user(APP, "SELECT join_date FROM User WHERE user_id = 2")
check("S6 gv_app cannot read other User columns", rc != 0 and "denied" in err, err[:120])
rc, out, err = as_user(APP, "UPDATE User SET email = 'x@y.zz' WHERE user_id = 2")
check("S7 gv_app cannot change e-mail directly", rc != 0 and "denied" in err, err[:120])
rc, out, err = as_user(APP, "CALL sp_upsert_rating(2, 12, 9, 'via procedure', NULL, @r); SELECT @r")
check("S8 gv_app writes through a stored procedure", rc == 0 and out.isdigit(), err[:150])
rc, out, err = as_user(APP, "INSERT INTO User (username, email, password_hash) VALUES ('s9user', 's9@example.com', 'pbkdf2-sha256$1$AA==$AA==')")
check("S9 gv_app can register a user (column grant)", rc == 0, err[:150])
rc, out, err = as_user(APP, "UPDATE User SET role_id = 2 WHERE username = 's9user'")
check("S10 gv_app cannot grant itself ADMIN", rc != 0 and "denied" in err, err[:120])
check("S11 trigger wrote the audit row with the caller id",
      val("SELECT COUNT(*) FROM Audit_Log WHERE table_name = 'Rating' AND changed_by = 2 AND action = 'INSERT'") == "1")
rc, out, err = as_user(REP, "SELECT COUNT(*) FROM v_user_dashboard")
check("S12 gv_report reads analytics views", rc == 0 and out != "", err[:150])
rc, out, err = as_user(REP, "SELECT * FROM v_user_game LIMIT 1")
check("S13 gv_report cannot read other views", rc != 0 and "denied" in err, err[:120])
rc, out, err = as_user(REP, "CALL sp_delete_rating(2, 12)")
check("S14 gv_report cannot execute procedures", rc != 0 and "denied" in err, err[:120])

print()
print(f"{passed} checks passed, {len(failed)} failed")
if failed:
    print("FAILED:", ", ".join(failed))
    sys.exit(1)
