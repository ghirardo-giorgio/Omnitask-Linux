import QtQuick
import QtQuick.Layouts

// Una riga dell'elenco processi: nome e riga di comando a sinistra,
// le cinque misure rigidamente incolonnate a destra.
Rectangle {
    id: row

    required property var process

    // Larghezza condivisa da tutte le colonne numeriche.
    property int metricWidth: 74

    // Larghezza massima della parte dedicata al processo.
    property int nameWidth: 460

    readonly property bool busy: Processes.pending[process.pid] !== undefined
    readonly property bool selected: Processes.isSelected(row.process.pid)
    readonly property bool suspended: row.process.state === "T"

    property bool confirming: false

    // Vero mentre è aperto il menu contestuale.
    property bool menuOpen: false

    signal hovered(int pid)
    signal menuRequested(var process, real x, real y)

    implicitHeight: 38
    radius: 6

    color: row.confirming
           ? "#161b22"
           : row.selected
             ? "#132033"
             : hover.hovered
               ? "#161b22"
               : "transparent"

    border.width: 1

    border.color: row.confirming
                  ? "#f85149"
                  : row.selected
                    ? "#1f6feb"
                    : "transparent"

    opacity: row.busy ? 0.5 : 1

    HoverHandler {
        id: hover

        onHoveredChanged:
            row.hovered(hover.hovered ? row.process.pid : 0)
    }

    // -------------------------------------------------------------
    // Selezione della riga
    // -------------------------------------------------------------

    TapHandler {
        acceptedButtons: Qt.LeftButton
        enabled: !row.menuOpen

        onTapped:
            Processes.toggleSelected(row.process)
    }

    // -------------------------------------------------------------
    // Menu contestuale
    // -------------------------------------------------------------

    TapHandler {
        acceptedButtons: Qt.RightButton
        enabled: !row.menuOpen

        onTapped: eventPoint =>
            row.menuRequested(
                row.process,
                eventPoint.scenePosition.x,
                eventPoint.scenePosition.y
            )
    }

    // =============================================================
    // Layout principale
    //
    // La struttura deve corrispondere esattamente all'intestazione:
    //
    // | checkbox | processo | spazio elastico |
    // | CPU | MEM | GPU | DISCO | RETE | azione |
    // =============================================================

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: 10
        anchors.rightMargin: 12

        spacing: 6

        // ---------------------------------------------------------
        // Checkbox
        // ---------------------------------------------------------

        Rectangle {
            Layout.minimumWidth: 13
            Layout.preferredWidth: 13
            Layout.maximumWidth: 13

            Layout.minimumHeight: 13
            Layout.preferredHeight: 13
            Layout.maximumHeight: 13

            radius: 3

            color: row.selected
                   ? "#1f6feb"
                   : "transparent"

            border.width: 1

            border.color: row.selected
                          ? "#58a6ff"
                          : "#30363d"

            Text {
                anchors.centerIn: parent

                visible: row.selected

                color: "#ffffff"
                font.pixelSize: 9

                text: "✓"
            }
        }

        // ---------------------------------------------------------
        // Colonna processo
        // ---------------------------------------------------------

        ColumnLayout {
            Layout.minimumWidth: 0
            Layout.fillWidth: true
            Layout.maximumWidth: row.nameWidth

            spacing: 0

            RowLayout {
                Layout.fillWidth: true
                Layout.minimumWidth: 0

                spacing: 5

                Text {
                    Layout.fillWidth: true
                    Layout.minimumWidth: 0

                    elide: Text.ElideRight

                    color: "#c9d1d9"
                    font.pixelSize: 12

                    text: row.process.name
                }

                // Di chi e' il processo, ma solo quando non e' mio: scritto
                // su tutte le righe sarebbe il proprio nome ripetuto trecento
                // volte, e la riga che conta smetterebbe di saltare all'occhio.
                Text {
                    visible: !row.process.owned

                    color: row.process.user === "root"
                           ? "#d29922"
                           : "#6e7681"

                    font.pixelSize: 9

                    text: row.process.user ?? ""
                }

                Text {
                    visible: row.suspended

                    color: "#d29922"
                    font.pixelSize: 9

                    text: I18n.t("sospeso")
                }

                Text {
                    id: nice

                    readonly property bool remembered:
                        Settings.priorityFor(row.process.name) > 0

                    Layout.fillWidth: true
                    Layout.minimumWidth: 0

                    visible: (row.process.nice ?? 0) !== 0

                    elide: Text.ElideRight

                    color: nice.remembered
                           ? "#8b949e"
                           : "#6e7681"

                    font.pixelSize: 9

                    text:
                        (nice.remembered ? "⤓ " : "")
                        + I18n.t("priorità %1")
                              .arg(row.process.nice)
                }
            }

            Text {
                Layout.fillWidth: true
                Layout.minimumWidth: 0

                elide: Text.ElideRight

                color: "#484f58"

                font.pixelSize: 9
                font.family: "monospace"

                text:
                    `${row.process.pid} · ${row.process.cmdline}`
            }
        }

        // ---------------------------------------------------------
        // Spazio elastico
        //
        // Assorbe tutto lo spazio rimasto tra la colonna processo
        // e le metriche. Le metriche rimangono quindi sempre
        // appoggiate verso destra.
        // ---------------------------------------------------------

        Item {
            Layout.fillWidth: true
            Layout.minimumWidth: 0
        }

        // ---------------------------------------------------------
        // Conferma chiusura
        //
        // Quando attiva sostituisce temporaneamente le metriche.
        // ---------------------------------------------------------

        RowLayout {
            visible: row.confirming

            spacing: 4

            Rectangle {
                implicitWidth: 46
                implicitHeight: 22

                radius: 4

                color: "#3d1418"

                border.width: 1
                border.color: "#f85149"

                Text {
                    anchors.centerIn: parent

                    color: "#f85149"
                    font.pixelSize: 10

                    text: I18n.t("chiudi")
                }

                MouseArea {
                    anchors.fill: parent

                    cursorShape: Qt.PointingHandCursor

                    onClicked: {
                        Processes.kill(row.process, false)
                        row.confirming = false
                    }
                }
            }

            Rectangle {
                implicitWidth: 42
                implicitHeight: 22

                radius: 4

                color: "#21262d"

                border.width: 1
                border.color: "#6e7681"

                Text {
                    anchors.centerIn: parent

                    color: "#8b949e"
                    font.pixelSize: 10

                    text: I18n.t("forza")
                }

                MouseArea {
                    anchors.fill: parent

                    cursorShape: Qt.PointingHandCursor

                    onClicked: {
                        Processes.kill(row.process, true)
                        row.confirming = false
                    }
                }
            }
        }

    // =========================================================
    // CPU
    // =========================================================

    ColumnLayout {
        Layout.minimumWidth: row.metricWidth
        Layout.preferredWidth: row.metricWidth
        Layout.maximumWidth: row.metricWidth

        visible: !row.confirming

        spacing: 0

        readonly property int threads: SystemStats.cores.length

        // -----------------------------------------------------
        // Valore principale
        //
        // Percentuale rapportata al numero totale di thread.
        // Questo e' il valore colorato mostrato sopra.
        // -----------------------------------------------------

        Text {
            readonly property real normalizedCpu:
                parent.threads > 0
                ? row.process.cpu / parent.threads
                : row.process.cpu

            Layout.fillWidth: true

            horizontalAlignment: Text.AlignRight

            color:
                normalizedCpu > 50
                ? "#f85149"
                : normalizedCpu > 10
                ? "#d29922"
                : "#8b949e"

            font.pixelSize: 11

            text: `${normalizedCpu.toFixed(1)}%`
        }

        // -----------------------------------------------------
        // Valore totale
        //
        // 100% corrisponde a un thread completamente occupato.
        // Questo valore viene mostrato sotto in grigio.
        // -----------------------------------------------------

        Text {
            Layout.fillWidth: true

            visible:
                parent.threads > 0
                && row.process.cpu > 0

            horizontalAlignment: Text.AlignRight

            color: "#484f58"

            font.pixelSize: 9

            text:
                `${row.process.cpu.toFixed(1)}% `
                + I18n.t("total")
        }
    }
        // =========================================================
        // MEMORIA
        // =========================================================

        Text {
            Layout.minimumWidth: row.metricWidth
            Layout.preferredWidth: row.metricWidth
            Layout.maximumWidth: row.metricWidth

            visible: !row.confirming

            horizontalAlignment: Text.AlignRight

            color: "#8b949e"

            font.pixelSize: 11

            text:
                SystemStats.formatBytes(
                    row.process.rss,
                    false
                )
        }

        // =========================================================
        // GPU
        // =========================================================

        ColumnLayout {
            Layout.minimumWidth: row.metricWidth
            Layout.preferredWidth: row.metricWidth
            Layout.maximumWidth: row.metricWidth

            visible: !row.confirming

            spacing: 0

            Text {
                readonly property var gpu:
                    row.process.gpu

                Layout.fillWidth: true

                horizontalAlignment: Text.AlignRight

                color:
                    gpu > 0
                    ? "#a371f7"
                    : "#484f58"

                font.pixelSize: 11

                text:
                    gpu === null
                    || gpu === undefined
                    ? "—"
                    : `${gpu}%`
            }

            Text {
                Layout.fillWidth: true

                visible:
                    (row.process.vram ?? 0) > 0

                horizontalAlignment: Text.AlignRight

                color: "#484f58"

                font.pixelSize: 9

                text:
                    SystemStats.formatBytes(
                        row.process.vram,
                        false
                    )
            }
        }

        // =========================================================
        // DISCO
        // =========================================================

        Text {
            Layout.minimumWidth: row.metricWidth
            Layout.preferredWidth: row.metricWidth
            Layout.maximumWidth: row.metricWidth

            visible: !row.confirming

            horizontalAlignment: Text.AlignRight

            color:
                row.process.io > 0
                ? "#8b949e"
                : "#484f58"

            font.pixelSize: 11

            text:
                row.process.io > 0
                ? SystemStats.formatBytes(
                      row.process.io,
                      true
                  )
                : "—"
        }

        // =========================================================
        // RETE
        // =========================================================

        Text {
            Layout.minimumWidth: row.metricWidth
            Layout.preferredWidth: row.metricWidth
            Layout.maximumWidth: row.metricWidth

            visible: !row.confirming

            horizontalAlignment: Text.AlignRight

            color:
                row.process.net > 0
                ? "#58a6ff"
                : "#484f58"

            font.pixelSize: 11

            text:
                row.process.net === null
                ? "—"
                : row.process.net > 0
                  ? SystemStats.formatBytes(
                        row.process.net,
                        true
                    )
                  : "0"
        }

        // =========================================================
        // Pulsante chiusura
        //
        // Stessa larghezza prevista dall'intestazione.
        // =========================================================

        Rectangle {
            Layout.minimumWidth: 24
            Layout.preferredWidth: 24
            Layout.maximumWidth: 24

            Layout.minimumHeight: 22
            Layout.preferredHeight: 22
            Layout.maximumHeight: 22

            radius: 4

            color:
                closeArea.containsMouse
                ? "#21262d"
                : "transparent"

            opacity:
                row.process.owned
                ? 1
                : 0.35

            Text {
                anchors.centerIn: parent

                color:
                    row.confirming
                    ? "#8b949e"
                    : "#f85149"

                font.pixelSize: 12

                text:
                    row.confirming
                    ? "↩"
                    : "✕"
            }

            MouseArea {
                id: closeArea

                anchors.fill: parent

                hoverEnabled: true

                enabled:
                    row.process.owned
                    && !row.busy

                cursorShape:
                    Qt.PointingHandCursor

                onClicked:
                    row.confirming = !row.confirming
            }
        }
    }
}