pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import Caelestia.Config
import qs.components
import qs.services

Item {
    id: root

    required property ShellScreen screen

    property bool gameActive: false
    property bool isMinimized: false
    property bool isClosed: false
    property string currentGameId: ""

    property string gameName: ""
    property string gameCover: ""
    property int sessionSeconds: 0
    property string sessionTime: formatSeconds(sessionSeconds)
    property string totalTime: "0 hrs"

    // Extended Hardware & Game Telemetry
    property int cpuUsage: 0
    property int cpuTemp: 0
    property real cpuWatts: 0
    property int gpuUsage: 0
    property int gpuTemp: 0
    property real gpuWatts: 0
    property real totalWatts: 0
    property real vramUsed: 0
    property real vramTotal: 8.0
    property int gameFps: 0
    property real frameTime: 0
    property bool hasFps: false
    property string insightPacing: "STABLE"
    property string insightHeadroom: "BALANCED"
    property string insightDiag: "SYSTEM NOMINAL"
    property string insightLevel: "normal"

    // Media Player Integration (MPRIS)
    property bool mediaActive: false
    property string mediaStatus: "Paused"
    property string mediaTitle: ""
    property string mediaArtist: ""
    property string mediaArtUrl: ""

    // Continuous media watcher (Instant playerctl event-driven stream, 0ms latency)
    Process {
        id: mediaStreamProcess
        command: ["playerctl", "--follow", "metadata", "--format", "{\"status\":\"{{status}}\",\"title\":\"{{markup_escape(title)}}\",\"artist\":\"{{markup_escape(artist)}}\",\"album\":\"{{markup_escape(album)}}\",\"artUrl\":\"{{mpris:artUrl}}\"}"]
        running: true
        stdout: SplitParser {
            onRead: line => {
                const text = line.trim();
                if (!text) return;
                try {
                    const d = JSON.parse(text);
                    if (d.status === "Playing" || d.status === "Paused") {
                        root.mediaActive = true;
                        root.mediaStatus = d.status;
                        root.mediaTitle = d.title || "";
                        root.mediaArtist = d.artist || d.album || "";
                        root.mediaArtUrl = d.artUrl || "";
                    } else {
                        root.mediaActive = false;
                    }
                } catch(e) {}
            }
        }
    }

    // 3-Zone Ambient LED Light Colors (Sampled from HDMI-A-1)
    property color ambientLeft: "#4457af"
    property color ambientCenter: "#4457af"
    property color ambientRight: "#465daf"

    // Auto-brightness controller: triggers maximum hardware brightness when deck is active
    readonly property bool isDeckActive: root.gameActive && !root.isClosed && !root.isMinimized
    onIsDeckActiveChanged: {
        const action = root.isDeckActive ? "max" : "restore";
        Quickshell.execDetached(["sh", `${Quickshell.shellDir}/scripts/arzopa_brightness.sh`, action]);
    }

    anchors.fill: parent

    function formatSeconds(sec) {
        const hrs = Math.floor(sec / 3600);
        const mins = Math.floor((sec % 3600) / 60);
        const s = sec % 60;
        const pad = function(n) { return n < 10 ? "0" + n : "" + n; };
        if (hrs > 0)
            return pad(hrs) + ":" + pad(mins) + ":" + pad(s);
        return pad(mins) + ":" + pad(s);
    }

    // Chronometer: Increments smoothly once every second in pure QML (Zero CPU overhead)
    Timer {
        id: chronometer
        interval: 1000
        repeat: true
        running: root.gameActive && !root.isClosed
        onTriggered: {
            root.sessionSeconds++;
        }
    }

    // Responsive, silky smooth color gliding for real-time Ambilight reaction
    Behavior on ambientLeft { ColorAnimation { duration: 400; easing.type: Easing.OutQuad } }
    Behavior on ambientCenter { ColorAnimation { duration: 400; easing.type: Easing.OutQuad } }
    Behavior on ambientRight { ColorAnimation { duration: 400; easing.type: Easing.OutQuad } }

    // Continuous real-time ambient stream process (Unbuffered pipe, zero-lag updates)
    Process {
        id: streamProcess

        command: ["python3", "-u", `${Quickshell.shellDir}/scripts/game_deck.py`, "--stream"]
        running: true
        stdout: SplitParser {
            onRead: line => {
                const text = line.trim();
                if (!text)
                    return;
                try {
                    const data = JSON.parse(text);
                    const isNowActive = data.active ?? false;
                    root.gameActive = isNowActive;

                    if (isNowActive) {
                        const newId = data.name || "game";
                        if (newId !== root.currentGameId) {
                            root.currentGameId = newId;
                            root.isMinimized = false;
                            root.isClosed = false;
                            root.sessionSeconds = data.sessionSeconds ?? 0;
                        } else {
                            if (data.sessionSeconds !== undefined) {
                                root.sessionSeconds = data.sessionSeconds;
                            }
                        }

                        root.gameName = data.name || "Active Game";
                        root.gameCover = data.cover || "";
                        root.totalTime = data.totalPlaytime || "";
                        if (data.ambient) {
                            root.ambientLeft = data.ambient.left || root.ambientLeft;
                            root.ambientCenter = data.ambient.center || root.ambientCenter;
                            root.ambientRight = data.ambient.right || root.ambientRight;
                        }
                        if (data.telemetry) {
                            const t = data.telemetry;
                            root.cpuUsage = t.cpuUsage ?? root.cpuUsage;
                            root.cpuTemp = t.cpuTemp ?? root.cpuTemp;
                            root.cpuWatts = t.cpuWatts ?? root.cpuWatts;
                            root.gpuUsage = t.gpuUsage ?? root.gpuUsage;
                            root.gpuTemp = t.gpuTemp ?? root.gpuTemp;
                            root.gpuWatts = t.gpuWatts ?? root.gpuWatts;
                            root.totalWatts = t.totalWatts ?? (root.gpuWatts + root.cpuWatts);
                            root.vramUsed = t.vramUsed ?? root.vramUsed;
                            root.vramTotal = t.vramTotal ?? root.vramTotal;
                            root.gameFps = t.fps ?? 0;
                            root.frameTime = t.frametime ?? 0;
                            root.hasFps = (t.fps !== undefined && t.fps !== null && t.fps > 0);
                            if (t.insight) {
                                root.insightPacing = t.insight.pacing || "STABLE";
                                root.insightHeadroom = t.insight.headroom || "BALANCED";
                                root.insightDiag = t.insight.diag || "SYSTEM NOMINAL";
                                root.insightLevel = t.insight.level || "normal";
                            }
                        }
                    } else {
                        root.currentGameId = "";
                        root.sessionSeconds = 0;
                    }
                } catch (e) {
                    // Ignore parse errors
                }
            }
        }
    }

    // -------------------------------------------------------------
    // MAIN FULLSCREEN GAME DECK CONTAINER (100% Surface Coverage)
    // -------------------------------------------------------------
    Item {
        id: deckContainer
        anchors.fill: parent

        readonly property bool shouldShow: root.gameActive && !root.isMinimized && !root.isClosed
        opacity: shouldShow ? 1.0 : 0.0
        visible: opacity > 0.001

        Behavior on opacity {
            NumberAnimation { duration: 350; easing.type: Easing.InOutCubic }
        }

        // --- LAYER -1: 100% OPAQUE SOLID BASE (Completely hides desktop wallpaper) ---
        Rectangle {
            anchors.fill: parent
            color: "#08090c"
        }

        // --- LAYER 0: Rich Full-Bleed Blurred Cover Art (Vibrant, Radiant Background) ---
        Image {
            id: bgBlurImage
            anchors.fill: parent
            source: root.gameCover ? (root.gameCover.startsWith("/") ? "file://" + root.gameCover : root.gameCover) : ""
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            smooth: true
            mipmap: true
            opacity: 0.70

            layer.enabled: true
            layer.effect: MultiEffect {
                blurEnabled: true
                blur: 1.0
                blurMax: 64
                saturation: 1.10
            }
        }

        // --- LAYER 1: Cinematic Soft Vignette Scrim (Preserves Cover Vibrancy & Text Legibility) ---
        Rectangle {
            anchors.fill: parent
            gradient: Gradient {
                GradientStop { position: 0.0; color: Qt.rgba(0.02, 0.03, 0.05, 0.32) }
                GradientStop { position: 0.45; color: Qt.rgba(0.02, 0.03, 0.05, 0.48) }
                GradientStop { position: 0.75; color: Qt.rgba(0.02, 0.03, 0.05, 0.62) }
                GradientStop { position: 1.0; color: Qt.rgba(0.02, 0.03, 0.05, 0.74) }
            }
        }

        // --- LAYER 2: Monitor edge ambilight removed (Reactive LEDs now encircle the poster card) ---

        // --- TOP BAR: Header & Window Controls (Minimize & Close) ---
        RowLayout {
            anchors.top: parent.top
            anchors.topMargin: 36
            anchors.left: parent.left
            anchors.leftMargin: 44
            anchors.right: parent.right
            anchors.rightMargin: 44
            z: 20

            // Live status badge
            RowLayout {
                spacing: 10

                // Live dot indicator
                Rectangle {
                    width: 8
                    height: 8
                    radius: 4
                    color: "#22c55e"

                    SequentialAnimation on opacity {
                        loops: Animation.Infinite
                        NumberAnimation { from: 0.4; to: 1.0; duration: 1200; easing.type: Easing.InOutQuad }
                        NumberAnimation { from: 1.0; to: 0.4; duration: 1200; easing.type: Easing.InOutQuad }
                    }
                }
            }

            Item { Layout.fillWidth: true }

            // Action Buttons: Minimize & Close
            RowLayout {
                spacing: 12

                // Minimize Button
                Rectangle {
                    id: minBtn
                    Layout.preferredWidth: 36
                    Layout.preferredHeight: 36
                    radius: 18
                    color: minMouseArea.containsMouse ? Qt.rgba(1, 1, 1, 0.25) : Qt.rgba(0, 0, 0, 0.40)
                    border.width: 1
                    border.color: Qt.rgba(1, 1, 1, 0.20)
                    Behavior on color { ColorAnimation { duration: 150 } }

                    Text {
                        anchors.centerIn: parent
                        anchors.verticalCenterOffset: -2
                        text: "—"
                        font.pixelSize: 13
                        font.bold: true
                        color: minMouseArea.containsMouse ? "#ffffff" : Qt.rgba(1, 1, 1, 0.85)
                    }

                    MouseArea {
                        id: minMouseArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            root.isMinimized = true;
                        }
                    }
                }

                // Close Button
                Rectangle {
                    id: closeBtn
                    Layout.preferredWidth: 36
                    Layout.preferredHeight: 36
                    radius: 18
                    color: closeMouseArea.containsMouse ? Qt.rgba(0.9, 0.2, 0.2, 0.55) : Qt.rgba(0, 0, 0, 0.40)
                    border.width: 1
                    border.color: closeMouseArea.containsMouse ? Qt.rgba(0.9, 0.3, 0.3, 0.7) : Qt.rgba(1, 1, 1, 0.20)
                    Behavior on color { ColorAnimation { duration: 150 } }

                    Text {
                        anchors.centerIn: parent
                        text: "✕"
                        font.pixelSize: 13
                        font.bold: true
                        color: closeMouseArea.containsMouse ? "#ffffff" : Qt.rgba(1, 1, 1, 0.85)
                    }

                    MouseArea {
                        id: closeMouseArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            root.isClosed = true;
                        }
                    }
                }
            }
        }

        // --- CONTENT COLUMN ---
        ColumnLayout {
            anchors.fill: parent
            anchors.topMargin: 120
            anchors.bottomMargin: 40
            anchors.leftMargin: 40
            anchors.rightMargin: 40
            spacing: 0
            z: 10

            // Hero Artwork Poster (Imposing Cinema Scale with Natural Bulb Backlight Falloff)
            Item {
                Layout.alignment: Qt.AlignHCenter
                Layout.fillWidth: true
                Layout.preferredHeight: 1120

                // --- NATURAL BULB PROJECTION (Continuous concentric radial falloff, ZERO square seams) ---
                Item {
                    id: posterBacklight
                    anchors.centerIn: heroCard
                    width: heroCard.width + 300
                    height: heroCard.height + 300
                    z: 0

                    // Organic breathing pulse
                    SequentialAnimation on opacity {
                        loops: Animation.Infinite
                        running: root.gameActive && !root.isClosed
                        NumberAnimation { from: 0.55; to: 1.0; duration: 2400; easing.type: Easing.InOutSine }
                        NumberAnimation { from: 1.0; to: 0.55; duration: 2400; easing.type: Easing.InOutSine }
                    }

                    // 1. Core Light Bloom (Intense base glow directly behind the card)
                    Rectangle {
                        anchors.centerIn: parent
                        width: heroCard.width + 48
                        height: heroCard.height + 48
                        radius: heroCard.radius + 24
                        opacity: 0.70

                        gradient: Gradient {
                            orientation: Gradient.Horizontal
                            GradientStop { position: 0.0; color: root.ambientLeft }
                            GradientStop { position: 0.5; color: root.ambientCenter }
                            GradientStop { position: 1.0; color: root.ambientRight }
                        }
                    }

                    // 2. Mid Dispersion Aura (Medium reach, perfectly curved corners)
                    Rectangle {
                        anchors.centerIn: parent
                        width: heroCard.width + 150
                        height: heroCard.height + 150
                        radius: heroCard.radius + 75
                        opacity: 0.45

                        gradient: Gradient {
                            orientation: Gradient.Horizontal
                            GradientStop { position: 0.0; color: root.ambientLeft }
                            GradientStop { position: 0.5; color: root.ambientCenter }
                            GradientStop { position: 1.0; color: root.ambientRight }
                        }
                    }

                    // 3. Wide Ambient Halo (Long exponential fade into darkness)
                    Rectangle {
                        anchors.centerIn: parent
                        width: heroCard.width + 280
                        height: heroCard.height + 280
                        radius: heroCard.radius + 140
                        opacity: 0.25

                        gradient: Gradient {
                            orientation: Gradient.Horizontal
                            GradientStop { position: 0.0; color: root.ambientLeft }
                            GradientStop { position: 0.5; color: root.ambientCenter }
                            GradientStop { position: 1.0; color: root.ambientRight }
                        }
                    }

                    layer.enabled: true
                    layer.effect: MultiEffect {
                        blurEnabled: true
                        blur: 1.0
                        blurMax: 64
                    }
                }

                // Clean Floating Poster Card (Pure Opaque Card, ZERO Glow or Neon Rim on the poster)
                Rectangle {
                    id: heroCard
                    anchors.centerIn: parent
                    width: Math.min(parent.width * 0.88, Math.round(parent.height * 0.70))
                    height: parent.height
                    radius: 28
                    color: Qt.rgba(0.04, 0.05, 0.08, 0.98)
                    clip: true
                    border.width: 1
                    border.color: Qt.rgba(1, 1, 1, 0.14)
                    z: 2

                    Image {
                        id: heroImage
                        anchors.fill: parent
                        source: root.gameCover ? (root.gameCover.startsWith("/") ? "file://" + root.gameCover : root.gameCover) : ""
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                        smooth: true
                        mipmap: true
                    }

                    layer.enabled: true
                    layer.effect: MultiEffect {
                        shadowEnabled: true
                        shadowColor: Qt.rgba(0, 0, 0, 0.65)
                        shadowBlur: 0.8
                        shadowVerticalOffset: 16
                    }
                }
            }

            // Dedicated Vertical Separation between Cover Art and Telemetry Data
            Item {
                Layout.preferredHeight: 80
                Layout.fillWidth: true
            }

            // Prominent Hardware & Chrono Cluster (Sits comfortably directly over the blurred backdrop - NO Glass Box!)
            Item {
                Layout.alignment: Qt.AlignHCenter
                Layout.preferredWidth: Math.min(parent.width * 0.90, 840)
                Layout.preferredHeight: 450

                ColumnLayout {
                    anchors.fill: parent
                    spacing: 22

                    // ROW 1: Real-Time FPS & System Power Draw
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 0

                        // FPS & Frametime (Left Column)
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 6

                            Text {
                                text: "REALTIME FRAMERATE"
                                font.pixelSize: 12
                                font.letterSpacing: 2.5
                                font.weight: Font.Bold
                                color: Qt.rgba(0.82, 0.88, 0.96, 0.75)
                                style: Text.Raised
                                styleColor: Qt.rgba(0, 0, 0, 0.75)
                            }

                            RowLayout {
                                spacing: 8
                                Text {
                                    text: root.hasFps ? (root.gameFps + " FPS") : (root.gpuUsage + "% LOAD")
                                    font.pixelSize: 34
                                    font.family: "monospace"
                                    font.weight: Font.Bold
                                    color: "#ffffff"
                                    style: Text.Raised
                                    styleColor: Qt.rgba(0, 0, 0, 0.75)
                                }
                                Text {
                                    visible: root.hasFps
                                    text: "•  " + root.frameTime.toFixed(1) + " MS"
                                    font.pixelSize: 18
                                    font.family: "monospace"
                                    font.weight: Font.DemiBold
                                    color: Qt.rgba(0.72, 0.82, 0.95, 0.65)
                                    Layout.alignment: Qt.AlignBaseline
                                }
                            }
                        }

                        // Vertical Divider
                        Item {
                            Layout.preferredWidth: 80
                            Layout.preferredHeight: 52

                            Rectangle {
                                anchors.centerIn: parent
                                width: 1
                                height: parent.height
                                color: Qt.rgba(1, 1, 1, 0.22)
                            }
                        }

                        // Power Consumption (Right Column)
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 6

                            Text {
                                text: "SYSTEM POWER DRAW"
                                font.pixelSize: 12
                                font.letterSpacing: 2.5
                                font.weight: Font.Bold
                                color: Qt.rgba(0.82, 0.88, 0.96, 0.75)
                                style: Text.Raised
                                styleColor: Qt.rgba(0, 0, 0, 0.75)
                            }

                            RowLayout {
                                spacing: 8
                                Text {
                                    text: Math.round(root.totalWatts) + " W"
                                    font.pixelSize: 34
                                    font.family: "monospace"
                                    font.weight: Font.Bold
                                    color: "#ffffff"
                                    style: Text.Raised
                                    styleColor: Qt.rgba(0, 0, 0, 0.75)
                                }
                                Text {
                                    text: "• GPU " + Math.round(root.gpuWatts) + "W"
                                    font.pixelSize: 18
                                    font.family: "monospace"
                                    font.weight: Font.DemiBold
                                    color: Qt.rgba(0.72, 0.82, 0.95, 0.65)
                                    Layout.alignment: Qt.AlignBaseline
                                }
                            }
                        }
                    }

                    // Horizontal Hairline Divider
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 1
                        color: Qt.rgba(1, 1, 1, 0.16)
                    }

                    // ROW 2: Hardware Load, Thermals & VRAM
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 0

                        // CPU Stats (Left Column)
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 6

                            Text {
                                text: "CPU LOAD & TEMP"
                                font.pixelSize: 12
                                font.letterSpacing: 2.5
                                font.weight: Font.Bold
                                color: Qt.rgba(0.82, 0.88, 0.96, 0.75)
                                style: Text.Raised
                                styleColor: Qt.rgba(0, 0, 0, 0.75)
                            }

                            Text {
                                text: root.cpuUsage + "%  •  " + root.cpuTemp + "°C"
                                font.pixelSize: 34
                                font.family: "monospace"
                                font.weight: Font.Bold
                                color: "#ffffff"
                                style: Text.Raised
                                styleColor: Qt.rgba(0, 0, 0, 0.75)
                            }
                        }

                        // Vertical Divider
                        Item {
                            Layout.preferredWidth: 80
                            Layout.preferredHeight: 52

                            Rectangle {
                                anchors.centerIn: parent
                                width: 1
                                height: parent.height
                                color: Qt.rgba(1, 1, 1, 0.22)
                            }
                        }

                        // GPU & VRAM Stats (Right Column)
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 6

                            Text {
                                text: "GPU LOAD, TEMP & VRAM"
                                font.pixelSize: 12
                                font.letterSpacing: 2.5
                                font.weight: Font.Bold
                                color: Qt.rgba(0.82, 0.88, 0.96, 0.75)
                                style: Text.Raised
                                styleColor: Qt.rgba(0, 0, 0, 0.75)
                            }

                            Text {
                                text: root.gpuUsage + "%  •  " + root.gpuTemp + "°C" + (root.vramUsed > 0 ? ("  •  " + root.vramUsed.toFixed(1) + "G") : "")
                                font.pixelSize: 34
                                font.family: "monospace"
                                font.weight: Font.Bold
                                color: "#ffffff"
                                style: Text.Raised
                                styleColor: Qt.rgba(0, 0, 0, 0.75)
                            }
                        }
                    }

                    // Horizontal Hairline Divider with spacious separation
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 1
                        color: Qt.rgba(1, 1, 1, 0.16)
                    }

                    // ROW 3: Gaming Time (Session Chrono & Total Playtime)
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 0

                        // Session Chronograph (Left Column)
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 6

                            Text {
                                text: "CURRENT SESSION"
                                font.pixelSize: 12
                                font.letterSpacing: 2.5
                                font.weight: Font.Bold
                                color: Qt.rgba(0.82, 0.88, 0.96, 0.75)
                                style: Text.Raised
                                styleColor: Qt.rgba(0, 0, 0, 0.75)
                            }

                            Text {
                                text: root.sessionTime
                                font.pixelSize: 34
                                font.family: "monospace"
                                font.weight: Font.Bold
                                color: "#ffffff"
                                style: Text.Raised
                                styleColor: Qt.rgba(0, 0, 0, 0.75)
                            }
                        }

                        // Vertical Divider
                        Item {
                            Layout.preferredWidth: 80
                            Layout.preferredHeight: 52

                            Rectangle {
                                anchors.centerIn: parent
                                width: 1
                                height: parent.height
                                color: Qt.rgba(1, 1, 1, 0.22)
                            }
                        }

                        // Total Recorded Time (Right Column)
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 6

                            Text {
                                text: "TOTAL RECORDED TIME"
                                font.pixelSize: 12
                                font.letterSpacing: 2.5
                                font.weight: Font.Bold
                                color: Qt.rgba(0.82, 0.88, 0.96, 0.75)
                                style: Text.Raised
                                styleColor: Qt.rgba(0, 0, 0, 0.75)
                            }

                            Text {
                                text: root.totalTime.toUpperCase()
                                font.pixelSize: 34
                                font.family: "monospace"
                                font.weight: Font.Bold
                                color: Qt.rgba(0.92, 0.95, 1.0, 0.95)
                                style: Text.Raised
                                styleColor: Qt.rgba(0, 0, 0, 0.75)
                            }
                        }
                    }

                    // Horizontal Hairline Divider
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 1
                        color: Qt.rgba(1, 1, 1, 0.16)
                    }

                    // ROW 4: Frame Pacing & Hardware Balance
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 0

                        // Frame Pacing (Left Column)
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 6

                            Text {
                                text: "FRAME PACING"
                                font.pixelSize: 12
                                font.letterSpacing: 2.5
                                font.weight: Font.Bold
                                color: Qt.rgba(0.82, 0.88, 0.96, 0.75)
                                style: Text.Raised
                                styleColor: Qt.rgba(0, 0, 0, 0.75)
                            }

                            Text {
                                text: root.insightPacing
                                font.pixelSize: 34
                                font.family: "monospace"
                                font.weight: Font.Bold
                                color: "#ffffff"
                                style: Text.Raised
                                styleColor: Qt.rgba(0, 0, 0, 0.75)
                            }
                        }

                        // Vertical Divider
                        Item {
                            Layout.preferredWidth: 80
                            Layout.preferredHeight: 52

                            Rectangle {
                                anchors.centerIn: parent
                                width: 1
                                height: parent.height
                                color: Qt.rgba(1, 1, 1, 0.22)
                            }
                        }

                        // Hardware Headroom (Right Column)
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 6

                            Text {
                                text: "HARDWARE HEADROOM"
                                font.pixelSize: 12
                                font.letterSpacing: 2.5
                                font.weight: Font.Bold
                                color: Qt.rgba(0.82, 0.88, 0.96, 0.75)
                                style: Text.Raised
                                styleColor: Qt.rgba(0, 0, 0, 0.75)
                            }

                            Text {
                                text: root.insightHeadroom
                                font.pixelSize: 34
                                font.family: "monospace"
                                font.weight: Font.Bold
                                color: root.insightLevel === "warn" ? "#fbbf24" : "#ffffff"
                                style: Text.Raised
                                styleColor: Qt.rgba(0, 0, 0, 0.75)
                            }
                        }
                    }

                    // Technical Diagnostic Strip (Razor-flat terminal architecture, strictly anti-pill)
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 34
                        radius: 4
                        color: Qt.rgba(0.04, 0.05, 0.08, 0.92)
                        border.width: 1
                        border.color: root.insightLevel === "warn" ? Qt.rgba(0.95, 0.65, 0.20, 0.40) : Qt.rgba(1, 1, 1, 0.12)

                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 16
                            anchors.rightMargin: 16
                            spacing: 12

                            Text {
                                text: "[SYS.DIAG]"
                                font.pixelSize: 11
                                font.letterSpacing: 1.5
                                font.weight: Font.Bold
                                font.family: "monospace"
                                color: root.insightLevel === "warn" ? "#fbbf24" : Qt.rgba(0.60, 0.70, 0.85, 0.65)
                            }

                            Rectangle {
                                Layout.preferredWidth: 1
                                Layout.preferredHeight: 14
                                color: Qt.rgba(1, 1, 1, 0.18)
                            }

                            Text {
                                Layout.fillWidth: true
                                text: root.insightDiag
                                font.pixelSize: 12
                                font.family: "monospace"
                                font.weight: Font.DemiBold
                                font.letterSpacing: 1.0
                                elide: Text.ElideRight
                                color: root.insightLevel === "warn" ? "#fef08a" : Qt.rgba(0.88, 0.92, 0.98, 0.88)
                            }
                        }
                    }
                }
            }

            // Espaciador para bajar la pastilla de musica
            Item {
                Layout.preferredHeight: 48
                visible: root.mediaActive
            }

            // --- PREMIUM HAPTIC MEDIA DOCK (Machined Nested Pill, Pure Visual Clarity) ---
            Item {
                Layout.alignment: Qt.AlignHCenter
                Layout.preferredWidth: Math.min(parent.width * 0.90, 840)
                Layout.preferredHeight: 76
                visible: root.mediaActive
                opacity: root.mediaActive ? 1.0 : 0.0

                Behavior on opacity {
                    NumberAnimation { duration: 250; easing.type: Easing.OutCubic }
                }

                // Outer machined tray (Double bezel architecture)
                Rectangle {
                    anchors.fill: parent
                    radius: 38
                    color: Qt.rgba(0.04, 0.05, 0.08, 0.92)
                    border.width: 1
                    border.color: Qt.rgba(1, 1, 1, 0.12)

                    layer.enabled: true
                    layer.effect: MultiEffect {
                        shadowEnabled: true
                        shadowColor: Qt.rgba(0, 0, 0, 0.55)
                        shadowBlur: 0.6
                        shadowVerticalOffset: 6
                    }

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 12
                        anchors.rightMargin: 16
                        spacing: 14

                        // Album Artwork Capsule
                        Rectangle {
                            Layout.preferredWidth: 52
                            Layout.preferredHeight: 52
                            radius: 26
                            color: "#181a22"
                            clip: true
                            border.width: 1
                            border.color: Qt.rgba(1, 1, 1, 0.14)

                            Image {
                                anchors.fill: parent
                                source: root.mediaArtUrl
                                fillMode: Image.PreserveAspectCrop
                                asynchronous: true
                                smooth: true
                            }
                        }

                        // Track Details
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 3

                            Text {
                                text: root.mediaTitle
                                font.pixelSize: 14
                                font.bold: true
                                font.letterSpacing: 0.2
                                color: "#ffffff"
                                elide: Text.ElideRight
                                Layout.fillWidth: true
                            }

                            Text {
                                text: root.mediaArtist
                                font.pixelSize: 11
                                font.letterSpacing: 0.5
                                color: Qt.rgba(0.85, 0.90, 1.0, 0.60)
                                elide: Text.ElideRight
                                Layout.fillWidth: true
                            }
                        }

                        // Transport Controls
                        RowLayout {
                            spacing: 10

                            // Previous
                            Rectangle {
                                id: prevBtn
                                Layout.preferredWidth: 36
                                Layout.preferredHeight: 36
                                radius: 18
                                color: prevArea.containsMouse ? (prevArea.pressed ? Qt.rgba(1, 1, 1, 0.20) : Qt.rgba(1, 1, 1, 0.12)) : Qt.rgba(1, 1, 1, 0.06)
                                border.width: 1
                                border.color: Qt.rgba(1, 1, 1, 0.10)
                                scale: prevArea.pressed ? 0.92 : 1.0
                                Behavior on scale { NumberAnimation { duration: 80 } }
                                Behavior on color { ColorAnimation { duration: 120 } }

                                Canvas {
                                    anchors.centerIn: parent
                                    width: 12
                                    height: 12
                                    onPaint: {
                                        const ctx = getContext("2d");
                                        ctx.reset();
                                        ctx.fillStyle = "#ffffff";
                                        // Bar
                                        ctx.fillRect(0, 1, 2, 10);
                                        // Left arrow
                                        ctx.beginPath();
                                        ctx.moveTo(12, 1);
                                        ctx.lineTo(3, 6);
                                        ctx.lineTo(12, 11);
                                        ctx.closePath();
                                        ctx.fill();
                                    }
                                }

                                MouseArea {
                                    id: prevArea
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: Quickshell.execDetached(["playerctl", "previous"])
                                }
                            }

                            // Play / Pause (Hero CTA Button)
                            Rectangle {
                                id: playBtn
                                Layout.preferredWidth: 44
                                Layout.preferredHeight: 44
                                radius: 22
                                color: playArea.containsMouse ? (playArea.pressed ? "#e2e6f0" : "#ffffff") : "#f4f6fb"
                                scale: playArea.pressed ? 0.88 : 1.0
                                Behavior on scale { NumberAnimation { duration: 80 } }
                                Behavior on color { ColorAnimation { duration: 120 } }

                                Canvas {
                                    id: playCanvas
                                    anchors.centerIn: parent
                                    anchors.horizontalCenterOffset: root.mediaStatus === "Playing" ? 0 : 1
                                    width: 14
                                    height: 14

                                    Connections {
                                        target: root
                                        function onMediaStatusChanged() { playCanvas.requestPaint(); }
                                    }

                                    onPaint: {
                                        const ctx = getContext("2d");
                                        ctx.reset();
                                        ctx.fillStyle = "#0c0d12";
                                        if (root.mediaStatus === "Playing") {
                                            ctx.fillRect(1, 1, 3.5, 12);
                                            ctx.fillRect(8.5, 1, 3.5, 12);
                                        } else {
                                            ctx.beginPath();
                                            ctx.moveTo(2, 0);
                                            ctx.lineTo(13, 7);
                                            ctx.lineTo(2, 14);
                                            ctx.closePath();
                                            ctx.fill();
                                        }
                                    }
                                }

                                MouseArea {
                                    id: playArea
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        Quickshell.execDetached(["playerctl", "play-pause"]);
                                    }
                                }
                            }

                            // Next
                            Rectangle {
                                id: nextBtn
                                Layout.preferredWidth: 36
                                Layout.preferredHeight: 36
                                radius: 18
                                color: nextArea.containsMouse ? (nextArea.pressed ? Qt.rgba(1, 1, 1, 0.20) : Qt.rgba(1, 1, 1, 0.12)) : Qt.rgba(1, 1, 1, 0.06)
                                border.width: 1
                                border.color: Qt.rgba(1, 1, 1, 0.10)
                                scale: nextArea.pressed ? 0.92 : 1.0
                                Behavior on scale { NumberAnimation { duration: 80 } }
                                Behavior on color { ColorAnimation { duration: 120 } }

                                Canvas {
                                    anchors.centerIn: parent
                                    width: 12
                                    height: 12
                                    onPaint: {
                                        const ctx = getContext("2d");
                                        ctx.reset();
                                        ctx.fillStyle = "#ffffff";
                                        // Right arrow
                                        ctx.beginPath();
                                        ctx.moveTo(0, 1);
                                        ctx.lineTo(9, 6);
                                        ctx.lineTo(0, 11);
                                        ctx.closePath();
                                        ctx.fill();
                                        // Bar
                                        ctx.fillRect(10, 1, 2, 10);
                                    }
                                }

                                MouseArea {
                                    id: nextArea
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: Quickshell.execDetached(["playerctl", "next"])
                                }
                            }
                        }
                    }
                }
            }

            // Lower breathing room for relaxed spatial harmony and Ambilight underglow
            Item { Layout.fillHeight: true }
        }
    }

    // -------------------------------------------------------------
    // MINIMIZED FLOATING PILL (Restore & Close inside Pill)
    // -------------------------------------------------------------
    Rectangle {
        id: restoreChip
        anchors.top: parent.top
        anchors.topMargin: 20
        anchors.right: parent.right
        anchors.rightMargin: 20
        z: 99

        readonly property bool shouldShowChip: root.gameActive && root.isMinimized && !root.isClosed
        opacity: shouldShowChip ? 1.0 : 0.0
        visible: opacity > 0.001

        Behavior on opacity {
            NumberAnimation { duration: 250 }
        }

        implicitWidth: chipRow.implicitWidth + 24
        implicitHeight: 38
        radius: 19
        color: Qt.rgba(0.08, 0.1, 0.15, 0.90)
        border.width: 1
        border.color: Qt.rgba(1, 1, 1, 0.18)

        layer.enabled: true
        layer.effect: MultiEffect {
            shadowEnabled: true
            shadowColor: Qt.rgba(0, 0, 0, 0.5)
            shadowBlur: 0.5
            shadowVerticalOffset: 4
        }

        RowLayout {
            id: chipRow
            anchors.centerIn: parent
            spacing: 10

            // Clickable pill body to restore
            MouseArea {
                id: restoreMouseArea
                Layout.preferredHeight: 36
                Layout.preferredWidth: restoreInnerRow.implicitWidth
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                    root.isMinimized = false;
                }

                RowLayout {
                    id: restoreInnerRow
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 8

                    Rectangle {
                        width: 7
                        height: 7
                        radius: 3.5
                        color: "#22c55e"
                    }

                    Text {
                        text: root.gameName + "  •  " + root.sessionTime
                        color: restoreMouseArea.containsMouse ? "#ffffff" : "#f1f5f9"
                        font.pixelSize: 12
                        font.weight: Font.Medium
                    }

                    Text {
                        text: "↗"
                        color: restoreMouseArea.containsMouse ? "#ffffff" : Qt.rgba(1, 1, 1, 0.6)
                        font.pixelSize: 12
                        font.bold: true
                    }
                }
            }

            // Divider
            Rectangle {
                Layout.preferredWidth: 1
                Layout.preferredHeight: 18
                color: Qt.rgba(1, 1, 1, 0.2)
            }

            // Direct Close Button inside the pill
            Rectangle {
                Layout.preferredWidth: 22
                Layout.preferredHeight: 22
                radius: 11
                color: chipCloseArea.containsMouse ? Qt.rgba(0.9, 0.2, 0.2, 0.5) : "transparent"

                Text {
                    anchors.centerIn: parent
                    text: "✕"
                    font.pixelSize: 11
                    font.bold: true
                    color: chipCloseArea.containsMouse ? "#ffffff" : Qt.rgba(1, 1, 1, 0.65)
                }

                MouseArea {
                    id: chipCloseArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        root.isClosed = true;
                    }
                }
            }
        }
    }
}
