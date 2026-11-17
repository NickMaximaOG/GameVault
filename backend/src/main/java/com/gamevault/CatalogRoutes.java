package com.gamevault;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/** Public, read-only game catalogue with filtering, sorting and paging. */
final class CatalogRoutes {
    private CatalogRoutes() {}

    private static final Map<String, String> SORTS = Map.of(
            "title", "c.title",
            "rating", "c.avg_rating",
            "release", "c.release_date",
            "popularity", "c.rating_count");

    static void register(Server s, Db db) {
        String p = "/api/v1/catalog";

        s.route("GET", p + "/lookups", Server.Access.OPTIONAL_USER, c -> {
            Map<String, Object> m = new LinkedHashMap<>();
            m.put("genres", db.query("SELECT genre_id, name FROM Genre ORDER BY name"));
            m.put("developers", db.query("SELECT developer_id, name FROM Developer ORDER BY name"));
            m.put("publishers", db.query("SELECT publisher_id, name FROM Publisher ORDER BY name"));
            m.put("platforms", db.query("SELECT platform_id, name FROM Platform ORDER BY name"));
            m.put("ageRatings", db.query(
                    "SELECT age_rating_id, rating_authority, label, minimum_age FROM Age_Rating "
                    + "ORDER BY rating_authority, minimum_age"));
            m.put("modes", db.query("SELECT mode_id, name FROM Game_Mode ORDER BY name"));
            m.put("statuses", db.query("SELECT status_id, name FROM Collection_Status ORDER BY sort_order"));
            return m;
        });

        // GET /catalog/games?q=&genres=1,3&match=all|any&platformId=&ageRatingId=&minRating=
        //                   &sort=title|rating|release|popularity&dir=asc|desc&page=1&size=12
        s.route("GET", p + "/games", Server.Access.OPTIONAL_USER, c -> {
            StringBuilder where = new StringBuilder(" WHERE 1 = 1");
            List<Object> args = new ArrayList<>();
            if (c.user != null) {
                where.append(" AND NOT EXISTS (SELECT 1 FROM Game_Age_Rating gar JOIN Age_Rating ar ON ar.age_rating_id = gar.age_rating_id "
                        + "WHERE gar.game_id = c.game_id AND ar.minimum_age > COALESCE((SELECT TIMESTAMPDIFF(YEAR, u.date_of_birth, CURDATE()) "
                        + "FROM User u WHERE u.user_id = ?), 99))");
                args.add(c.user.id());
            }

            String q = c.q("q");
            if (q != null && !q.isBlank()) {
                if (q.length() > 100) throw ApiException.badRequest("Search text is too long");
                String like = "%" + q.strip().replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_") + "%";
                where.append(" AND (c.title LIKE ? OR c.description LIKE ?)");
                args.add(like);
                args.add(like);
            }

            List<Integer> genres = c.qIntList("genres", 12);
            if (!genres.isEmpty()) {
                String in = String.join(",", genres.stream().map(g -> "?").toList());
                boolean all = !"any".equalsIgnoreCase(c.q("match"));
                if (all) {
                    where.append(" AND (SELECT COUNT(DISTINCT gg.genre_id) FROM Game_Genre gg "
                            + "WHERE gg.game_id = c.game_id AND gg.genre_id IN (" + in + ")) = ?");
                    args.addAll(genres);
                    args.add(genres.stream().distinct().count());
                } else {
                    where.append(" AND EXISTS (SELECT 1 FROM Game_Genre gg "
                            + "WHERE gg.game_id = c.game_id AND gg.genre_id IN (" + in + "))");
                    args.addAll(genres);
                }
            }

            int platformId = c.qInt("platformId", 0, 0, Integer.MAX_VALUE);
            if (platformId > 0) {
                where.append(" AND EXISTS (SELECT 1 FROM Game_Platform gp WHERE gp.game_id = c.game_id AND gp.platform_id = ?)");
                args.add(platformId);
            }
            int ageRatingId = c.qInt("ageRatingId", 0, 0, Integer.MAX_VALUE);
            if (ageRatingId > 0) {
                where.append(" AND EXISTS (SELECT 1 FROM Game_Age_Rating gar WHERE gar.game_id = c.game_id AND gar.age_rating_id = ?)");
                args.add(ageRatingId);
            }
            int minRating = c.qInt("minRating", 0, 0, 10);
            if (minRating > 0) {
                where.append(" AND c.avg_rating >= ?");
                args.add(minRating);
            }

            String sortCol = SORTS.getOrDefault(c.q("sort") == null ? "title" : c.q("sort"), "c.title");
            String dir = "desc".equalsIgnoreCase(c.q("dir")) ? "DESC" : "ASC";   // whitelisted, never user text
            int size = c.qInt("size", 12, 1, 50);
            int page = c.qInt("page", 1, 1, 100_000);

            long total = ((Number) db.one("SELECT COUNT(*) AS n FROM v_game_catalog c" + where, args.toArray()).get("n")).longValue();
            List<Object> pageArgs = new ArrayList<>(args);
            pageArgs.add(size);
            pageArgs.add((long) (page - 1) * size);
            List<Map<String, Object>> items = db.query(
                    "SELECT c.* FROM v_game_catalog c" + where + " ORDER BY " + sortCol + " " + dir + ", c.title LIMIT ? OFFSET ?",
                    pageArgs.toArray());

            Map<String, Object> out = new LinkedHashMap<>();
            out.put("items", items);
            out.put("page", page);
            out.put("size", size);
            out.put("total", total);
            return out;
        });

        s.route("GET", p + "/games/{id}", Server.Access.OPTIONAL_USER, c -> {
            int id = c.pathInt("id");
            if (c.user != null) {
                Map<String, Object> age = db.one("SELECT COALESCE(TIMESTAMPDIFF(YEAR, date_of_birth, CURDATE()), 99) AS age FROM User WHERE user_id = ?", c.user.id());
                Map<String, Object> restricted = db.one("SELECT MAX(ar.minimum_age) AS min_age FROM Game_Age_Rating gar JOIN Age_Rating ar ON ar.age_rating_id = gar.age_rating_id WHERE gar.game_id = ?", id);
                int userAge = ((Number) age.get("age")).intValue();
                int minAge = restricted == null || restricted.get("min_age") == null ? 0 : ((Number) restricted.get("min_age")).intValue();
                if (userAge < minAge) throw ApiException.forbidden("Age restricted: this game requires an age of " + minAge + " or above.");
            }
            Map<String, Object> game = db.one("SELECT * FROM v_game_catalog WHERE game_id = ?", id);
            if (game == null) throw ApiException.notFound("Game not found");
            Map<String, Object> m = new LinkedHashMap<>(game);
            m.put("genreList", db.query("SELECT gn.genre_id, gn.name FROM Game_Genre gg "
                    + "JOIN Genre gn ON gn.genre_id = gg.genre_id WHERE gg.game_id = ? ORDER BY gn.name", id));
            m.put("platformList", db.query("SELECT p.platform_id, p.name, gp.platform_release_date FROM Game_Platform gp "
                    + "JOIN Platform p ON p.platform_id = gp.platform_id WHERE gp.game_id = ? ORDER BY p.name", id));
            m.put("ageRatingList", db.query("SELECT ar.age_rating_id, ar.rating_authority, ar.label, ar.minimum_age FROM Game_Age_Rating gar "
                    + "JOIN Age_Rating ar ON ar.age_rating_id = gar.age_rating_id WHERE gar.game_id = ? "
                    + "ORDER BY ar.rating_authority", id));
            m.put("achievements", db.query(
                    "SELECT achievement_id, rarity, CASE WHEN is_hidden = 1 THEN 'Hidden achievement' ELSE name END AS name, "
                    + "CASE WHEN is_hidden = 1 THEN NULL ELSE description END AS description, points, is_hidden "
                    + "FROM Achievement WHERE game_id = ? ORDER BY points, achievement_id", id));
            m.put("screenshots", db.query("SELECT screenshot_id, image_url, caption FROM Game_Screenshot WHERE game_id = ? ORDER BY sort_order, screenshot_id", id));
            m.put("reviews", db.query("SELECT u.username, r.rating, r.review_text, r.review_date FROM v_rating r "
                    + "JOIN v_user u ON u.user_id = r.user_id WHERE r.game_id = ? "
                    + "ORDER BY r.review_date DESC, r.rating_id DESC LIMIT 20", id));
            return m;
        });
    }
}
