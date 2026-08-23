import QtQuick

// L'etichetta che compare sopra un elemento quando il puntatore ci si ferma.
//
// Scritta a mano invece di usare ToolTip di QtQuick.Controls: quello si veste
// col tema di Controls, che qui non e' impostato, e verrebbe fuori un
// rettangolo di sistema in mezzo a un'interfaccia disegnata tutta a mano.
//
// Si mette come figlia dell'elemento a cui si riferisce e si posiziona da se'.
// Le anchors qui vanno bene anche dentro un layout: chi le usa e' figlio di un
// elemento normale, non del layout — il caso storto e' l'item che sta *dentro*
// il layout, e infatti quello non le usa (vedi il commento in NetPanel).
//
// Non c'e' bisogno di alzare z: l'etichetta esce verso l'alto, e li' sopra c'e'
// solo roba dichiarata prima, che viene disegnata prima. Sotto ci finirebbe
// invece quello che viene dopo, ed e' per questo che sale invece di scendere.
Rectangle {
    id: root

    property string text: ""
    // Ci si lega il `hovered` di un HoverHandler.
    property bool hovered: false
    // Un attimo di attesa: senza, spazzando il mouse sopra una fila di
    // pulsanti si accende una sfilza di etichette una dopo l'altra.
    property int delay: 350

    property bool shown: false

    onHoveredChanged: {
        if (root.hovered) {
            appear.restart();
        } else {
            appear.stop();
            root.shown = false;
        }
    }

    Timer {
        id: appear

        interval: root.delay
        onTriggered: root.shown = true
    }

    anchors.horizontalCenter: parent.horizontalCenter
    anchors.bottom: parent.top
    anchors.bottomMargin: 5

    implicitWidth: label.implicitWidth + 14
    implicitHeight: label.implicitHeight + 9

    radius: 5
    color: "#1c2128"
    border.width: 1
    border.color: "#30363d"

    // Non deve mai rubare il clic all'elemento che descrive: nasce proprio
    // sotto il puntatore che sta per premere.
    enabled: false

    visible: root.opacity > 0
    opacity: root.shown && root.text.length > 0 ? 1 : 0

    Behavior on opacity {
        NumberAnimation {
            duration: 120
        }
    }

    Text {
        id: label

        anchors.centerIn: parent
        color: "#c9d1d9"
        font.pixelSize: 10
        text: root.text
    }
}
