import QtQuick
import QtQuick.Layouts

// Riga compatta: etichetta, barra di riempimento, valore testuale a destra.
RowLayout {
    id: root

    property string label: ""
    // I nomi dei sensori sono piu' lunghi di una sigla: la colonna si allarga
    // da fuori, cosi' righe diverse nello stesso pannello restano allineate.
    property int labelWidth: 38
    property real percent: 0
    property string detail: ""
    property color barColor: "#58a6ff"

    Layout.fillWidth: true
    spacing: 8

    Text {
        Layout.preferredWidth: root.labelWidth
        elide: Text.ElideRight
        color: "#8b949e"
        font.pixelSize: 11
        text: root.label
    }

    Rectangle {
        Layout.fillWidth: true
        implicitHeight: 6
        radius: 3
        color: "#161b22"

        Rectangle {
            width: parent.width * Math.max(0, Math.min(100, root.percent)) / 100
            height: parent.height
            radius: 3
            color: root.percent > 90 ? "#f85149" : root.barColor

            Behavior on width {
                NumberAnimation {
                    duration: 300
                    easing.type: Easing.OutQuad
                }
            }
        }
    }

    Text {
        Layout.preferredWidth: 96
        horizontalAlignment: Text.AlignRight
        color: "#c9d1d9"
        font.pixelSize: 11
        text: root.detail
    }
}
