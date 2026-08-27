import QtQuick
import QtQuick.Layouts

// Il pannello sta in panels/: senza `import ".."` si caricherebbe lo stesso,
// ma SystemStats, Settings, I18n e i componenti della dashboard resterebbero
// indefiniti — vedi scripts/panels.py, che verifica la riga e lo dice.
import ".."

// Il battito del braccialetto, e i numeri della giornata sotto.
//
// L'etichetta con l'eta' del dato non e' un ornamento: fra il polso e questo
// grafico passa la sincronizzazione dell'app Fitbit, che arriva a blocchi ogni
// venti o trenta minuti. Senza quella riga, un battito di mezz'ora fa si legge
// come se fosse di adesso — ed e' l'unica differenza fra le due cose.
ColumnLayout {
    id: panel

    // L'id ferma il pannello nella configurazione salvata (le colonne
    // di dashboard.json lo citano) e lo distingue nel catalogo; il titolo
    // e' quello che la finestra Opzioni mostra. Dichiarati qui, il
    // catalogo e' tutto scoperto da panels/ e Settings non tiene elenchi.
    property string panelId: "heart"
    property string panelTitle: "Battito"

    // I valori che prima erano scritti nel codice e adesso stanno nel file
    // di configurazione (sezione "panelParams" di dashboard.json): qui
    // resta solo il default, che il pannello registra al primo avvio.
    readonly property var defs: ({ minSpanBpm: 20 })
    // Ampiezza minima del grafico: sotto, ingrandirebbe il rumore di un
    // polso fermo fino a farlo sembrare una corsa.
    readonly property int minSpanBpm: Settings.panelParam("heart", "minSpanBpm", defs.minSpanBpm)

    Component.onCompleted: {
        Fitbit.watch();
        Settings.declarePanelParams("heart", defs);
    }

    Component.onDestruction: Fitbit.unwatch()

    spacing: 8

    readonly property int minutesOld: Fitbit.lagSeconds < 0 ? -1 : Math.round(Fitbit.lagSeconds / 60)

    function ago(minutes) {
        if (minutes < 1)
            return I18n.t("adesso");
        if (minutes < 60)
            return I18n.t("%1 min fa").arg(minutes);
        return I18n.t("%1 h fa").arg((minutes / 60).toFixed(1));
    }

    // Un nome fra cui scegliere. Il tasto ⟳ dell'intestazione non si presta a
    // fare anche da stampo: quello e' un glifo quadrato che gira, questi sono
    // etichette larghe quanto il nome che portano.
    component Choice: Rectangle {
        id: choice

        required property string label

        signal chosen

        implicitWidth: name.implicitWidth + 14
        implicitHeight: 20
        radius: 4
        color: choiceHover.hovered ? "#21262d" : "transparent"
        border.width: 1
        border.color: choiceHover.hovered ? "#58a6ff" : "#30363d"

        Text {
            id: name

            anchors.centerIn: parent
            color: choiceHover.hovered ? "#58a6ff" : "#8b949e"
            font.pixelSize: 11
            text: choice.label
        }

        HoverHandler {
            id: choiceHover

            cursorShape: Qt.PointingHandCursor
        }

        TapHandler {
            onSingleTapped: choice.chosen()
        }
    }

    RowLayout {
        Layout.fillWidth: true

        Text {
            Layout.fillWidth: true
            color: "#c9d1d9"
            font.pixelSize: 12
            text: I18n.t("Battito")
        }

        // L'eta' del dato sta prima del numero e in grigio: si legge dopo il
        // battito ma prima di crederci.
        Text {
            color: "#8b949e"
            font.pixelSize: 11
            visible: panel.minutesOld >= 0
            text: panel.ago(panel.minutesOld)
        }

        Text {
            color: Settings.colorFor("heart", "#f85149")
            font.pixelSize: 12
            font.bold: true
            text: Fitbit.latest ? `${Fitbit.latest.bpm} bpm` : "—"
        }

        // Il giro automatico e' al minuto, ma i dati arrivano a blocchi da
        // molto piu' lontano: chi ha appena visto l'app Fitbit sincronizzare
        // vuole guardare adesso, non al prossimo minuto. Il gesto c'era gia' —
        // doppio tap sul grafico — ma un gesto senza niente addosso lo conosce
        // solo chi ha letto il codice.
        Rectangle {
            id: poll

            readonly property bool can: !Fitbit.loading

            implicitWidth: 20
            implicitHeight: 18
            radius: 4
            color: poll.can && pollHover.hovered ? "#21262d" : "transparent"
            border.width: 1
            border.color: poll.can && pollHover.hovered ? "#30363d" : "#21262d"

            Text {
                id: glyph

                anchors.centerIn: parent
                color: !poll.can ? "#484f58" : (pollHover.hovered ? "#58a6ff" : "#8b949e")
                font.pixelSize: 11
                text: "⟳"

                // Gira finche' dura la lettura, e la lettura dura qualche
                // secondo di telefono: senza, fra un pulsante premuto e un
                // pulsante che non ha sentito il clic non ci sarebbe
                // differenza visibile. A fine giro torna dritto, altrimenti
                // resterebbe storto all'angolo in cui e' finito.
                RotationAnimation on rotation {
                    id: spin

                    running: Fitbit.loading
                    loops: Animation.Infinite
                    from: 0
                    to: 360
                    duration: 900
                    onRunningChanged: {
                        if (!spin.running)
                            glyph.rotation = 0;
                    }
                }
            }

            HoverHandler {
                id: pollHover

                cursorShape: poll.can ? Qt.PointingHandCursor : Qt.ArrowCursor
            }

            Tooltip {
                hovered: pollHover.hovered
                text: poll.can ? I18n.t("chiedi adesso il battito al telefono") : I18n.t("lettura in corso…")
            }

            TapHandler {
                onSingleTapped: {
                    if (!poll.can)
                        return;

                    Fitbit.refresh();
                    Fitbit.refreshToday();
                }
            }
        }
    }

    HistoryChart {
        Layout.fillWidth: true
        implicitHeight: 64
        values: Fitbit.values
        hours: Settings.heartWindowHours
        decimals: 0
        // Venti battiti di ampiezza minima: sotto, il grafico ingrandirebbe il
        // rumore di un polso fermo fino a farlo sembrare una corsa.
        minSpan: panel.minSpanBpm
        lineColor: Settings.colorFor("heart", "#f85149")
        series: [
            {
                id: "heart",
                label: I18n.t("Battito"),
                fallback: "#f85149"
            }
        ]

        TapHandler {
            acceptedButtons: Qt.LeftButton
            onDoubleTapped: {
                Fitbit.refresh();
                Fitbit.refreshToday();
            }
        }
    }

    // Perche' il grafico e' vuoto, quando lo e'. Le tre ragioni portano a tre
    // gesti diversi, e un pannello muto le farebbe sembrare la stessa cosa.
    Text {
        Layout.fillWidth: true
        color: "#8b949e"
        font.pixelSize: 11
        wrapMode: Text.WordWrap
        visible: text !== ""
        text: {
            if (Fitbit.lastError)
                return Fitbit.lastError;
            if (!Fitbit.loaded)
                return Fitbit.loading ? I18n.t("lettura in corso…") : "";
            if (!Fitbit.span)
                return I18n.t("nessun dato dal braccialetto in questa finestra");
            return "";
        }
    }

    // Quando l'errore e' «manca la chiave», la chiave si da' qui.
    //
    // E' lo stesso principio della riga dei telefoni qui sotto: un pannello che
    // dice cosa manca e non lascia darlo manda a cercare un terminale per un
    // comando solo, e chi ha il telefono in mano con il QR aperto ce l'ha
    // davanti adesso, non fra dieci minuti.
    //
    // La chiave non si nasconde mentre la si scrive: sta gia' in chiaro sullo
    // schermo del telefono da cui la si sta copiando, e mascherarla toglierebbe
    // solo la possibilita' di accorgersi di un carattere sbagliato.
    ColumnLayout {
        Layout.fillWidth: true
        spacing: 4
        visible: Fitbit.needsToken

        RowLayout {
            Layout.fillWidth: true
            spacing: 6

            Rectangle {
                Layout.fillWidth: true
                implicitHeight: 26
                radius: 5
                color: "#0d1117"
                border.width: 1
                border.color: key.activeFocus ? "#58a6ff" : "#30363d"

                TextInput {
                    id: key

                    anchors.fill: parent
                    anchors.leftMargin: 8
                    anchors.rightMargin: 8
                    verticalAlignment: TextInput.AlignVCenter
                    color: "#c9d1d9"
                    font.pixelSize: 12
                    font.family: "monospace"
                    enabled: !Fitbit.pairing
                    // Nove caratteri di un alfabeto senza le lettere che si
                    // confondono con le cifre: e' cosi' che l'app la genera, e
                    // filtrare qui evita di mandare allo script una chiave che
                    // non puo' essere giusta.
                    maximumLength: 9
                    validator: RegularExpressionValidator {
                        regularExpression: /[a-hj-km-np-z2-9]*/
                    }
                    // Quella registrata, quando ce n'e' una: qui si arriva
                    // anche perche' il telefono l'ha rifiutata, e in quel caso
                    // un campo vuoto nasconde proprio cio' che serve
                    // confrontare con la chiave nuova.
                    text: Fitbit.token
                    onAccepted: Fitbit.pair(key.text)

                    // Il binding si spezza al primo carattere scritto, che e'
                    // giusto; ma allora una chiave cambiata dalle opzioni
                    // mentre questo campo e' aperto non comparirebbe qui.
                    Connections {
                        target: Fitbit

                        function onTokenChanged() {
                            key.text = Fitbit.token;
                        }
                    }

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: key.text === ""
                        color: "#484f58"
                        font.pixelSize: 11
                        text: I18n.t("la chiave scritta nell'app, poi Invio")
                    }
                }
            }

            Choice {
                label: Fitbit.pairing ? I18n.t("collego…") : I18n.t("Collega")
                onChosen: Fitbit.pair(key.text)
            }
        }

        Text {
            Layout.fillWidth: true
            color: "#8b949e"
            font.pixelSize: 10
            wrapMode: Text.WordWrap
            visible: text !== ""
            text: Fitbit.pairError
        }
    }

    // Quando l'errore e' «indica quale telefono», i telefoni stanno qui sotto:
    // un messaggio che chiede di scegliere in un pannello dove non si sceglie
    // niente e' un vicolo cieco, e la scelta resta salvata come se fosse stata
    // fatta dalle opzioni.
    RowLayout {
        Layout.fillWidth: true
        spacing: 6
        visible: Fitbit.choices.length > 0

        Text {
            color: "#6e7681"
            font.pixelSize: 11
            text: I18n.t("quale:")
        }

        Repeater {
            model: Fitbit.choices

            Choice {
                required property string modelData

                label: modelData
                onChosen: {
                    Settings.setHeartDevice(modelData);
                    Fitbit.refresh();
                    Fitbit.refreshToday();
                }
            }
        }

        Item {
            Layout.fillWidth: true
        }
    }

    RowLayout {
        Layout.fillWidth: true
        spacing: 12
        visible: Fitbit.span !== null

        Text {
            color: "#8b949e"
            font.pixelSize: 11
            text: Fitbit.span
                ? I18n.t("min %1 · media %2 · max %3")
                    .arg(Fitbit.span.min.toFixed(0))
                    .arg(Fitbit.span.avg.toFixed(0))
                    .arg(Fitbit.span.max.toFixed(0))
                : ""
        }
    }

    // I numeri della giornata. Quelli che Health Connect non ha restano "n/d":
    // "non lo so" e "zero" sono due cose diverse, e mostrarle uguali farebbe
    // sembrare rotto un braccialetto che sta solo dormendo.
    GridLayout {
        Layout.fillWidth: true
        columns: 4
        columnSpacing: 10
        rowSpacing: 3
        visible: Fitbit.today !== null

        component Cell: Text {
            color: "#8b949e"
            font.pixelSize: 11
        }

        Cell {
            text: I18n.t("passi")
        }
        Cell {
            color: "#c9d1d9"
            text: Fitbit.today && Fitbit.today.steps !== null ? String(Fitbit.today.steps) : I18n.t("n/d")
        }
        Cell {
            text: I18n.t("km")
        }
        Cell {
            color: "#c9d1d9"
            text: Fitbit.today && Fitbit.today.distanceMeters !== null ? (Fitbit.today.distanceMeters / 1000).toFixed(2) : I18n.t("n/d")
        }

        Cell {
            text: I18n.t("kcal")
        }
        Cell {
            color: "#c9d1d9"
            text: Fitbit.today && Fitbit.today.calories !== null ? Fitbit.today.calories.toFixed(0) : I18n.t("n/d")
        }
        Cell {
            text: I18n.t("sonno")
        }
        Cell {
            color: "#c9d1d9"
            text: {
                const sleep = Fitbit.today ? Fitbit.today.sleep : null;
                if (!sleep)
                    return I18n.t("n/d");
                const hours = Math.floor(sleep.seconds / 3600);
                const minutes = Math.round((sleep.seconds % 3600) / 60);
                return `${hours}h ${minutes}m`;
            }
        }
    }
}
