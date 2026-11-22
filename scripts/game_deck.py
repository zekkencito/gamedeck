#!/usr/bin/env python3
import json
import subprocess
import time
import io
import os
import sys
import re

SCRIPT_DIR = os.path.dirname(os.path.realpath(__file__))
GAMES_CACHE_PATH = os.path.join(SCRIPT_DIR, "games.py")
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
    "discord", "vesktop", "spotify", "slack", "telegram-desktop"
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

def get_ambient_colors(monitor="HDMI-A-1"):
    try:
        from PIL import Image
        p = subprocess.run(["grim", "-o", monitor, "-s", "0.01", "-"], capture_output=True, timeout=1.5)
        if not p.stdout:
            return {"left": "#63452f", "center": "#956b44", "right": "#ad8956"}
        img = Image.open(io.BytesIO(p.stdout)).convert("RGB")
        resized = img.resize((3, 1), Image.Resampling.BILINEAR)

        def norm_rgb(c, target_bright=175):
            r, g, b = c
            m = max(r, g, b)
            if m == 0:
                return 80, 80, 80
            scale = max(1.0, target_bright / m)
            return min(255, int(r * scale)), min(255, int(g * scale)), min(255, int(b * scale))

        cl = norm_rgb(resized.getpixel((0, 0)))
        cc = norm_rgb(resized.getpixel((1, 0)))
        cr = norm_rgb(resized.getpixel((2, 0)))

        return {
            "left": f"#{cl[0]:02x}{cl[1]:02x}{cl[2]:02x}",
            "center": f"#{cc[0]:02x}{cc[1]:02x}{cc[2]:02x}",
            "right": f"#{cr[0]:02x}{cr[1]:02x}{cr[2]:02x}"
        }
    except Exception:
        return {"left": "#63452f", "center": "#956b44", "right": "#ad8956"}

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

        client_pid = client.get("pid") if client else None
        proc_uptime = get_process_uptime(client_pid)
        session_dur = proc_uptime if (proc_uptime is not None and proc_uptime > 0) else 0
        
        ambient = get_ambient_colors("HDMI-A-1")
        
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
            "telemetry": cached_telemetry
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
        
    ambient = get_ambient_colors("HDMI-A-1")
    telem = update_telemetry()
    
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
        "telemetry": telem
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
