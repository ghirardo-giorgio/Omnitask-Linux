import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

// La finestra della chat con Hermes: tutta la conversazione, con il respiro
// che il pannello non ha. Il pannello Comando IA resta snello — pulsanti,
// trascrizione, stato — e qui sta la conversazione per intera.
//
// La fonte e' il file che scripts/hermes_chat.py riscrive a ogni scambio
// (~/.cache/quickshell/hermes-chat.json): FileView lo tiene sotto controllo,
// quindi una risposta nuova compare da sola mentre la finestra e' aperta.
// Un file che manca vale conversazione vuota, non un guasto.
MemoryWindow {
    id: win

    title: I18n.t("Hermes")
    key: "hermes"
    defaultWidth: 460
    defaultHeight: 540

    // [{role: "user"|"assistant", content: "..."}] — lo stesso formato che
    // va all'API di LM Studio.
    property var history: []

    readonly property int scambi: Math.floor(win.history.length / 2)

    FileView {
        path: Quickshell.env("HOME") + "/.cache/quickshell/hermes-chat.json"
        watchChanges: true
        onFileChanged: reload()
        onLoaded: {
            try {
                const data = JSON.parse(this.text());
                win.history = Array.isArray(data) ? data : [];
            } catch (e) {
                win.history = [];
            }
        }
        onLoadFailed: () => win.history = []
    }

    ColumnLayout {
        id: column

        anchors.fill: parent
        anchors.margins: 12
        spacing: 8

        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            Text {
                color: "#c9d1d9"
                font.pixelSize: 11
                font.letterSpacing: 1
                text: "HERMES · " + win.scambi
            }

            Item {
                Layout.fillWidth: true
            }

            // Lo stesso interruttore del pannello: e' il singleton Tts a
            // tenere lo stato, quindi i due si muovono insieme.
            TtsButton {
            }

            Text {
                color: resetArea.containsMouse ? "#388bfd" : "#6e7681"
                font.pixelSize: 10
                text: I18n.t("nuova conversazione")

                MouseArea {
                    id: resetArea

                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: resetProc.running = true
                }
            }
        }

        Flickable {
            id: chatFlick

            Layout.fillWidth: true
            Layout.fillHeight: true
            contentWidth: width
            clip: true

            // si resta sul fondo: la risposta nuova e' quella che conta
            onContentHeightChanged:
                contentY = Math.max(0, contentHeight - height)

            ColumnLayout {
                width: chatFlick.width
                spacing: 6

                Repeater {
                    model: win.history

                    delegate: Rectangle {
                        required property int index
                        required property var modelData

                        readonly property bool mine: modelData.role === "user"

                        Layout.fillWidth: true
                        implicitHeight: msgText.implicitHeight + 12
                        radius: 8
                        color: mine ? "#1d1608" : "#161b22"
                        border.width: 1
                        border.color: mine ? "#7a5c1f" : "#30363d"

                        Text {
                            id: msgText

                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.top: parent.top
                            anchors.margins: 6
                            wrapMode: Text.Wrap
                            horizontalAlignment: parent.mine ? Text.AlignRight : Text.AlignLeft
                            color: parent.mine ? "#e3b341" : "#c9d1d9"
                            font.pixelSize: 12
                            text: modelData.content ?? ""
                        }
                    }
                }

                Item {
                    Layout.fillHeight: true
                }
            }
        }
    }

    Process {
        id: resetProc

        command: ["python3", PluginPaths.of("scripts/hermes_chat.py"), "reset"]
    }
}
