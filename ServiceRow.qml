import QtQuick
import QtQuick.Layouts

// Una riga dell'elenco servizi. Tre comandi distinti e volutamente separati:
// il pallino a sinistra avvia/ferma adesso, il pulsante a destra decide se il
// servizio parte da solo all'avvio, la stella in fondo lo tiene in cima
// all'elenco (vedi Settings.favServices) — segnare un preferito non tocca il
// servizio, dice solo dove lo si va a cercare.
Item {
    id: row

    required property var service
    required property string scope

    // Vero per la prima riga non preferita: e' lei a disegnare la linea che
    // chiude il blocco in cima. Lo decide chi conosce l'ordine dell'elenco
    // (vedi ServicesPanel), non la riga.
    property bool divider: false

    readonly property bool running: ["active", "reloading"].includes(service.active)
    readonly property bool transitioning: ["activating", "deactivating"].includes(service.active)
    readonly property bool failed: service.active === "failed"
    readonly property bool enabled_: service.state === "enabled"
    // static/masked/generated non si possono abilitare: non hanno un [Install].
    readonly property bool togglable: ["enabled", "disabled"].includes(service.state)
    readonly property bool busy: Services.pending[service.name] !== undefined
    readonly property bool fav: Settings.isFavService(row.scope, row.service.name)

    // Azione distruttiva in attesa di conferma: "stop" o "disable".
    property string confirming: ""

    implicitHeight: row.divider ? 51 : 42

    // La linea di separazione sta fuori dallo sfondo della riga: dentro, il
    // colore dell'hover ci finirebbe sopra e il blocco dei preferiti si
    // chiuderebbe con una banda invece che con un filo.
    Rectangle {
        visible: row.divider
        height: 1
        color: "#21262d"

        anchors {
            left: parent.left
            right: parent.right
            top: parent.top
            topMargin: 4
            leftMargin: 8
            rightMargin: 12
        }
    }

    Rectangle {
        id: body

        anchors.fill: parent
        anchors.topMargin: row.divider ? 9 : 0
        radius: 6
        color: hover.hovered ? "#161b22" : "transparent"

        HoverHandler {
            id: hover
        }

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 8
            anchors.rightMargin: 12
            spacing: 10

            // --- stato + avvio/arresto ---
            Rectangle {
                implicitWidth: 22
                implicitHeight: 22
                radius: 11
                color: stopArea.containsMouse ? "#21262d" : "transparent"

                Rectangle {
                    anchors.centerIn: parent
                    width: 10
                    height: 10
                    radius: 5
                    color: row.busy ? "#8b949e" : row.failed ? "#f85149" : row.transitioning ? "#d29922" : row.running ? "#3fb950" : "#484f58"

                    SequentialAnimation on opacity {
                        running: row.busy || row.transitioning
                        loops: Animation.Infinite
                        NumberAnimation {
                            to: 0.3
                            duration: 500
                        }
                        NumberAnimation {
                            to: 1
                            duration: 500
                        }
                    }
                }

                MouseArea {
                    id: stopArea

                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    enabled: !row.busy && row.confirming === ""
                    onClicked: {
                        if (row.running)
                            row.confirming = "stop";
                        else
                            Services.act(row.scope, row.service.name, "start");
                    }
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 0

                Text {
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                    color: row.failed ? "#f85149" : "#c9d1d9"
                    font.pixelSize: 12
                    // Il suffisso .service e' uguale per tutti: toglierlo lascia
                    // spazio al nome vero.
                    text: row.service.name.replace(/\.service$/, "")
                }

                Text {
                    Layout.fillWidth: true
                    visible: text !== ""
                    elide: Text.ElideRight
                    color: "#6e7681"
                    font.pixelSize: 10
                    text: row.service.description
                }
            }

            // --- conferma per le azioni distruttive ---
            RowLayout {
                visible: row.confirming !== ""
                spacing: 4

                Text {
                    color: "#8b949e"
                    font.pixelSize: 10
                    text: row.confirming === "stop" ? I18n.t("fermare?") : I18n.t("disattivare?")
                }

                Repeater {
                    model: [
                        {
                            label: I18n.t("sì"),
                            accept: true
                        },
                        {
                            label: I18n.t("no"),
                            accept: false
                        }
                    ]

                    Rectangle {
                        required property var modelData

                        implicitWidth: 26
                        implicitHeight: 20
                        radius: 4
                        color: modelData.accept ? "#3d1418" : "#21262d"
                        border.width: 1
                        border.color: modelData.accept ? "#f85149" : "#30363d"

                        Text {
                            anchors.centerIn: parent
                            color: parent.modelData.accept ? "#f85149" : "#8b949e"
                            font.pixelSize: 10
                            text: parent.modelData.label
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                if (parent.modelData.accept)
                                    Services.act(row.scope, row.service.name, row.confirming);
                                row.confirming = "";
                            }
                        }
                    }
                }
            }

            // --- avvio automatico ---
            Rectangle {
                visible: row.confirming === ""
                implicitWidth: 52
                implicitHeight: 20
                radius: 10
                color: row.enabled_ ? "#12261a" : "transparent"
                border.width: 1
                border.color: row.enabled_ ? "#3fb950" : "#30363d"
                opacity: row.togglable ? 1 : 0.45

                Text {
                    anchors.centerIn: parent
                    color: row.enabled_ ? "#3fb950" : "#6e7681"
                    font.pixelSize: 9
                    text: row.togglable ? (row.enabled_ ? "AUTO" : I18n.t("manuale")) : row.service.state
                }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: row.togglable ? Qt.PointingHandCursor : Qt.ArrowCursor
                    enabled: row.togglable && !row.busy
                    onClicked: {
                        if (row.enabled_)
                            row.confirming = "disable";
                        else
                            Services.act(row.scope, row.service.name, "enable");
                    }
                }
            }

            // --- preferito ---
            // Resta nel layout anche quando non si vede: nasconderla farebbe
            // allargare le altre colonne al passaggio del mouse, e la riga
            // ballerebbe proprio mentre la si sta puntando.
            Item {
                implicitWidth: 16
                implicitHeight: 16
                opacity: row.fav || hover.hovered ? 1 : 0

                Text {
                    anchors.centerIn: parent
                    color: row.fav ? "#d29922" : "#6e7681"
                    font.pixelSize: 14
                    text: row.fav ? "★" : "☆"
                }

                MouseArea {
                    anchors.fill: parent
                    anchors.margins: -4
                    cursorShape: Qt.PointingHandCursor
                    onClicked: Settings.toggleFavService(row.scope, row.service.name)
                }
            }
        }
    }
}
