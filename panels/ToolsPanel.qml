import QtQuick
import QtQuick.Layouts

// Il pannello sta in panels/: senza `import ".."` si caricherebbe lo stesso,
// ma SystemStats, Settings, I18n e i componenti della dashboard resterebbero
// indefiniti — vedi scripts/panels.py, che verifica la riga e lo dice.
import ".."

// I pulsanti che aprono le finestre di sistema, affiancati su una riga sola.
// Le opzioni non stanno qui: sono un ingranaggio in cima alla colonna destra
// (vedi Dashboard.qml), dove si cerca un pulsante di impostazioni.
RowLayout {
    id: root

    // L'id ferma il pannello nella configurazione salvata (le colonne
    // di dashboard.json lo citano) e lo distingue nel catalogo; il titolo
    // e' quello che la finestra Opzioni mostra. Dichiarati qui, il
    // catalogo e' tutto scoperto da panels/ e Settings non tiene elenchi.
    property string panelId: "tools"
    property string panelTitle: "Servizi e processi"

    spacing: 6

    Repeater {
        model: [
            {
                label: "Servizi systemd",
                action: "services"
            },
            {
                label: "Cerca processi",
                action: "processes"
            },
            {
                label: "Hardware",
                action: "hardware"
            }
        ]

        Rectangle {
            id: button

            required property var modelData

            Layout.fillWidth: true
            implicitHeight: 28
            radius: 6
            color: area.containsMouse ? "#161b22" : "transparent"
            border.width: 1
            border.color: "#30363d"

            Text {
                anchors.centerIn: parent
                width: parent.width - 12
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideRight
                color: "#8b949e"
                font.pixelSize: 11
                text: I18n.t(button.modelData.label)
            }

            MouseArea {
                id: area

                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                    if (button.modelData.action === "services")
                        DashActions.openServices();
                    else if (button.modelData.action === "processes")
                        DashActions.openProcesses();
                    else
                        DashActions.openHardware();
                }
            }
        }
    }
}
