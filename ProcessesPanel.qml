import QtQuick
import QtQuick.Layouts
import Quickshell

// Elenco di tutti i processi, ordinabile per una qualunque delle cinque
// misure, con un riquadro di dettaglio che segue il puntatore.
Rectangle {
    id: win






    // larghezza delle colonne numeriche: la condividono intestazione e righe
    readonly property int metricWidth: 74
    // La colonna del processo non supera mai il 40% della finestra: la riga di
    // comando dei processi lunghi si taglia comunque, e le misure restano
    // sempre incolonnate sulla destra.
    readonly property int nameWidth: Math.round(win.width * 0.40)
    // La fascia a destra occupata dalle cinque colonne numeriche, dal pulsante
    // di chiusura e dalle spaziature fra loro: i numeri sono quelli del
    // RowLayout di ProcRow. Serve al riquadro di dettaglio, che deve stare
    // fuori da qui.
    readonly property int metricsWidth: 5 * win.metricWidth + 24 + 6 * 6 + 8

    // azione di massa in attesa del secondo clic di conferma
    property string confirmingAction: ""

    // processo su cui e' aperto il menu del tasto destro, e dove aprirlo
    property var menuProcess: null
    property real menuX: 0
    property real menuY: 0
    // main | priority | affinity
    property string menuPage: "main"
    // thread scelti nel pannello dell'affinita'
    property var affinityChoice: []

    function openMenu(process: var, x: real, y: real) {
        win.menuProcess = process;
        win.menuX = x;
        win.menuY = y;
        win.menuPage = "main";
        // i dettagli portano l'affinita' e la priorita' correnti: il pannello
        // parte da com'e' il processo adesso, non da zero
        Processes.describe(process.pid);
    }

    function closeMenu() {
        win.menuProcess = null;
        win.menuPage = "main";
    }

    // Il menu e' aperto, oppure lo era fino a un attimo fa. Le righe restano
    // insensibili al click anche per un momento dopo la chiusura: il click con
    // cui si sceglie una voce — e quello con cui si chiude il menu cliccando
    // fuori, che spesso arriva quando il menu si e' gia' chiuso da solo — non
    // deve anche selezionare il processo che si trovava sotto il puntatore.
    readonly property bool menuShown: win.menuProcess !== null
    property bool menuJustClosed: false

    onMenuShownChanged: {
        if (win.menuShown)
            win.menuJustClosed = false;
        else {
            win.menuJustClosed = true;
            menuGrace.restart();
        }
    }

    Timer {
        id: menuGrace

        interval: 250
        onTriggered: win.menuJustClosed = false
    }

    // Chiusura rimandata al ritorno all'event loop. Chiuderlo dentro onTapped
    // vorrebbe dire far sparire il menu — e la barriera che gli sta sotto —
    // mentre il click e' ancora in consegna: il resto dell'evento finirebbe
    // sulle righe rimaste scoperte, e in Qt un TapHandler non consuma il click
    // come farebbe una MouseArea. Vedi ProcRow.menuOpen.
    function closeMenuLater() {
        Qt.callLater(win.closeMenu);
    }

    function runFromMenu(action: string) {
        Processes.act(win.menuProcess, action);
        win.closeMenuLater();
    }

    implicitWidth: 840
    implicitHeight: 620
    color: "#0d1117"

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 12
        spacing: 8

        // -------------------------------------------------------- ricerca
        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            // Di chi mostrare i processi. Come nel selettore di ambito dei
            // servizi la chiave sta nel modello e la traduzione nel Text, cosi'
            // cambiare lingua riscrive i pulsanti invece di ricostruirli.
            Repeater {
                model: [
                    {
                        id: "tutti",
                        label: "Tutti"
                    },
                    {
                        id: "miei",
                        label: "Miei"
                    },
                    {
                        id: "root",
                        label: "root"
                    },
                    {
                        id: "altri",
                        label: "Altri"
                    }
                ]

                Rectangle {
                    id: scopeChip

                    required property var modelData

                    readonly property bool current: Processes.scope === scopeChip.modelData.id
                    // quanti ce ne sono davvero: un pulsante che non filtra
                    // niente e' peggio che non averlo
                    readonly property int count: {
                        switch (scopeChip.modelData.id) {
                        case "miei":
                            return Processes.ownedCount;
                        case "root":
                            return Processes.rootCount;
                        case "altri":
                            return Processes.othersCount;
                        }
                        return Processes.all.length;
                    }

                    implicitWidth: scopeLabel.implicitWidth + 18
                    implicitHeight: 32
                    radius: 6
                    color: scopeChip.current ? "#21262d" : "transparent"
                    border.width: 1
                    border.color: scopeChip.current ? "#58a6ff" : "#30363d"

                    Text {
                        id: scopeLabel

                        anchors.centerIn: parent
                        color: scopeChip.current ? "#58a6ff" : "#8b949e"
                        font.pixelSize: 11
                        // "root" e' un nome di utente, non una parola da tradurre
                        text: (scopeChip.modelData.id === "root" ? "root" : I18n.t(scopeChip.modelData.label)) + ` · ${scopeChip.count}`
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: Processes.scope = scopeChip.modelData.id
                    }
                }
            }

            Rectangle {
                Layout.fillWidth: true
                implicitHeight: 32
                radius: 6
                color: "#161b22"
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

                        onTextEdited: Processes.query = text
                        Keys.onEscapePressed: {
                            text = "";
                            Processes.query = "";
                        }

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            visible: search.text === ""
                            color: "#484f58"
                            font.pixelSize: 12
                            text: I18n.t("filtra per nome, utente o riga di comando…")
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
                            onClicked: {
                                search.text = "";
                                Processes.query = "";
                            }
                        }
                    }
                }
            }

            Text {
                color: "#6e7681"
                font.pixelSize: 10
                text: I18n.t("%1 di %2").arg(Processes.results.length).arg(Processes.scopeCount)
            }
        }

        Text {
            Layout.fillWidth: true
            visible: Processes.message.length > 0
            wrapMode: Text.Wrap
            color: Processes.message.startsWith("terminato") ? "#8b949e" : "#f85149"
            font.pixelSize: 10
            text: Processes.message
        }

        // ------------------------------------------- azioni sui selezionati
        // Compare solo quando c'e' una selezione: una barra di comandi sempre
        // presente ma quasi sempre inerte insegna a ignorarla.
        Rectangle {
            Layout.fillWidth: true
            visible: Processes.selectedCount > 0
            implicitHeight: 32
            radius: 6
            color: "#132033"
            border.width: 1
            border.color: "#1f6feb"

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 10
                anchors.rightMargin: 6
                spacing: 6

                Text {
                    Layout.fillWidth: true
                    color: "#c9d1d9"
                    font.pixelSize: 11
                    text: I18n.tn(Processes.selectedCount, "1 processo selezionato", "%1 processi selezionati")
                }

                Repeater {
                    model: [
                        {
                            action: "stop",
                            label: I18n.t("sospendi"),
                            danger: false
                        },
                        {
                            action: "resume",
                            label: I18n.t("riprendi"),
                            danger: false
                        },
                        {
                            action: "terminate",
                            label: I18n.t("termina"),
                            danger: true
                        },
                        {
                            action: "force",
                            label: I18n.t("forza"),
                            danger: true
                        }
                    ]

                    Rectangle {
                        id: bulkButton

                        required property var modelData

                        readonly property bool armed: win.confirmingAction === bulkButton.modelData.action

                        implicitWidth: bulkLabel.implicitWidth + 16
                        implicitHeight: 22
                        radius: 4
                        color: bulkButton.armed ? "#3d1418" : bulkHover.hovered ? "#21262d" : "transparent"
                        border.width: 1
                        border.color: bulkButton.modelData.danger ? "#f85149" : "#30363d"

                        HoverHandler {
                            id: bulkHover

                            cursorShape: Qt.PointingHandCursor
                        }

                        Text {
                            id: bulkLabel

                            anchors.centerIn: parent
                            color: bulkButton.modelData.danger ? "#f85149" : "#8b949e"
                            font.pixelSize: 10
                            // le azioni distruttive chiedono un secondo clic:
                            // qui sotto ci sono decine di processi, e un clic
                            // per sbaglio ne chiuderebbe piu' di uno
                            text: bulkButton.armed ? I18n.t("confermi?") : bulkButton.modelData.label
                        }

                        TapHandler {
                            onTapped: {
                                if (!bulkButton.modelData.danger || bulkButton.armed) {
                                    Processes.applyToSelected(bulkButton.modelData.action);
                                    win.confirmingAction = "";
                                } else {
                                    win.confirmingAction = bulkButton.modelData.action;
                                }
                            }
                        }
                    }
                }

                // Copia il pid negli appunti. Compare solo con un unico
                // processo selezionato: con piu' righe non ci sarebbe un solo
                // pid da copiare, e il pid vuoto non lo copia nessuno.
                Rectangle {
                    id: copyPidButton

                    visible: Processes.selectedCount === 1
                    implicitWidth: copyPidLabel.implicitWidth + 16
                    implicitHeight: 22
                    radius: 4
                    color: copyPidHover.hovered ? "#21262d" : "transparent"
                    border.width: 1
                    border.color: "#30363d"

                    // "copiato" e' uno stato transitorio: il testo torna
                    // quello normale dopo un momento
                    property bool copied: false

                    HoverHandler {
                        id: copyPidHover

                        cursorShape: Qt.PointingHandCursor
                    }

                    Text {
                        id: copyPidLabel

                        anchors.centerIn: parent
                        color: copyPidButton.copied ? "#3fb950" : "#8b949e"
                        font.pixelSize: 10
                        text: copyPidButton.copied ? I18n.t("copiato") : I18n.t("copy PID")
                    }

                    Timer {
                        id: copyPidReset

                        interval: 1200
                        onTriggered: copyPidButton.copied = false
                    }

                    TapHandler {
                        onTapped: {
                            if (Processes.selectedCount === 1) {
                                const pid = Object.keys(Processes.selected)[0];
                                Quickshell.clipboardText = String(pid);
                                copyPidButton.copied = true;
                                copyPidReset.restart();
                            }
                        }
                    }
                }

                Rectangle {
                    implicitWidth: 22
                    implicitHeight: 22
                    radius: 4
                    color: clearHover.hovered ? "#21262d" : "transparent"

                    HoverHandler {
                        id: clearHover

                        cursorShape: Qt.PointingHandCursor
                    }

                    Text {
                        anchors.centerIn: parent
                        color: "#8b949e"
                        font.pixelSize: 11
                        text: "✕"
                    }

                    TapHandler {
                        onTapped: {
                            Processes.clearSelected();
                            win.confirmingAction = "";
                        }
                    }
                }
            }
        }

        // --------------------------------------------- intestazioni colonne
        RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: 10
            Layout.rightMargin: 8
            spacing: 6

            Text {
                Layout.fillWidth: true
                Layout.maximumWidth: win.nameWidth
                color: Processes.sortKey === "name" ? "#58a6ff" : "#6e7681"
                font.pixelSize: 10
                font.letterSpacing: 1
                text: I18n.t("PROCESSO") + (Processes.sortKey === "name" ? (Processes.sortDesc ? " ↓" : " ↑") : "")

                MouseArea {
                    anchors.fill: parent
                    anchors.margins: -4
                    cursorShape: Qt.PointingHandCursor
                    onClicked: Processes.sortBy("name")
                }
            }

            // lo spazio in piu' della colonna del processo, come nelle righe
            Item {
                Layout.fillWidth: true
            }

            // Come nel selettore di ambito dei servizi: la chiave italiana sta
            // nel modello, la traduzione nel Text, cosi' cambiare lingua non
            // ricostruisce le intestazioni mentre ci si sta ordinando sopra.
            Repeater {
                model: [
                    {
                        key: "cpu",
                        label: "CPU"
                    },
                    {
                        key: "rss",
                        label: "MEMORIA"
                    },
                    {
                        key: "gpu",
                        label: "GPU"
                    },
                    {
                        key: "io",
                        label: "DISCO"
                    },
                    {
                        key: "net",
                        label: "RETE"
                    }
                ]

                Text {
                    id: heading

                    required property var modelData

                    readonly property bool current: Processes.sortKey === heading.modelData.key

                    Layout.preferredWidth: win.metricWidth
                    horizontalAlignment: Text.AlignRight
                    color: heading.current ? "#58a6ff" : "#6e7681"
                    font.pixelSize: 10
                    font.letterSpacing: 1
                    text: I18n.t(heading.modelData.label) + (heading.current ? (Processes.sortDesc ? " ↓" : " ↑") : "")

                    MouseArea {
                        anchors.fill: parent
                        anchors.margins: -4
                        cursorShape: Qt.PointingHandCursor
                        onClicked: Processes.sortBy(heading.modelData.key)
                    }
                }
            }

            // spazio della colonna del pulsante di chiusura
            Item {
                implicitWidth: 24
            }
        }

        // --------------------------------------------------------- elenco
        ListView {
            id: list


            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            // Non legata direttamente a Processes.results: vedi sotto, il
            // momento in cui il modello cambia dev'essere nostro.
            model: list.rows
            spacing: 1
            boundsBehavior: Flickable.StopAtBounds

            // --- lo scorrimento sopravvive ai campioni -------------------
            //
            // Il modello e' un array JavaScript rifatto da capo a ogni
            // campione, e riassegnarlo non e' un aggiornamento: per la vista
            // e' un azzeramento, tutte le righe tolte e rimesse, e con esse se
            // ne andava la posizione. Misurato prima della correzione:
            // contentY portato a 600 tornava a 0 due secondi dopo — con 400
            // processi in elenco, non si arrivava mai in fondo.
            //
            // Non basta accorgersene e rimettere la posizione: `onModelChanged`
            // arriva troppo tardi. L'azzeramento della vista e' codice C++ che
            // gira PRIMA dell'handler QML, quindi quando l'handler parte la
            // posizione da salvare vale gia' zero. Misurato anche questo, con
            // una sonda: keep=0 al primo campione.
            //
            // Quindi il modello non e' legato a Processes.results, ma copiato
            // a mano quando quello cambia. Cosi' il momento e' nostro: si
            // salva la posizione mentre e' ancora quella vera, poi si assegna,
            // poi si rimette.
            //
            // In pixel e non per riga: mentre si scorre il puntatore e' per
            // forza qui sopra, quindi l'ordine e' congelato e sopra la
            // finestra non si sposta niente.
            property var rows: []
            property real keepY: 0

            Component.onCompleted: list.rows = Processes.results

            Connections {
                target: Processes

                function onResultsChanged(): void {
                    list.keepY = list.contentY;
                    list.rows = Processes.results;
                    settle.restart();
                }
            }

            // A intervallo zero: scatta appena la coda degli eventi si svuota,
            // cioe' quando la vista ha gia' ricalcolato contentHeight ma prima
            // che si disegni.
            Timer {
                id: settle

                interval: 0
                onTriggered: {
                    const limit = Math.max(0, list.contentHeight - list.height);
                    list.contentY = Math.max(0, Math.min(list.keepY, limit));
                }
            }

            delegate: ProcRow {
                required property var modelData

                width: list.width
                process: modelData
                metricWidth: win.metricWidth
                nameWidth: win.nameWidth
                menuOpen: win.menuShown || win.menuJustClosed
                onHovered: pid => detailTimer.request(pid)
                onMenuRequested: (process, mx, my) => win.openMenu(process, mx, my)
            }

            // Finche' il puntatore e' qui sopra le righe non si riordinano:
            // vedi Processes.updateFreeze.
            HoverHandler {
                onHoveredChanged: Processes.pointerOver = hovered
            }

            ScrollBar {
                anchors.right: parent.right
                height: parent.height
                view: list
            }

            Text {
                anchors.centerIn: parent
                visible: list.count === 0
                color: "#484f58"
                font.pixelSize: 12
                text: Processes.all.length === 0 ? I18n.t("in attesa del primo campione…") : Processes.query.length === 0 ? I18n.t("nessun processo di questo utente") : I18n.t("nessun processo per “%1”").arg(Processes.query)
            }
        }

        // Nota sulla rete solo quando manca: se funziona non c'e' niente da
        // spiegare.
        Text {
            Layout.fillWidth: true
            visible: !Processes.netAvailable
            wrapMode: Text.Wrap
            color: "#6e7681"
            font.pixelSize: 9
            font.family: "monospace"
            text: Processes.netError
        }

        // Stessa regola per la GPU: la colonna vuota va spiegata.
        Text {
            Layout.fillWidth: true
            visible: !Processes.gpuAvailable
            wrapMode: Text.Wrap
            color: "#6e7681"
            font.pixelSize: 9
            font.family: "monospace"
            text: Processes.gpuError
        }

        // E le connessioni che non si e' riusciti ad attribuire: senza dirlo,
        // i processi di root sembrerebbero semplicemente non usare la rete.
        FixHint {
            Layout.fillWidth: true
            Layout.topMargin: 4
            visible: Processes.orphanConns > 0
            headline: I18n.tn(Processes.orphanConns, "1 connessione senza processo", "%1 connessioni senza processo")
            explanation: Processes.connError
            command: Processes.connFix
        }
    }

    // Il dettaglio si chiede solo quando il puntatore si ferma: passando
    // veloce sull'elenco si lancerebbe uno script per riga sorvolata.
    Timer {
        id: detailTimer

        property int pid: 0

        function request(nextPid: int) {
            detailTimer.pid = nextPid;
            if (nextPid === 0) {
                detailTimer.stop();
                Processes.describe(0);
            } else {
                detailTimer.restart();
            }
        }

        interval: 220
        onTriggered: Processes.describe(detailTimer.pid)
    }

    // --------------------------------------------------------- dettaglio
    // Segue il puntatore restando dentro la finestra: un riquadro che esce dal
    // bordo sarebbe illeggibile proprio sulle righe in fondo.
    Rectangle {
        id: detailBox

        readonly property var info: Processes.detail
        // i peer non stanno nei dettagli (che leggono /proc a richiesta) ma nel
        // campione periodico: si ripescano dal processo con lo stesso pid
        readonly property var peers: {
            if (!detailBox.info)
                return [];
            const found = Processes.all.find(p => p.pid === detailBox.info.pid);
            return found ? (found.peers ?? []) : [];
        }

        function flag(iso: string): string {
            if (!iso || iso.length !== 2)
                return "";
            const base = 0x1F1E6;
            return String.fromCodePoint(base + iso.charCodeAt(0) - 65) + String.fromCodePoint(base + iso.charCodeAt(1) - 65);
        }

        visible: detailBox.info !== null
        // Sta dalla parte del processo e non sconfina mai sulle colonne
        // numeriche: la ✕ e' all'estrema destra della riga, e un riquadro che
        // ci finisce sopra la nasconde proprio mentre la si sta cercando.
        width: Math.max(240, Math.min(360, win.width - win.metricsWidth - 20))
        height: detailColumn.implicitHeight + 20
        x: Math.max(8, Math.min(hoverPosition.x + 18, win.width - win.metricsWidth - width - 12))
        y: Math.min(Math.max(8, hoverPosition.y - height / 2), win.height - height - 8)
        radius: 8
        color: "#0d1117"
        border.width: 1
        border.color: "#30363d"

        ColumnLayout {
            id: detailColumn

            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: 10
            spacing: 3

            Text {
                Layout.fillWidth: true
                elide: Text.ElideRight
                color: "#c9d1d9"
                font.pixelSize: 12
                font.bold: true
                text: detailBox.info ? `${detailBox.info.name} · ${detailBox.info.pid}` : ""
            }

            Text {
                Layout.fillWidth: true
                Layout.bottomMargin: 4
                wrapMode: Text.Wrap
                maximumLineCount: 4
                elide: Text.ElideRight
                color: "#8b949e"
                font.pixelSize: 9
                font.family: "monospace"
                text: detailBox.info ? detailBox.info.cmdline : ""
            }

            ProcInfo {
                Layout.fillWidth: true
                info: detailBox.info
            }

            // --- con chi sta parlando ---
            // Gli stessi indirizzi della finestra Rete: guardare un processo e
            // chiedersi con chi comunica e' la stessa domanda, posta da
            // un'altra finestra.
            Text {
                Layout.fillWidth: true
                Layout.topMargin: 4
                visible: detailBox.peers.length > 0
                color: "#6e7681"
                font.pixelSize: 9
                font.letterSpacing: 1
                text: I18n.tn(detailBox.peers.length, "1 CONNESSIONE", "%1 CONNESSIONI")
            }

            Repeater {
                model: detailBox.peers.slice(0, 6)

                RowLayout {
                    id: peerLine

                    required property var modelData

                    Layout.fillWidth: true
                    spacing: 6

                    Text {
                        font.pixelSize: 10
                        text: detailBox.flag(peerLine.modelData.iso ?? "")
                    }

                    Text {
                        Layout.fillWidth: true
                        elide: Text.ElideMiddle
                        color: "#8b949e"
                        font.pixelSize: 10
                        font.family: "monospace"
                        text: peerLine.modelData.name && peerLine.modelData.name.length > 0 ? peerLine.modelData.name : peerLine.modelData.ip
                    }

                    Text {
                        color: "#484f58"
                        font.pixelSize: 9
                        font.family: "monospace"
                        text: ":" + peerLine.modelData.port
                    }
                }
            }

            Text {
                Layout.fillWidth: true
                visible: detailBox.peers.length > 6
                color: "#484f58"
                font.pixelSize: 9
                text: I18n.t("e altri %1").arg(detailBox.peers.length - 6)
            }
        }
    }

    // Posizione del puntatore dentro la finestra, per piazzare il riquadro.
    // Non intercetta i click: le righe sotto restano cliccabili.
    HoverHandler {
        id: hoverHandler
    }

    QtObject {
        id: hoverPosition

        readonly property real x: hoverHandler.point.position.x
        readonly property real y: hoverHandler.point.position.y
    }

    // ================================================= menu del tasto destro
    // Chiude cliccando fuori: un menu che resta aperto mentre si fa altro
    // finisce per applicarsi al processo sbagliato.
    MouseArea {
        anchors.fill: parent
        visible: win.menuProcess !== null
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onClicked: win.closeMenuLater()
    }

    Rectangle {
        id: menu

        readonly property var process: win.menuProcess

        visible: menu.process !== null
        width: win.menuPage === "affinity" ? 250 : 190
        height: menuColumn.implicitHeight + 12
        x: Math.min(win.menuX, win.width - width - 8)
        y: Math.min(win.menuY, win.height - height - 8)
        z: 10
        radius: 8
        color: "#161b22"
        border.width: 1
        border.color: "#30363d"

        // Il popup non lascia passare niente: le voci usano TapHandler, che in
        // Qt non consuma il click, e senza questa MouseArea a fare da fondo lo
        // stesso click arriverebbe anche a quello che sta sotto il menu.
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton | Qt.RightButton
        }

        ColumnLayout {
            id: menuColumn

            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: 6
            spacing: 1

            Text {
                Layout.fillWidth: true
                Layout.leftMargin: 4
                Layout.bottomMargin: 2
                elide: Text.ElideRight
                color: "#6e7681"
                font.pixelSize: 9
                text: menu.process ? `${menu.process.name} · ${menu.process.pid}` : ""
            }

            // --- pagina principale ---
            Repeater {
                model: win.menuPage !== "main" ? [] : [
                    {
                        kind: "action",
                        action: "stop",
                        label: I18n.t("Sospendi"),
                        hint: "SIGSTOP",
                        danger: false,
                        enabled: !(menu.process && menu.process.state === "T")
                    },
                    {
                        kind: "action",
                        action: "resume",
                        label: I18n.t("Riprendi"),
                        hint: "SIGCONT",
                        danger: false,
                        enabled: menu.process ? menu.process.state === "T" : false
                    },
                    {
                        kind: "page",
                        page: "priority",
                        label: I18n.t("Priorità"),
                        hint: "›",
                        danger: false,
                        enabled: true
                    },
                    {
                        kind: "page",
                        page: "affinity",
                        label: I18n.t("Affinità"),
                        hint: "›",
                        danger: false,
                        enabled: true
                    },
                    {
                        kind: "action",
                        action: "terminate",
                        label: I18n.t("Termina"),
                        hint: "SIGTERM",
                        danger: true,
                        enabled: true
                    },
                    {
                        kind: "action",
                        action: "force",
                        label: I18n.t("Forza chiusura"),
                        hint: "SIGKILL",
                        danger: true,
                        enabled: true
                    }
                ]

                Rectangle {
                    id: menuItem

                    required property var modelData

                    Layout.fillWidth: true
                    implicitHeight: 24
                    radius: 4
                    color: itemHover.hovered && menuItem.modelData.enabled ? "#21262d" : "transparent"
                    opacity: menuItem.modelData.enabled ? 1 : 0.35

                    HoverHandler {
                        id: itemHover

                        cursorShape: menuItem.modelData.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                    }

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 6
                        anchors.rightMargin: 6
                        spacing: 6

                        Text {
                            Layout.fillWidth: true
                            color: menuItem.modelData.danger ? "#f85149" : "#c9d1d9"
                            font.pixelSize: 11
                            text: menuItem.modelData.label
                        }

                        Text {
                            color: "#484f58"
                            font.pixelSize: 9
                            font.family: menuItem.modelData.hint === "›" ? "sans-serif" : "monospace"
                            text: menuItem.modelData.hint
                        }
                    }

                    TapHandler {
                        enabled: menuItem.modelData.enabled
                        onTapped: {
                            if (menuItem.modelData.kind === "page") {
                                if (menuItem.modelData.page === "affinity")
                                    win.affinityChoice = Processes.detail && Processes.detail.pid === menu.process.pid ? Processes.detail.affinity.slice() : [];
                                win.menuPage = menuItem.modelData.page;
                            } else {
                                win.runFromMenu(menuItem.modelData.action);
                            }
                        }
                    }
                }
            }

            // --- priorità ---
            // Cinque livelli invece dei quaranta valori possibili: nessuno
            // ragiona in "nice 7", si ragiona in "che passi in secondo piano".
            Repeater {
                model: win.menuPage !== "priority" ? [] : [
                    {
                        value: -10,
                        label: I18n.t("Molto alta"),
                        needsRoot: true
                    },
                    {
                        value: -5,
                        label: I18n.t("Alta"),
                        needsRoot: true
                    },
                    {
                        value: 0,
                        label: I18n.t("Normale"),
                        needsRoot: false
                    },
                    {
                        value: 5,
                        label: I18n.t("Bassa"),
                        needsRoot: false
                    },
                    {
                        value: 19,
                        label: I18n.t("Molto bassa"),
                        needsRoot: false
                    }
                ]

                Rectangle {
                    id: niceItem

                    required property var modelData

                    readonly property bool current: menu.process ? (menu.process.nice ?? 0) === niceItem.modelData.value : false

                    Layout.fillWidth: true
                    implicitHeight: 24
                    radius: 4
                    color: niceHover.hovered ? "#21262d" : "transparent"

                    HoverHandler {
                        id: niceHover

                        cursorShape: Qt.PointingHandCursor
                    }

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 6
                        anchors.rightMargin: 6
                        spacing: 6

                        Text {
                            color: niceItem.current ? "#58a6ff" : "#c9d1d9"
                            font.pixelSize: 11
                            text: (niceItem.current ? "• " : "") + niceItem.modelData.label
                        }

                        Text {
                            Layout.fillWidth: true
                            horizontalAlignment: Text.AlignRight
                            // le priorita' alte richiedono privilegi: dirlo
                            // prima e' meglio di un errore dopo il clic
                            color: niceItem.modelData.needsRoot ? "#d29922" : "#484f58"
                            font.pixelSize: 9
                            text: niceItem.modelData.needsRoot ? I18n.t("serve root") : `nice ${niceItem.modelData.value}`
                        }
                    }

                    TapHandler {
                        onTapped: {
                            Processes.setNice(menu.process, niceItem.modelData.value);
                            // Se c'e' una regola per questo programma la si
                            // aggiorna al livello appena scelto: altrimenti fra
                            // due secondi la regola vecchia riporterebbe tutto
                            // com'era, e sembrerebbe che il menu non funzioni.
                            // Sulle priorita' alte la regola si toglie: non e'
                            // un livello che si possa riapplicare da soli.
                            if (menu.process && Settings.priorityFor(menu.process.name) >= 0) {
                                if (niceItem.modelData.value < 0)
                                    Settings.forgetPriority(menu.process.name);
                                else
                                    Settings.rememberPriority(menu.process.name, niceItem.modelData.value);
                            }
                            win.closeMenuLater();
                        }
                    }
                }
            }

            // --- ricorda la priorità ---
            // Vale per il programma, non per il processo: i pid cambiano a ogni
            // avvio, il nome no. Una regola copre anche tutti i processi che il
            // programma apre — un browser ne ha decine.
            Rectangle {
                id: rememberItem

                readonly property string name: menu.process ? menu.process.name : ""
                readonly property int remembered: Settings.priorityFor(rememberItem.name)
                readonly property int level: menu.process ? (menu.process.nice ?? 0) : 0
                // Si ricorda dalla priorita' normale in giu'. Le priorita'
                // alte (nice negativo) no: riapplicarle vorrebbe i privilegi
                // di amministratore, e la regola resterebbe a fallire in
                // silenzio a ogni giro. Lo zero invece e' una regola utile:
                // dice "questo programma resta a priorita' normale" e disdice
                // quella bassa di prima.
                readonly property bool usable: rememberItem.level >= 0 || rememberItem.remembered >= 0
                // -1 e' "nessuna regola": lo zero e' una regola come le altre
                readonly property bool active: rememberItem.remembered >= 0

                Layout.fillWidth: true
                Layout.topMargin: 4
                visible: win.menuPage === "priority"
                implicitHeight: 30
                radius: 4
                color: rememberHover.hovered && rememberItem.usable ? "#21262d" : "transparent"
                border.width: 1
                border.color: rememberItem.active ? "#30363d" : "transparent"

                HoverHandler {
                    id: rememberHover

                    cursorShape: rememberItem.usable ? Qt.PointingHandCursor : Qt.ArrowCursor
                }

                TapHandler {
                    enabled: rememberItem.usable
                    onTapped: {
                        if (rememberItem.active)
                            Settings.forgetPriority(rememberItem.name);
                        else
                            Settings.rememberPriority(rememberItem.name, rememberItem.level);
                    }
                }

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 6
                    anchors.rightMargin: 6
                    spacing: 6

                    Rectangle {
                        implicitWidth: 26
                        implicitHeight: 15
                        radius: 7.5
                        opacity: rememberItem.usable ? 1 : 0.4
                        color: rememberItem.active ? "#1f6feb" : "#21262d"
                        border.width: 1
                        border.color: rememberItem.active ? "#58a6ff" : "#30363d"

                        Rectangle {
                            width: 10
                            height: 10
                            radius: 5
                            anchors.verticalCenter: parent.verticalCenter
                            x: rememberItem.active ? parent.width - width - 2.5 : 2.5
                            color: rememberItem.active ? "#ffffff" : "#6e7681"

                            Behavior on x {
                                NumberAnimation {
                                    duration: 120
                                }
                            }
                        }
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 0

                        Text {
                            Layout.fillWidth: true
                            elide: Text.ElideRight
                            color: rememberItem.usable ? "#c9d1d9" : "#484f58"
                            font.pixelSize: 11
                            text: I18n.t("Ricorda per questo programma")
                        }

                        Text {
                            Layout.fillWidth: true
                            elide: Text.ElideRight
                            color: "#484f58"
                            font.pixelSize: 9
                            text: rememberItem.active ? (rememberItem.remembered > 0 ? I18n.t("%1 parte sempre a nice %2").arg(rememberItem.name).arg(rememberItem.remembered) : I18n.t("%1 parte sempre a priorità normale").arg(rememberItem.name)) : (rememberItem.usable ? I18n.t("da riapplicare a ogni avvio") : I18n.t("solo dalla priorità normale in giù"))
                        }
                    }
                }
            }

            // --- affinità ---
            ColumnLayout {
                Layout.fillWidth: true
                visible: win.menuPage === "affinity"
                spacing: 4

                Text {
                    Layout.fillWidth: true
                    Layout.leftMargin: 4
                    wrapMode: Text.Wrap
                    color: "#6e7681"
                    font.pixelSize: 9
                    text: I18n.t("Su quali thread può girare:")
                }

                Flow {
                    Layout.fillWidth: true
                    Layout.leftMargin: 4
                    Layout.rightMargin: 4
                    spacing: 3

                    Repeater {
                        model: win.menuPage === "affinity" ? SystemStats.cores.length : 0

                        Rectangle {
                            id: coreBox

                            required property int index

                            readonly property bool on: win.affinityChoice.includes(coreBox.index)

                            width: 22
                            height: 20
                            radius: 3
                            color: coreBox.on ? "#1f6feb" : "transparent"
                            border.width: 1
                            border.color: coreBox.on ? "#58a6ff" : "#30363d"

                            Text {
                                anchors.centerIn: parent
                                color: coreBox.on ? "#ffffff" : "#6e7681"
                                font.pixelSize: 9
                                text: coreBox.index
                            }

                            TapHandler {
                                onTapped: {
                                    const next = win.affinityChoice.slice();
                                    const at = next.indexOf(coreBox.index);
                                    if (at >= 0)
                                        next.splice(at, 1);
                                    else
                                        next.push(coreBox.index);
                                    win.affinityChoice = next;
                                }
                            }
                        }
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    Layout.leftMargin: 4
                    Layout.rightMargin: 4
                    spacing: 4

                    Rectangle {
                        Layout.fillWidth: true
                        implicitHeight: 22
                        radius: 4
                        color: allHover.hovered ? "#21262d" : "transparent"
                        border.width: 1
                        border.color: "#30363d"

                        HoverHandler {
                            id: allHover

                            cursorShape: Qt.PointingHandCursor
                        }

                        Text {
                            anchors.centerIn: parent
                            color: "#8b949e"
                            font.pixelSize: 10
                            text: I18n.t("tutti")
                        }

                        TapHandler {
                            onTapped: {
                                const all = [];
                                for (let i = 0; i < SystemStats.cores.length; i++)
                                    all.push(i);
                                win.affinityChoice = all;
                            }
                        }
                    }

                    Rectangle {
                        Layout.fillWidth: true
                        implicitHeight: 22
                        radius: 4
                        // senza nemmeno un thread il kernel rifiuterebbe: il
                        // pulsante resta spento invece di far arrivare l'errore
                        opacity: win.affinityChoice.length > 0 ? 1 : 0.4
                        color: applyHover.hovered && win.affinityChoice.length > 0 ? "#1f6feb" : "#21262d"
                        border.width: 1
                        border.color: "#388bfd"

                        HoverHandler {
                            id: applyHover

                            cursorShape: Qt.PointingHandCursor
                        }

                        Text {
                            anchors.centerIn: parent
                            color: "#c9d1d9"
                            font.pixelSize: 10
                            text: I18n.t("applica")
                        }

                        TapHandler {
                            enabled: win.affinityChoice.length > 0
                            onTapped: {
                                Processes.setAffinity(menu.process, win.affinityChoice);
                                win.closeMenuLater();
                            }
                        }
                    }
                }
            }

            // --- ritorno dalle sottopagine ---
            Rectangle {
                Layout.fillWidth: true
                Layout.topMargin: 2
                visible: win.menuPage !== "main"
                implicitHeight: 22
                radius: 4
                color: backHover.hovered ? "#21262d" : "transparent"

                HoverHandler {
                    id: backHover

                    cursorShape: Qt.PointingHandCursor
                }

                Text {
                    anchors.centerIn: parent
                    color: "#8b949e"
                    font.pixelSize: 10
                    text: I18n.t("‹ indietro")
                }

                TapHandler {
                    onTapped: win.menuPage = "main"
                }
            }
        }
    }
}
