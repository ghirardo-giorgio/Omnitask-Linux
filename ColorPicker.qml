import QtQuick
import QtQuick.Layouts

// Il menu del tasto destro dei grafici: il colore delle serie e, per i grafici
// che vengono da Home Assistant, la cancellazione della lettura sotto il
// puntatore.
//
// Disegnato a mano come tutto il resto: QtQuick.Dialogs offrirebbe un
// ColorDialog pronto, ma aprirebbe una finestra di sistema con l'aspetto del
// tema Qt in un'app che non importa QtQuick.Controls da nessuna parte.
//
// Due pagine, come il menu dei processi: un grafico con due serie (rete,
// disco, consumo) chiede prima *quale*, poi mostra le pastiglie. Con una serie
// sola la prima pagina si salta.
Item {
    id: root

    // [{ id, label, fallback }] della serie o delle serie del grafico su cui si
    // e' premuto. Vuoto = menu chiuso.
    property var series: []
    // indice della serie scelta, -1 finche' non si e' deciso
    property int chosen: -1

    // La lettura sotto il puntatore — { entity, index, when, value } — o null
    // se il grafico non viene da Home Assistant: li' non c'e' niente da
    // cancellare, e la voce non compare.
    property var point: null
    // La cancellazione e' irreversibile e il gesto che la chiede e' lo stesso
    // con cui si cambia un colore: la conferma sta fra i due, come per fermare
    // un servizio (vedi ServiceRow).
    property bool confirming: false
    // Si e' confermato e si aspetta l'esito. Il menu resta aperto apposta: un
    // intervallo senza letture o un database occupato sono risposte che
    // l'utente deve leggere, e chiudersi subito le nasconderebbe.
    property bool waiting: false

    // Dove il menu vorrebbe stare: la posizione del puntatore, che diventa
    // quella della scheda solo dopo essere stata riportata dentro la finestra.
    property real wantX: 0
    property real wantY: 0

    readonly property bool open: root.series.length > 0
    readonly property var current: root.chosen >= 0 && root.chosen < root.series.length ? root.series[root.chosen] : null

    // Sedici tinte che staccano sul fondo #0d1117 e reggono la sfumatura sotto
    // la linea: le otto gia' in uso nel progetto piu' otto vicine di tono. Un
    // colore troppo scuro sparirebbe nel fondo, uno troppo desaturato non si
    // distinguerebbe dalla griglia.
    readonly property var palette: [
        "#3fb950", "#7ee787", "#39c5cf", "#58a6ff",
        "#1f6feb", "#a371f7", "#bc8cff", "#db6d28",
        "#e3b341", "#f0883e", "#ff7b72", "#f85149",
        "#db61a2", "#ff9bce", "#8b949e", "#c9d1d9"
    ]

    function show(list: var, x: real, y: real, point: var) {
        root.series = list ?? [];
        // con una serie sola non c'e' niente da scegliere: si va dritti alle
        // pastiglie
        root.chosen = root.series.length === 1 ? 0 : -1;
        root.point = point ?? null;
        root.confirming = false;
        root.waiting = false;
        root.place(x, y);
    }

    function close() {
        root.series = [];
        root.chosen = -1;
        root.point = null;
        root.confirming = false;
        root.waiting = false;
    }

    // Il menu segue il puntatore ma non esce dalla finestra: un grafico in
    // fondo alla colonna lo aprirebbe per meta' fuori dal bordo. Sono due
    // legami e non due assegnazioni perche' la scheda cresce mentre e' aperta —
    // la conferma e l'esito aggiungono una riga — e una posizione calcolata
    // all'apertura lascerebbe uscire dal bordo proprio quella riga.
    function place(x: real, y: real) {
        root.wantX = x;
        root.wantY = y;
    }

    anchors.fill: parent
    visible: root.open
    z: 100

    // Chiude cliccando fuori. Intercetta anche il tasto destro, altrimenti un
    // secondo clic destro aprirebbe un selettore sopra quello aperto.
    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onClicked: root.close()
    }

    Rectangle {
        id: card

        implicitWidth: 208
        implicitHeight: body.implicitHeight + 16
        x: Math.max(6, Math.min(root.wantX, root.width - card.width - 6))
        y: Math.max(6, Math.min(root.wantY, root.height - card.height - 6))
        radius: 8
        color: "#161b22"
        border.width: 1
        border.color: "#30363d"

        // il clic dentro la scheda non deve arrivare allo sfondo che chiude
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton | Qt.RightButton
        }

        ColumnLayout {
            id: body

            anchors.fill: parent
            anchors.margins: 8
            spacing: 6

            Text {
                Layout.fillWidth: true
                elide: Text.ElideRight
                color: "#8b949e"
                font.pixelSize: 10
                font.letterSpacing: 1
                text: root.current ? I18n.t("COLORE · %1").arg(root.current.label) : I18n.t("QUALE SERIE")
            }

            // --- pagina 1: quale serie ---
            Repeater {
                model: root.chosen < 0 ? root.series : []

                Rectangle {
                    id: pick

                    required property var modelData
                    required property int index

                    Layout.fillWidth: true
                    implicitHeight: 26
                    radius: 6
                    color: pickHover.hovered ? "#21262d" : "transparent"

                    HoverHandler {
                        id: pickHover

                        cursorShape: Qt.PointingHandCursor
                    }

                    TapHandler {
                        onTapped: root.chosen = pick.index
                    }

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 6
                        anchors.rightMargin: 6
                        spacing: 8

                        Rectangle {
                            implicitWidth: 10
                            implicitHeight: 10
                            radius: 2
                            color: Settings.colorFor(pick.modelData.id, pick.modelData.fallback)
                        }

                        Text {
                            Layout.fillWidth: true
                            elide: Text.ElideRight
                            color: "#c9d1d9"
                            font.pixelSize: 11
                            text: pick.modelData.label
                        }
                    }
                }
            }

            // --- pagina 2: le pastiglie ---
            Grid {
                Layout.alignment: Qt.AlignHCenter
                visible: root.chosen >= 0
                columns: 8
                spacing: 4

                Repeater {
                    model: root.chosen >= 0 ? root.palette : []

                    Rectangle {
                        id: swatch

                        required property string modelData

                        readonly property bool current: root.current && Settings.colorFor(root.current.id, root.current.fallback).toLowerCase() === swatch.modelData

                        width: 20
                        height: 20
                        radius: 4
                        color: swatch.modelData
                        // il bordo dice qual e' quello in uso: su una pastiglia
                        // colorata un segno di spunta si leggerebbe male
                        border.width: swatch.current ? 2 : (swatchHover.hovered ? 1 : 0)
                        border.color: "#f0f6fc"

                        HoverHandler {
                            id: swatchHover

                            cursorShape: Qt.PointingHandCursor
                        }

                        TapHandler {
                            onTapped: {
                                Settings.setColor(root.current.id, swatch.modelData);
                                root.close();
                            }
                        }
                    }
                }
            }

            // --- esadecimale e ritorno al default ---
            RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: 2
                visible: root.chosen >= 0
                spacing: 6

                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: 24
                    radius: 6
                    color: "#0d1117"
                    border.width: 1
                    // il bordo diventa rosso mentre si scrive qualcosa che non
                    // e' un colore, invece di rifiutarlo in silenzio a fine
                    // digitazione
                    border.color: hex.acceptableInput ? "#30363d" : "#f85149"

                    TextInput {
                        id: hex

                        anchors.fill: parent
                        anchors.leftMargin: 7
                        anchors.rightMargin: 7
                        verticalAlignment: TextInput.AlignVCenter
                        color: "#c9d1d9"
                        font.pixelSize: 11
                        font.family: "monospace"
                        selectByMouse: true
                        selectionColor: "#1f6feb"
                        validator: RegularExpressionValidator {
                            regularExpression: /#[0-9a-fA-F]{6}/
                        }
                        // si riempie all'apertura e a ogni cambio di serie, ma
                        // non mentre l'utente sta scrivendo
                        text: root.current && !hex.activeFocus ? Settings.colorFor(root.current.id, root.current.fallback) : hex.text
                        onAccepted: {
                            if (hex.acceptableInput && root.current) {
                                Settings.setColor(root.current.id, hex.text);
                                root.close();
                            }
                        }
                    }
                }

                Rectangle {
                    implicitWidth: 24
                    implicitHeight: 24
                    radius: 6
                    color: resetHover.hovered ? "#21262d" : "transparent"
                    border.width: 1
                    border.color: "#30363d"

                    HoverHandler {
                        id: resetHover

                        cursorShape: Qt.PointingHandCursor
                    }

                    Text {
                        anchors.centerIn: parent
                        color: "#8b949e"
                        font.pixelSize: 12
                        text: "↺"
                    }

                    TapHandler {
                        onTapped: {
                            Settings.resetColor(root.current.id);
                            root.close();
                        }
                    }
                }
            }

            // --- cancellare la lettura ---------------------------------------
            //
            // Un sensore che una volta sola legge quello che non c'e' lascia
            // nel grafico una montagna per tutta la finestra dello storico. Il
            // menu nomina la lettura con la sua ora — non con quella del punto
            // su cui si e' premuto, che puo' esserne la ripetizione — cosi' si
            // vede quale riga si sta per togliere da Home Assistant.
            Rectangle {
                Layout.fillWidth: true
                Layout.topMargin: 2
                visible: root.point !== null
                implicitHeight: 1
                color: "#21262d"
            }

            Rectangle {
                Layout.fillWidth: true
                visible: root.point !== null && !root.confirming && !root.waiting
                implicitHeight: 24
                radius: 6
                color: cutHover.hovered ? "#21262d" : "transparent"

                HoverHandler {
                    id: cutHover

                    cursorShape: Qt.PointingHandCursor
                }

                TapHandler {
                    onTapped: root.confirming = true
                }

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 6
                    anchors.rightMargin: 6
                    spacing: 6

                    Text {
                        Layout.fillWidth: true
                        elide: Text.ElideRight
                        color: "#f85149"
                        font.pixelSize: 11
                        text: root.point ? I18n.t("Cancella la lettura delle %1").arg(root.point.when) : ""
                    }

                    Text {
                        color: "#484f58"
                        font.pixelSize: 9
                        font.family: "monospace"
                        text: root.point ? root.point.value : ""
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                visible: root.confirming
                spacing: 4

                Text {
                    Layout.fillWidth: true
                    Layout.leftMargin: 6
                    color: "#8b949e"
                    font.pixelSize: 10
                    text: I18n.t("cancellare da Home Assistant?")
                }

                Repeater {
                    model: [
                        {
                            label: I18n.t("sì"),
                            accept: true
                        },
                        {
                            label: I18n.t("no"),
                            accept: false
                        }
                    ]

                    Rectangle {
                        id: answer

                        required property var modelData

                        implicitWidth: 26
                        implicitHeight: 20
                        radius: 4
                        color: answer.modelData.accept ? "#3d1418" : "#21262d"
                        border.width: 1
                        border.color: answer.modelData.accept ? "#f85149" : "#30363d"

                        Text {
                            anchors.centerIn: parent
                            color: answer.modelData.accept ? "#f85149" : "#8b949e"
                            font.pixelSize: 10
                            text: answer.modelData.label
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                root.confirming = false;

                                if (!answer.modelData.accept)
                                    return;

                                root.waiting = true;
                                HomeAssistant.deletePoint(root.point.entity, root.point.index);
                            }
                        }
                    }
                }
            }

            // L'esito, per il tempo che serve a leggerlo: la riuscita chiude il
            // menu da se' (vedi sotto), quindi qui resta solo cio' che l'utente
            // deve sapere — un errore, o un intervallo in cui non c'era piu'
            // niente perche' qualcuno aveva gia' cancellato.
            Text {
                Layout.fillWidth: true
                Layout.leftMargin: 6
                visible: root.waiting
                wrapMode: Text.Wrap
                font.pixelSize: 10
                color: HomeAssistant.deleteError !== "" ? "#f85149" : "#8b949e"
                text: {
                    if (HomeAssistant.deleting)
                        return I18n.t("cancellazione in corso…");
                    if (HomeAssistant.deleteError !== "")
                        return HomeAssistant.deleteError;
                    return I18n.t("niente da cancellare qui");
                }
            }
        }
    }

    // La riuscita si vede nel grafico, che si ridisegna senza quella lettura:
    // un menu che resta aperto sopra il risultato e' un menu da chiudere a
    // mano per vedere cio' che si e' appena chiesto.
    Connections {
        target: HomeAssistant

        function onDeletingChanged(): void {
            if (!root.waiting || HomeAssistant.deleting)
                return;

            if (HomeAssistant.deleteError === "" && HomeAssistant.deletedRows > 0)
                root.close();
        }
    }
}
