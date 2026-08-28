import QtQuick
import QtQuick.Layouts
import Quickshell

// Contenuto dell'elenco servizi, separato dalla finestra che lo ospita (stesso
// schema di Dashboard.qml).
Rectangle {
    id: win

    property string scope: "user"
    property string query: ""

    // I preferiti in cima, il resto nell'ordine che arriva da systemctl. La
    // ricerca restringe l'elenco ma non tocca l'ordine: chi cerca "blue" e ha
    // bluetooth fra i preferiti se lo ritrova dov'e' abituato a guardare.
    readonly property var filtered: {
        const list = Services.list(win.scope);
        const q = win.query.trim().toLowerCase();
        const found = q === "" ? list : list.filter(s => s.name.toLowerCase().includes(q) || (s.description ?? "").toLowerCase().includes(q));
        const fav = found.filter(s => Settings.isFavService(win.scope, s.name));
        if (fav.length === 0)
            return found;
        return fav.concat(found.filter(s => !Settings.isFavService(win.scope, s.name)));
    }

    // Dove finiscono i preferiti: e' l'indice della prima riga che non lo e',
    // e la riga che ci capita sopra si porta la linea di separazione.
    readonly property int favCount: win.filtered.filter(s => Settings.isFavService(win.scope, s.name)).length

    implicitWidth: 560
    implicitHeight: 660
    color: "#0d1117"

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 12
        spacing: 10

        // ------------------------------------------------ selettore ambito
        RowLayout {
            Layout.fillWidth: true
            spacing: 6

            // Le etichette restano in italiano nel modello e si traducono nel
            // Text piu' sotto: dentro il modello la traduzione ci sarebbe
            // anche, ma al cambio di lingua il Repeater ricostruirebbe i
            // pulsanti invece di riscriverli.
            Repeater {
                model: [
                    {
                        id: "user",
                        label: "Utente"
                    },
                    {
                        id: "system",
                        label: "Sistema"
                    }
                ]

                Rectangle {
                    required property var modelData

                    readonly property bool current: win.scope === modelData.id

                    implicitWidth: 88
                    implicitHeight: 26
                    radius: 6
                    color: current ? "#21262d" : "transparent"
                    border.width: 1
                    border.color: current ? "#58a6ff" : "#30363d"

                    Text {
                        anchors.centerIn: parent
                        color: parent.current ? "#58a6ff" : "#8b949e"
                        font.pixelSize: 11
                        text: I18n.t(parent.modelData.label)
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: win.scope = parent.modelData.id
                    }
                }
            }

            Item {
                Layout.fillWidth: true
            }

            Text {
                color: "#6e7681"
                font.pixelSize: 10
                text: Services.loading ? "aggiornamento…" : `${win.filtered.length} di ${Services.list(win.scope).length}`
            }

            Rectangle {
                implicitWidth: 26
                implicitHeight: 26
                radius: 6
                color: reloadArea.containsMouse ? "#21262d" : "transparent"
                border.width: 1
                border.color: "#30363d"

                Text {
                    anchors.centerIn: parent
                    color: "#8b949e"
                    font.pixelSize: 13
                    text: "⟳"
                }

                MouseArea {
                    id: reloadArea

                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: Services.refresh()
                }
            }
        }

        // ------------------------------------------------------- ricerca
        Rectangle {
            Layout.fillWidth: true
            implicitHeight: 32
            radius: 6
            color: "#0d1117"
            border.width: 1
            border.color: search.activeFocus ? "#58a6ff" : "#30363d"

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 10
                anchors.rightMargin: 8
                spacing: 6

                Text {
                    color: "#6e7681"
                    font.pixelSize: 12
                    text: "⌕"
                }

                TextInput {
                    id: search

                    Layout.fillWidth: true
                    clip: true
                    color: "#c9d1d9"
                    font.pixelSize: 12
                    selectionColor: "#1f6feb"
                    selectedTextColor: "#ffffff"
                    focus: true
                    onTextChanged: win.query = text
                    Keys.onEscapePressed: text = ""

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: search.text === ""
                        color: "#484f58"
                        font.pixelSize: 12
                        text: I18n.t("cerca per nome o descrizione…")
                    }
                }

                Text {
                    visible: search.text !== ""
                    color: "#6e7681"
                    font.pixelSize: 12
                    text: "✕"

                    MouseArea {
                        anchors.fill: parent
                        anchors.margins: -4
                        cursorShape: Qt.PointingHandCursor
                        onClicked: search.text = ""
                    }
                }
            }
        }

        // --------------------------------------------------------- elenco
        ListView {
            id: list

            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            model: win.filtered
            spacing: 1
            // Un elenco lungo scorre meglio senza inerzia elastica.
            boundsBehavior: Flickable.StopAtBounds

            delegate: ServiceRow {
                required property var modelData
                required property int index

                width: list.width
                service: modelData
                scope: win.scope
                divider: win.favCount > 0 && index === win.favCount
            }

            ScrollBar {
                anchors.right: parent.right
                height: parent.height
                view: list
            }

            Text {
                anchors.centerIn: parent
                visible: list.count === 0 && !Services.loading
                color: "#484f58"
                font.pixelSize: 12
                text: win.query === "" ? "nessun servizio" : `nessun risultato per "${win.query}"`
            }
        }

        // --------------------------------------------------------- footer
        Text {
            Layout.fillWidth: true
            visible: Services.lastError !== ""
            wrapMode: Text.Wrap
            maximumLineCount: 2
            elide: Text.ElideRight
            color: "#f85149"
            font.pixelSize: 10
            text: Services.lastError
        }

        Text {
            Layout.fillWidth: true
            color: "#484f58"
            font.pixelSize: 9
            text: win.scope === "system" ? "I servizi di sistema richiedono l'autenticazione: GNOME chiede la password." : "Servizi della tua sessione: nessuna autenticazione richiesta."
        }
    }
}
