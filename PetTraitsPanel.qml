import QtQuick
import QtQuick.Layouts
import Quickshell

// Dove si collegano i sensori al pet.
//
// Le quattro statistiche del gioco — fame, energia, felicita', pulizia —
// decadono da sole e si curano con un pulsante. Queste no: una caratteristica
// di qui legge un sensore vero, e per farla tornare a posto bisogna cambiare la
// cosa vera. E' il punto: la CO2 alta non si cura cliccando, si cura aprendo la
// finestra.
Rectangle {
    id: win

    implicitWidth: 620
    implicitHeight: 560
    color: "#0d1117"

    readonly property string terrain: Settings.panelParam("pet", "terrain", "")
    readonly property string background: Settings.panelParam("pet", "background", "")
    readonly property string terrainColor: Settings.panelParam("pet", "terrainColor", "")
    readonly property real terrainOpacity: Settings.panelParam("pet", "terrainOpacity", 0.35)
    readonly property real terrainDepth: Settings.panelParam("pet", "terrainDepth", 0.25)
    readonly property real backgroundDim: Settings.panelParam("pet", "backgroundDim", 0.35)
    readonly property int dropSeconds: Settings.panelParam("pet", "dropSeconds", 6)

    // Su cosa si puo' camminare: il piatto di prima, le misure che la dashboard
    // campiona gia', e lo storico di Home Assistant di ogni caratteristica che
    // ne ha una. Niente sonde nuove in nessuno dei due casi.
    readonly property var terrainChoices: {
        const out = [
            {
                source: "",
                label: I18n.t("pavimento piatto")
            },
            {
                source: "sys:cpu",
                label: I18n.t("CPU")
            },
            {
                source: "sys:mem",
                label: I18n.t("RAM occupata")
            },
            {
                source: "sys:gpu",
                label: I18n.t("GPU")
            }
        ];
        for (const t of PetTraits.traits) {
            if (typeof t.source === "string" && t.source.startsWith("ha:"))
                out.push({
                    source: t.source,
                    label: t.label || t.id
                });
        }
        return out;
    }

    // ------------------------------------------------------- aggiunta
    //
    // La ricerca e' quella che le Opzioni usano gia' per le entita' di Home
    // Assistant (OptionsPanel): si scrive, escono al massimo otto
    // corrispondenze fra id e nome amichevole, si clicca. Qui in piu' ci sono
    // le misure che la dashboard raccoglie da se', nella stessa lista: da
    // collegare sono la stessa cosa, e due elenchi separati vorrebbero dire
    // sapere prima da che parte sta quello che si cerca.
    property string query: ""

    // Un sensore per RUOLO, non un sensore in tutto: «la GPU fa il benessere»
    // e «la GPU fa cadere un peperoncino» sono due cose diverse e sensate
    // insieme, e un elenco solo le renderebbe alternative.
    readonly property var usedAs: {
        const out = {
            wellness: [],
            drop: []
        };
        for (const t of PetTraits.traits)
            out[PetTraits.roleOf(t)].push(t.source);
        return out;
    }

    function usedFor(source: string, role: string): bool {
        return win.usedAs[role].includes(source);
    }

    readonly property var alreadyUsed: win.usedAs.wellness.filter(x => win.usedAs.drop.includes(x))

    // Quale riga dell'elenco e' aperta. 🔴 Sta qui e non nella riga: aperta ne
    // va una sola — sei controlli per due caratteristiche insieme non ci
    // starebbero — e un ListView ricicla i delegate mentre si scorre, quindi
    // uno stato tenuto la' dentro si perderebbe da solo.
    property string openId: ""

    readonly property var matches: {
        const q = win.query.trim().toLowerCase();

        if (q.length < 2)
            return [];

        const out = [];

        // Le misure di sistema per prime: sono poche e si scrivono per intero,
        // quindi non affogano nelle quarantotto entita' di Home Assistant.
        for (const s of PetTraits.systemSources) {
            const source = `sys:${s.key}`;
            if (win.alreadyUsed.includes(source))
                continue;
            if (s.key.toLowerCase().includes(q) || s.label.toLowerCase().includes(q))
                out.push({
                    source: source,
                    name: s.label,
                    detail: I18n.t("dashboard")
                });
        }

        for (const key of SystemStats.sensorKeys) {
            const source = `sys:temp:${key}`;
            if (win.alreadyUsed.includes(source))
                continue;
            const sensor = SystemStats.sensor(key);
            if (!sensor)
                continue;
            if (key.toLowerCase().includes(q) || (sensor.label ?? "").toLowerCase().includes(q))
                out.push({
                    source: source,
                    name: sensor.label ?? key,
                    detail: I18n.t("sonda %1").arg(sensor.chip ?? key)
                });
            if (out.length >= 8)
                return out;
        }

        for (const id in HomeAssistant.states) {
            const source = `ha:${id}`;
            if (win.alreadyUsed.includes(source))
                continue;

            const name = HomeAssistant.friendlyName(id);

            if (id.toLowerCase().includes(q) || name.toLowerCase().includes(q)) {
                // Solo quello che si puo' mettere su una barra: uno stato
                // "on"/"off" non ha un campo, e offrirlo vorrebbe dire lasciar
                // collegare qualcosa che poi dira' sempre «n/d».
                const n = parseFloat(HomeAssistant.state(id));
                if (!isFinite(n))
                    continue;

                out.push({
                    source: source,
                    name: name,
                    detail: `${HomeAssistant.state(id)} ${HomeAssistant.unit(id)}`.trim()
                });
            }

            if (out.length >= 8)
                break;
        }

        return out;
    }

    function add(source: string, name: string, role: string) {
        const value = PetTraits.rawValue(source);
        // I valori di partenza li decide PetTraits.defaultsFor(): stanno nel
        // singleton perche' servono anche alla riga, quando si cambia ruolo a
        // una caratteristica che c'e' gia'.
        const base = PetTraits.defaultsFor(source, isFinite(value) && value !== null ? value : 0, role);

        // L'id viene dalla sorgente: la regola sta in PetTraits perche' la usa
        // anche il server MCP quando aggiunge una caratteristica da fuori.
        const id = PetTraits.freeId(PetTraits.idFor(source));

        PetTraits.upsert(Object.assign({
            id: id,
            label: name.slice(0, 16),
            source: source
        }, base));

        win.query = "";
        search.text = "";
        // Aperta subito: una caratteristica appena aggiunta e' esattamente
        // quella che si vuole configurare, e lasciarla chiusa vorrebbe dire un
        // clic in piu' sempre.
        win.openId = id;
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 12
        spacing: 10

        // ------------------------------------------------------- ricerca
        Rectangle {
            Layout.fillWidth: true
            implicitHeight: 32
            radius: 6
            color: "#0d1117"
            border.width: 1
            border.color: search.activeFocus ? "#58a6ff" : "#30363d"

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 10
                anchors.rightMargin: 8
                spacing: 6

                Text {
                    color: "#6e7681"
                    font.pixelSize: 12
                    text: "⌕"
                }

                TextInput {
                    id: search

                    Layout.fillWidth: true
                    clip: true
                    color: "#c9d1d9"
                    font.pixelSize: 12
                    selectionColor: "#1f6feb"
                    selectedTextColor: "#ffffff"
                    focus: true
                    onTextChanged: win.query = text
                    Keys.onEscapePressed: text = ""

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: search.text === ""
                        color: "#484f58"
                        font.pixelSize: 12
                        text: I18n.t("aggiungi: cerca un sensore, per esempio co2…")
                    }
                }

                Text {
                    visible: search.text !== ""
                    color: "#6e7681"
                    font.pixelSize: 12
                    text: "✕"

                    MouseArea {
                        anchors.fill: parent
                        anchors.margins: -4
                        cursorShape: Qt.PointingHandCursor
                        onClicked: search.text = ""
                    }
                }
            }
        }

        // I risultati della ricerca, sopra l'elenco: si sceglie il ruolo e la
        // caratteristica compare gia' configurata con un campo sensato.
        //
        // Due chip e non un clic sulla riga intera come prima: il ruolo va
        // scelto adesso — decide che cosa sara' la caratteristica — e «clicca
        // qui per uno, la' per l'altro» non si indovina.
        ColumnLayout {
            Layout.fillWidth: true
            spacing: 2
            visible: win.matches.length > 0

            Repeater {
                model: win.matches

                Rectangle {
                    id: hit

                    required property var modelData

                    Layout.fillWidth: true
                    implicitHeight: 26
                    radius: 5
                    color: hitHover.hovered ? "#161b22" : "transparent"
                    border.width: 1
                    border.color: hitHover.hovered ? "#30363d" : "transparent"

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 8
                        anchors.rightMargin: 8
                        spacing: 8

                        Text {
                            Layout.fillWidth: true
                            elide: Text.ElideRight
                            color: "#c9d1d9"
                            font.pixelSize: 11
                            text: hit.modelData.name
                        }

                        Text {
                            color: "#6e7681"
                            font.pixelSize: 11
                            text: hit.modelData.detail
                        }

                        Repeater {
                            model: [
                                {
                                    role: "wellness",
                                    label: I18n.t("benessere")
                                },
                                {
                                    role: "drop",
                                    label: I18n.t("oggetti")
                                }
                            ]

                            Rectangle {
                                id: roleChip

                                required property var modelData

                                readonly property bool taken: win.usedFor(hit.modelData.source, roleChip.modelData.role)

                                implicitWidth: roleLabel.implicitWidth + 14
                                implicitHeight: 20
                                radius: 5
                                color: roleHover.hovered && !roleChip.taken ? "#21262d" : "transparent"
                                border.width: 1
                                border.color: roleChip.taken ? "#21262d" : (roleHover.hovered ? "#58a6ff" : "#30363d")

                                Text {
                                    id: roleLabel

                                    anchors.centerIn: parent
                                    color: roleChip.taken ? "#484f58" : (roleHover.hovered ? "#58a6ff" : "#8b949e")
                                    font.pixelSize: 10
                                    text: roleChip.modelData.label
                                }

                                HoverHandler {
                                    id: roleHover

                                    enabled: !roleChip.taken
                                    cursorShape: Qt.PointingHandCursor
                                }

                                Tooltip {
                                    hovered: roleHover.hovered
                                    text: roleChip.taken ? I18n.t("già collegato così") : I18n.t("aggiungi")
                                }

                                TapHandler {
                                    enabled: !roleChip.taken
                                    onSingleTapped: win.add(hit.modelData.source, hit.modelData.name, roleChip.modelData.role)
                                }
                            }
                        }
                    }

                    HoverHandler {
                        id: hitHover

                        cursorShape: Qt.ArrowCursor
                    }
                }
            }
        }

        Text {
            Layout.fillWidth: true
            visible: win.query.trim().length >= 2 && win.matches.length === 0
            color: "#484f58"
            font.pixelSize: 11
            text: I18n.t("nessun sensore numerico per «%1»").arg(win.query.trim())
        }

        // --------------------------------------------------------- elenco
        ListView {
            id: list

            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            spacing: 8
            model: PetTraits.traits
            boundsBehavior: Flickable.StopAtBounds

            // 🔴 L'introduzione e la stanza scorrono INSIEME all'elenco, e non
            // e' una questione di gusto: in una finestra da 560 punti quei due
            // blocchi ne prendevano piu' di duecento, e all'elenco ne
            // restavano meno di una riga aperta — le caratteristiche in fondo
            // non si raggiungevano. Qui dentro tornano al viewport quando
            // servono e se ne vanno quando si scorre. La ricerca invece resta
            // fissa la' sotto: e' il modo di aggiungere, e doverla riportare a
            // galla ogni volta sarebbe un passo in piu' sempre.
            header: Item {
                // Senza questa riga l'intestazione ha larghezza zero e tutto
                // quello che ci sta dentro collassa: un header di ListView non
                // eredita la larghezza della vista, gliela si da'.
                width: list.width
                implicitHeight: headerBox.implicitHeight + 8

                ColumnLayout {
                    id: headerBox

                    width: parent.width
                    spacing: 10

                    Text {
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                        color: "#8b949e"
                        font.pixelSize: 11
                        text: I18n.t("Ogni caratteristica legge un sensore e ne fa una delle due cose. Il benessere diventa una barra nella stanza: quando arriva a zero il pet si ammala, e dodici ore così sono la cerimonia — la stessa regola della fame. Gli oggetti invece cadono: se il valore resta oltre la soglia per qualche minuto, dall'alto scende una mela o un peperoncino, e il pet lo prende solo se il suo girovagare ce lo porta sopra. Un sensore che non risponde non conta: dice «n/d» e non fa male a nessuno.")
                    }

                    // ------------------------------------------------- la stanza
                    //
                    // Pavimento e fondale riguardano la STANZA, non una caratteristica: il
                    // pavimento e' uno solo anche quando le caratteristiche sono cinque.
                    // Per questo stanno qui in cima e nei panelParams, non in una riga.
                    Rectangle {
                        Layout.fillWidth: true
                        implicitHeight: roomBox.implicitHeight + 20
                        radius: 8
                        color: "#0d1117"
                        border.width: 1
                        border.color: "#21262d"

                        ColumnLayout {
                            id: roomBox

                            anchors.fill: parent
                            anchors.margins: 10
                            spacing: 6

                            Text {
                                color: "#8b949e"
                                font.pixelSize: 11
                                text: I18n.t("La stanza")
                            }

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 6

                                Text {
                                    color: "#6e7681"
                                    font.pixelSize: 10
                                    text: I18n.t("il pet cammina su")
                                }

                                Flow {
                                    Layout.fillWidth: true
                                    spacing: 4

                                    Repeater {
                                        model: win.terrainChoices

                                        Rectangle {
                                            id: floorChip

                                            required property var modelData

                                            readonly property bool current: win.terrain === floorChip.modelData.source

                                            implicitWidth: floorLabel.implicitWidth + 16
                                            implicitHeight: 22
                                            radius: 5
                                            color: floorChip.current ? "#21262d" : "transparent"
                                            border.width: 1
                                            border.color: floorChip.current ? "#58a6ff" : "#30363d"

                                            Text {
                                                id: floorLabel

                                                anchors.centerIn: parent
                                                color: floorChip.current ? "#58a6ff" : "#8b949e"
                                                font.pixelSize: 11
                                                text: floorChip.modelData.label
                                            }

                                            MouseArea {
                                                anchors.fill: parent
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: Settings.setPanelParam("pet", "terrain", floorChip.modelData.source)
                                            }
                                        }
                                    }
                                }
                            }

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 6

                                Text {
                                    color: "#6e7681"
                                    font.pixelSize: 10
                                    text: I18n.t("sfondo")
                                }

                                Rectangle {
                                    Layout.fillWidth: true
                                    implicitHeight: 24
                                    radius: 5
                                    color: "#161b22"
                                    border.width: 1
                                    border.color: bgInput.activeFocus ? "#58a6ff" : "#30363d"

                                    TextInput {
                                        id: bgInput

                                        anchors.fill: parent
                                        anchors.leftMargin: 7
                                        anchors.rightMargin: 7
                                        verticalAlignment: TextInput.AlignVCenter
                                        clip: true
                                        color: "#c9d1d9"
                                        font.pixelSize: 11
                                        selectionColor: "#1f6feb"
                                        selectedTextColor: "#ffffff"
                                        text: win.background

                                        Connections {
                                            target: win

                                            function onBackgroundChanged() {
                                                if (!bgInput.activeFocus)
                                                    bgInput.text = win.background;
                                            }
                                        }

                                        onEditingFinished: Settings.setPanelParam("pet", "background", bgInput.text.trim())
                                        Keys.onReturnPressed: Settings.setPanelParam("pet", "background", bgInput.text.trim())

                                        Text {
                                            anchors.verticalCenter: parent.verticalCenter
                                            visible: bgInput.text === ""
                                            color: "#484f58"
                                            font.pixelSize: 11
                                            text: I18n.t("~/Immagini/stanza.png — pixel art, ingrandita a numero intero")
                                        }
                                    }
                                }
                            }

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 12

                                PetSwatch {
                                    label: I18n.t("colore del grafico")
                                    value: win.terrainColor !== "" ? win.terrainColor : "#c9d1d9"
                                    onPicked: c => Settings.setPanelParam("pet", "terrainColor", String(c))
                                }

                                ColumnLayout {
                                    spacing: 2

                                    Text {
                                        color: "#6e7681"
                                        font.pixelSize: 10
                                        text: I18n.t("trasparenza del grafico")
                                    }

                                    RowLayout {
                                        spacing: 4

                                        Repeater {
                                            model: [0.15, 0.35, 0.55, 0.8, 1.0]

                                            Rectangle {
                                                id: opChip

                                                required property var modelData

                                                readonly property bool current: Math.abs(win.terrainOpacity - opChip.modelData) < 0.01

                                                implicitWidth: 34
                                                implicitHeight: 22
                                                radius: 5
                                                color: opChip.current ? "#21262d" : "transparent"
                                                border.width: 1
                                                border.color: opChip.current ? "#58a6ff" : "#30363d"

                                                Text {
                                                    anchors.centerIn: parent
                                                    color: opChip.current ? "#58a6ff" : "#8b949e"
                                                    font.pixelSize: 10
                                                    text: Math.round(opChip.modelData * 100) + "%"
                                                }

                                                MouseArea {
                                                    anchors.fill: parent
                                                    cursorShape: Qt.PointingHandCursor
                                                    onClicked: Settings.setPanelParam("pet", "terrainOpacity", opChip.modelData)
                                                }
                                            }
                                        }
                                    }
                                }

                                ColumnLayout {
                                    spacing: 2

                                    Text {
                                        color: "#6e7681"
                                        font.pixelSize: 10
                                        text: I18n.t("prospettiva")
                                    }

                                    RowLayout {
                                        spacing: 4

                                        Repeater {
                                            model: [0.0, 0.15, 0.25, 0.4]

                                            Rectangle {
                                                id: depthChip

                                                required property var modelData

                                                readonly property bool current: Math.abs(win.terrainDepth - depthChip.modelData) < 0.01

                                                implicitWidth: 34
                                                implicitHeight: 22
                                                radius: 5
                                                color: depthChip.current ? "#21262d" : "transparent"
                                                border.width: 1
                                                border.color: depthChip.current ? "#58a6ff" : "#30363d"

                                                Text {
                                                    anchors.centerIn: parent
                                                    color: depthChip.current ? "#58a6ff" : "#8b949e"
                                                    font.pixelSize: 10
                                                    text: Math.round(depthChip.modelData * 100) + "%"
                                                }

                                                MouseArea {
                                                    anchors.fill: parent
                                                    cursorShape: Qt.PointingHandCursor
                                                    onClicked: Settings.setPanelParam("pet", "terrainDepth", depthChip.modelData)
                                                }
                                            }
                                        }
                                    }
                                }

                                ColumnLayout {
                                    spacing: 2

                                    Text {
                                        color: "#6e7681"
                                        font.pixelSize: 10
                                        text: I18n.t("velo sullo sfondo")
                                    }

                                    RowLayout {
                                        spacing: 4

                                        Repeater {
                                            model: [0.0, 0.2, 0.35, 0.55, 0.75]

                                            Rectangle {
                                                id: dimChip

                                                required property var modelData

                                                readonly property bool current: Math.abs(win.backgroundDim - dimChip.modelData) < 0.01

                                                implicitWidth: 34
                                                implicitHeight: 22
                                                radius: 5
                                                color: dimChip.current ? "#21262d" : "transparent"
                                                border.width: 1
                                                border.color: dimChip.current ? "#58a6ff" : "#30363d"

                                                Text {
                                                    anchors.centerIn: parent
                                                    color: dimChip.current ? "#58a6ff" : "#8b949e"
                                                    font.pixelSize: 10
                                                    text: Math.round(dimChip.modelData * 100) + "%"
                                                }

                                                MouseArea {
                                                    anchors.fill: parent
                                                    cursorShape: Qt.PointingHandCursor
                                                    onClicked: Settings.setPanelParam("pet", "backgroundDim", dimChip.modelData)
                                                }
                                            }
                                        }
                                    }
                                }

                                ColumnLayout {
                                    spacing: 2

                                    Text {
                                        color: "#6e7681"
                                        font.pixelSize: 10
                                        text: I18n.t("l'oggetto resta a terra")
                                    }

                                    RowLayout {
                                        spacing: 4

                                        Repeater {
                                            model: [4, 6, 8, 10]

                                            Rectangle {
                                                id: dropChip

                                                required property var modelData

                                                readonly property bool current: win.dropSeconds === dropChip.modelData

                                                implicitWidth: 30
                                                implicitHeight: 22
                                                radius: 5
                                                color: dropChip.current ? "#21262d" : "transparent"
                                                border.width: 1
                                                border.color: dropChip.current ? "#58a6ff" : "#30363d"

                                                Text {
                                                    anchors.centerIn: parent
                                                    color: dropChip.current ? "#58a6ff" : "#8b949e"
                                                    font.pixelSize: 10
                                                    text: I18n.t("%1 s").arg(dropChip.modelData)
                                                }

                                                MouseArea {
                                                    anchors.fill: parent
                                                    cursorShape: Qt.PointingHandCursor
                                                    onClicked: Settings.setPanelParam("pet", "dropSeconds", dropChip.modelData)
                                                }
                                            }
                                        }
                                    }
                                }

                                Item {
                                    Layout.fillWidth: true
                                }
                            }

                            Text {
                                Layout.fillWidth: true
                                wrapMode: Text.WordWrap
                                color: "#484f58"
                                font.pixelSize: 10
                                text: I18n.t("Lo sfondo copre tutto il pannello e sta sotto al grafico. Qualunque misura va bene: se è più piccola viene ingrandita di un numero intero di volte a pixel netti, se è più grande viene rimpicciolita in modo morbido. Per disegnarla a pixel, 256 × 160 px.")
                            }

                            Text {
                                Layout.fillWidth: true
                                wrapMode: Text.WordWrap
                                color: "#484f58"
                                font.pixelSize: 10
                                text: I18n.t("La prospettiva è quanto il pet rimpicciolisce salendo sul grafico: sulla cima è lontano, nella valle è vicino. A 0% resta della stessa misura ovunque.")
                            }
                        }
                    }
                }
            }

            delegate: PetTraitRow {
                required property var modelData

                width: list.width
                trait: modelData
                open: win.openId === modelData.id
                onToggled: win.openId = (win.openId === modelData.id ? "" : modelData.id)
            }

            ScrollBar {
                anchors.right: parent.right
                height: parent.height
                view: list
            }

            Text {
                anchors.centerIn: parent
                width: parent.width - 60
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                visible: list.count === 0
                color: "#484f58"
                font.pixelSize: 12
                text: I18n.t("Nessuna caratteristica. Cerca un sensore qui sopra — «co2» per il monitor della stanza — e diventerà una barra del pet.")
            }
        }

        Text {
            Layout.fillWidth: true
            visible: PetTraits.lastError !== ""
            wrapMode: Text.Wrap
            color: "#f85149"
            font.pixelSize: 10
            text: PetTraits.lastError
        }

        Text {
            Layout.fillWidth: true
            elide: Text.ElideRight
            color: "#484f58"
            font.pixelSize: 10
            text: I18n.t("si salva da sé in %1").arg(PetTraits.path)
        }
    }
}
