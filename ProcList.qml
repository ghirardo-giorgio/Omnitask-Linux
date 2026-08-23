import QtQuick
import QtQuick.Layouts

// Classifica compatta di processi: nome a sinistra, valore a destra e una
// barra di sfondo proporzionale al primo della lista.
ColumnLayout {
    id: root

    property string title: ""
    property color accent: "#58a6ff"
    // Ogni voce: { name, value, text, sub }. `value` serve solo alla barra.
    property var entries: []
    property string emptyText: "—"

    Layout.fillWidth: true
    spacing: 1

    Text {
        Layout.bottomMargin: 2
        color: "#8b949e"
        font.pixelSize: 10
        font.letterSpacing: 1
        text: root.title
    }

    Repeater {
        model: root.entries

        Item {
            required property var modelData

            Layout.fillWidth: true
            implicitHeight: 19

            // La barra e' relativa al primo in classifica, non al 100%:
            // con la CPU quasi scarica le differenze resterebbero invisibili.
            Rectangle {
                readonly property real peak: root.entries.length ? Math.max(...root.entries.map(e => e.value)) : 0

                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                width: peak > 0 ? parent.width * Math.min(1, parent.modelData.value / peak) : 0
                height: parent.height - 2
                radius: 3
                color: Qt.alpha(root.accent, 0.16)
            }

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 6
                anchors.rightMargin: 6
                spacing: 6

                Text {
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                    color: "#c9d1d9"
                    font.pixelSize: 11
                    text: parent.parent.modelData.name
                }

                Text {
                    visible: text !== ""
                    color: "#6e7681"
                    font.pixelSize: 10
                    text: parent.parent.modelData.sub ?? ""
                }

                Text {
                    color: root.accent
                    font.pixelSize: 11
                    font.bold: true
                    text: parent.parent.modelData.text
                }
            }
        }
    }

    Text {
        Layout.fillWidth: true
        visible: root.entries.length === 0
        color: "#484f58"
        font.pixelSize: 11
        text: root.emptyText
    }
}
