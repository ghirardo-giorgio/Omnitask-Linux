import QtQuick
import QtQuick.Layouts
import Quickshell

// Un guasto che si ripara con un comando, detto per intero: cosa non va, e la
// riga da incollare nel terminale col tasto per copiarla.
//
// Sta in un file suo perche' serve in due finestre — Processi e Rete
// raccontano lo stesso permesso mancante da due punti di vista — e le due
// devono mostrare esattamente lo stesso comando: e' proprio quando la riga si
// scrive due volte che le due copie divergono.
//
// Il comando viaggia separato dalla spiegazione (vedi CONN_FIX in procmon.py):
// chi lo incolla vuole il comando, non la prosa che lo introduce.
ColumnLayout {
    id: root

    // riga di apertura, in evidenza: cosa e' successo
    property string headline: ""
    // perche', e cosa lo risolve
    property string explanation: ""
    // la riga da incollare, l'unica cosa che finisce negli appunti
    property string command: ""

    spacing: 4

    Text {
        Layout.fillWidth: true
        visible: root.headline.length > 0
        wrapMode: Text.Wrap
        color: "#c9d1d9"
        font.pixelSize: 12
        text: root.headline
    }

    Text {
        Layout.fillWidth: true
        visible: root.explanation.length > 0
        wrapMode: Text.Wrap
        color: "#8b949e"
        font.pixelSize: 11
        text: root.explanation
    }

    Rectangle {
        Layout.fillWidth: true
        visible: root.command.length > 0
        implicitHeight: 30
        radius: 6
        color: "#161b22"
        border.width: 1
        border.color: "#30363d"

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 10
            anchors.rightMargin: 4
            spacing: 6

            Text {
                Layout.fillWidth: true
                elide: Text.ElideRight
                color: "#c9d1d9"
                font.pixelSize: 11
                font.family: "monospace"
                text: root.command
            }

            Rectangle {
                id: copyButton

                // "copiato" e' uno stato transitorio: il tasto torna com'era
                // dopo un momento (come il copy PID della finestra Processi)
                property bool copied: false

                implicitWidth: copyLabel.implicitWidth + 14
                implicitHeight: 22
                radius: 4
                color: copyButton.copied ? "#132033" : copyHover.hovered ? "#21262d" : "transparent"
                border.width: 1
                border.color: copyButton.copied ? "#1f6feb" : "#30363d"

                HoverHandler {
                    id: copyHover

                    cursorShape: Qt.PointingHandCursor
                }

                Text {
                    id: copyLabel

                    anchors.centerIn: parent
                    color: copyButton.copied ? "#58a6ff" : "#8b949e"
                    font.pixelSize: 11
                    // il glifo di copia non sta in ogni font, ma Qt lo va a
                    // cercare da solo in quelli installati quando manca
                    font.family: "monospace"
                    text: copyButton.copied ? "✓" : "⧉"
                }

                Timer {
                    id: copyReset

                    interval: 1200
                    onTriggered: copyButton.copied = false
                }

                TapHandler {
                    onTapped: {
                        Quickshell.clipboardText = root.command;
                        copyButton.copied = true;
                        copyReset.restart();
                    }
                }
            }
        }
    }
}
