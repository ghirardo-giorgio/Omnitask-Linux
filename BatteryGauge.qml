import QtQuick

// Il corpo di una batteria disegnata in orizzontale: il contatto sporge sulla
// destra, il colore sale da sinistra. Niente numeri qui — quelli li scrive
// chi usa il componente, perche' ogni pannello ha i suoi — solo il disegno su
// cui leggere lo stato a colpo d'occhio: ambra che respira mentre carica,
// verde fermo quando e' piena.
//
// Nasce verticale nel pannello solare e diventa orizzontale quando due
// batterie devono stare nella stessa colonna: una riga bassa si legge senza
// fermare l'occhio, e due orientamenti diversi per la stessa cosa sarebbero
// due lingue diverse.
Item {
    id: root

    // Riempimento 0..1: quanta barra mostrare.
    property real fraction: 0
    // Colore del riempimento: ambra mentre carica, verde a batteria piena.
    property string fillColor: "#e3b341"
    // Piena: bordo e contatto prendono il verde, cosi' anche da spento il
    // contorno ricorda lo stato.
    property bool full: false
    // Respira mentre sta caricando: chi passa davanti vede la vita senza
    // dover leggere niente. Piena o scarica: fermo.
    property bool pulsing: false

    // Il corpo. Il contenitore del riempimento taglia via tutto cio' che
    // sborda, cosi' la barra resta dentro il corpo anche agli estremi dove
    // gli angoli arrotondati curvano.
    Rectangle {
        id: body

        x: 0
        y: 2
        width: parent.width - 9
        height: parent.height - 4
        radius: 10
        color: "#161b22"
        border.width: 2
        border.color: root.full ? "#3fb950" : "#30363d"

        Rectangle {
            anchors.fill: parent
            anchors.margins: 5
            radius: 6
            clip: true
            color: "transparent"

            // Il riempimento: parte da sinistra e cresce. La larghezza si
            // anima, perche' tra una lettura e l'altra passano minuti e un
            // salto secco non direbbe quanto e' successo in mezzo.
            Rectangle {
                id: fill

                anchors.top: parent.top
                anchors.bottom: parent.bottom
                anchors.left: parent.left
                width: root.fraction * parent.width
                radius: 6
                color: root.fillColor

                Behavior on width {
                    NumberAnimation {
                        duration: 800
                        easing.type: Easing.OutCubic
                    }
                }

                SequentialAnimation {
                    running: root.pulsing
                    loops: Animation.Infinite
                    alwaysRunToEnd: true

                    NumberAnimation {
                        target: fill
                        property: "opacity"
                        to: 0.55
                        duration: 1100
                        easing.type: Easing.InOutQuad
                    }

                    NumberAnimation {
                        target: fill
                        property: "opacity"
                        to: 1
                        duration: 1100
                        easing.type: Easing.InOutQuad
                    }
                }
            }
        }
    }

    // Il contatto positivo: piccolo, sporge sulla destra come su ogni
    // batteria mai disegnata in orizzontale.
    Rectangle {
        anchors.verticalCenter: parent.verticalCenter
        x: parent.width - 7
        width: 7
        height: 20
        radius: 2
        color: root.full ? "#3fb950" : "#30363d"
    }
}
