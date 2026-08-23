import QtQuick
import QtQuick.Layouts

// Una barretta verticale per thread logico, col suo numero sotto: il
// riempimento e' il carico istantaneo, il colore vira al rosso sopra il 75%.
// L'ordine e' quello di /proc/stat, quindi la colonna N e' la cpu N.
RowLayout {
    id: root

    property var values: []
    // altezza della sola barra: l'etichetta si aggiunge sotto
    property int barHeight: 44

    spacing: 2
    // Un Layout ricalcola il proprio implicitHeight dai figli, e qui i figli
    // riempiono l'altezza (implicito 0): assegnarlo non avrebbe effetto — le
    // barre resterebbero schiacciate a pochi pixel. L'altezza va chiesta al
    // layout che ci contiene, ed e' questo che fa Layout.preferredHeight.
    Layout.preferredHeight: root.barHeight + 12
    Layout.minimumHeight: root.barHeight + 12

    Repeater {
        model: root.values

        ColumnLayout {
            id: core

            required property real modelData
            required property int index

            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 2

            Rectangle {
                Layout.fillWidth: true
                Layout.fillHeight: true
                radius: 2
                color: "#161b22"

                Rectangle {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    radius: 2
                    height: Math.max(2, parent.height * Math.min(100, core.modelData) / 100)
                    color: core.modelData > 75 ? "#f85149" : core.modelData > 40 ? "#d29922" : "#3fb950"

                    Behavior on height {
                        NumberAnimation {
                            duration: 300
                            easing.type: Easing.OutQuad
                        }
                    }
                }
            }

            Text {
                Layout.fillWidth: true
                // su una macchina con molti thread le colonne diventano piu'
                // strette del numero: meglio nessuna etichetta che una fila di
                // cifre sovrapposte
                visible: width >= 11
                horizontalAlignment: Text.AlignHCenter
                color: core.modelData > 75 ? "#8b949e" : "#484f58"
                font.pixelSize: 8
                text: core.index
            }
        }
    }
}
