#!/usr/bin/env python3
import json
import subprocess
import time
import io
import os
import sys
import re

GAMES_CACHE_PATH = "/home/renzo/.config/quickshell/caelestia/scripts/games.py"
OUTPUT_STATE_PATH = "/tmp/caelestia_gamedeck.json"
SESSION_TRACK_PATH = "/tmp/caelestia_gamedeck_session.json"

cached_games = []
last_games_load = 0

def load_games():
    global cached_games, last_games_load
    now = time.time()
    if now - last_games_load < 120 and cached_games:
        return cached_games
    try:
        p = subprocess.run(["python3", GAMES_CACHE_PATH], capture_output=True, text=True, timeout=5)
        cached_games = json.loads(p.stdout)
        last_games_load = now
    except Exception:
        pass
    return cached_games

IGNORED_CLASSES = {
    "opera", "google-chrome", "firefox", "chromium", "brave-browser", "zen-browser",
    "foot", "kitty", "alacritty", "konsole", "xterm",
    "org.kde.dolphin", "dolphin", "thunar", "nemo", "nautilus",
    "code", "vscodium", "sublime_text", "org.kde.kate", "gedit",
    "discord", "vesktop", "spotify", "slack", "telegram-desktop",
    "youtube-music-desktop-app", "com.github.th-ch.youtube-music", "feishin", "supersonic", "plexamp"
}

def find_active_game():
    try:
        p = subprocess.run(["hyprctl", "clients", "-j"], capture_output=True, text=True, timeout=2)
        clients = json.loads(p.stdout)
    except Exception:
        return None, None

    games = load_games()
    
    for c in clients:
        c_title = c.get("title", "").strip().lower()
        c_class = c.get("class", "").strip().lower()
        
        if not c_title and not c_class:
            continue

        if c_class in IGNORED_CLASSES:
            continue
            
        for g in games:
            g_name = g.get("name", "").strip().lower()
            if not g_name or len(g_name) < 3:
                continue
            
            # 1. Match Steam App ID
            if "steam_app_" in c_class and str(g.get("id", "")).endswith(c_class.replace("steam_app_", "")):
                return g, c
                
            # 2. Exact match on title or class
            if g_name == c_title or g_name == c_class:
                return g, c

            # 3. Whole game title found inside window title
            pattern = r'\b' + re.escape(g_name) + r'\b'
            if re.search(pattern, c_title):
                return g, c
                
            # 4. If class contains the full game name (e.g. custom launcher classes)
            if len(g_name) >= 4 and g_name in c_class:
                return g, c

    return None, None

ambient_cache = {}

def get_cover_ambient_colors(cover_path):
    if not cover_path or not os.path.exists(cover_path):
        return {"left": "#c07050", "center": "#c05050", "right": "#c04060"}
    
    if cover_path in ambient_cache:
        return ambient_cache[cover_path]

    try:
        from PIL import Image
        img = Image.open(cover_path).convert("RGB")
        w, h = img.size

        # Extract saturated perimeter colors, ignoring text / white highlights
        def extract_edge_color(crop_box):
            crop = img.crop(crop_box)
            # Use small thumbnail for fast analysis
            crop.thumbnail((48, 48), Image.Resampling.BOX)
            try:
                pixels = list(crop.get_flattened_data())
            except AttributeError:
                pixels = list(crop.getdata())
            
            scored = []
            for pixel in pixels:
                r, g, b = pixel[:3]
                max_c = max(r, g, b)
                min_c = min(r, g, b)
                sat = (max_c - min_c) / max(max_c, 1)
                # Filter out pure whites (text), grey washed pixels and pitch darks
                if min_c > 200 or max_c < 30:
                    continue
                # Weight by saturation and luminance
                score = sat * (max_c / 255.0)
                scored.append((score, (r, g, b)))
            
            if scored:
                scored.sort(reverse=True)
                top = [c for s, c in scored[:max(1, len(scored) // 6)]]
                avg_r = sum(c[0] for c in top) // len(top)
                avg_g = sum(c[1] for c in top) // len(top)
                avg_b = sum(c[2] for c in top) // len(top)
                # Boost brightness for clean backlight glow
                m = max(avg_r, avg_g, avg_b, 1)
                scale = max(1.0, 205 / m)
                return f"#{min(255, int(avg_r * scale)):02x}{min(255, int(avg_g * scale)):02x}{min(255, int(avg_b * scale)):02x}"
            return "#c05050"

        # 15% edge strips for perimeter matching
        left_color = extract_edge_color((0, 0, max(1, int(w * 0.18)), h))
        center_color = extract_edge_color((max(0, int(w * 0.25)), 0, min(w, int(w * 0.75)), h))
        right_color = extract_edge_color((max(0, int(w * 0.82)), 0, w, h))

        cols = {
            "left": left_color,
            "center": center_color,
            "right": right_color
        }
        ambient_cache[cover_path] = cols
        return cols
    except Exception:
        return {"left": "#c07050", "center": "#c05050", "right": "#c04060"}

def format_time(seconds):
    hrs = int(seconds // 3600)
    mins = int((seconds % 3600) // 60)
    secs = int(seconds % 60)
    if hrs > 0:
        return f"{hrs:02d}:{mins:02d}:{secs:02d}"
    return f"{mins:02d}:{secs:02d}"

def get_process_uptime(pid):
    if not pid:
        return None
    try:
        p = subprocess.run(["ps", "-o", "etimes=", "-p", str(pid)], capture_output=True, text=True, timeout=1)
        val = p.stdout.strip()
        if val and val.isdigit():
            return int(val)
    except Exception:
        pass
    return None

def read_cpu_stat():
    try:
        with open("/proc/stat", "r") as f:
            fields = [float(x) for x in f.readline().strip().split()[1:]]
        return fields[3], sum(fields)
    except Exception:
        return 0, 0

cached_telemetry = {"cpuUsage": 0, "cpuTemp": 0, "gpuUsage": 0, "gpuTemp": 0}
cached_media = None
last_media_check = 0

def update_media():
    global cached_media
    try:
        p = subprocess.run([
            "playerctl", "metadata", "--format",
            json.dumps({
                "status": "{{status}}",
                "title": "{{title}}",
                "artist": "{{artist}}",
                "album": "{{album}}",
                "artUrl": "{{mpris:artUrl}}"
            })
        ], capture_output=True, text=True, timeout=0.8)
        
        if p.returncode == 0 and p.stdout.strip():
            raw = json.loads(p.stdout.strip())
            if raw.get("status") in ("Playing", "Paused") and raw.get("title"):
                cached_media = {
                    "active": True,
                    "status": raw.get("status"),
                    "title": raw.get("title", ""),
                    "artist": raw.get("artist", "") or raw.get("album", ""),
                    "artUrl": raw.get("artUrl", "")
                }
                return cached_media
    except Exception:
        pass
    cached_media = {"active": False}
    return cached_media
last_cpu_idle, last_cpu_total = read_cpu_stat()

def update_telemetry():
    global cached_telemetry, last_cpu_idle, last_cpu_total
    cpu_usage = cached_telemetry.get("cpuUsage", 0)
    
    # 1. CPU usage
    idle, total = read_cpu_stat()
    if last_cpu_total > 0 and total > last_cpu_total:
        d_idle = idle - last_cpu_idle
        d_total = total - last_cpu_total
        if d_total > 0:
            cpu_usage = int(max(0, min(100, 100.0 * (1.0 - d_idle / d_total))))
    last_cpu_idle, last_cpu_total = idle, total

    # 2. CPU Temp
    cpu_temp = cached_telemetry.get("cpuTemp", 0)
    try:
        p = subprocess.run(["sensors"], capture_output=True, text=True, timeout=0.6)
        m = re.search(r"Tctl:\s+\+([0-9\.]+)°C", p.stdout)
        if m:
            cpu_temp = int(float(m.group(1)))
        else:
            m = re.search(r"temp1:\s+\+([0-9\.]+)°C", p.stdout)
            if m:
                cpu_temp = int(float(m.group(1)))
    except Exception:
        pass

    # 3. GPU Stats
    gpu_usage = cached_telemetry.get("gpuUsage", 0)
    gpu_temp = cached_telemetry.get("gpuTemp", 0)
    try:
        p = subprocess.run(["nvidia-smi", "--query-gpu=utilization.gpu,temperature.gpu", "--format=csv,noheader,nounits"], capture_output=True, text=True, timeout=0.6)
        parts = [x.strip() for x in p.stdout.strip().split(",")]
        if len(parts) >= 2:
            gpu_usage = int(float(parts[0]))
            gpu_temp = int(float(parts[1]))
    except Exception:
        pass

    cached_telemetry = {
        "cpuUsage": cpu_usage,
        "cpuTemp": cpu_temp,
        "gpuUsage": gpu_usage,
        "gpuTemp": gpu_temp
    }
    return cached_telemetry

def stream_loop():
    last_game_check = 0
    last_telem_check = 0
    last_media_check = 0
    game = None
    client = None
    
    while True:
        now = time.time()
        
        if os.path.exists("/tmp/caelestia_gamedeck_force_test.json"):
            try:
                with open("/tmp/caelestia_gamedeck_force_test.json") as f:
                    t_data = json.load(f)
                print(json.dumps(t_data), flush=True)
                time.sleep(0.5)
                continue
            except Exception:
                pass

        if now - last_game_check >= 2.0:
            game, client = find_active_game()
            last_game_check = now
            
        if not game:
            print(json.dumps({"active": False}), flush=True)
            time.sleep(1.0)
            continue
            
        if now - last_telem_check >= 1.2:
            update_telemetry()
            last_telem_check = now

        if now - last_media_check >= 1.5:
            update_media()
            last_media_check = now

        client_pid = client.get("pid") if client else None
        proc_uptime = get_process_uptime(client_pid)
        session_dur = proc_uptime if (proc_uptime is not None and proc_uptime > 0) else 0
        
        ambient = get_cover_ambient_colors(game.get("cover", ""))
        
        total_play = game.get("playtime", 0.0)
        total_str = f"{total_play:.1f} hrs" if total_play > 0 else "Primera vez"

        msg = {
            "active": True,
            "name": game.get("name", "Juego"),
            "cover": game.get("cover", ""),
            "banner": game.get("coverRemote", ""),
            "sessionSeconds": int(session_dur),
            "sessionFormatted": format_time(session_dur),
            "totalPlaytime": total_str,
            "ambient": ambient,
            "telemetry": cached_telemetry,
            "media": cached_media or {"active": False}
        }
        try:
            print(json.dumps(msg), flush=True)
        except (BrokenPipeError, IOError):
            sys.exit(0)
        time.sleep(0.40)

def update_tick():
    game, client = find_active_game()
    now = time.time()
    
    sessions = {}
    if os.path.exists(SESSION_TRACK_PATH):
        try:
            with open(SESSION_TRACK_PATH, "r") as f:
                sessions = json.load(f)
        except Exception:
            sessions = {}

    if not game:
        cleaned = {k: v for k, v in sessions.items() if isinstance(v, dict) and (now - v.get("last_seen", 0) < 300)}
        try:
            with open(SESSION_TRACK_PATH, "w") as f:
                json.dump(cleaned, f)
        except Exception:
            pass

        state = {"active": False}
        with open(OUTPUT_STATE_PATH + ".tmp", "w") as f:
            json.dump(state, f)
        os.replace(OUTPUT_STATE_PATH + ".tmp", OUTPUT_STATE_PATH)
        return state

    game_id = str(game.get("id") or game.get("name"))
    client_pid = client.get("pid") if client else None
    proc_uptime = get_process_uptime(client_pid)
    
    sess = sessions.get(game_id) if isinstance(sessions.get(game_id), dict) else None
    
    if sess and (now - sess.get("last_seen", now) < 180):
        start_time = sess.get("start", now)
    else:
        start_time = now - (proc_uptime if proc_uptime else 0)
        
    sessions[game_id] = {
        "start": start_time,
        "last_seen": now
    }
    try:
        with open(SESSION_TRACK_PATH, "w") as f:
            json.dump(sessions, f)
    except Exception:
        pass
        
    if proc_uptime is not None and proc_uptime > 0:
        session_dur = proc_uptime
    else:
        session_dur = max(0, now - start_time)
        
    ambient = get_cover_ambient_colors(game.get("cover", ""))
    telem = update_telemetry()
    media = update_media()
    
    total_play = game.get("playtime", 0.0)
    total_str = f"{total_play:.1f} hrs" if total_play > 0 else "Primera vez"

    state = {
        "active": True,
        "name": game.get("name", "Juego"),
        "cover": game.get("cover", ""),
        "banner": game.get("coverRemote", ""),
        "sessionSeconds": int(session_dur),
        "sessionFormatted": format_time(session_dur),
        "totalPlaytime": total_str,
        "ambient": ambient,
        "telemetry": telem,
        "media": media
    }
    
    with open(OUTPUT_STATE_PATH + ".tmp", "w") as f:
        json.dump(state, f)
    os.replace(OUTPUT_STATE_PATH + ".tmp", OUTPUT_STATE_PATH)
    return state

if __name__ == "__main__":
    if "--stream" in sys.argv:
        stream_loop()
    else:
        res = update_tick()
        print(json.dumps(res, indent=2))
