# GameDeck for Quickshell / Wayland

An overlay module for secondary displays (portrait or landscape) that detects active games running on Wayland (Hyprland), displaying dynamic game poster art with ambient backlight effects, live system telemetry (CPU & GPU usage and temperatures), and session / total playtime.

## Features

- **Automatic Game Detection:** Integrates with Hyprland clients and local game libraries (Steam, Lutris, Heroic).
- **Ambient Glow / Backlight:** Concentric radial lighting that reacts to the artwork tones.
- **Hardware Telemetry:** Real-time CPU and GPU usage and temperatures via hardware sensors.
- **Playtime Tracking:** Session chronometer and accumulated playtime statistics.
- **Minimalist Window Controls:** Support for minimizing to a small status bar chip and non-intrusive overlay layers.

## Architecture

- `modules/GameDeck.qml`: Main presentation layer written for Quickshell.
- `modules/GameDeckWindow.qml`: Wayland layershell window definition and screen binding.
- `scripts/game_deck.py`: Background telemetry and active window detection daemon.
- `scripts/games.py`: Steam and launcher library parser.

## Requirements

- [Quickshell](https://outfoxxed.me/quickshell/)
- Hyprland / Wayland compositor
- Python 3 with `Pillow`
