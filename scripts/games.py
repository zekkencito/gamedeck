#!/usr/bin/env python3
"""Aggregate installed and owned games from Steam, Lutris and Heroic.

Read-only. Prints a JSON array to stdout, one object per game:
    id, name, source (steam|lutris|heroic), installed, runner,
    developer, playtime (hours), lastPlayed (unix ts),
    cover (local path or ""), coverRemote (URL or ""),
    launch (argv array for execDetached).

Order: installed first (by last played desc), then uninstalled (by name).
"""

import glob
import json
import os
import sqlite3
import sys

HOME = os.path.expanduser("~")
STEAM_ROOT = os.path.join(HOME, ".local/share/Steam")
LUTRIS_ROOT = os.path.join(HOME, ".local/share/lutris")
HEROIC_CONFIG = os.path.join(HOME, ".config/heroic")

STEAM_TOOL_KEYWORDS = (
    "proton",
    "linux runtime",
    "source sdk",
    "steamworks",
    "steam sdk",
    "redistributable",
    "retail",
    "dedicated server",
)

LUTRIS_LAUNCHER_SLUGS = {
    "epic-games-store",
    "ubisoft-connect",
    "ludusavi",
    "steam",
    "galaxy",
}

HEROIC_REDIST = {
    "gog-redist",
}


def exists(*parts):
    return os.path.isfile(os.path.join(*parts))


def cover_or_none(*parts):
    return os.path.join(*parts) if exists(*parts) else ""


def fmt_time(ts):
    try:
        return int(ts or 0)
    except (TypeError, ValueError):
        return 0


def fmt_float(value):
    try:
        return round(float(value or 0), 3)
    except (TypeError, ValueError):
        return 0.0


# ---------------------------------------------------------------- Steam ----
def read_steam():
    games = []
    try:
        import vdf  # noqa: PLC0415

        library_root = STEAM_ROOT
        try:
            folders = vdf.load(open(os.path.join(STEAM_ROOT, "steamapps/libraryfolders.vdf")))
            roots = [f["path"] for f in folders.get("libraryfolders", {}).values() if isinstance(f, dict) and f.get("path")]
        except Exception:
            roots = []
        roots = [STEAM_ROOT] + [r for r in roots if r and r != STEAM_ROOT]

        for root in roots:
            for manifest in sorted(glob.glob(os.path.join(root, "steamapps/appmanifest_*.acf"))):
                try:
                    app = vdf.load(open(manifest))["AppState"]
                except Exception:
                    continue
                appid = str(app.get("appid", ""))
                name = str(app.get("name", ""))
                if not appid or not name:
                    continue
                if any(k in name.lower() for k in STEAM_TOOL_KEYWORDS):
                    continue
                installed = bool(int(app.get("StateFlags", 0) or 0) & 4)
                if not installed:
                    continue
                cover = cover_or_none(root, "appcache/librarycache/%s/library_600x900.jpg" % appid)
                if not cover:
                    cover = cover_or_none(root, "appcache/librarycache/%s/header.jpg" % appid)
                games.append({
                    "id": "steam-%s" % appid,
                    "name": name,
                    "source": "steam",
                    "installed": True,
                    "runner": "steam",
                    "developer": "",
                    "playtime": 0.0,
                    "lastPlayed": fmt_time(app.get("LastPlayed")),
                    "cover": cover,
                    "coverRemote": "",
                    "launch": ["steam", "steam://rungameid/%s" % appid],
                })
    except Exception as exc:
        sys.stderr.write("steam: %s\n" % exc)
    return games


# ---------------------------------------------------------------- Lutris ---
def read_lutris():
    games = []
    db_path = os.path.join(LUTRIS_ROOT, "pga.db")
    if not os.path.isfile(db_path):
        return games
    try:
        conn = sqlite3.connect("file:%s?mode=ro" % db_path, uri=True)
        rows = conn.execute(
            "SELECT id, name, slug, runner, service, service_id, installed, "
            "playtime, lastplayed FROM games ORDER BY name"
        ).fetchall()
        conn.close()
    except Exception as exc:
        sys.stderr.write("lutris: %s\n" % exc)
        return games

    for row in rows:
        gid, name, slug, runner, service, service_id, installed, playtime, lastplayed = row
        if slug in LUTRIS_LAUNCHER_SLUGS:
            continue
        cover = cover_or_none(LUTRIS_ROOT, "coverart/%s.png" % slug)
        if not cover:
            cover = cover_or_none(LUTRIS_ROOT, "coverart/%s.jpg" % slug)
        if not cover:
            cover = cover_or_none(LUTRIS_ROOT, "banners/%s.png" % slug)
        if not cover:
            cover = cover_or_none(LUTRIS_ROOT, "banners/%s.jpg" % slug)
        if not cover:
            cover = cover_or_none(HOME, ".cache/lutris/steam/covers/%s.jpg" % slug)
        if not cover:
            cover = cover_or_none(HOME, ".cache/lutris/egs/game_box_tall/%s.jpg" % slug)
        entry = {
            "id": "lutris-%s" % slug,
            "name": name,
            "source": "lutris",
            "installed": bool(installed),
            "runner": runner or "wine",
            "developer": "",
            "playtime": fmt_float(playtime),
            "lastPlayed": fmt_time(lastplayed),
            "cover": cover,
            "coverRemote": "",
            "launch": ["lutris", "lutris:rungame/%s" % slug],
        }
        if service == "steam" and service_id:
            entry["steamAppid"] = str(service_id)
        games.append(entry)
    return games


# ---------------------------------------------------------------- Heroic ---
def read_heroic():
    games = []
    try:
        with open(os.path.join(HEROIC_CONFIG, "store_cache/legendary_library.json")) as f:
            lib = json.load(f)
        entries = lib.get("library", [])
        installed_legendary = _heroic_installed("legendaryConfig/legendary/installed.json")
        for entry in entries:
            app_name = str(entry.get("app_name", ""))
            title = str(entry.get("title", ""))
            if not app_name or not title:
                continue
            if entry.get("is_dlc"):
                continue
            cover = cover_or_none(HEROIC_CONFIG, "icons/%s.jpg" % app_name)
            games.append({
                "id": "heroic-%s" % app_name,
                "name": title,
                "source": "heroic",
                "installed": app_name in installed_legendary,
                "runner": "legendary",
                "developer": str(entry.get("developer") or ""),
                "playtime": 0.0,
                "lastPlayed": 0,
                "cover": cover,
                "coverRemote": str(entry.get("art_cover") or entry.get("art_square") or ""),
                "launch": ["heroic", app_name],
            })
    except Exception as exc:
        sys.stderr.write("heroic legendary: %s\n" % exc)

    try:
        with open(os.path.join(HEROIC_CONFIG, "store_cache/gog_library.json")) as f:
            lib = json.load(f)
        entries = lib.get("games", []) or lib.get("library", [])
        installed_gog = _heroic_installed("gog_store/installed.json")
        for entry in entries:
            app_name = str(entry.get("app_name", ""))
            title = str(entry.get("title", ""))
            if not app_name or not title:
                continue
            if app_name in HEROIC_REDIST:
                continue
            cover = cover_or_none(HEROIC_CONFIG, "icons/%s.jpg" % app_name)
            games.append({
                "id": "heroic-%s" % app_name,
                "name": title,
                "source": "heroic",
                "installed": app_name in installed_gog,
                "runner": "gog",
                "developer": str(entry.get("developer") or ""),
                "playtime": 0.0,
                "lastPlayed": 0,
                "cover": cover,
                "coverRemote": str(entry.get("art_cover") or entry.get("art_square") or ""),
                "launch": ["heroic", app_name],
            })
    except Exception as exc:
        sys.stderr.write("heroic gog: %s\n" % exc)
    return games


def _heroic_installed(rel_path):
    try:
        with open(os.path.join(HEROIC_CONFIG, rel_path)) as f:
            data = json.load(f)
        if isinstance(data, dict):
            if "installed" in data:
                data = data["installed"]
            elif isinstance(data, dict) and "app_name" in data:
                data = [data]
            else:
                return set(data.keys())
        return {str(i.get("app_name", "")) for i in data}
    except Exception:
        return set()


# ---------------------------------------------------------------- Quiver ---
QUIVER_CONFIG = os.path.join(HOME, ".local/share/com.quiverlauncher.app")
PORTS_DIR = os.path.join(HOME, "Disco Games/Games/Ports")


def read_quiver():
    games = []
    installs_path = os.path.join(QUIVER_CONFIG, "installs.json")
    catalog_path = os.path.join(QUIVER_CONFIG, "catalog.json")
    if not os.path.isfile(installs_path) or not os.path.isfile(catalog_path):
        return games
    try:
        with open(installs_path) as f:
            installs = json.load(f)
        with open(catalog_path) as f:
            catalog = json.load(f)
        for port_id, inst in installs.items():
            cat_info = catalog.get(port_id, {})
            name = cat_info.get("name") or inst.get("folder")
            folder = inst.get("folder", "")
            execs = inst.get("executables", [])
            exe_name = execs[0] if execs else "totk"
            exe_path = os.path.join(PORTS_DIR, folder, exe_name)

            cover = cover_or_none(PORTS_DIR, folder, "art/cover.png")
            if not cover:
                cover = cover_or_none(PORTS_DIR, folder, "art/icon.png")
            cover_remote = (
                cat_info.get("libraryArt", {}).get("cover")
                or cat_info.get("artwork")
                or ""
            )

            games.append({
                "id": "quiver-%s" % port_id,
                "name": name,
                "source": "quiver",
                "installed": os.path.exists(exe_path),
                "runner": "port",
                "developer": str(cat_info.get("developer", {}).get("name") or "Port"),
                "playtime": 0.0,
                "lastPlayed": fmt_time(inst.get("lastPlayed")),
                "cover": cover,
                "coverRemote": cover_remote,
                "launch": [exe_path] if os.path.isfile(exe_path) else [],
            })
    except Exception as exc:
        sys.stderr.write("quiver: %s\n" % exc)
    return games


# ---------------------------------------------------------------- Merge ----
def merge(steam, lutris, heroic, quiver=()):
    result = list(lutris)
    steam_appids = {g["id"].split("-", 1)[1] for g in steam}
    result.extend(steam)
    result.extend(heroic)
    result.extend(quiver)

    # Dedup by steam appid first (for steam-linked lutris rows), then by name.
    seen = {}
    for g in result:
        if g["source"] == "lutris" and g.get("steamAppid") in steam_appids:
            continue
        key = g["name"].lower()
        if key in seen:
            prev = seen[key]
            prefer_prev = (prev["installed"] and not g["installed"]) or (
                prev["installed"] == g["installed"] and _source_rank(prev) <= _source_rank(g)
            )
            if not prefer_prev:
                seen[key] = g
        else:
            seen[key] = g
    merged = list(seen.values())

    merged.sort(key=lambda g: (0 if g["installed"] else 1, -(g["lastPlayed"] or 0), g["name"].lower()))
    return merged


def _source_rank(g):
    return {"lutris": 0, "quiver": 1, "steam": 2, "heroic": 3}.get(g["source"], 4)


def main():
    steam = read_steam()
    lutris = read_lutris()
    heroic = read_heroic()
    quiver = read_quiver()
    games = merge(steam, lutris, heroic, quiver)
    json.dump(games, sys.stdout, ensure_ascii=False)


if __name__ == "__main__":
    main()
