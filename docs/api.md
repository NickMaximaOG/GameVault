# GameVault REST API (v1)

Base path `/api/v1`. JSON in, JSON out. The browser calls these through the Node server, which turns the login token into an
HttpOnly cookie. Direct clients (scripts, tests) send `Authorization: Bearer <token>`.

**Errors** always look like `{"error":{"code":"...","message":"...","requestId":"..."}}`.
Status codes: 400 validation, 401 not signed in, 403 forbidden, 404 not found, 409 conflict (stale `expectedVersion` or duplicate),
413 body over 1 MB, 429 rate limited or account locked.

Writes through the Node server must send the header `X-Requested-With: gamevault` (CSRF defence).

## Auth

| Method and path | Body | Result |
|---|---|---|
| POST `/auth/register` | `username`, `email`, `password` (10+ chars, letters and digits) | 201 user |
| POST `/auth/login` | `username` (or email), `password` | 200 `{token, expiresInSeconds, user}`; through Node the token is replaced by the cookie |
| POST `/auth/logout` | | 204 |
| GET `/auth/me` | | current user |
| GET `/health` | | `{status, database, time}` |

## Catalog (public)

| Method and path | Notes |
|---|---|
| GET `/catalog/lookups` | genres, platforms, ageRatings, modes, statuses |
| GET `/catalog/games` | query: `q`, `genres` (ids, comma-separated), `match=all\|any`, `platformId`, `ageRatingId`, `minRating`, `sort=title\|rating\|release\|popularity`, `dir=asc\|desc`, `page`, `size` (max 50). Returns `{items, page, size, total}` |
| GET `/catalog/games/{id}` | game with genres, platforms, age ratings, achievements (secret ones masked), latest reviews |

## My data (signed in)

| Method and path | Body | Notes |
|---|---|---|
| GET `/me/collection` | | optional `statusId`; includes derived `playtime_hours`, achievement counts, `my_rating`, `row_version` |
| POST `/me/collection` | `gameId`, `platformId`, `purchaseDate?`, `price?`, `statusId?` | 201 entry; the game must support that platform |
| PATCH `/me/collection/{id}` | `statusId`, `expectedVersion?` | 409 if `expectedVersion` is stale |
| DELETE `/me/collection/{id}` | | soft delete, 204 |
| GET, POST `/me/collection/{id}/sessions` | POST: `startedAt` (ISO), `minutes` (1-1440), `note?` | play sessions |
| GET `/me/collection/{id}/achievements` | | every achievement of the game with your progress |
| PUT `/me/collection/{id}/achievements/{achievementId}` | `progress` 0-100 | 100 unlocks it |
| GET `/me/ratings` | | |
| PUT `/me/ratings/{gameId}` | `rating` 1-10, `review?`, `expectedVersion?` | create or update |
| DELETE `/me/ratings/{gameId}` | | 204 |
| GET `/me/dashboard` | | summary, byStatus, topGames, recentUnlocks |

## Admin (role ADMIN)

| Method and path | Notes |
|---|---|
| GET `/admin/users` | |
| POST `/admin/users/{id}/deactivate` | hides the user, ends sign-in; data kept |
| POST `/admin/users/{id}/erase` | body `{confirmUsername}`; permanent erasure including personal data in the audit log |
| GET `/admin/audit` | query `table`, `recordPk`, `changedBy`, `limit` (max 200) |
