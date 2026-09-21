import QtQuick

// Quello che cade dal cielo nella stanza del pet.
//
// L'altra meccanica delle caratteristiche dai sensori: il benessere agisce
// sempre e di poco, un oggetto agisce una volta e di colpo. La RAM che resta
// oltre la soglia per qualche minuto fa scendere un peperoncino; se il pet ci
// passa sopra mentre girovaga se lo prende, e se no dopo sei secondi non c'e'
// piu'. Il fatto che spesso non lo prenda E' la meccanica: un oggetto che
// arriva sempre a destinazione sarebbe solo un effetto in ritardo.
//
// Roba nostra, quindi nella radice come PetMolecules e PetTerrain: `pet/` e'
// di terzi e resta com'e' (vedi pet/UPSTREAM.md).
//
// Questo file non decide NIENTE: non sa cos'e' una soglia, non sa cosa fa un
// peperoncino, non scrive le statistiche. Riceve gli oggetti gia' risolti, li
// fa cadere, guarda se il pet li tocca e lo riferisce — chi decide e'
// panels/PetPanel.qml, che possiede lo stato e il salvataggio.
Item {
    id: field

    // Gli oggetti a terra adesso, come li passa il pannello: `key` (unica per
    // caduta), `glyph` e `kind`.
    //
    // 🔴 E' un array, ma il pannello ce ne mette al massimo UNO, e va tenuto
    // cosi'. Un Repeater su un array JavaScript non confronta niente: a ogni
    // riassegnazione distrugge e ricrea tutti i delegati, quindi il secondo
    // oggetto farebbe ricominciare da capo la caduta del primo — che si
    // vedrebbe come una mela che risale in cielo. Il giorno che ne servono due
    // insieme la strada e' un ListModel riempito per differenza, non un
    // secondo elemento qui dentro.
    property var drops: []

    // Il pet, per la collisione: qui serve solo dov'e' e quanto e' largo.
    property Item target: null

    // La misura dell'oggetto, gia' arrotondata da chi ce la passa.
    property int itemSize: 16

    // Quanto resta a terra prima di sparire, l'ultimo secondo in dissolvenza.
    property int groundSeconds: 6

    // Quanto stare lontani dai bordi della stanza.
    property real margin: 6

    property bool running: true

    // La quota del suolo, come funzione della frazione di larghezza.
    //
    // 🔴 Una funzione e non un numero, perche' il pavimento e' una curva
    // (PetTerrain) e ogni oggetto cade in un punto diverso: con una quota sola
    // una mela caduta in una valle resterebbe appesa a mezz'aria sopra il
    // terreno, che e' esattamente il genere di dettaglio che disfa
    // l'illusione. E' la stessa `groundY()` che usa gia' lo sporco.
    property var groundAt: null

    signal caught(string key)
    signal expired(string key)

    // 🔴 Un Timer per il campo, non uno per oggetto e nessun onFrame: e' la
    // regola di PetMolecules, e qui c'e' anche il numero giusto. Il pet
    // attraversa la stanza in 500 ms nel caso piu' svelto (walkDurationMs), e
    // la finestra in cui si sovrappone a un oggetto e' larga meta' pet piu'
    // meta' oggetto: a 100 ms ci cascano dentro almeno due controlli, a un
    // quarto di secondo il pet ci passerebbe attraverso senza che nessuno se
    // ne accorga — e sarebbe un guasto invisibile, di quelli che si scoprono
    // dopo settimane come «ogni tanto non lo prende».
    Timer {
        interval: 100
        running: field.running && field.drops.length > 0 && field.target !== null
        repeat: true
        onTriggered: field.sweep()
    }

    function sweep() {
        for (let i = 0; i < rep.count; i++) {
            const it = rep.itemAt(i);
            if (!it || !it.onGround || it.taken)
                continue;

            const dx = Math.abs((it.x + it.width / 2) - (field.target.x + field.target.width / 2));

            // Il fattore perche' il riquadro dello sprite e' in buona parte
            // margine trasparente: con la larghezza piena il pet raccatterebbe
            // cose che gli passano accanto senza toccarle.
            if (dx > (field.target.width + it.width) / 2 * 0.8)
                continue;

            // Marcato SUBITO, e l'animazione fermata: fra il segnale e la
            // riga tolta dal modello passa un giro, e senza questo il giro
            // dopo lo raccoglierebbe una seconda volta.
            it.taken = true;
            it.life.stop();
            // Il suono della raccolta parte QUI e non da chi riceve il
            // segnale: e' l'istante in cui la cosa e' successa, e passarlo di
            // mano vorrebbe dire un suono in ritardo di un giro su un gesto
            // che dura un fotogramma. Se i suoni sono spenti, play() non fa
            // niente — la guardia sta dentro PetSfx, una volta sola.
            PetSfx.play("catch");
            field.caught(it.key);
            return;
        }
    }

    Repeater {
        id: rep

        model: field.drops

        Item {
            id: drop

            required property var modelData

            readonly property string key: drop.modelData.key
            readonly property alias life: life

            // Vero da quando ha toccato terra: prima di allora e' per aria e
            // non si prende, anche se passa davanti al muso del pet.
            property bool onGround: false
            property bool taken: false

            width: field.itemSize
            height: field.itemSize

            // Fuori dalla cima della stanza, che ha `clip: true`: cosi' entra
            // in campo cadendo invece di comparire gia' dentro.
            y: -field.itemSize

            Text {
                anchors.centerIn: parent
                // Il glifo riempie il riquadro: la misura la decide chi ci
                // passa `itemSize`, che e' un terzo del pet.
                font.pixelSize: field.itemSize
                // 🔴 Come ogni Text di questa dashboard: un testo con del
                // markup dentro diventerebbe una richiesta di rete fatta dalla
                // shell, e qui il testo viene da un file che si corregge a
                // mano.
                textFormat: Text.PlainText
                text: drop.modelData.glyph
            }

            // Dove cade, deciso una volta sola.
            //
            // 🔴 In un handler e non in un binding: un Math.random() dentro un
            // binding si rivaluta a ogni cambio di larghezza della stanza, e
            // l'oggetto si teletrasporterebbe mentre cade.
            Component.onCompleted: {
                const span = Math.max(1, field.width - 2 * field.margin - drop.width);
                let x = 0;

                // Cinque tentativi per non cadergli addosso. Serve perche' un
                // pet molto trascurato NON SI MUOVE PIU' (stillChance a 1):
                // senza questo gli cadrebbe sempre in testa, e «lo prende solo
                // se ci passa sopra» diventerebbe «lo prende sempre» proprio
                // quando stanno arrivando i dispetti.
                for (let i = 0; i < 5; i++) {
                    x = field.margin + Math.random() * span;
                    if (!field.target)
                        break;
                    const gap = Math.abs((x + drop.width / 2) - (field.target.x + field.target.width / 2));
                    if (gap > (field.target.width + drop.width) / 2 * 1.2)
                        break;
                }

                drop.x = Math.round(x);

                const frac = (drop.x + drop.width / 2) / Math.max(1, field.width);
                const ground = field.groundAt ? field.groundAt(frac) : field.height;
                fall.to = Math.round(Math.max(0, ground - drop.height));
                // Un tempo di caduta proporzionale all'altezza, con un minimo:
                // una stanza bassa non deve far cadere le cose al rallentatore.
                fall.duration = Math.max(350, Math.round((fall.to - drop.y) * 1.4));
                life.start();
            }

            // Tutta la vita in una animazione sola, invece di un secondo
            // orologio da tenere d'accordo con questo: si ferma con uno stop()
            // quando il pet lo raccoglie, e i sei secondi sono un suo ramo.
            SequentialAnimation {
                id: life

                NumberAnimation {
                    id: fall

                    target: drop
                    property: "y"
                    // E' gravita': parte piano e arriva veloce. Una velocita'
                    // costante si legge come un oggetto calato con una corda.
                    easing.type: Easing.InQuad
                }

                ScriptAction {
                    script: {
                        drop.onGround = true;
                        PetSfx.play("land");
                    }
                }

                PauseAnimation {
                    duration: Math.max(0, (field.groundSeconds - 1) * 1000)
                }

                // L'ultimo secondo sfuma: sparire di colpo si legge come un
                // guasto, mentre una dissolvenza dice «sta per finire» e da'
                // anche il tempo di correre.
                NumberAnimation {
                    target: drop
                    property: "opacity"
                    to: 0
                    duration: 1000
                }

                ScriptAction {
                    script: field.expired(drop.key)
                }
            }
        }
    }
}
