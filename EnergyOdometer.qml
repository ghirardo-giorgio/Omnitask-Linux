import QtQuick

// I rullini del contatore: una cifra per finestrella, che scatta in su quando
// il numero cresce.
//
// Il rullo si muove sempre in AVANTI, e non e' un dettaglio estetico: e' la
// cosa che distingue un contatore da un'etichetta con dentro un numero. Un
// contatore non torna indietro, e quando la cifra passa dal nove allo zero
// deve salire sullo zero del giro dopo — non riavvolgersi attraverso otto,
// sette, sei. Da qui l'undicesima cella di ogni rullo (vedi `slot`), che e' il
// solo pezzo di questo file che non si indovina leggendolo.
Row {
    id: root

    property real value: 0
    // Quante cifre prima e dopo la virgola. Quattro intere arrivano a 9999 Wh,
    // che sono dieci chilowattora: piu' di quanti un computer ne faccia in una
    // accensione, e se ci arriva il contatore torna a zero come quelli veri.
    property int intDigits: 4
    property int decimals: 1

    property color digitColor: "#e6edf3"
    property color decimalColor: "#e3b341"
    property color drumColor: "#161b22"

    property string fontFamily: PetStyle.arcadeFamily
    property int fontSize: 13

    // Il rullo e' piu' alto che largo, come i rullini veri.
    readonly property int cellWidth: Math.round(root.fontSize * 1.15)
    readonly property int cellHeight: Math.round(root.fontSize * 1.7)

    spacing: 1

    // Il valore in unita' dell'ultima cifra mostrata: 284,7 con un decimale
    // diventa 2847, e da li' ogni rullo e' una divisione per dieci. Cosi' la
    // virgola non e' un caso speciale, e' solo dove la si disegna.
    readonly property int scaled: Math.max(0, Math.floor(root.value * Math.pow(10, root.decimals)))

    function digitAt(place: int): int {
        return Math.floor(root.scaled / Math.pow(10, place)) % 10;
    }

    component Drum: Item {
        id: drum

        required property int place

        readonly property int digit: root.digitAt(drum.place)
        property color textColor: root.digitColor

        // Su quale cella e' fermo il rullo, da 0 a 10. La cella 10 e' un
        // SECONDO zero, identico al primo, e serve solo a far uscire il nove
        // dall'alto: si sale sulla dieci, e appena l'animazione finisce si
        // torna sulla zero senza animarla, che e' la stessa cella disegnata.
        //
        // 🔴 NON e' un binding su `digit`, ed e' l'unica riga di questo file
        // che si sbaglia scrivendola nel modo ovvio: legata alla cifra, al
        // passaggio dal nove allo zero il binding riporterebbe il rullo sulla
        // cella zero — indietro, attraverso otto sette sei — proprio nel caso
        // per cui la cella in piu' esiste. Qui si assegna a mano.
        property int slot: 0

        implicitWidth: root.cellWidth
        implicitHeight: root.cellHeight

        clip: true

        Rectangle {
            anchors.fill: parent
            radius: 2
            color: root.drumColor

            // L'ombra dentro la finestrella: sopra e sotto il rullo sparisce
            // nel buio, ed e' quello che fa sembrare la cifra stampata su un
            // cilindro invece che scritta su un rettangolo.
            gradient: Gradient {
                GradientStop {
                    position: 0
                    color: Qt.darker(root.drumColor, 2.2)
                }

                GradientStop {
                    position: 0.5
                    color: root.drumColor
                }

                GradientStop {
                    position: 1
                    color: Qt.darker(root.drumColor, 2.2)
                }
            }
        }

        Column {
            id: strip

            width: parent.width
            y: -drum.slot * root.cellHeight

            Behavior on y {
                id: rolling

                NumberAnimation {
                    duration: drum.rollMs
                    easing.type: Easing.OutCubic
                }
            }

            Repeater {
                model: 11

                Text {
                    required property int index

                    width: strip.width
                    height: root.cellHeight
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    color: drum.textColor
                    font.family: root.fontFamily
                    font.pixelSize: root.fontSize
                    text: index % 10
                }
            }
        }

        readonly property int rollMs: 280

        Component.onCompleted: drum.slot = drum.digit

        onDigitChanged: {
            // Se il rullo stava ancora sullo zero del giro dopo, ci si rimette
            // sullo zero vero prima di muoversi: la cella e' la stessa, quindi
            // non si vede niente, ma da li' il conto delle celle torna a
            // essere quello delle cifre.
            if (drum.slot === 10)
                drum.settle();

            // Piu' piccola di prima vuol dire che ha passato il nove — un
            // contatore non cala. L'unico caso in cui cala davvero e' il
            // riavvio della macchina, che riazzera tutto: allora e' il salto
            // di un giro solo, e si vede passare per lo zero.
            if (drum.digit < drum.slot) {
                drum.slot = 10;
                wrap.restart();
            } else {
                drum.slot = drum.digit;
            }
        }

        function settle(): void {
            rolling.enabled = false;
            drum.slot = 0;
            rolling.enabled = true;
        }

        // Il salto dalla cella dieci alla zero si fa a tempo e non aspettando
        // che l'animazione del Behavior dica di aver finito: quell'animazione
        // e' costruita da Qt dentro il Behavior, e il suo `running` non e' una
        // cosa su cui appoggiarsi. Un pelo piu' lungo della rotazione, e la
        // cifra vera si rimette subito dopo — cosi' un rullo che ha saltato
        // qualche numero (conteggio veloce: da 8 a 2 in un colpo) finisce di
        // salire invece di restare fermo sullo zero fino al numero dopo.
        Timer {
            id: wrap

            interval: drum.rollMs + 30
            onTriggered: {
                drum.settle();

                if (drum.digit !== 0)
                    drum.slot = drum.digit;
            }
        }
    }

    Repeater {
        model: root.intDigits

        Drum {
            required property int index

            // Il primo rullo a sinistra e' la cifra piu' alta: il posto e' il
            // numero di cifre che gli stanno a destra, virgola compresa.
            place: root.intDigits + root.decimals - 1 - index
        }
    }

    Text {
        visible: root.decimals > 0
        width: 5
        height: root.cellHeight
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignBottom
        bottomPadding: 3
        color: root.decimalColor
        font.family: root.fontFamily
        font.pixelSize: root.fontSize
        text: ","
    }

    Repeater {
        model: root.decimals

        Drum {
            required property int index

            place: root.decimals - 1 - index
            // I decimali in un altro colore, come la finestrella rossa dei
            // contatori veri: dice a colpo d'occhio dove finisce il numero che
            // conta e comincia quello che balla.
            textColor: root.decimalColor
        }
    }
}
