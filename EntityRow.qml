import QtQuick
import QtQuick.Layouts

// Una riga: nome dell'entita' a sinistra, valore a destra.
// Se l'entita' e' commutabile (luce, switch, ...) il click la accende/spegne.
MouseArea {
    id: root

    required property string entityId
    property bool toggleable: ["light", "switch", "fan", "input_boolean"].includes(entityId.split(".")[0])

    readonly property string value: HomeAssistant.state(entityId)
    readonly property bool isOn: value === "on"

    implicitHeight: 34
    Layout.fillWidth: true
    cursorShape: toggleable ? Qt.PointingHandCursor : Qt.ArrowCursor
    hoverEnabled: toggleable
    enabled: toggleable && value !== ""
    // per le luci non e' un semplice toggle: si riaccendono col colore e la
    // luminosita' che avevano (vedi HomeAssistant.toggleEntity)
    onClicked: HomeAssistant.toggleEntity(entityId)

    Rectangle {
        anchors.fill: parent
        radius: 8
        color: root.containsMouse ? "#1affffff" : "transparent"
    }

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: 10
        anchors.rightMargin: 10
        spacing: 12

        Rectangle {
            implicitWidth: 8
            implicitHeight: 8
            radius: 4
            visible: root.toggleable
            color: root.isOn ? "#7ee787" : "#484f58"
        }

        Text {
            Layout.fillWidth: true
            elide: Text.ElideRight
            color: "#c9d1d9"
            font.pixelSize: 13
            text: HomeAssistant.friendlyName(root.entityId)
        }

        Text {
            color: root.isOn ? "#7ee787" : "#8b949e"
            font.pixelSize: 13
            font.bold: true
            text: root.value === "" ? "—" : `${root.value} ${HomeAssistant.unit(root.entityId)}`.trim()
        }
    }
}
