import QtQuick
import QtQuick.Layouts

// Una riga «etichetta — campo — unita'» attaccata a un parametro di pannello.
//
// I parametri dei pannelli (vedi Settings.panelParam) sono nati per essere
// cambiati a mano in dashboard.json, e per le soglie va benissimo: si toccano
// una volta e mai piu'. La tariffa dell'elettricita' no — cambia col contratto,
// con la stagione e col paese in cui si vive — e chiedere di aprire un file
// JSON per scriverci dentro un numero che sta gia' stampato sulla bolletta e'
// il modo di non farlo mai.
//
// Il campo scrive DIRETTAMENTE nella configurazione, senza un pulsante
// «applica»: e' la stessa promessa che fa la finestra Opzioni, e il pannello
// dietro si aggiorna mentre si scrive.
RowLayout {
    id: field

    // Dove finisce il valore: `panel` e' l'id del pannello (la sezione di
    // panelParams), `key` il nome del parametro.
    property string panel: ""
    property string key: ""

    property string label: ""
    // Quello che c'e' scritto dopo il campo: W, ¥/kWh, giri.
    property string unit: ""
    // Il perche' del parametro, per chi ci passa sopra col mouse.
    property string hint: ""

    // Il default del pannello: lo stesso che sta nei suoi `defs`, cosi' un
    // parametro mai scritto mostra il numero che il pannello sta usando.
    property var fallback: 0

    // Falso per i valori che non sono numeri — il simbolo della valuta, la
    // lista dei mesi: si scrivono come sono e si salvano come stringa.
    property bool numeric: true
    property int decimals: 2
    property real minimum: 0
    property real maximum: 1000000

    property int fieldWidth: 66

    readonly property var saved: Settings.panelParam(field.panel, field.key, field.fallback)

    function shownFor(value: var): string {
        return field.numeric ? Number(value).toFixed(field.decimals) : String(value);
    }

    // Quello che si e' scritto diventa un valore salvato, e il campo torna a
    // mostrare il valore salvato — non quello scritto.
    //
    // La differenza si vede solo quando le due cose non coincidono: «abc» in un
    // campo numerico, o un rendimento del 300%. Rimettere il salvato e' il modo
    // di dirlo senza un messaggio d'errore: il numero rifiutato sparisce, e
    // quello in vigore resta sotto gli occhi.
    function commit(): void {
        if (!field.numeric) {
            const text = input.text.trim();
            Settings.setPanelParam(field.panel, field.key, text);
            input.text = field.shownFor(text);
            return;
        }

        // Virgola o punto: chi scrive «0,9» sta scrivendo lo stesso numero di
        // chi scrive «0.9», e in italiano e' anzi il modo naturale.
        const parsed = parseFloat(input.text.replace(",", "."));

        if (isFinite(parsed)) {
            const clamped = Math.min(field.maximum, Math.max(field.minimum, parsed));
            Settings.setPanelParam(field.panel, field.key, clamped);
            input.text = field.shownFor(clamped);
            return;
        }

        input.text = field.shownFor(field.saved);
    }

    spacing: 6

    // Il campo non e' legato in scrittura al valore salvato: un binding su
    // `text` si spezzerebbe al primo carattere digitato, e da li' in poi un
    // valore cambiato da un'altra parte non comparirebbe piu'. Si riallinea a
    // mano, e solo quando nessuno ci sta scrivendo dentro.
    onSavedChanged: {
        if (!input.activeFocus)
            input.text = field.shownFor(field.saved);
    }

    Component.onCompleted: input.text = field.shownFor(field.saved)

    Text {
        Layout.fillWidth: true
        elide: Text.ElideRight
        color: "#8b949e"
        font.pixelSize: 10
        text: field.label

        HoverHandler {
            id: labelHover
        }

        Tooltip {
            hovered: field.hint !== "" && labelHover.hovered
            text: field.hint
        }
    }

    Rectangle {
        implicitWidth: field.fieldWidth
        implicitHeight: 20
        radius: 4
        color: "#0d1117"
        border.width: 1
        border.color: input.activeFocus ? "#58a6ff" : "#30363d"

        TextInput {
            id: input

            anchors.fill: parent
            anchors.leftMargin: 6
            anchors.rightMargin: 6
            clip: true
            horizontalAlignment: TextInput.AlignRight
            verticalAlignment: TextInput.AlignVCenter
            color: "#c9d1d9"
            font.pixelSize: 11
            selectionColor: "#1f6feb"
            selectedTextColor: "#ffffff"

            // Scatta sia con Invio sia quando il campo perde il fuoco: chi
            // scrive un numero e va a cliccare altrove ha finito di scriverlo
            // esattamente come chi preme Invio.
            onEditingFinished: field.commit()
            // Il campo lasciato a meta' torna com'era, che e' cio' che ci si
            // aspetta da Esc.
            Keys.onEscapePressed: {
                input.text = field.shownFor(field.saved);
                input.focus = false;
            }
        }
    }

    Text {
        visible: field.unit !== ""
        color: "#6e7681"
        font.pixelSize: 10
        text: field.unit
    }
}
