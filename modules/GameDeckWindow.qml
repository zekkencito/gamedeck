pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.components.containers
import qs.services

Variants {
    model: Quickshell.screens.filter(s => s.name === "DP-3" || (s.model && s.model.toLowerCase().includes("arzopa")))

    StyledWindow {
        id: win

        required property ShellScreen modelData
        screen: modelData
        name: "arzopa-gamedeck"

        WlrLayershell.exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

        anchors.top: true
        anchors.bottom: true
        anchors.left: true
        anchors.right: true

        color: "transparent"
        surfaceFormat.opaque: false

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
