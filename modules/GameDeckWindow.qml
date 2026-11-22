pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Io

Variants {
    id: windowVariants

    // Screen selection: checks config.json if present, otherwise auto-detects secondary/portrait monitor
    model: {
        const screens = Quickshell.screens;
        if (screens.length === 1) return screens;
        // Prioritize explicit names or secondary vertical / DP monitors
        const target = screens.filter(s => s.name === "DP-3" || (s.model && s.model.toLowerCase().includes("arzopa")));
        if (target.length > 0) return target;
        // Fallback: any screen that is portrait or secondary
        const portrait = screens.filter(s => s.height > s.width);
        if (portrait.length > 0) return portrait;
        return [screens[screens.length - 1]];
    }

    PanelWindow {
        id: win

        required property ShellScreen modelData
        screen: modelData

        WlrLayershell.exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

        anchors.top: true
        anchors.bottom: true
        anchors.left: true
        anchors.right: true

        color: "transparent"

        visible: deck.gameActive && !deck.isClosed

        mask: (!deck.gameActive || deck.isClosed) ? emptyRegion : (deck.isMinimized ? chipRegion : null)

        Region {
            id: emptyRegion
            width: 0
            height: 0
        }

        Region {
            id: chipRegion
            x: win.width - 320
            y: 15
            width: 310
            height: 50
        }

        GameDeck {
            id: deck
            screen: win.modelData
            anchors.fill: parent
        }
    }
}
