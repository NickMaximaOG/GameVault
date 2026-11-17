# GameVault: Game Collection and Achievement Tracker (v2)

Track the games you own, the time you spend in them, ratings, and achievements.

| Layer | Technology | Folder |
|---|---|---|
| Frontend | Node.js 22 (Express as a backend-for-frontend) + a plain JavaScript single-page app | `frontend/` |
| Backend | Java 21 REST API (JDK HTTP server on virtual threads, HikariCP, Jackson) | `backend/` |
| Database | MySQL 8.0 (`gamevault_db`) with views, stored procedures, triggers | `database/` |

```
Browser  --HTTPS-->  Node (static app + /api proxy, HttpOnly cookie)  -->  Java API (/api/v1, Bearer token)  -->  MySQL
```

The browser never sees the login token. Node keeps it in an `HttpOnly; SameSite=Strict` cookie and adds it as a
`Bearer` header when it forwards `/api/*` calls to Java. The Java API enforces every rule again; it does not trust Node.

## Quick start with Docker

```bash
cp .env.example .env          # then change the passwords
docker compose --env-file .env up --build
# open http://localhost:3000
```

Sign in with a demo account, for example `aarav_k` (administrator) or `meera_s`, password `ChangeMe!2026`.
All demo accounts share that password. Change it before any real use.

## Run the pieces by hand

1. **Database.** In MySQL 8.0 run `database/schema.sql`, then `database/security.sql`
   (see `docs/workbench_guide.md` for MySQL Workbench steps).
2. **API.** `cd backend && mvn package && DB_PASSWORD=change-me-app-Passw0rd java -jar target/gamevault-api-2.0.0.jar`
3. **Web.** `cd frontend && npm install && BACKEND_URL=http://localhost:8080 npm start`, then open http://localhost:3000.

On a machine without Maven access, `backend/build.sh` and `backend/run.sh` build and run the API from apt-installed
jars (see the header of `build.sh`). That is how the code was tested here. `backend/pom.xml` is the normal route but
was **not executed** in the sandbox that wrote it (Maven Central was unreachable there).

## Tests

`./test-all.sh` runs everything, against a local MySQL (it drops and recreates `gamevault_db`):

| Suite | What it covers |
|---|---|
| `database/tests/run_db_tests.py` | schema load, 80 validation checks, 30 negative tests (bad data must be rejected), 26 queries, procedures, triggers, privileges |
| `backend` JUnit 5 | password hashing, input validation, 38 tests including the full API against the real database |
| `frontend` `node --test` | cookie and CSRF handling, proxy, security headers, CSP-safe pages |
| `frontend/e2e/ui-walkthrough.cjs` | optional browser walkthrough with Playwright (sign in, change status, log time, achievements, admin) |

## Documentation

- `docs/er_diagram.mmd` - ER diagram (Mermaid), generated from the live schema by `database/tools/gen_er.py`
- `docs/normalization_report.md` (+ `.pdf`) - 1NF, 2NF, 3NF analysis
- `docs/api.md` - REST API reference
- `docs/workbench_guide.md` - run and explore the database in MySQL Workbench
- `docs/CHANGES_v1_to_v2.md` - what changed from the first version and why
- `database/queries.sql` - 26 example queries; `database/validation.sql` - data checks

## Security notes

Passwords: PBKDF2-HMAC-SHA256, 600,000 iterations, upgraded on login. Sessions: random tokens stored only as SHA-256 hashes,
expiring. Lockout after repeated failures; per-IP rate limit; strict CSP; CSRF protection; least-privilege database
accounts (`gv_app` can only call procedures and read views). Deactivation hides a user; `sp_purge_user` erases one for good
(GDPR) including personal data in the audit log.

## Known limits

- Cover image URLs in the sample data are placeholders; the UI falls back to a generated cover.
- Age-rating classes (ESRB/PEGI) and achievement names in the sample data are illustrative, not verified against publishers.
- There is no email verification or password reset yet; both need an outgoing mail service.
