import QtQuick

// Il disco del contatore elettrico, quello di alluminio che gira nel quadro in
// corridoio. Non e' una decorazione retro': e' l'unico strumento che dice due
// cose insieme senza chiedere di leggere due numeri — quanto stai consumando
// ADESSO (la velocita') e quanto ne hai consumato in TUTTO (i giri fatti, che
// sono i wattora dell'odometro qui accanto). A macchina ferma striscia, sotto
// carico frulla, e questo si vede con la coda dell'occhio da dall'altra parte
// della stanza.
//
// Il legame fra le due cose e' quello dei contatori veri: `revPerKwh` giri per
// chilowattora. Un contatore di casa ne fa 600 e a 100 W girerebbe una volta
// ogni minuto — troppo lento per accorgersene, perche' un contatore di casa
// misura una casa e questo misura un computer. Il default e' cinque volte
// tanto, che a 100 W fa un giro ogni dodici secondi.
Item {
    id: root

    // Watt istantanei: la velocita'. Zero ferma il disco, e ferma anche
    // l'animazione — un disco che non gira non deve costare un frame.
    property real watts: 0
    property real revPerKwh: 3000

    property color discColor: "#e3b341"
    property color markColor: "#f85149"

    // La posizione del disco, in gradi. Non e' legata ai wattora accumulati
    // ma integrata qui frame per frame, e la differenza conta: i wattora
    // arrivano una volta al secondo, e un disco che si aggiornasse solo li'
    // andrebbe a scatti di un secondo invece di girare.
    property real angle: 0

    implicitWidth: 46
    implicitHeight: 46

    // giri/h = W/1000 x revPerKwh, da cui i gradi al secondo.
    readonly property real degPerSecond: root.watts > 0 ? root.watts / 1000 * root.revPerKwh * 360 / 3600 : 0

    FrameAnimation {
        // Spento quando non c'e' niente da girare: a potenza nulla, e quando
        // il pannello non si vede. Il secondo caso e' quello che conta, ed e'
        // una questione di coerenza prima che di costo — un pannello che
        // misura i consumi non puo' essere quello che tiene sveglia la GPU per
        // disegnare un disco che nessuno guarda.
        running: root.visible && root.degPerSecond > 0

        onTriggered: root.angle = (root.angle + root.degPerSecond * frameTime) % 360
    }

    // La cassa: il disco vero sta dentro una finestrella, e senza il bordo
    // scuro attorno il cerchio giallo galleggerebbe sul fondo del pannello.
    Rectangle {
        anchors.fill: parent
        radius: width / 2
        color: "#0d1117"
        border.width: 1
        border.color: "#30363d"
    }

    Item {
        id: disc

        anchors.fill: parent
        anchors.margins: 4
        rotation: root.angle

        Rectangle {
            anchors.fill: parent
            radius: width / 2

            // L'alluminio: la sfumatura verticale e' quello che lo fa
            // sembrare metallo invece di un bollo di colore piatto. Gira col
            // disco, quindi la luce gira con lui — che e' sbagliato per un
            // riflesso vero, ma e' proprio quello che rende visibile la
            // rotazione anche quando la tacca sta dietro.
            gradient: Gradient {
                GradientStop {
                    position: 0
                    color: Qt.lighter(root.discColor, 1.35)
                }

                GradientStop {
                    position: 0.5
                    color: root.discColor
                }

                GradientStop {
                    position: 1
                    color: Qt.darker(root.discColor, 1.5)
                }
            }
        }

        // La tacca. Sui contatori veri e' una riga nera dipinta sul bordo del
        // disco, ed e' l'unica cosa che si guarda: senza un riferimento un
        // disco liscio che gira sembra fermo.
        Rectangle {
            width: 3
            height: parent.height / 2 - 2
            radius: 1.5
            color: root.markColor
            x: (parent.width - width) / 2
            y: 2
        }

        // Il perno.
        Rectangle {
            width: 6
            height: 6
            radius: 3
            anchors.centerIn: parent
            color: "#0d1117"
            opacity: 0.65
        }
    }

    // Il vetro, che invece NON gira: una lama di luce ferma sopra il disco che
    // scorre. E' la sola cosa in questo file che sta li' per essere bella, e
    // costa un rettangolo semitrasparente.
    Rectangle {
        anchors.fill: parent
        anchors.margins: 4
        radius: width / 2
        opacity: 0.16

        gradient: Gradient {
            GradientStop {
                position: 0
                color: "#ffffff"
            }

            GradientStop {
                position: 0.45
                color: "transparent"
            }

            GradientStop {
                position: 1
                color: "transparent"
            }
        }
    }
}
