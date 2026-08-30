import QtQuick
import QtQuick.Layouts

// Una caratteristica del pet nella finestra che le configura.
//
// Due editor in un file solo, uno per ruolo: quello di BENESSERE ha il campo
// della barra e le soglie che decidono quando il pet comincia a stare male,
// quello a OGGETTI ha una soglia sola, l'attesa, il riposo e cosa cade. Un
// file per ruolo sarebbe stato piu' pulito a guardarlo da fuori e peggiore da
// usare: meta' della riga — nome, sensore, valore vivo, apri e chiudi — e' la
// stessa, e duplicarla vuol dire due posti in cui correggere ogni ritocco.
//
// Sta in un file suo come ServiceRow e EntityRow: la riga ha sei controlli e
// una logica sua, e infilarla nel pannello renderebbe illeggibili tutti e due.
Rectangle {
    id: row

    // La caratteristica come sta nel file (PetTraits.traits), non come la
    // risolve PetTraits.list: qui si modifica la configurazione, e il valore
    // vivo serve solo da riscontro.
    required property var trait

    // La stessa caratteristica risolta, per mostrare quanto legge adesso il
    // sensore. null finche' non c'e' un valore.
    readonly property var live: PetTraits.list.find(t => t.id === row.trait.id) ?? null

    // Il passo e il tetto, con gli stessi ripieghi che usa PetTraits: cosi' i
    // due numeri mostrati qui sono quelli che la stanza usera' davvero.
    readonly property real step: row.trait.particleStep > 0 ? row.trait.particleStep : PetTraits.defaultStep(row.trait.min ?? 0, row.trait.max ?? 100)
    readonly property real base: row.trait.particleBase !== undefined ? row.trait.particleBase : (row.trait.min ?? 0)
    readonly property int cap: Settings.panelParam("pet", "particleMax", 40)

    function countAt(v) {
        if (v === null || v === undefined)
            return 0;
        return Math.max(0, Math.min(row.cap, Math.floor((v - row.base) / Math.max(1e-9, row.step))));
    }

    readonly property int moleculeCount: row.live ? row.countAt(row.live.value) : 0
    readonly property int moleculeCountAtMax: row.countAt(row.trait.max ?? 100)

    readonly property string role: PetTraits.roleOf(row.trait)
    readonly property bool isDrop: row.role === "drop"

    // Aperta o chiusa. 🔴 NON e' uno stato di questo file: lo possiede la
    // finestra, perche' aperta ne va una sola e perche' un ListView RICICLA i
    // delegate mentre si scorre — tenuto qui, si perderebbe da solo appena la
    // riga esce dallo schermo.
    required property bool open

    signal toggled

    // L'oggetto che cade, gia' risolto col suo ripiego.
    readonly property var dropItem: PetTraits.dropItemById(row.trait.item ?? "apple")

    // Quale dei due cataloghi si sta ampliando: "" (nessuno), "bonus", "malus".
    // Uno solo alla volta, cosi' il campo del glifo e' sempre uno e non c'e'
    // modo di scrivere in quello sbagliato.
    property string adding: ""

    function commitEmoji() {
        const id = PetTraits.addDropItem(glyphInput.text, emojiName.text, row.adding);
        if (id === "")
            return;
        // Scelto subito: chi aggiunge un'emoji la sta aggiungendo per usarla,
        // e farla scegliere di nuovo dal chip appena comparso sarebbe un
        // passo in piu' ogni volta.
        row.setAll({
            item: id,
            gift: PetTraits.giftOf({
                item: id
            })
        });
        glyphInput.text = "";
        emojiName.text = "";
        row.adding = "";
    }

    readonly property real threshold: typeof row.trait.threshold === "number" && isFinite(row.trait.threshold) ? row.trait.threshold : 0
    readonly property bool dropBelow: row.trait.dropWhen === "below"

    // Se adesso la condizione e' vera. E' il riscontro che dice se la soglia
    // e' quella giusta: senza, si salva e si aspetta cinque minuti per
    // scoprire che il verso era al contrario.
    readonly property var dropNow: {
        if (!row.isDrop || !row.live || row.live.value === null)
            return null;
        return row.dropBelow ? row.live.value < row.threshold : row.live.value > row.threshold;
    }

    readonly property string direction: row.trait.direction ?? "low"
    readonly property bool band: row.direction === "band"

    // La rampa piu' stretta fra quelle attive. Zero = gradino.
    readonly property real rampWidth: {
        const good = row.trait.good ?? 0;
        const bad = row.trait.bad ?? 100;
        if (row.direction === "high")
            return Math.abs(good - bad);
        if (!row.band)
            return Math.abs(bad - good);
        const lowBad = row.trait.lowBad ?? 0;
        const goodHigh = row.trait.goodHigh ?? good;
        return Math.min(Math.abs(good - lowBad), Math.abs(bad - goodHigh));
    }

    implicitHeight: body.implicitHeight + 20
    radius: 8
    color: "#0d1117"
    border.width: 1
    border.color: row.live && row.live.critical ? "#f85149" : "#21262d"

    function weightOf(key) {
        const e = row.trait.effects;
        const v = e ? e[key] : undefined;
        return typeof v === "number" && isFinite(v) ? v : 0;
    }

    // I pesi stanno in una sezione annidata, quindi non basta `set`: si
    // ricostruisce l'oggetto intero, come si fa in tutto il resto del file.
    function setEffect(key, value) {
        const effects = {};
        for (const k of PetTraits.statKeys)
            effects[k] = row.weightOf(k);
        effects[key] = value;
        row.set("effects", effects);
    }

    // Scrive un campo solo e salva. Il file si riscrive intero (vedi
    // PetTraits.save): sono manciate di oggetti, e una riscrittura sola tiene
    // lontano il caso di due modifiche parziali che si incrociano.
    function set(key, value) {
        const next = {};
        for (const k in row.trait)
            next[k] = row.trait[k];
        next[key] = value;
        PetTraits.upsert(next);
    }

    // Cambiare ruolo riempie i campi che l'altro ruolo non ha mai scritto: una
    // caratteristica passata a benessere senza `min` e `max` cadrebbe sui
    // ripieghi 0-100 e mostrerebbe un profilo che non vuol dire niente, e una
    // passata a oggetti senza soglia ne avrebbe una a zero — sempre superata.
    function setRole(next) {
        if (next === row.role)
            return;
        const value = row.live && row.live.value !== null ? row.live.value : 0;
        const base = PetTraits.defaultsFor(row.trait.source, value, next);
        const out = {};
        for (const k in row.trait)
            out[k] = row.trait[k];
        for (const k in base)
            if (out[k] === undefined)
                out[k] = base[k];
        out.role = next;
        PetTraits.upsert(out);
    }

    // Come `set`, ma piu' campi in un colpo. Due `set` di fila riscriverebbero
    // il file due volte, e il secondo partirebbe da un `row.trait` che e' gia'
    // quello di prima: la seconda scrittura cancellerebbe la prima.
    function setAll(patch) {
        const out = {};
        for (const k in row.trait)
            out[k] = row.trait[k];
        for (const k in patch)
            out[k] = patch[k];
        PetTraits.upsert(out);
    }

    // Un numero, con la sua etichetta sopra.
    //
    // Accetta anche il punto e la virgola: chi scrive una soglia in italiano
    // batte la virgola, e rifiutarla vorrebbe dire un campo che non reagisce
    // senza dire perche'.
    component Num: ColumnLayout {
        id: num

        required property string label
        required property real value
        property string hint: ""

        signal edited(real v)

        spacing: 2

        Text {
            color: "#6e7681"
            font.pixelSize: 10
            text: num.label
        }

        Rectangle {
            Layout.fillWidth: true
            implicitWidth: 64
            implicitHeight: 24
            radius: 5
            color: "#161b22"
            border.width: 1
            border.color: input.activeFocus ? "#58a6ff" : "#30363d"

            TextInput {
                id: input

                anchors.fill: parent
                anchors.leftMargin: 7
                anchors.rightMargin: 7
                verticalAlignment: TextInput.AlignVCenter
                clip: true
                color: "#c9d1d9"
                font.pixelSize: 11
                selectionColor: "#1f6feb"
                selectedTextColor: "#ffffff"
                text: String(num.value)

                // Il binding si spezza al primo carattere scritto, ed e'
                // giusto; ma allora un valore cambiato da fuori — il file
                // corretto a mano mentre la finestra e' aperta — non
                // comparirebbe piu' qui.
                Connections {
                    target: num

                    function onValueChanged() {
                        if (!input.activeFocus)
                            input.text = String(num.value);
                    }
                }

                function commit() {
                    const n = parseFloat(input.text.replace(",", "."));
                    if (isFinite(n))
                        num.edited(n);
                    else
                        input.text = String(num.value);
                }

                onEditingFinished: input.commit()
                Keys.onReturnPressed: input.commit()

                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: input.text === ""
                    color: "#484f58"
                    font.pixelSize: 11
                    text: num.hint
                }
            }
        }
    }

    // Una scelta fra poche, come le etichette cliccabili del resto della
    // dashboard.
    component Chip: Rectangle {
        id: chip

        required property string label
        required property bool current

        signal chosen

        implicitWidth: chipText.implicitWidth + 16
        implicitHeight: 22
        radius: 5
        color: chip.current ? "#21262d" : "transparent"
        border.width: 1
        border.color: chip.current ? "#58a6ff" : "#30363d"

        Text {
            id: chipText

            anchors.centerIn: parent
            color: chip.current ? "#58a6ff" : "#8b949e"
            font.pixelSize: 11
            text: chip.label
        }

        // Esposto perche' i chip delle molecole ci appendono un Tooltip: senza,
        // «CO₂» e «O₃» sono due sigle e basta, e quale sia piegata a 117° non
        // lo dice nessuno.
        readonly property alias hovered: chipArea.containsMouse

        MouseArea {
            id: chipArea

            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: chip.chosen()
        }
    }

    ColumnLayout {
        id: body

        anchors.fill: parent
        anchors.margins: 10
        spacing: 8

        // ------------------------------------------------ nome e valore vivo
        //
        // Tutta la barra apre e chiude la riga: aperta ne va una sola, e con
        // sei controlli per caratteristica un elenco sempre spalancato non ci
        // sta in nessuna finestra.
        Item {
            Layout.fillWidth: true
            implicitHeight: 24

            // 🔴 Dichiarata PRIMA della RowLayout, e non e' un caso: in QML
            // l'ordine di dichiarazione e' l'ordine di disegno, e l'input va a
            // chi sta sopra. Cosi' il campo del nome, i chip e la ✕ si
            // prendono i loro clic, e tutto il resto della barra apre e chiude.
            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: row.toggled()
            }

            RowLayout {
                anchors.fill: parent
                spacing: 8

                Text {
                    Layout.preferredWidth: 10
                    color: "#6e7681"
                    font.pixelSize: 11
                    text: row.open ? "⌄" : "›"
                }

                // A riga chiusa il nome non si modifica, si legge: un campo di
                // testo in un elenco di sole intestazioni invita a scriverci
                // dentro quando quello che si vuole e' aprire.
                Text {
                    visible: !row.open
                    Layout.preferredWidth: 120
                    elide: Text.ElideRight
                    color: "#c9d1d9"
                    font.pixelSize: 12
                    textFormat: Text.PlainText
                    text: row.trait.label && row.trait.label.length > 0 ? row.trait.label : PetTraits.sourceName(row.trait.source)
                }


                Rectangle {
                    visible: row.open
                    Layout.preferredWidth: 120
                    implicitHeight: 24
                    radius: 5
                    color: "#161b22"
                    border.width: 1
                    border.color: nameInput.activeFocus ? "#58a6ff" : "#30363d"

                    TextInput {
                        id: nameInput

                        anchors.fill: parent
                        anchors.leftMargin: 7
                        anchors.rightMargin: 7
                        verticalAlignment: TextInput.AlignVCenter
                        clip: true
                        color: "#c9d1d9"
                        font.pixelSize: 12
                        selectionColor: "#1f6feb"
                        selectedTextColor: "#ffffff"
                        maximumLength: 16
                        text: row.trait.label ?? ""
                        onEditingFinished: row.set("label", nameInput.text.trim())
                        Keys.onReturnPressed: row.set("label", nameInput.text.trim())

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            visible: nameInput.text === ""
                            color: "#484f58"
                            font.pixelSize: 11
                            text: I18n.t("nome")
                        }
                    }
                }

                // Il sensore a cui e' attaccata, per nome amichevole: l'entity_id
                // per esteso non entra e non aiuta a riconoscerla.
                Text {
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                    color: "#8b949e"
                    font.pixelSize: 11
                    text: PetTraits.sourceName(row.trait.source)
                }

                // Quanto legge adesso, e il benessere che ne esce. E' il riscontro
                // che dice se si e' collegato il sensore giusto — senza, si salva e
                // si va a guardare il pannello per scoprirlo.
                Text {
                    color: !row.live || row.live.wellness === null ? "#484f58" : (row.live.critical ? "#f85149" : "#c9d1d9")
                    font.pixelSize: 11
                    font.bold: true
                    text: row.live ? row.live.text : "—"
                }

                Text {
                    visible: row.live !== null && row.live.wellness !== null
                    color: "#6e7681"
                    font.pixelSize: 11
                    text: row.live && row.live.wellness !== null ? `· ${Math.round(row.live.wellness)}%` : ""
                }

                Rectangle {
                    implicitWidth: 22
                    implicitHeight: 22
                    radius: 5
                    color: killHover.hovered ? "#21262d" : "transparent"
                    border.width: 1
                    border.color: killHover.hovered ? "#f85149" : "#30363d"

                    Text {
                        anchors.centerIn: parent
                        color: killHover.hovered ? "#f85149" : "#6e7681"
                        font.pixelSize: 11
                        text: "✕"
                    }

                    HoverHandler {
                        id: killHover

                        cursorShape: Qt.PointingHandCursor
                    }

                    Tooltip {
                        hovered: killHover.hovered
                        text: I18n.t("togli questa caratteristica")
                    }

                    TapHandler {
                        onSingleTapped: PetTraits.remove(row.trait.id)
                    }
                }

                // La regola in una riga, per l'elenco chiuso: senza, due
                // caratteristiche a oggetti sullo stesso sensore sono due
                // righe identiche e bisogna aprirle per sapere quale e' quale.
                Text {
                    visible: !row.open && row.isDrop
                    color: "#6e7681"
                    font.pixelSize: 10
                    textFormat: Text.PlainText
                    text: `${row.dropItem.glyph} ${row.dropBelow ? I18n.t("sotto") : I18n.t("sopra")} ${PetTraits.pretty(row.threshold)}`
                }
            }
        }

        // ------------------------------------------------------------ ruolo
        //
        // Le due meccaniche, e una caratteristica ne fa una sola. In cima
        // perche' decide che cosa sono tutti i controlli sotto: cambiarlo
        // scambia meta' della riga.
        RowLayout {
            Layout.fillWidth: true
            spacing: 6
            visible: row.open

            Text {
                color: "#6e7681"
                font.pixelSize: 10
                text: I18n.t("questo sensore")
            }

            Chip {
                label: I18n.t("fa il benessere")
                current: !row.isDrop
                onChosen: row.setRole("wellness")
            }

            Chip {
                label: I18n.t("fa cadere un oggetto")
                current: row.isDrop
                onChosen: row.setRole("drop")
            }

            Item {
                Layout.fillWidth: true
            }
        }

        // ------------------------------------------------- quando cade
        ColumnLayout {
            Layout.fillWidth: true
            spacing: 6
            visible: row.open && row.isDrop

            RowLayout {
                Layout.fillWidth: true
                spacing: 6

                Text {
                    color: "#6e7681"
                    font.pixelSize: 10
                    text: I18n.t("cade se il valore resta")
                }

                Chip {
                    label: I18n.t("sopra")
                    current: !row.dropBelow
                    onChosen: row.set("dropWhen", "above")
                }

                Chip {
                    label: I18n.t("sotto")
                    current: row.dropBelow
                    onChosen: row.set("dropWhen", "below")
                }

                Item {
                    Layout.fillWidth: true
                }

                // Il riscontro vivo, con la stessa ragione del profilo del
                // benessere: senza, si sceglie una soglia e si aspetta cinque
                // minuti per scoprire che il verso era al contrario.
                Text {
                    color: row.dropNow === null ? "#484f58" : (row.dropNow ? "#d29922" : "#6e7681")
                    font.pixelSize: 10
                    textFormat: Text.PlainText
                    text: {
                        if (!row.live || row.live.value === null)
                            return I18n.t("adesso non si sa");
                        return row.dropNow ? I18n.t("adesso %1: la condizione è vera").arg(row.live.text) : I18n.t("adesso %1: la condizione è falsa").arg(row.live.text);
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                Num {
                    label: I18n.t("soglia")
                    value: row.threshold
                    onEdited: v => row.set("threshold", v)
                }

                Num {
                    label: I18n.t("per (minuti)")
                    value: row.trait.holdMinutes ?? 5
                    onEdited: v => row.set("holdMinutes", v)
                }

                Num {
                    label: I18n.t("poi riposa (minuti)")
                    value: row.trait.cooldownMinutes ?? 10
                    onEdited: v => row.set("cooldownMinutes", v)
                }

                Item {
                    Layout.fillWidth: true
                }
            }

            // ------------------------------------------- che cosa cade
            //
            // Il clic scrive l'oggetto E i suoi punti in un colpo solo:
            // scegliere la bomba deve dare subito i numeri della bomba, e
            // lasciare quelli di prima sarebbe un chip che sembra non aver
            // fatto niente. Chi vuole i suoi li scrive dopo, qui sotto.
            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                Text {
                    Layout.alignment: Qt.AlignTop
                    Layout.topMargin: 3
                    Layout.preferredWidth: 54
                    color: "#6e7681"
                    font.pixelSize: 10
                    text: I18n.t("regali")
                }

                Flow {
                    Layout.fillWidth: true
                    spacing: 4

                    Repeater {
                        model: PetTraits.dropItems.filter(d => d.kind === "bonus")

                        Chip {
                            required property var modelData

                            label: `${modelData.glyph} ${modelData.label}`
                            current: (row.trait.item ?? "apple") === modelData.id
                            onChosen: row.setAll({
                                item: modelData.id,
                                gift: modelData.gift
                            })

                            Tooltip {
                                hovered: parent.hovered
                                text: modelData.hint.length > 0 ? modelData.hint : I18n.t("aggiunta da te")
                            }
                        }
                    }

                    Chip {
                        label: row.adding === "bonus" ? I18n.t("chiudi") : I18n.t("+ emoji")
                        current: row.adding === "bonus"
                        onChosen: row.adding = (row.adding === "bonus" ? "" : "bonus")

                        Tooltip {
                            hovered: parent.hovered
                            text: I18n.t("aggiungi un'emoji ai regali")
                        }
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                Text {
                    Layout.alignment: Qt.AlignTop
                    Layout.topMargin: 3
                    Layout.preferredWidth: 54
                    color: "#6e7681"
                    font.pixelSize: 10
                    text: I18n.t("dispetti")
                }

                Flow {
                    Layout.fillWidth: true
                    spacing: 4

                    Repeater {
                        model: PetTraits.dropItems.filter(d => d.kind === "malus")

                        Chip {
                            required property var modelData

                            label: `${modelData.glyph} ${modelData.label}`
                            current: (row.trait.item ?? "apple") === modelData.id
                            onChosen: row.setAll({
                                item: modelData.id,
                                gift: modelData.gift
                            })

                            Tooltip {
                                hovered: parent.hovered
                                text: modelData.hint.length > 0 ? modelData.hint : I18n.t("aggiunta da te")
                            }
                        }
                    }

                    Chip {
                        label: row.adding === "malus" ? I18n.t("chiudi") : I18n.t("+ emoji")
                        current: row.adding === "malus"
                        onChosen: row.adding = (row.adding === "malus" ? "" : "malus")

                        Tooltip {
                            hovered: parent.hovered
                            text: I18n.t("aggiungi un'emoji ai dispetti")
                        }
                    }
                }
            }

            // ------------------------------------------- aggiungi un'emoji
            //
            // Si apre col «+ emoji» di una delle due file e aggiunge LA' —
            // cioe' fra i regali o fra i dispetti — perche' il segno di un
            // oggetto e' la prima cosa da sapere e sceglierlo dopo, in un
            // campo, sarebbe una domanda in piu' a cui si puo' rispondere
            // male. I quattro punti nascono a ±10 di allegria e si correggono
            // qui sotto: un oggetto che non fa niente sembrerebbe un guasto.
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 6
                visible: row.adding !== ""

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8

                    Rectangle {
                        Layout.preferredWidth: 54
                        implicitHeight: 26
                        radius: 5
                        color: "#161b22"
                        border.width: 1
                        border.color: glyphInput.activeFocus ? "#58a6ff" : "#30363d"

                        TextInput {
                            id: glyphInput

                            anchors.fill: parent
                            anchors.leftMargin: 7
                            anchors.rightMargin: 7
                            verticalAlignment: TextInput.AlignVCenter
                            horizontalAlignment: TextInput.AlignHCenter
                            clip: true
                            color: "#c9d1d9"
                            font.pixelSize: 15
                            selectionColor: "#1f6feb"
                            selectedTextColor: "#ffffff"
                            Keys.onReturnPressed: row.commitEmoji()
                            Keys.onEscapePressed: row.adding = ""

                            Text {
                                anchors.centerIn: parent
                                visible: glyphInput.text === ""
                                color: "#484f58"
                                font.pixelSize: 13
                                text: "🙂"
                            }
                        }
                    }

                    Rectangle {
                        Layout.preferredWidth: 130
                        implicitHeight: 26
                        radius: 5
                        color: "#161b22"
                        border.width: 1
                        border.color: emojiName.activeFocus ? "#58a6ff" : "#30363d"

                        TextInput {
                            id: emojiName

                            anchors.fill: parent
                            anchors.leftMargin: 7
                            anchors.rightMargin: 7
                            verticalAlignment: TextInput.AlignVCenter
                            clip: true
                            color: "#c9d1d9"
                            font.pixelSize: 11
                            selectionColor: "#1f6feb"
                            selectedTextColor: "#ffffff"
                            maximumLength: 16
                            Keys.onReturnPressed: row.commitEmoji()
                            Keys.onEscapePressed: row.adding = ""

                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                visible: emojiName.text === ""
                                color: "#484f58"
                                font.pixelSize: 11
                                text: I18n.t("nome (facoltativo)")
                            }
                        }
                    }

                    Chip {
                        label: row.adding === "malus" ? I18n.t("aggiungi ai dispetti") : I18n.t("aggiungi ai regali")
                        current: glyphInput.text.length > 0
                        onChosen: row.commitEmoji()
                    }

                    Item {
                        Layout.fillWidth: true
                    }
                }

                // I propri, con la crocetta per toglierli. Sta qui e non sul
                // chip del catalogo perche' una ✕ su ogni chip sarebbe una ✕
                // accanto a ogni scelta: si toglie da dove si aggiunge.
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 6
                    visible: PetTraits.customDropItems.some(d => d.kind === row.adding)

                    Text {
                        color: "#6e7681"
                        font.pixelSize: 10
                        text: I18n.t("tue:")
                    }

                    Flow {
                        Layout.fillWidth: true
                        spacing: 4

                        Repeater {
                            model: PetTraits.customDropItems.filter(d => d.kind === row.adding)

                            Chip {
                                required property var modelData

                                label: `${modelData.glyph} ${modelData.label} ✕`
                                current: false
                                onChosen: PetTraits.removeDropItem(modelData.id)

                                Tooltip {
                                    hovered: parent.hovered
                                    text: I18n.t("togli questa emoji dal catalogo")
                                }
                            }
                        }
                    }
                }

                Text {
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    color: "#484f58"
                    font.pixelSize: 10
                    text: I18n.t("Incolla un'emoji nel primo campo (su GNOME, Ctrl+. apre la tastiera delle emoji). Vale per tutte le caratteristiche, non solo per questa, e si salva in %1.").arg(PetTraits.dropItemsPath)
                }
            }

            Rectangle {
                Layout.fillWidth: true
                implicitHeight: 1
                color: "#21262d"
            }

            // I punti UNA TANTUM, che sono l'altra meta' della differenza con
            // il benessere: li' sono punti all'ora e agiscono sempre, qui
            // agiscono una volta e solo se il pet ci passa sopra.
            Text {
                color: "#6e7681"
                font.pixelSize: 10
                text: I18n.t("punti una tantum, quando lo raccoglie (una cura ne vale 30-50)")
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                Repeater {
                    model: [
                        {
                            key: "hunger",
                            label: "Fame"
                        },
                        {
                            key: "energy",
                            label: "Energia"
                        },
                        {
                            key: "happiness",
                            label: "Felice"
                        },
                        {
                            key: "hygiene",
                            label: "Pulito"
                        }
                    ]

                    Num {
                        required property var modelData

                        Layout.fillWidth: true
                        label: I18n.t(modelData.label)
                        value: PetTraits.giftOf(row.trait)[modelData.key]
                        onEdited: v => {
                            const gift = PetTraits.giftOf(row.trait);
                            gift[modelData.key] = v;
                            row.set("gift", gift);
                        }
                    }
                }
            }

            Text {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                color: "#484f58"
                font.pixelSize: 10
                text: I18n.t("L'oggetto cade dall'alto e resta a terra pochi secondi: il pet lo prende solo se il suo girovagare ce lo porta sopra, quindi spesso non lo prende. Quanto resta si sceglie nella stanza, qui sopra.")
            }
        }

        // ------------------------------------------------------------ verso
        RowLayout {
            Layout.fillWidth: true
            spacing: 6
            visible: row.open && !row.isDrop

            Text {
                color: "#6e7681"
                font.pixelSize: 10
                text: I18n.t("sta bene quando il valore è")
            }

            Chip {
                label: I18n.t("basso")
                current: row.direction === "low"
                onChosen: row.set("direction", "low")
            }

            Chip {
                label: I18n.t("alto")
                current: row.direction === "high"
                onChosen: row.set("direction", "high")
            }

            Chip {
                label: I18n.t("in mezzo")
                current: row.direction === "band"
                onChosen: row.set("direction", "band")
            }

            Item {
                Layout.fillWidth: true
            }

            // Le molecole nell'aria. Una sola caratteristica alla volta le puo'
            // avere: due nuvole diverse nella stessa stanza non si
            // distinguerebbero, e la stanza smetterebbe di dire qualcosa.
            Chip {
                label: I18n.t("molecole")
                current: row.trait.particles === true
                onChosen: row.set("particles", row.trait.particles !== true)
            }
        }

        // ------------------------------------------------- campo e soglie
        RowLayout {
            Layout.fillWidth: true
            spacing: 8
            visible: row.open && !row.isDrop

            Num {
                label: I18n.t("valore da")
                value: row.trait.min ?? 0
                onEdited: v => row.set("min", v)
            }

            Num {
                label: I18n.t("valore a")
                value: row.trait.max ?? 100
                onEdited: v => row.set("max", v)
            }

            Rectangle {
                Layout.preferredWidth: 1
                Layout.preferredHeight: 30
                Layout.alignment: Qt.AlignVCenter
                color: "#21262d"
            }

            // In «in mezzo» le soglie sono quattro: sotto la prima e sopra
            // l'ultima si sta male, in mezzo si sta bene.
            Num {
                visible: row.band
                label: I18n.t("male sotto")
                value: row.trait.lowBad ?? 0
                onEdited: v => row.set("lowBad", v)
            }

            Num {
                label: row.band ? I18n.t("bene da") : I18n.t("bene fino a")
                value: row.trait.good ?? 0
                onEdited: v => row.set("good", v)
            }

            Num {
                visible: row.band
                label: I18n.t("bene fino a")
                value: row.trait.goodHigh ?? row.trait.good ?? 0
                onEdited: v => row.set("goodHigh", v)
            }

            Num {
                label: I18n.t("male oltre")
                value: row.trait.bad ?? 100
                onEdited: v => row.set("bad", v)
            }

            Item {
                Layout.fillWidth: true
            }
        }

        // ---------------------------------- il profilo del benessere
        //
        // Le quattro soglie sembrano una ripetizione, e a leggerle in fila lo
        // sembrano davvero. Non lo sono: sono i quattro angoli di due RAMPE, e
        // le due coppie dicono quanto in fretta si peggiora. Un disegno lo
        // spiega in un colpo d'occhio dove quattro etichette non ci riescono —
        // e soprattutto si vede subito quando una rampa ha larghezza zero,
        // perche' diventa un muro verticale invece di una salita.
        //
        // Trenta barrette in un Repeater e nessun Canvas: la forma e' quella
        // del benessere lungo tutto il campo, calcolata dalla stessa funzione
        // che usa il pet.
        ColumnLayout {
            Layout.fillWidth: true
            spacing: 3
            visible: row.open && !row.isDrop

            Item {
                Layout.fillWidth: true
                implicitHeight: 34

                Row {
                    id: profile

                    anchors.fill: parent
                    spacing: 1

                    readonly property int slots: 40
                    readonly property real lo: row.trait.min ?? 0
                    readonly property real hi: row.trait.max ?? 100

                    Repeater {
                        model: profile.slots

                        Rectangle {
                            required property int index

                            readonly property real at: profile.lo + (profile.hi - profile.lo) * (index + 0.5) / profile.slots
                            readonly property real w: PetTraits.wellnessOf(row.trait, at) ?? 0

                            width: (profile.width - profile.spacing * (profile.slots - 1)) / profile.slots
                            height: Math.max(1, profile.height * w / 100)
                            y: profile.height - height
                            radius: 1
                            color: w <= 0 ? "#f85149" : (w >= 100 ? "#3fb950" : "#d29922")
                            opacity: 0.85
                        }
                    }
                }

                // Dove sta il valore adesso. Senza, il profilo e' un disegno
                // astratto; con, e' il posto in cui si trova il pet.
                Rectangle {
                    visible: row.live !== null && row.live.value !== null
                    width: 2
                    height: parent.height + 4
                    y: -2
                    x: {
                        if (!row.live || row.live.value === null)
                            return 0;
                        const f = (row.live.value - profile.lo) / Math.max(1e-9, profile.hi - profile.lo);
                        return Math.max(0, Math.min(1, f)) * (parent.width - width);
                    }
                    color: "#c9d1d9"
                }
            }

            Text {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                color: "#484f58"
                font.pixelSize: 10
                // Il muro verticale ha un nome, cosi' chi lo vede sa che e' una
                // scelta e non un guasto.
                text: row.rampWidth <= 0 ? I18n.t("le due soglie coincidono: il benessere salta da 100 a 0, senza rampa") : I18n.t("fra le due soglie il benessere scende a poco a poco: è la pendenza, non un doppione")
            }
        }

        // ------------------------------------- effetto sulle statistiche
        //
        // 🔴 Il motivo per cui una caratteristica esiste, quindi sempre in
        // vista e non dietro un interruttore. Senza un peso, questa
        // caratteristica e' una barra che informa e nient'altro: non puo' piu'
        // far male al pet, perche' l'orologio separato non c'e' piu' — la CO2
        // uccide scaricando l'energia, e la morte resta quella del gioco.
        ColumnLayout {
            Layout.fillWidth: true
            Layout.topMargin: 2
            spacing: 4
            visible: row.open && !row.isDrop

            Rectangle {
                Layout.fillWidth: true
                implicitHeight: 1
                color: "#21262d"
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 6

                Text {
                    color: "#6e7681"
                    font.pixelSize: 10
                    text: I18n.t("punti all'ora sulle statistiche")
                }

                Text {
                    color: "#484f58"
                    font.pixelSize: 10
                    // La misura di riferimento, perche' «−10» da solo non dice
                    // se e' un ritocco o una condanna.
                    text: I18n.t("(il gioco scarica da sé di 12-25 all'ora)")
                }

                Item {
                    Layout.fillWidth: true
                }

                Chip {
                    label: I18n.t("barra nella stanza")
                    current: row.trait.bar !== false
                    onChosen: row.set("bar", row.trait.bar === false)
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                Repeater {
                    model: [
                        { key: "hunger", label: "Fame" },
                        { key: "energy", label: "Energia" },
                        { key: "happiness", label: "Felice" },
                        { key: "hygiene", label: "Pulito" }
                    ]

                    ColumnLayout {
                        id: effect

                        required property var modelData

                        readonly property real weight: row.weightOf(effect.modelData.key)
                        readonly property real rate: row.live ? PetTraits.rateNow(row.live, effect.modelData.key) : 0

                        spacing: 2

                        Num {
                            Layout.fillWidth: true
                            label: I18n.t(effect.modelData.label)
                            value: effect.weight
                            onEdited: v => row.setEffect(effect.modelData.key, v)
                        }

                        // Quanto sta davvero applicando adesso, col benessere
                        // di questo momento: e' l'unico modo di sapere se il
                        // peso scelto e' forte senza aspettare un'ora.
                        Text {
                            Layout.fillWidth: true
                            horizontalAlignment: Text.AlignHCenter
                            color: effect.rate === 0 ? "#484f58" : (effect.rate < 0 ? "#f85149" : "#3fb950")
                            font.pixelSize: 10
                            text: effect.weight === 0 ? "—" : (effect.rate > 0 ? "+" : "") + effect.rate.toFixed(1) + "/h"
                        }
                    }
                }
            }
        }

        // ------------------------------------------------- le molecole
        //
        // Si vede solo quando la caratteristica le ha accese: sono cinque
        // controlli, e tenerli sempre aperti riempirebbe la finestra di roba
        // che non riguarda le altre caratteristiche.
        ColumnLayout {
            Layout.fillWidth: true
            Layout.topMargin: 2
            spacing: 6
            visible: row.open && !row.isDrop && row.trait.particles === true

            Rectangle {
                Layout.fillWidth: true
                implicitHeight: 1
                color: "#21262d"
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                // L'anteprima, disegnata dallo stesso componente della stanza.
                // Non e' un vezzo: e' l'unico modo di sapere che cosa si sta
                // scegliendo senza andare a guardare il pannello, e siccome e'
                // lo stesso file non puo' mentire.
                Rectangle {
                    Layout.preferredWidth: 78
                    Layout.preferredHeight: 54
                    radius: 6
                    color: "#0d1117"
                    border.width: 1
                    border.color: "#21262d"

                    PetMolecule {
                        anchors.centerIn: parent
                        spec: PetTraits.moleculeById(row.trait.molecule ?? "co2").shape
                        // Piu' grande che nella stanza: qui si guarda per
                        // scegliere, li' si guarda di sfuggita.
                        unit: 5
                        outerColor: row.trait.outerColor ?? "#58a6ff"
                        centerColor: row.trait.centerColor ?? "#8b949e"
                        bondColor: row.trait.bondColor ?? "#8b949e"
                    }
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 6

                    // Quale molecola. Molecole vere, non geometrie: si sceglie
                    // CO2 e viene la CO2, con l'angolo che ha.
                    Flow {
                        Layout.fillWidth: true
                        spacing: 4

                        Repeater {
                            model: PetTraits.molecules

                            Chip {
                                required property var modelData

                                label: modelData.label
                                current: (row.trait.molecule ?? "co2") === modelData.id
                                onChosen: row.set("molecule", modelData.id)

                                Tooltip {
                                    hovered: parent.hovered
                                    text: modelData.hint
                                }
                            }
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8

                        PetSwatch {
                            label: I18n.t("atomi")
                            value: row.trait.outerColor ?? "#58a6ff"
                            onPicked: c => row.set("outerColor", String(c))
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8

                        PetSwatch {
                            label: I18n.t("centro")
                            value: row.trait.centerColor ?? "#8b949e"
                            onPicked: c => row.set("centerColor", String(c))
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8

                        PetSwatch {
                            label: I18n.t("legami")
                            value: row.trait.bondColor ?? "#8b949e"
                            onPicked: c => row.set("bondColor", String(c))
                        }
                    }
                }
            }

            // Il passo, in unita' vere. E' la manopola che decide quanto si
            // riempie la stanza, e conta piu' di tutti i colori messi insieme.
            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                Num {
                    label: I18n.t("una molecola ogni")
                    value: row.step
                    onEdited: v => row.set("particleStep", v)
                }

                Num {
                    label: I18n.t("a partire da")
                    value: row.trait.particleBase !== undefined ? row.trait.particleBase : (row.trait.min ?? 0)
                    onEdited: v => row.set("particleBase", v)
                }

                // Quante se ne vedono adesso, e quante al fondoscala: due
                // numeri che dicono subito se il passo e' sensato, invece di
                // farlo scoprire guardando la stanza.
                Text {
                    Layout.fillWidth: true
                    Layout.alignment: Qt.AlignBottom
                    wrapMode: Text.WordWrap
                    color: "#6e7681"
                    font.pixelSize: 10
                    text: I18n.t("adesso %1, a fondoscala %2 (tetto %3)")
                        .arg(row.moleculeCount)
                        .arg(row.moleculeCountAtMax)
                        .arg(row.cap)
                }
            }
        }

        // La barra come la vedra' il pet, qui sotto le soglie: cosi' si vede
        // subito l'effetto di un numero cambiato, senza andare a guardare la
        // dashboard.
        Rectangle {
            Layout.fillWidth: true
            implicitHeight: 6
            radius: 3
            color: "#21262d"
            visible: row.open && !row.isDrop

            Rectangle {
                width: parent.width * (row.live && row.live.wellness !== null ? row.live.wellness / 100 : 0)
                height: parent.height
                radius: 3
                color: row.live && row.live.wellness !== null && row.live.wellness <= 20 ? "#f85149" : "#58a6ff"

                Behavior on width {
                    NumberAnimation {
                        duration: 200
                    }
                }
            }
        }
    }
}
