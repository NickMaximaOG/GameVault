#!/usr/bin/env python3
"""Builds database/schema.sql from the hand-written parts plus generated data.

    python3 database/tools/gen_schema.py

Everything is resolved by name -> id dictionaries and every cross-table rule is
asserted here BEFORE any SQL is written, so a bad edit fails loudly.
"""
import base64
import hashlib
import math
import os
import random
from datetime import date, datetime, timedelta

HERE = os.path.dirname(os.path.abspath(__file__))
DB_DIR = os.path.dirname(HERE)
PARTS = os.path.join(DB_DIR, "parts")
OUT = os.path.join(DB_DIR, "schema.sql")
TODAY = date(2026, 10, 27)          # fixed so the seed is reproducible
DEMO_PASSWORD = "ChangeMe!2026"     # every demo account; documented in the README
PBKDF2_ITERATIONS = 600_000         # OWASP 2023 guidance for PBKDF2-HMAC-SHA256


def q(v):
    if v is None:
        return "NULL"
    if isinstance(v, bool):
        return "1" if v else "0"
    if isinstance(v, (int, float)):
        return str(v)
    if isinstance(v, datetime):
        return "'" + v.strftime("%Y-%m-%d %H:%M:%S") + "'"
    if isinstance(v, date):
        return "'" + v.isoformat() + "'"
    return "'" + str(v).replace("\\", "\\\\").replace("'", "''") + "'"


def d(s):
    return date.fromisoformat(s) if s else None


def pbkdf2_hash(password, salt):
    dk = hashlib.pbkdf2_hmac("sha256", password.encode(), salt, PBKDF2_ITERATIONS, 32)
    b64 = lambda b: base64.b64encode(b).decode()
    return f"pbkdf2-sha256${PBKDF2_ITERATIONS}${b64(salt)}${b64(dk)}"


# ------------------------------------------------------------------ lookups
roles = [(1, "USER", "Normal member: manages only their own data."),
         (2, "ADMIN", "Administrator: may deactivate or erase users and read the audit log.")]
statuses = [(1, "Backlog", 3), (2, "Playing", 1), (3, "Completed", 5), (4, "On Hold", 2), (5, "Dropped", 4)]
STATUS_ID = {n: i for i, n, _ in statuses}
assert STATUS_ID["Completed"] == 3, "chk_ug_completed hard-codes status 3"

developers = [
    ("Santa Monica Studio", "United States", "https://sms.playstation.com"),
    ("Naughty Dog", "United States", "https://www.naughtydog.com"),
    ("FromSoftware", "Japan", "https://www.fromsoftware.jp"),
    ("Game Science", "China", None),
    ("CD Projekt Red", "Poland", "https://www.cdprojektred.com"),
    ("Mojang Studios", "Sweden", "https://www.mojang.com"),
    ("Supergiant Games", "United States", "https://www.supergiantgames.com"),
    ("Larian Studios", "Belgium", "https://larian.com"),
    ("Playground Games", "United Kingdom", "https://playground-games.com"),
    ("Team Cherry", "Australia", "https://www.teamcherry.com.au"),
    ("ConcernedApe", "United States", "https://www.stardewvalley.net"),
    ("Maddy Makes Games", "Canada", "https://www.celestegame.com"),
    ("Rockstar Games", "United States", "https://www.rockstargames.com"),
    ("Nintendo EPD", "Japan", "https://www.nintendo.com"),
    ("id Software", "United States", "https://www.idsoftware.com"),
    ("Arrowhead Game Studios", "Sweden", "https://www.arrowheadgamestudios.com"),
    ("Firaxis Games", "United States", "https://firaxis.com"),
]
publishers = [
    ("Sony Interactive Entertainment", "United States", "https://www.playstation.com"),
    ("Bandai Namco Entertainment", "Japan", "https://www.bandainamcoent.com"),
    ("Game Science", "China", None),
    ("CD Projekt", "Poland", "https://www.cdprojekt.com"),
    ("Xbox Game Studios", "United States", "https://www.xbox.com"),
    ("Supergiant Games", "United States", "https://www.supergiantgames.com"),
    ("Larian Studios", "Belgium", "https://larian.com"),
    ("Team Cherry", "Australia", "https://www.teamcherry.com.au"),
    ("ConcernedApe", "United States", "https://www.stardewvalley.net"),
    ("Maddy Makes Games", "Canada", "https://www.celestegame.com"),
    ("Rockstar Games", "United States", "https://www.rockstargames.com"),
    ("Nintendo", "Japan", "https://www.nintendo.com"),
    ("Bethesda Softworks", "United States", "https://bethesda.net"),
    ("Activision", "United States", "https://www.activision.com"),
    ("2K", "United States", "https://2k.com"),
]
genres = [
    ("Action", "Gameplay centred on reflexes, combat and physical challenges."),
    ("Adventure", "Story-driven exploration and discovery."),
    ("RPG", "Character progression, builds and narrative choices."),
    ("Open World", "Large explorable maps with non-linear objectives."),
    ("Roguelike", "Procedurally varied runs with permadeath and meta-progression."),
    ("Metroidvania", "Interconnected maps gated by abilities and backtracking."),
    ("Racing", "Competitive or free-roam driving."),
    ("Sandbox", "Open-ended creation and player-defined goals."),
    ("Platformer", "Precision jumping and traversal."),
    ("Simulation", "Systems that model real or fictional activities."),
    ("Strategy", "Planning, tactics and resource management."),
    ("Shooter", "Ranged combat from first- or third-person view."),
]
platforms = [
    ("PC (Windows)", None, None),
    ("PlayStation 5", "Sony", 2020),
    ("PlayStation 4", "Sony", 2013),
    ("Xbox Series X|S", "Microsoft", 2020),
    ("Xbox One", "Microsoft", 2013),
    ("Nintendo Switch", "Nintendo", 2017),
]
age_ratings = [  # label, authority, description, min_age
    ("E", "ESRB", "Everyone: content is generally suitable for all ages.", 0),
    ("E10+", "ESRB", "Everyone 10+: may contain mild violence or mild language.", 10),
    ("T", "ESRB", "Teen: may contain violence, crude humor or suggestive themes.", 13),
    ("M", "ESRB", "Mature 17+: may contain intense violence, blood and strong language.", 17),
    ("3", "PEGI", "Suitable for all age groups.", 3),
    ("7", "PEGI", "Mild fantasy violence or frightening scenes.", 7),
    ("12", "PEGI", "Moderate violence and mild bad language.", 12),
    ("16", "PEGI", "Realistic violence and stronger language.", 16),
    ("18", "PEGI", "Graphic violence and adult content.", 18),
]
modes = [
    ("Single-player", "One player, offline or online."),
    ("Online Co-op", "Players cooperate over the internet."),
    ("Online Multiplayer", "Players compete or share a world over the internet."),
    ("Local Co-op", "Players cooperate on the same device or screen."),
    ("Local Multiplayer", "Players compete on the same device or screen."),
]

IDX = lambda lst: {row[0]: i + 1 for i, row in enumerate(lst)}
dev_id, pub_id = IDX(developers), IDX(publishers)
genre_id, plat_id = IDX(genres), IDX(platforms)
rating_id = {(a, l): i + 1 for i, (l, a, _, _) in enumerate(age_ratings)}
mode_id = IDX(modes)

# Game: title, release, developer, publisher, ESRB label, description, genres, modes
games = [
    ("God of War Ragnarök", "2022-11-09", "Santa Monica Studio", "Sony Interactive Entertainment", "M",
     "Kratos and Atreus travel the Nine Realms as Ragnarök approaches.",
     ["Action", "Adventure"], ["Single-player"]),
    ("The Last of Us Part I", "2022-09-02", "Naughty Dog", "Sony Interactive Entertainment", "M",
     "A rebuilt version of the post-pandemic story of Joel and Ellie.",
     ["Action", "Adventure"], ["Single-player"]),
    ("Elden Ring", "2022-02-25", "FromSoftware", "Bandai Namco Entertainment", "M",
     "A huge open-world action RPG set in the Lands Between.",
     ["Action", "RPG", "Open World"], ["Single-player", "Online Co-op", "Online Multiplayer"]),
    ("Black Myth: Wukong", "2024-08-20", "Game Science", "Game Science", "T",
     "An action RPG inspired by Journey to the West.",
     ["Action", "RPG"], ["Single-player"]),
    ("Cyberpunk 2077", "2020-12-10", "CD Projekt Red", "CD Projekt", "M",
     "An open-world action RPG set in the dystopian Night City.",
     ["RPG", "Open World", "Action"], ["Single-player"]),
    ("Minecraft", "2011-11-18", "Mojang Studios", "Xbox Game Studios", "E10+",
     "A block-based sandbox about mining, building and survival.",
     ["Sandbox", "Adventure"], ["Single-player", "Online Co-op", "Online Multiplayer", "Local Co-op"]),
    ("Hades", "2020-09-17", "Supergiant Games", "Supergiant Games", "T",
     "A roguelike dungeon crawler about escaping the Underworld.",
     ["Roguelike", "Action"], ["Single-player"]),
    ("Baldur's Gate 3", "2023-08-03", "Larian Studios", "Larian Studios", "M",
     "A turn-based, party-driven RPG built on Dungeons & Dragons rules.",
     ["RPG", "Strategy"], ["Single-player", "Online Co-op", "Local Co-op"]),
    ("Forza Horizon 5", "2021-11-09", "Playground Games", "Xbox Game Studios", "E",
     "An open-world racing festival set in Mexico.",
     ["Racing", "Open World"], ["Single-player", "Online Multiplayer"]),
    ("Hollow Knight", "2017-02-24", "Team Cherry", "Team Cherry", "E10+",
     "A hand-drawn metroidvania set in the ruined insect kingdom of Hallownest.",
     ["Metroidvania", "Platformer", "Action"], ["Single-player"]),
    ("Stardew Valley", "2016-02-26", "ConcernedApe", "ConcernedApe", "E10+",
     "A farming and life simulation with a deep social system.",
     ["Simulation", "RPG"], ["Single-player", "Online Co-op", "Local Co-op"]),
    ("Celeste", "2018-01-25", "Maddy Makes Games", "Maddy Makes Games", "E10+",
     "A tight precision platformer about climbing a mountain.",
     ["Platformer"], ["Single-player"]),
    ("The Witcher 3: Wild Hunt", "2015-05-19", "CD Projekt Red", "CD Projekt", "M",
     "A story-rich open-world RPG following the monster hunter Geralt.",
     ["RPG", "Open World", "Action"], ["Single-player"]),
    ("Red Dead Redemption 2", "2018-10-26", "Rockstar Games", "Rockstar Games", "M",
     "A western epic about the decline of the Van der Linde gang.",
     ["Action", "Adventure", "Open World"], ["Single-player", "Online Multiplayer"]),
    ("The Legend of Zelda: Breath of the Wild", "2017-03-03", "Nintendo EPD", "Nintendo", "E10+",
     "An open-air Zelda adventure built around exploration and physics.",
     ["Action", "Adventure", "Open World"], ["Single-player"]),
    ("DOOM Eternal", "2020-03-20", "id Software", "Bethesda Softworks", "M",
     "A fast first-person shooter about ripping through demonic invasions.",
     ["Shooter", "Action"], ["Single-player", "Online Multiplayer"]),
    ("Mario Kart 8 Deluxe", "2017-04-28", "Nintendo EPD", "Nintendo", "E",
     "Arcade kart racing with items, 48 tracks and split-screen play.",
     ["Racing"], ["Single-player", "Online Multiplayer", "Local Multiplayer"]),
    ("Helldivers 2", "2024-02-08", "Arrowhead Game Studios", "Sony Interactive Entertainment", "M",
     "A cooperative third-person shooter about spreading managed democracy.",
     ["Shooter", "Action"], ["Online Co-op"]),
    ("Sekiro: Shadows Die Twice", "2019-03-22", "FromSoftware", "Activision", "M",
     "A posture-based action adventure set in sengoku-era Japan.",
     ["Action", "Adventure"], ["Single-player"]),
    ("Sid Meier's Civilization VI", "2016-10-21", "Firaxis Games", "2K", "E10+",
     "A turn-based 4X strategy game about leading a civilization through history.",
     ["Strategy"], ["Single-player", "Online Multiplayer", "Local Multiplayer"]),
]
game_id = {g[0]: i + 1 for i, g in enumerate(games)}

# PEGI classes (general knowledge, not individually re-verified)
PEGI = {"Elden Ring": "16", "Cyberpunk 2077": "18", "God of War Ragnarök": "18",
        "The Last of Us Part I": "18", "Minecraft": "7", "Mario Kart 8 Deluxe": "3",
        "Forza Horizon 5": "3", "The Witcher 3: Wild Hunt": "18",
        "Red Dead Redemption 2": "18", "DOOM Eternal": "18"}

P = "PC (Windows)"; PS5 = "PlayStation 5"; PS4 = "PlayStation 4"
XS = "Xbox Series X|S"; XO = "Xbox One"; NS = "Nintendo Switch"
game_platforms = {
    "God of War Ragnarök": [(PS4, "2022-11-09"), (PS5, "2022-11-09"), (P, "2024-09-19")],
    "The Last of Us Part I": [(PS5, "2022-09-02"), (P, "2023-03-28")],
    "Elden Ring": [(P, "2022-02-25"), (PS4, "2022-02-25"), (PS5, "2022-02-25"),
                   (XS, "2022-02-25"), (XO, "2022-02-25")],
    "Black Myth: Wukong": [(P, "2024-08-20"), (PS5, "2024-08-20"), (XS, "2025-08-20")],
    "Cyberpunk 2077": [(P, "2020-12-10"), (PS4, "2020-12-10"), (XO, "2020-12-10"),
                       (PS5, "2022-02-15"), (XS, "2022-02-15")],
    "Minecraft": [(P, "2011-11-18"), (PS4, "2014-09-04"), (XO, "2014-09-05"),
                  (NS, "2017-05-11"), (PS5, None), (XS, None)],
    "Hades": [(P, "2020-09-17"), (NS, "2020-09-17"), (PS4, "2021-08-13"),
              (PS5, "2021-08-13"), (XS, "2021-08-13")],
    "Baldur's Gate 3": [(P, "2023-08-03"), (PS5, "2023-09-06"), (XS, "2023-12-07")],
    "Forza Horizon 5": [(XS, "2021-11-09"), (XO, "2021-11-09"), (P, "2021-11-09"),
                        (PS5, "2025-04-29")],
    "Hollow Knight": [(P, "2017-02-24"), (NS, "2018-06-12"), (PS4, "2018-09-25"),
                      (XO, "2018-09-25")],
    "Stardew Valley": [(P, "2016-02-26"), (PS4, "2016-12-13"), (XO, "2016-12-14"),
                       (NS, "2017-10-05")],
    "Celeste": [(P, "2018-01-25"), (NS, "2018-01-25"), (PS4, "2018-01-25"), (XO, "2018-01-25")],
    "The Witcher 3: Wild Hunt": [(P, "2015-05-19"), (PS4, "2015-05-19"), (XO, "2015-05-19"),
                                 (NS, "2019-10-15"), (PS5, "2022-12-14")],
    "Red Dead Redemption 2": [(PS4, "2018-10-26"), (XO, "2018-10-26"), (P, "2019-11-05")],
    "The Legend of Zelda: Breath of the Wild": [(NS, "2017-03-03")],
    "DOOM Eternal": [(P, "2020-03-20"), (PS4, "2020-03-20"), (XO, "2020-03-20"),
                     (NS, "2021-12-08")],
    "Mario Kart 8 Deluxe": [(NS, "2017-04-28")],
    "Helldivers 2": [(P, "2024-02-08"), (PS5, "2024-02-08")],
    "Sekiro: Shadows Die Twice": [(P, "2019-03-22"), (PS4, "2019-03-22"), (XO, "2019-03-22")],
    "Sid Meier's Civilization VI": [(P, "2016-10-21"), (NS, "2018-11-15"),
                                    (PS4, "2019-11-22"), (XO, "2019-11-22")],
}
assert set(game_platforms) == set(game_id)
gp_date = {(g, p): d(dt) for g, lst in game_platforms.items() for p, dt in lst}

# username, email, join date, avatar, role   (aarav_k is the demo administrator)
users = [
    ("aarav_k", "aarav.k@example.com", "2023-08-02", "https://avatars.example.com/aarav_k.png", "ADMIN"),
    ("meera_s", "meera.s@example.com", "2022-09-05", "https://avatars.example.com/meera_s.png", "USER"),
    ("rohan_v", "rohan.v@example.com", "2023-01-17", None, "USER"),
    ("ananya_d", "ananya.d@example.com", "2022-03-21", "https://avatars.example.com/ananya_d.png", "USER"),
    ("kabir_m", "kabir.m@example.com", "2023-02-11", None, "USER"),
    ("ishita_r", "ishita.r@example.com", "2021-11-30", "https://avatars.example.com/ishita_r.png", "USER"),
    ("new_player_07", "new.player07@example.com", "2026-10-20", None, "USER"),
]
user_id = {u[0]: i + 1 for i, u in enumerate(users)}
ROLE_ID = {n: i for i, n, _ in roles}
srng = random.Random(20261028)
user_hashes = [pbkdf2_hash(DEMO_PASSWORD, bytes(srng.randrange(256) for _ in range(16))) for _ in users]

# User_Game: user, game, platform, purchase_date, price, status, hours, started, completed
UG = [
    ("aarav_k", "God of War Ragnarök", P, "2024-09-25", 59.99, "Completed", 41.5, "2024-09-26", "2024-11-02"),
    ("aarav_k", "Elden Ring", P, "2022-03-01", 59.99, "Completed", 132.5, "2022-03-02", "2022-06-20"),
    ("aarav_k", "Hades", P, "2021-01-10", 24.99, "Completed", 58.0, "2021-01-11", "2021-03-14"),
    ("aarav_k", "Hollow Knight", P, "2020-05-20", 14.99, "Playing", 31.0, "2020-05-21", None),
    ("aarav_k", "Baldur's Gate 3", P, "2023-08-03", 59.99, "Playing", 87.5, "2023-08-04", None),
    ("aarav_k", "Cyberpunk 2077", P, "2022-11-24", 29.99, "On Hold", 22.0, "2022-11-25", None),
    ("aarav_k", "Sekiro: Shadows Die Twice", P, "2023-01-15", 39.99, "Dropped", 6.5, "2023-01-16", None),
    ("meera_s", "The Last of Us Part I", PS5, "2022-09-02", 69.99, "Completed", 24.0, "2022-09-03", "2022-09-20"),
    ("meera_s", "God of War Ragnarök", PS5, "2022-11-09", 69.99, "Completed", 38.5, "2022-11-10", "2022-12-15"),
    ("meera_s", "Elden Ring", PS5, "2022-04-02", 59.99, "Playing", 65.0, "2022-04-03", None),
    ("meera_s", "Black Myth: Wukong", PS5, "2024-08-20", 59.99, "Completed", 44.0, "2024-08-21", "2024-09-14"),
    ("meera_s", "Minecraft", NS, "2019-06-01", 29.99, "Playing", 120.0, "2019-06-02", None),
    ("meera_s", "Mario Kart 8 Deluxe", NS, "2020-03-10", 59.99, "Playing", 75.5, "2020-03-11", None),
    ("meera_s", "Hades", NS, "2021-02-14", 24.99, "Completed", 49.0, "2021-02-15", "2021-04-03"),
    ("rohan_v", "Cyberpunk 2077", P, "2021-01-05", 59.99, "Completed", 78.0, "2021-01-06", "2021-03-02"),
    ("rohan_v", "The Witcher 3: Wild Hunt", P, "2019-12-01", 39.99, "Completed", 160.0, "2019-12-02", "2020-04-18"),
    ("rohan_v", "Forza Horizon 5", XS, "2021-11-09", 59.99, "Playing", 95.0, "2021-11-09", None),
    ("rohan_v", "Elden Ring", XS, "2022-02-25", 59.99, "Dropped", 18.0, "2022-02-26", None),
    ("rohan_v", "DOOM Eternal", P, "2020-04-01", 39.99, "Completed", 21.5, "2020-04-02", "2020-04-20"),
    ("rohan_v", "Baldur's Gate 3", XS, "2023-12-07", 59.99, "Backlog", 0.0, None, None),
    ("rohan_v", "Minecraft", P, "2018-07-01", 26.95, "Playing", 210.0, "2018-07-02", None),
    ("ananya_d", "The Legend of Zelda: Breath of the Wild", NS, "2017-03-03", 59.99, "Completed", 110.0, "2017-03-04", "2017-09-10"),
    ("ananya_d", "Hollow Knight", NS, "2018-06-12", 14.99, "Completed", 42.0, "2018-06-13", "2018-08-01"),
    ("ananya_d", "Celeste", NS, "2018-02-01", 19.99, "Completed", 11.5, "2018-02-02", "2018-02-20"),
    ("ananya_d", "Stardew Valley", NS, "2017-10-05", 14.99, "Playing", 140.0, "2017-10-06", None),
    ("ananya_d", "Minecraft", NS, "2018-12-24", 0.00, "Playing", 15.0, "2018-12-26", None),
    ("ananya_d", "Hades", P, "2022-07-20", 24.99, "On Hold", 12.0, "2022-07-21", None),
    ("ananya_d", "Sid Meier's Civilization VI", NS, "2019-01-12", 59.99, "Playing", 33.0, "2019-01-13", None),
    ("kabir_m", "God of War Ragnarök", PS5, "2023-01-10", 49.99, "Dropped", 9.0, "2023-01-11", None),
    ("kabir_m", "The Last of Us Part I", PS5, "2023-03-01", 59.99, "Backlog", 0.0, None, None),
    ("kabir_m", "Helldivers 2", PS5, "2024-02-08", 39.99, "Playing", 150.0, "2024-02-08", None),
    ("kabir_m", "Red Dead Redemption 2", PS4, "2019-01-20", 59.99, "Completed", 68.0, "2019-01-21", "2019-04-12"),
    ("kabir_m", "The Witcher 3: Wild Hunt", PS5, "2023-02-02", 19.99, "Playing", 55.0, "2023-02-03", None),
    ("kabir_m", "Cyberpunk 2077", PS5, "2022-03-05", 39.99, "Completed", 52.0, "2022-03-06", "2022-05-01"),
    ("ishita_r", "Stardew Valley", P, "2016-04-01", 14.99, "Completed", 200.0, "2016-04-02", "2016-09-30"),
    ("ishita_r", "Celeste", P, "2018-02-10", 19.99, "Completed", 14.0, "2018-02-11", "2018-03-01"),
    ("ishita_r", "Hollow Knight", P, "2018-03-05", 14.99, "Completed", 55.0, "2018-03-06", "2018-05-20"),
    ("ishita_r", "Sid Meier's Civilization VI", P, "2017-01-15", 59.99, "Playing", 420.0, "2017-01-16", None),
    ("ishita_r", "Baldur's Gate 3", P, "2023-08-03", 59.99, "On Hold", 30.0, "2023-08-04", None),
    ("ishita_r", "Elden Ring", P, "2022-02-25", 59.99, "Completed", 98.0, "2022-02-26", "2022-05-10"),
]
ug_id = {(r[0], r[1], r[2]): i + 1 for i, r in enumerate(UG)}
assert len(ug_id) == len(UG) == 40

ACH = {
    "God of War Ragnarök": [
        ("Fimbulwinter Survivor", "Finish the opening chapters of the story.", 10, False),
        ("Realm Traveler", "Visit every one of the Nine Realms.", 25, False),
        ("Valkyrie Slayer", "Defeat every Valkyrie.", 50, False),
        ("Ragnarök Complete", "Finish the main story.", 100, False)],
    "The Last of Us Part I": [
        ("Crafty Survivor", "Craft 50 items during one playthrough.", 25, False),
        ("Collector", "Find every artifact.", 50, False),
        ("Endurance", "Finish the main story.", 100, False)],
    "Elden Ring": [
        ("Lands Between Explorer", "Discover 100 map locations.", 25, False),
        ("Shardbearer Slayer", "Defeat your first Shardbearer.", 25, False),
        ("Great Rune Restored", "Restore a Great Rune.", 25, False),
        ("Elden Lord", "Reach the main ending.", 100, False),
        ("Hidden Ending Seeker", "Reach a secret ending.", 50, True)],
    "Black Myth: Wukong": [
        ("Destined One", "Finish the first chapter.", 10, False),
        ("Yaoguai Hunter", "Defeat 50 yaoguai.", 25, False),
        ("Transformation Master", "Use every transformation.", 25, False),
        ("Journey Complete", "Finish the main story.", 100, False)],
    "Cyberpunk 2077": [
        ("Nomad Beginnings", "Complete the prologue.", 10, False),
        ("Cyberware Collector", "Install 10 cyberware pieces.", 25, False),
        ("Street Legend", "Reach maximum Street Cred.", 50, False),
        ("Night City Legend", "Reach any ending.", 100, True)],
    "Minecraft": [
        ("Taking Inventory", "Open your inventory.", 10, False),
        ("Getting an Upgrade", "Craft a better pickaxe.", 10, False),
        ("Diamonds!", "Mine your first diamond.", 25, False),
        ("The End?", "Enter the End dimension.", 50, False)],
    "Hades": [
        ("Out of the Underworld", "Escape the Underworld once.", 25, False),
        ("Weapon Master", "Clear a run with every weapon.", 50, False),
        ("Heat Seeker", "Escape with 10 Heat or more.", 50, False),
        ("Pact of Punishment", "Clear a run with 15 Heat or more.", 50, False),
        ("Full House", "Meet every major character.", 25, True)],
    "Baldur's Gate 3": [
        ("Party Assembled", "Recruit your first three companions.", 10, False),
        ("Tadpole Resolved", "Resolve the tadpole problem.", 25, False),
        ("Camp Secrets", "Find every hidden camp scene.", 25, True),
        ("Honour Mode Clear", "Finish the game on Honour Mode.", 100, False)],
    "Forza Horizon 5": [
        ("Festival Starter", "Complete the opening races.", 10, False),
        ("Mexico Explorer", "Discover every biome.", 25, False),
        ("Hot Lap Collector", "Earn gold in every road race.", 50, False)],
    "Hollow Knight": [
        ("Kingdom Traveller", "Reach the City of Tears.", 10, False),
        ("Charm Collector", "Collect 20 charms.", 25, False),
        ("Pantheon Challenger", "Clear a Pantheon of Hallownest.", 50, False),
        ("True Ending", "Reach the true ending.", 100, False),
        ("Dream Seeker", "Find every Dream Nail secret.", 50, True)],
    "Stardew Valley": [
        ("First Harvest", "Harvest your first crop.", 10, False),
        ("Community Hero", "Restore the Community Center.", 50, False),
        ("Perfection", "Reach 100% Perfection.", 100, False)],
    "Celeste": [
        ("Strawberry Collector", "Collect 20 strawberries.", 25, False),
        ("Summit Reached", "Reach the summit.", 50, False),
        ("B-Side Climber", "Clear every B-Side.", 50, True)],
    "The Witcher 3: Wild Hunt": [
        ("Wolf School Initiate", "Complete the first contract.", 10, False),
        ("Gwent Champion", "Win 20 Gwent matches.", 50, False),
        ("End of Journey", "Finish the main story.", 100, False)],
}
ach_rows, ach_id, ach_by_game = [], {}, {}
for g in games:
    title = g[0]
    for n, desc, pts, hid in ACH.get(title, []):
        aid = len(ach_rows) + 1
        ach_rows.append((aid, title, n, desc, pts, hid))
        ach_id[(title, n)] = aid
        ach_by_game.setdefault(title, []).append(aid)
assert len(ach_rows) == 50

# User_Achievement progression rules (by collection status)
prng = random.Random(77)
ua_rows = []
for r in UG:
    user, title, plat, pdt, price, status, hours, started, completed = r
    if status == "Backlog" or title not in ach_by_game:
        continue
    ugid = ug_id[(user, title, plat)]
    ids = ach_by_game[title]
    n = len(ids)
    s_date, c_date = d(started), d(completed)
    if status == "Completed":
        k_unlocked = n
    elif status == "Playing":
        k_unlocked = n // 2
    elif status == "On Hold":
        k_unlocked = max(1, n // 3)
    else:
        k_unlocked = 1 if n >= 4 else 0
    hidden_locked = {aid for aid in ids
                     if ach_rows[aid - 1][5] and (ugid % 3 != 0) and status == "Completed"}
    span = (c_date - s_date).days if c_date else min(400, (TODAY - s_date).days - 1)
    span = max(span, n)
    partial_done = False
    for pos, aid in enumerate(ids):
        locked = pos >= k_unlocked or aid in hidden_locked
        if not locked:
            day = s_date + timedelta(days=max(1, int(span * (pos + 1) / (n + 0.5))))
            if c_date and day > c_date:
                day = c_date
            if day >= TODAY:
                day = TODAY - timedelta(days=1)
            minute = (ugid * 37 + aid * 53) % 540 + 600
            ts = datetime(day.year, day.month, day.day, minute // 60, minute % 60, (ugid + aid) % 60)
            ua_rows.append((ugid, aid, game_id[title], ts, 100.00, True))
        else:
            if not partial_done and status in ("Playing", "On Hold", "Dropped"):
                prog = round(prng.choice([15, 25, 40, 55, 60, 75, 85]) + prng.random() * 4, 2)
                partial_done = True
            elif status == "Completed":
                prog = round(prng.choice([30, 45, 60, 70]) + prng.random() * 4, 2)
            else:
                prog = 0.00
            ua_rows.append((ugid, aid, game_id[title], None, prog, False))
assert len(ua_rows) >= 100

RT = [
    ("aarav_k", "God of War Ragnarök", 9, "Great combat and a satisfying end to the saga. A few pacing dips in the middle.", "2024-11-04"),
    ("aarav_k", "Elden Ring", 10, "Exploration at its best. Every direction hides something worth finding.", "2022-06-22"),
    ("aarav_k", "Hades", 9, "Each run feels different and the story rewards failing. Endlessly replayable.", "2021-03-16"),
    ("aarav_k", "Hollow Knight", 9, "Atmospheric and generous in content. The map takes some getting used to.", "2020-08-12"),
    ("aarav_k", "Baldur's Gate 3", 10, "Reactive writing and tactical combat that rewards experimenting.", "2023-12-20"),
    ("meera_s", "The Last of Us Part I", 10, "The remake keeps everything that made the original land so hard.", "2022-09-22"),
    ("meera_s", "God of War Ragnarök", 9, "Strong performances and a world that is a pleasure to travel through.", "2022-12-17"),
    ("meera_s", "Minecraft", 9, "Still the best creative sandbox. Better with friends.", "2021-06-10"),
    ("meera_s", "Hades", 9, "Excellent on Switch. The runs are short enough for a commute.", "2021-04-05"),
    ("rohan_v", "Cyberpunk 2077", 8, "Rough at launch, but the world and quests are strong after the patches.", "2021-03-05"),
    ("rohan_v", "The Witcher 3: Wild Hunt", 10, "Side quests with real stakes. A benchmark for open-world RPGs.", "2020-04-20"),
    ("rohan_v", "Forza Horizon 5", 9, "Beautiful, varied and always something to chase.", "2022-01-15"),
    ("rohan_v", "Elden Ring", 5, "Impressive world, but the difficulty was not for me and I bounced off.", "2022-03-20"),
    ("ananya_d", "The Legend of Zelda: Breath of the Wild", 10, "Freedom in every direction. Made exploring feel new again.", "2017-09-12"),
    ("ananya_d", "Hollow Knight", 10, "Huge amount of game for the price. The boss fights are superb.", "2018-08-03"),
    ("ananya_d", "Celeste", 9, "Tough but fair, with assist options that respect the player.", "2018-02-22"),
    ("ananya_d", "Stardew Valley", 9, "Relaxing and bottomless. Always one more day to play.", "2018-01-10"),
    ("kabir_m", "God of War Ragnarök", 6, "Looks great but the combat did not hold me, so I dropped it.", "2023-02-02"),
    ("kabir_m", "Helldivers 2", 8, "Chaotic co-op fun. Even better with a coordinated squad.", "2024-05-18"),
    ("kabir_m", "Red Dead Redemption 2", 9, "Slow-burn story and astonishing detail.", "2019-04-14"),
    ("kabir_m", "Cyberpunk 2077", 7, "Strong ending and great atmosphere, with some leftover rough edges.", "2022-05-03"),
    ("ishita_r", "Stardew Valley", 10, "My comfort game. Two hundred hours and counting.", "2016-10-02"),
    ("ishita_r", "Celeste", 9, "Excellent level design and a story that means something.", "2018-03-02"),
    ("ishita_r", "Hollow Knight", 9, "A world you want to get lost in.", "2018-05-22"),
    ("ishita_r", "Elden Ring", 9, "Brutal and beautiful. Several boss fights are unforgettable.", "2022-05-12"),
]
assert len(RT) == 25 and len({(r[0], r[1]) for r in RT}) == 25

# ------------------------------------------------- playtime sessions (D8)
# Each entry's TOTAL hours stay exactly as in v1: baseline + sessions.
srng2 = random.Random(4242)
NOTES = [None, None, None, "Evening session", "Weekend marathon", "Boss attempts",
         "Co-op night", "Short break session", "Finally got past it"]
baseline = {}      # ugid -> baseline hours
sessions = []      # (ugid, datetime, minutes, note)
for r in UG:
    user, title, plat, pdt, price, status, hours, started, completed = r
    ugid = ug_id[(user, title, plat)]
    tenths = int(round(hours * 10))
    if tenths == 0:
        baseline[ugid] = 0.0
        continue
    sess_t = min(tenths, max(2, int(round(tenths * 0.15))))
    n = min(max(2, math.ceil(sess_t / 120)), 8, sess_t)
    while True:
        cuts = sorted(srng2.sample(range(1, sess_t), n - 1)) if n > 1 else []
        parts = [b - a for a, b in zip([0] + cuts, cuts + [sess_t])]
        if all(1 <= p <= 200 for p in parts):
            break
    s_date = d(started)
    e_date = d(completed) if completed else TODAY - timedelta(days=1)
    span = max((e_date - s_date).days, 0)
    for p in parts:
        day = s_date + timedelta(days=srng2.randint(0, span))
        when = datetime(day.year, day.month, day.day, srng2.randint(12, 22), srng2.choice([0, 15, 30, 45]))
        sessions.append((ugid, when, p * 6, srng2.choice(NOTES)))
    baseline[ugid] = round((tenths - sess_t) / 10, 1)
    assert round(baseline[ugid] * 10) + sum(p for p in parts) == tenths
sessions.sort(key=lambda s: (s[0], s[1]))

# ---------------------------------------------------------------- assertions
owned = {(r[0], r[1]) for r in UG}
for u, g, *_ in RT:
    assert (u, g) in owned, ("rating without collection entry", u, g)
for r in UG:
    user, title, plat, pdt, price, status, hours, started, completed = r
    assert (title, plat) in gp_date, ("unsupported platform", title, plat)
    rel = gp_date[(title, plat)]
    if rel and pdt:
        assert d(pdt) >= rel, ("purchase before platform release", r)
    if started and pdt:
        assert d(started) >= d(pdt), ("started before purchase", r)
    if completed:
        assert status == "Completed" and d(completed) >= d(started)
    if status == "Completed":
        assert completed
    if status == "Backlog":
        assert hours == 0 and not started
    else:
        assert started and hours > 0
for (ugid, aid, gid, ts, prog, unl) in ua_rows:
    ug = UG[ugid - 1]
    assert game_id[ug[1]] == gid == game_id[ach_rows[aid - 1][1]]
    if unl:
        assert ts and prog == 100 and ts.date() >= d(ug[7]) and ts.date() < TODAY
        if ug[8]:
            assert ts.date() <= d(ug[8])
    else:
        assert ts is None and 0 <= prog < 100
tot = {}
for ugid, when, mins, _ in sessions:
    ug = UG[ugid - 1]
    assert d(ug[7]) <= when.date() <= (d(ug[8]) or TODAY - timedelta(days=1)), ("session outside play window", ug, when)
    assert 1 <= mins <= 1440
    tot[ugid] = tot.get(ugid, 0) + mins
for r in UG:
    ugid = ug_id[(r[0], r[1], r[2])]
    assert abs(baseline[ugid] + tot.get(ugid, 0) / 60 - r[6]) < 0.0501, ("hours mismatch", r)

# ------------------------------------------------------------- emit the DML
out = []
w = out.append


def block(title, table, cols, rows, comment=None):
    w(f"-- {title}")
    if comment:
        w(f"-- {comment}")
    w(f"INSERT INTO {table} ({', '.join(cols)}) VALUES")
    w(",\n".join("  (" + ", ".join(q(v) for v in r) + ")" for r in rows) + ";")
    w("")


w("-- ---------------------------------------------------------------------")
w("-- 5. SAMPLE DATA (parents first, then children)")
w(f"--    Every demo account uses the password  {DEMO_PASSWORD}  (change it!).")
w(f"--    Hashes are PBKDF2-HMAC-SHA256, {PBKDF2_ITERATIONS} iterations, random 16-byte salts.")
w("--    aarav_k is the ADMIN demo account. Activity data is fictional.")
w("-- ---------------------------------------------------------------------")
w("")
block("Role", "Role", ["role_id", "name", "description"], roles)
block("Collection_Status", "Collection_Status", ["status_id", "name", "sort_order"], statuses)
block("User (7 rows; user 7 deliberately owns no games)", "User",
      ["user_id", "username", "email", "password_hash", "role_id", "join_date", "profile_picture"],
      [(i + 1, u[0], u[1], user_hashes[i], ROLE_ID[u[4]], d(u[2]), u[3]) for i, u in enumerate(users)])
extra_hash = pbkdf2_hash(DEMO_PASSWORD, b"GVdemoSalt000001")
w("-- Portal demo accounts; all initially use the documented demo password.")
w("INSERT INTO User (user_id, username, email, password_hash, role_id, join_date, date_of_birth) VALUES")
w("  (8, 'admin', 'admin@gamevault.local', " + q(extra_hash) + ", 2, CURRENT_DATE, NULL),")
w("  (9, 'NickMaxima', 'nickmaxima@gamevault.local', " + q(extra_hash) + ", 1, CURRENT_DATE, NULL),")
w("  (10, 'Dibu2007', 'dibu2007@gamevault.local', " + q(extra_hash) + ", 1, CURRENT_DATE, NULL),")
w("  (11, 'Xlitz', 'xlitz@gamevault.local', " + q(extra_hash) + ", 1, CURRENT_DATE, '2010-01-01');")
w("INSERT INTO Friendship (requester_id, recipient_id, status) SELECT a.user_id, b.user_id, 'ACCEPTED' FROM User a JOIN User b WHERE a.username = 'NickMaxima' AND b.username = 'Dibu2007';")
w("")
block("Developer (17 rows)", "Developer", ["developer_id", "name", "country", "website"],
      [(i + 1, *r) for i, r in enumerate(developers)])
block("Publisher (15 rows)", "Publisher", ["publisher_id", "name", "country", "website"],
      [(i + 1, *r) for i, r in enumerate(publishers)],
      "Self-published studios appear in both Developer and Publisher: the roles are separate entities.")
block("Genre (12 rows)", "Genre", ["genre_id", "name", "description"],
      [(i + 1, *r) for i, r in enumerate(genres)])
block("Platform (6 rows)", "Platform", ["platform_id", "name", "manufacturer", "release_year"],
      [(i + 1, *r) for i, r in enumerate(platforms)],
      "PC has no manufacturer or release year, which demonstrates the nullable columns.")
block("Age_Rating (9 rows: 4 ESRB + 5 PEGI)", "Age_Rating",
      ["age_rating_id", "label", "rating_authority", "description", "minimum_age"],
      [(i + 1, *r) for i, r in enumerate(age_ratings)])
block("Game_Mode (5 rows)", "Game_Mode", ["mode_id", "name", "description"],
      [(i + 1, *r) for i, r in enumerate(modes)])
steam_cover_ids = {
    "God of War Ragnarök": 2322010, "The Last of Us Part I": 1888930, "Elden Ring": 1245620,
    "Black Myth: Wukong": 2358720, "Cyberpunk 2077": 1091500, "Hades": 1145360,
    "Baldur's Gate 3": 1086940, "Forza Horizon 5": 1551360, "Hollow Knight": 367520,
    "Stardew Valley": 413150, "Celeste": 504230, "The Witcher 3: Wild Hunt": 292030,
    "Red Dead Redemption 2": 1174180, "DOOM Eternal": 782330, "Helldivers 2": 553850,
    "Sekiro: Shadows Die Twice": 814380, "Sid Meier's Civilization VI": 289070,
}
def cover_for(title):
    if title in steam_cover_ids:
        return f"https://cdn.akamai.steamstatic.com/steam/apps/{steam_cover_ids[title]}/library_600x900.jpg"
    if title == "Minecraft": return "https://images.unsplash.com/photo-1607513746994-51f730a44832?w=700&auto=format&fit=crop"
    return "https://images.unsplash.com/photo-1511512578047-dfb367046420?w=700&auto=format&fit=crop"
block("Game (20 rows)", "Game",
      ["game_id", "title", "release_date", "description", "cover_image", "developer_id", "publisher_id"],
      [(i + 1, g[0], d(g[1]), g[5], cover_for(g[0]), dev_id[g[2]], pub_id[g[3]]) for i, g in enumerate(games)],
      "Cover art uses Steam CDN library artwork where available; fallback art is illustrative.")
block("Game_Screenshot (sample screenshots)", "Game_Screenshot",
      ["game_id", "image_url", "caption", "sort_order"],
      [(game_id[n], f"https://cdn.akamai.steamstatic.com/steam/apps/{steam_cover_ids[n]}/header.jpg", "Official game artwork", 1)
       for n in steam_cover_ids if n in game_id][:12])
gar = [(game_id[g[0]], "ESRB", rating_id[("ESRB", g[4])]) for g in games]
gar += [(game_id[t], "PEGI", rating_id[("PEGI", lbl)]) for t, lbl in PEGI.items()]
gar.sort()
block(f"Game_Age_Rating ({len(gar)} rows)", "Game_Age_Rating",
      ["game_id", "rating_authority", "age_rating_id"], gar,
      "ESRB classes checked against esrb.org for Black Myth: Wukong, Hades, Hollow Knight, "
      "Civilization VI and Helldivers 2; the others and all PEGI classes are from general knowledge.")
gg = [(game_id[g[0]], genre_id[x]) for g in games for x in g[6]]
assert len(gg) == len(set(gg))
block(f"Game_Genre ({len(gg)} rows)", "Game_Genre", ["game_id", "genre_id"], gg)
gpr = [(game_id[g], plat_id[p], d(dt)) for g, lst in game_platforms.items() for p, dt in lst]
block(f"Game_Platform ({len(gpr)} rows)", "Game_Platform",
      ["game_id", "platform_id", "platform_release_date"], gpr,
      "NULL dates mean the release date on that platform is not recorded.")
gm = [(game_id[g[0]], mode_id[x]) for g in games for x in g[7]]
assert len(gm) == len(set(gm))
block(f"Game_Mode_Map ({len(gm)} rows)", "Game_Mode_Map", ["game_id", "mode_id"], gm)
block("User_Game (40 rows)", "User_Game",
      ["user_game_id", "user_id", "game_id", "platform_id", "purchase_date", "purchase_price",
       "baseline_hours", "status_id", "started_at", "completed_at"],
      [(i + 1, user_id[r[0]], game_id[r[1]], plat_id[r[2]], d(r[3]), r[4], baseline[i + 1],
        STATUS_ID[r[5]], d(r[7]), d(r[8])) for i, r in enumerate(UG)],
      "Every (game_id, platform_id) pair exists in Game_Platform (enforced by fk_user_game_supported_platform). "
      "Playtime = baseline_hours + sessions.")
w("-- Shared-progress demo entries for NickMaxima and Dibu2007.")
w("INSERT INTO User_Game (user_game_id, user_id, game_id, platform_id, purchase_date, purchase_price, baseline_hours, status_id, started_at, completed_at) VALUES")
w("  (41, 9, 3, 1, '2026-10-01', 0.00, 34.2, 2, '2026-10-01', NULL),")
w("  (42, 10, 7, 1, '2026-09-15', 0.00, 24.8, 2, '2026-09-15', NULL);")
w("")
block(f"Playtime_Session ({len(sessions)} rows)", "Playtime_Session",
      ["user_game_id", "started_at", "duration_minutes", "note"],
      [(s[0], s[1], s[2], s[3]) for s in sessions])
w("INSERT INTO Playtime_Session (user_game_id, started_at, duration_minutes, note) VALUES")
w("  (41, '2026-11-15 19:30:00', 85, 'Demo friend progress'),")
w("  (42, '2026-11-16 20:00:00', 50, 'Demo friend progress');")
w("")
block("Rating (25 rows)", "Rating",
      ["rating_id", "user_id", "game_id", "rating", "review_text", "review_date"],
      [(i + 1, user_id[r[0]], game_id[r[1]], r[2], r[3], d(r[4])) for i, r in enumerate(RT)],
      "Black Myth: Wukong, Sekiro, Mario Kart 8 Deluxe, DOOM Eternal and Civilization VI have no ratings on purpose.")
block("Achievement (50 rows)", "Achievement",
      ["achievement_id", "game_id", "name", "description", "points", "is_hidden"],
      [(a[0], game_id[a[1]], a[2], a[3], a[4], a[5]) for a in ach_rows],
      "13 games have achievements; the other 7 have none on purpose. Names are illustrative.")
w("UPDATE Achievement SET rarity = CASE WHEN points >= 100 THEN 'LEGENDARY' WHEN points >= 50 THEN 'EPIC' WHEN points >= 25 THEN 'RARE' ELSE 'COMMON' END;")
w("")
block(f"User_Achievement ({len(ua_rows)} rows)", "User_Achievement",
      ["user_game_id", "achievement_id", "game_id", "unlocked_at", "progress", "is_unlocked"],
      ua_rows,
      "Unlocked => timestamp + 100%. Locked => no timestamp + progress below 100.")
w("INSERT INTO User_Achievement (user_game_id, achievement_id, game_id, unlocked_at, progress, is_unlocked)")
w("SELECT 41, achievement_id, game_id, '2026-10-20 12:00:00', 100, 1 FROM Achievement WHERE name = 'Lands Between Explorer';")
w("INSERT INTO User_Achievement (user_game_id, achievement_id, game_id, unlocked_at, progress, is_unlocked)")
w("SELECT 41, achievement_id, game_id, NULL, 70, 0 FROM Achievement WHERE name = 'Shardbearer Slayer';")
w("INSERT INTO User_Achievement (user_game_id, achievement_id, game_id, unlocked_at, progress, is_unlocked)")
w("SELECT 42, achievement_id, game_id, '2026-10-01 12:00:00', 100, 1 FROM Achievement WHERE name = 'Out of the Underworld';")
w("")

# --------------------------------------------------- triggers (after the seed)
AUDITED = {
    "User": (["user_id"], ["user_id", "username", "email", "role_id", "join_date",
                           "profile_picture", "deleted_at"]),
    "Game": (["game_id"], ["game_id", "title", "release_date", "description", "cover_image",
                           "is_upcoming", "developer_id", "publisher_id", "deleted_at"]),
    "User_Game": (["user_game_id"], ["user_game_id", "user_id", "game_id", "platform_id",
                                     "purchase_date", "purchase_price", "baseline_hours",
                                     "status_id", "started_at", "completed_at",
                                     "deleted_at", "row_version"]),
    "Rating": (["rating_id"], ["rating_id", "user_id", "game_id", "rating", "review_text",
                               "review_date", "deleted_at", "row_version"]),
    "User_Achievement": (["user_game_id", "achievement_id"],
                         ["user_game_id", "achievement_id", "unlocked_at", "progress", "is_unlocked"]),
    "Playtime_Session": (["session_id"], ["session_id", "user_game_id", "started_at",
                                          "duration_minutes", "note"]),
}


def jobj(prefix, cols):
    return "JSON_OBJECT(" + ", ".join(f"'{c}', {prefix}.{c}" for c in cols) + ")"


def pk(prefix, pkcols):
    if len(pkcols) == 1:
        return f"CAST({prefix}.{pkcols[0]} AS CHAR)"
    return "CONCAT_WS('-', " + ", ".join(f"{prefix}.{c}" for c in pkcols) + ")"


w("-- ---------------------------------------------------------------------")
w("-- 6. TRIGGERS (installed after the seed data on purpose, see D10)")
w("--    a) optimistic-locking version bump   b) audit trail   c) Audit_Log guard")
w("-- ---------------------------------------------------------------------")
w("")
for t in ("User_Game", "Rating"):
    w(f"CREATE TRIGGER trg_{t.lower()}_bv BEFORE UPDATE ON {t}")
    w("FOR EACH ROW SET NEW.row_version = OLD.row_version + 1;")
    w("")
for t, (pkc, cols) in AUDITED.items():
    base = f"trg_{t.lower()}"
    w(f"CREATE TRIGGER {base}_ai AFTER INSERT ON {t} FOR EACH ROW")
    w(f"  INSERT INTO Audit_Log (table_name, record_pk, action, changed_by, new_values)")
    w(f"  VALUES ('{t}', {pk('NEW', pkc)}, 'INSERT', @app_user_id, {jobj('NEW', cols)});")
    w("")
    w(f"-- UPDATE is logged only when an audited column really changed")
    w(f"CREATE TRIGGER {base}_au AFTER UPDATE ON {t} FOR EACH ROW")
    w(f"  INSERT INTO Audit_Log (table_name, record_pk, action, changed_by, old_values, new_values)")
    w(f"  SELECT '{t}', {pk('NEW', pkc)}, 'UPDATE', @app_user_id, {jobj('OLD', cols)}, {jobj('NEW', cols)}")
    w(f"  FROM DUAL WHERE NOT ({jobj('OLD', cols)} <=> {jobj('NEW', cols)});")
    w("")
    w(f"CREATE TRIGGER {base}_ad AFTER DELETE ON {t} FOR EACH ROW")
    w(f"  INSERT INTO Audit_Log (table_name, record_pk, action, changed_by, old_values)")
    w(f"  VALUES ('{t}', {pk('OLD', pkc)}, 'DELETE', @app_user_id, {jobj('OLD', cols)});")
    w("")
w("DELIMITER $$")
for ev in ("UPDATE", "DELETE"):
    w(f"CREATE TRIGGER trg_audit_log_no_{ev.lower()} BEFORE {ev} ON Audit_Log FOR EACH ROW")
    w("BEGIN")
    w("    IF COALESCE(@gv_allow_audit_scrub, 0) <> 1 THEN")
    w("        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'FORBIDDEN: Audit_Log is append-only';")
    w("    END IF;")
    w("END$$")
w("DELIMITER ;")
w("")
w("-- Server-side age guard: block age-ineligible collection entries even if UI checks are bypassed.")
w("DELIMITER $$")
for event, verb in (("bi", "INSERT"), ("bu", "UPDATE")):
    w(f"CREATE TRIGGER trg_user_game_age_guard_{event} BEFORE {verb} ON User_Game FOR EACH ROW")
    w("BEGIN")
    w("  DECLARE v_age INT DEFAULT 99; DECLARE v_min_age INT DEFAULT 0;")
    w("  SELECT COALESCE(TIMESTAMPDIFF(YEAR,date_of_birth,CURDATE()),99) INTO v_age FROM User WHERE user_id=NEW.user_id;")
    w("  SELECT COALESCE(MAX(ar.minimum_age),0) INTO v_min_age FROM Game_Age_Rating gar JOIN Age_Rating ar ON ar.age_rating_id=gar.age_rating_id WHERE gar.game_id=NEW.game_id;")
    w("  IF v_age < v_min_age THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='FORBIDDEN: this game is restricted by your age profile'; END IF;")
    w("END$$")
w("DELIMITER ;")
w("")
w("-- ---------------------------------------------------------------------")
w("-- 7. SCHEDULED MAINTENANCE")
w("--    Needs event_scheduler=ON (the MySQL 8.0 default).")
w("-- ---------------------------------------------------------------------")
w("CREATE EVENT ev_purge_expired_sessions")
w("  ON SCHEDULE EVERY 1 DAY")
w("  COMMENT 'Deletes login sessions that expired more than 7 days ago'")
w("  DO DELETE FROM Auth_Session WHERE expires_at < UTC_TIMESTAMP() - INTERVAL 7 DAY;")
w("")
w("-- End of schema.sql")

with open(OUT, "w", encoding="utf-8") as f:
    for part in ("01_header_ddl.sql", "02_views.sql", "03_procedures.sql"):
        with open(os.path.join(PARTS, part), encoding="utf-8") as p:
            f.write(p.read())
            f.write("\n")
    f.write("\n".join(out) + "\n")

print("games", len(games), "gar", len(gar), "gg", len(gg), "gp", len(gpr), "gm", len(gm),
      "ug", len(UG), "sessions", len(sessions), "ach", len(ach_rows), "ua", len(ua_rows), "rt", len(RT))
print("wrote", OUT)
