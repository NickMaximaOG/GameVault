#!/usr/bin/env bash
# Runs every automated test: database suite, then backend unit + integration tests.
# Needs: MySQL 8 running, `mysql` client, Java 21 and the Maven-free libraries (backend/build.sh header).
# The database suite DROPS and recreates gamevault_db.   MYSQL_CLI="mysql -uroot" by default.
set -euo pipefail
cd "$(dirname "$0")"
echo "=== database tests ==="
python3 -I database/tests/run_db_tests.py
echo "=== backend tests ==="
export DB_PASSWORD="${DB_PASSWORD:-change-me-app-Passw0rd}"
backend/build.sh test
echo "=== frontend tests ==="
(cd frontend && npm test --silent)
