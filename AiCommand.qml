import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

// Pannello "Comando IA": si parla al microfono del PC, il demone Stenografa
// trascrive con Whisper e fa interpretare la frase al suo backend LLM, che
// la traduce in una scorciatoia, nell'avvio di un'applicazione o in comandi
// da terminale. E' lo stesso motore del pulsante vocale dell'app telefono.
//
// Interpretazione ed esecuzione restano due passaggi separati, per due
// motivi diversi: i tasti simulati vanno a chi ha il fuoco, quindi la
// finestra deve prima togliersi di mezzo; i comandi da terminale invece si
// leggono e si confermano, e il demone li rifiuta senza conferma esplicita.
ColumnLayout {
    id: root

    // Chi tiene la dashboard su un monitor secondario senza darle mai il
    // fuoco puo' spegnerlo e vedere l'esito senza che la finestra sparisca.
    property bool hideWhileExecuting: true
    // Pausa fra il nascondersi della finestra e l'invio dei tasti: il
    // compositor restituisce il fuoco in modo asincrono.
    property int focusReturnDelay: 400

    // Vero fra il momento in cui si decide di troncare Hermes e quello in
    // cui il processo morto smette di parlare: serve a far ignorare al
    // raccoglitore l'output strappato dell'uccisione, che sembrerebbe una
    // risposta illeggibile invece che un'interruzione voluta.
    property bool hermesAborting: false

    // Chiede a chi ospita il pannello di togliere di mezzo la finestra.
    signal beforeExecute

    // idle | recording | transcribing | thinking | choice | confirm | executing | done | error
    property string phase: "idle"
    // comandi = interprete di Stenografa; hermes = l'agente che gira su questa
    // macchina (~/.hermes), quello con i suoi strumenti e la sua memoria
    property string mode: "comandi"
    property string message: ""
    // frase dettata, come l'ha capita Whisper
    property string transcript: ""
    property var options: []
    property string requestId: ""
    // opzione da terminale in attesa di conferma
    property int pendingIndex: -1
    property string output: ""

    // La conversazione sta tutta nel file che scripts/hermes_chat.py riscrive
    // a ogni scambio, e la finestra Hermes la mostra per intera. Qui resta
    // solo il conto degli scambi, per la riga che apre quella finestra.
    property var history: []
    readonly property int scambi: Math.floor(root.history.length / 2)

    FileView {
        path: Quickshell.env("HOME") + "/.cache/quickshell/hermes-chat.json"
        watchChanges: true
        onFileChanged: reload()
        onLoaded: {
            try {
                const data = JSON.parse(this.text());
                root.history = Array.isArray(data) ? data : [];
            } catch (e) {
                root.history = [];
            }
        }
        onLoadFailed: () => root.history = []
    }

    // Come parlare a Hermes (sezione "panelParams", chiave "ai").
    //
    // `hermesSession` e' il nome del filo di conversazione: lo script lo
    // riprende a ogni domanda, e "nuova conversazione" lo fa ruotare. Vuoto
    // vale "quello aperto adesso", che e' quasi sempre la risposta giusta.
    //
    // `hermesCwd` e' la cartella in cui Hermes gira: la home lo lascia
    // assistente generale, la cartella di un progetto gli fa leggere le regole
    // di quel progetto. `hermesModel` vuoto vuol dire quello configurato in
    // Hermes, che e' dove la scelta del modello ha da stare.
    readonly property string hermesSession: Settings.panelParam("ai", "hermesSession", defs.hermesSession)
    readonly property string hermesCwd: Settings.panelParam("ai", "hermesCwd", defs.hermesCwd)
    readonly property string hermesModel: Settings.panelParam("ai", "hermesModel", defs.hermesModel)
    readonly property int hermesTimeout: Settings.panelParam("ai", "hermesTimeout", defs.hermesTimeout)
    readonly property var defs: ({
            hermesSession: "",
            hermesCwd: "~",
            hermesModel: "",
            hermesTimeout: 300
        })

    Component.onCompleted:
        Settings.declarePanelParams("ai", ({ hermesSession: defs.hermesSession, hermesCwd: defs.hermesCwd, hermesModel: defs.hermesModel, hermesTimeout: defs.hermesTimeout }))

    // Stato per pulsante: mentre Hermes pensa il pulsante dei comandi resta
    // a metta luce, e viceversa — si vede quale dei due e' in coda.
    readonly property bool recComandi: root.mode === "comandi" && root.recording
    readonly property bool busyComandi: root.mode === "comandi" && root.busy
    readonly property bool recHermes: root.mode === "hermes" && root.recording
    readonly property bool busyHermes: root.mode === "hermes" && root.busy
    readonly property bool hermesThinking: root.mode === "hermes" && root.phase === "thinking"

    // Secondi da quando la domanda e' partita. Servono perche' Hermes non e'
    // una completion: puo' cercare, leggere file, chiamare i suoi MCP, e
    // mezzo minuto e' un'attesa normale. Senza un numero che sale, "sta
    // lavorando" e "si e' piantato" si distinguono solo fissando il puntino.
    property int hermesElapsed: 0

    Timer {
        id: hermesClock

        interval: 1000
        repeat: true
        running: root.hermesThinking
        onTriggered: {
            root.hermesElapsed += 1;
            root.message = I18n.t("hermes pensa… %1s").arg(root.hermesElapsed);
        }
    }

    readonly property string scriptPath: PluginPaths.of("scripts/stenografa_ai.py")
    readonly property bool busy: ["transcribing", "thinking", "executing"].includes(root.phase)
    readonly property bool recording: root.phase === "recording"

    // Riga descrittiva di un'opzione: la macro elenca i suoi passi, l'avvio
    // di un'applicazione dice quale, il comando da terminale se stesso.
    function describe(option: var): string {
        if (option.shell)
            return option.shell.join(" ; ");
        if (option.combos)
            return option.combos.join(" → ");
        if (option.app_id)
            return I18n.t("avvia %1").arg(option.app_name ?? option.app_id);
        return option.combo ?? "";
    }

    function reset() {
        root.phase = "idle";
        root.message = "";
        root.transcript = "";
        root.options = [];
        root.requestId = "";
        root.pendingIndex = -1;
        root.output = "";
    }

    // Il pulsante fa da interruttore: un tocco per parlare, uno per finire.
    // Se non si tocca piu' nulla ci pensa lo stop automatico sul silenzio
    // configurato nel demone. Premere l'altro pulsante mentre si parla
    // cambia strada a metà: si chiude la sessione e riparte con l'altro
    // destinatario.
    function toggleRecording(target) {
        const want = target ?? "comandi";

        if (root.busy)
            return;

        if (!(root.recording && root.mode === want)) {
            root.reset();
            root.mode = want;
            root.phase = "recording";
            root.message = I18n.t("avvio…");
        }
        recordProc.command = ["python3", root.scriptPath, "record"];
        recordProc.running = true;
    }

    // Un'opzione scelta (o l'unica trovata): i comandi da terminale passano
    // sempre dalla conferma, il resto parte subito.
    function activate(index: int) {
        const option = root.options[index];
        if (!option)
            return;
        if (option.shell) {
            root.pendingIndex = index;
            root.phase = "confirm";
            root.message = I18n.t("esegue nel terminale:");
            return;
        }
        root.execute(index, false);
    }

    function execute(index: int, confirmShell: bool) {
        const option = root.options[index];
        if (!root.requestId.length || !option)
            return;
        root.phase = "executing";
        root.message = I18n.t("esecuzione…");
        // Nascondersi serve solo a chi preme dei tasti: quelli vanno a chi ha
        // il fuoco, che finche' la dashboard e' in primo piano e' la
        // dashboard stessa. Avviare un'applicazione o eseguire un comando da
        // terminale non tocca la tastiera: li' sparire sarebbe solo un
        // effetto collaterale, e toglierebbe di vista l'esito.
        const needsFocus = !!(option.combo || option.combos);
        const delay = needsFocus && root.hideWhileExecuting ? root.focusReturnDelay : 0;
        if (delay > 0)
            root.beforeExecute();
        chooseProc.command = ["python3", root.scriptPath, "choose", root.requestId, String(index), String(delay)].concat(confirmShell ? ["confirm"] : []);
        chooseProc.running = true;
    }

    function cancel() {
        cancelProc.command = ["python3", root.scriptPath, "cancel"];
        cancelProc.running = true;
        root.reset();
    }

    // Interrompe Hermes a meta' risposta: uccide la richiesta, chiude anche
    // la sessione del demone se fosse rimasta appesa e torna libero. La
    // domanda gia' in chat resta senza risposta: e' la verita', non un
    // errore da nascondere.
    function abortHermes() {
        root.hermesAborting = true;
        // Anche la voce: se si tronca la domanda non si vuole sentire la
        // risposta di quella prima finire di essere letta.
        Tts.stop();
        askProc.running = false;
        watchProc.running = false;
        cancelProc.command = ["python3", root.scriptPath, "cancel"];
        cancelProc.running = true;
        hermesAbortingReset.restart();
        root.phase = "idle";
        root.message = "";
    }

    // Il processo ucciso puo' ancora emettere qualcosa mentre muore: il
    // guard vale finche' quell'output non e' arrivato, poi si spegne da solo.
    Timer {
        id: hermesAbortingReset

        interval: 500
        onTriggered: root.hermesAborting = false
    }

    // Ogni riga stampata da `watch` e' una fotografia della sessione.
    function applySession(session: var) {
        root.transcript = session.text ?? "";
        const phase = session.phase ?? "";

        // In modalita' Hermes il demone serve solo fino alla trascrizione:
        // l'interpretazione dei comandi non ci riguarda, si cancella e la
        // frase va a Hermes, che risponde nella finestra della chat.
        if (root.mode === "hermes") {
            if (phase === "thinking" || phase === "choice") {
                cancelProc.command = ["python3", root.scriptPath, "cancel"];
                cancelProc.running = true;

                const text = root.transcript.trim();

                if (!text.length) {
                    root.phase = "error";
                    root.message = I18n.t("non ho sentito nulla");
                    return;
                }

                root.phase = "thinking";
                root.hermesElapsed = 0;
                root.message = I18n.t("hermes pensa…");
                askProc.command = ["python3", PluginPaths.of("scripts/hermes_chat.py"),
                                   "ask", text,
                                   "--session", root.hermesSession,
                                   "--cwd", root.hermesCwd,
                                   "--model", root.hermesModel,
                                   "--timeout", String(root.hermesTimeout)];
                askProc.running = true;
            }
            return;
        }

        if (phase === "error") {
            root.phase = "error";
            root.message = session.error ?? I18n.t("errore");
            return;
        }
        if (phase === "choice") {
            root.options = session.options ?? [];
            root.requestId = session.request_id ?? "";
            if (root.options.length === 0) {
                root.phase = "error";
                root.message = I18n.t("nessuna interpretazione trovata");
            } else if (root.options.length === 1) {
                // comando chiaro: si esegue senza chiedere altro, a meno
                // che non sia da terminale (activate se ne accorge)
                root.activate(0);
            } else {
                root.phase = "choice";
                root.message = I18n.t("%1 interpretazioni: scegli quale eseguire").arg(root.options.length);
            }
            return;
        }
        if (phase === "recording") {
            root.phase = "recording";
            root.message = I18n.t("in ascolto… tocca per fermare");
        } else if (phase === "transcribing") {
            root.phase = "transcribing";
            root.message = I18n.t("trascrizione…");
        } else if (phase === "thinking") {
            root.phase = "thinking";
            root.message = I18n.t("interpretazione…");
        }
    }

    spacing: 6

    RowLayout {
        Layout.fillWidth: true
        spacing: 8

        Rectangle {
            implicitWidth: 8
            implicitHeight: 8
            radius: 4
            color: root.recording ? "#f85149" : root.busy ? "#d29922" : root.phase === "error" ? "#f85149" : root.phase === "choice" || root.phase === "confirm" ? "#58a6ff" : "#484f58"

            SequentialAnimation on opacity {
                running: root.recording || root.busy
                loops: Animation.Infinite

                NumberAnimation {
                    to: 0.3
                    duration: 500
                }

                NumberAnimation {
                    to: 1
                    duration: 500
                }
            }
        }

        Text {
            Layout.fillWidth: true
            color: "#8b949e"
            font.pixelSize: 10
            font.letterSpacing: 1
            text: root.mode === "hermes" ? "HERMES" : I18n.t("COMANDO IA")
        }

        // La voce sta qui e non fra i due microfoni perche' non e' un modo di
        // parlare: e' cosa succede alla risposta quando arriva.
        TtsButton {
        }
    }

    // --- i due pulsanti microfono ----------------------------------------
    // Stesso microfono, due destinazioni: l'interprete dei comandi del
    // demone, oppure Hermes in persona. Quello attivo si accende,
    // quello dell'altra strada resta a metta luce finche' non finisce.
    RowLayout {
        Layout.fillWidth: true
        spacing: 8

        Rectangle {
            Layout.fillWidth: true
            implicitHeight: 34
            radius: 6
            color: root.recComandi ? "#3d1418" : cmdArea.containsMouse && !root.busy ? "#161b22" : "transparent"
            border.width: 1
            border.color: root.recComandi ? "#f85149" : cmdArea.containsMouse && !root.busy ? "#388bfd" : "#30363d"
            opacity: root.busy && root.mode !== "comandi" ? 0.45 : 1

            RowLayout {
                anchors.centerIn: parent
                spacing: 8

                Rectangle {
                    implicitWidth: 10
                    implicitHeight: 10
                    radius: root.recComandi ? 2 : 5
                    color: root.recComandi ? "#f85149" : "#8b949e"

                    Behavior on radius {
                        NumberAnimation {
                            duration: 120
                        }
                    }
                }

                Text {
                    color: root.recComandi ? "#f0f6fc" : "#c9d1d9"
                    font.pixelSize: 12
                    text: root.recComandi ? I18n.t("Ferma e interpreta") : root.busyComandi ? "…" : I18n.t("Parla")
                }
            }

            MouseArea {
                id: cmdArea

                anchors.fill: parent
                hoverEnabled: true
                enabled: !root.busy || root.mode === "comandi"
                cursorShape: Qt.PointingHandCursor
                onClicked: root.toggleRecording("comandi")
            }
        }

        Rectangle {
            Layout.fillWidth: true
            implicitHeight: 34
            radius: 6
            color: root.recHermes ? "#3d1418" : root.busyHermes ? "#2a1f0e" : hermesArea.containsMouse && !root.busy ? "#161b22" : "transparent"
            border.width: 1
            border.color: root.recHermes ? "#f85149" : root.busyHermes ? "#d29922" : hermesArea.containsMouse && !root.busy ? "#388bfd" : "#30363d"
            opacity: root.busyComandi ? 0.45 : 1

            RowLayout {
                anchors.centerIn: parent
                spacing: 8

                Rectangle {
                    implicitWidth: 10
                    implicitHeight: 10
                    radius: root.recHermes ? 2 : 5
                    color: root.recHermes ? "#f85149" : root.busyHermes ? "#d29922" : "#8b949e"
                }

                Text {
                    color: root.recHermes || root.busyHermes ? "#f0f6fc" : "#c9d1d9"
                    font.pixelSize: 12
                    // Da attivo a stop: mentre registra tronca la dettatura,
                    // mentre Hermes risponde ammazza la richiesta.
                    text: root.recHermes || root.busyHermes ? I18n.t("Ferma") : I18n.t("Parla con Hermes")
                }
            }

            MouseArea {
                id: hermesArea

                anchors.fill: parent
                hoverEnabled: true
                enabled: !root.busy || root.mode === "hermes"
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                    // Mentre Hermes risponde lo stesso pulsante diventa lo stop:
                    // un tocco tronca la richiesta e libera il pannello.
                    if (root.busyHermes) {
                        root.abortHermes();
                        return;
                    }
                    root.toggleRecording("hermes");
                }
            }
        }
    }

    // --- frase capita da Whisper ---
    Text {
        Layout.fillWidth: true
        visible: root.transcript.length > 0
        wrapMode: Text.Wrap
        color: "#c9d1d9"
        font.pixelSize: 11
        font.italic: true
        text: `“${root.transcript}”`
    }

    Text {
        Layout.fillWidth: true
        visible: root.message.length > 0
        wrapMode: Text.Wrap
        color: root.phase === "error" ? "#f85149" : "#8b949e"
        font.pixelSize: 10
        text: root.message
    }

    // La voce ha una riga sua: quando non parte, il motivo e' suo (motore da
    // installare, audio occupato) e non c'entra con quello che sta facendo il
    // microfono.
    Text {
        Layout.fillWidth: true
        visible: Tts.phase === "error" && Tts.message.length > 0
        wrapMode: Text.Wrap
        color: "#f85149"
        font.pixelSize: 10
        text: I18n.t("voce: %1").arg(Tts.message)
    }

    // --- la conversazione sta in una finestra a parte ---------------------
    // Nel pannello solo il conto degli scambi e il collegamento: la colonna
    // della dashboard e' stretta, e una chat merita respiro.
    RowLayout {
        Layout.fillWidth: true
        visible: root.scambi > 0
        spacing: 8

        Text {
            color: "#6e7681"
            font.pixelSize: 10
            font.letterSpacing: 1
            text: "HERMES · " + root.scambi
        }

        Item {
            Layout.fillWidth: true
        }

        Text {
            color: openArea.containsMouse ? "#388bfd" : "#8b949e"
            font.pixelSize: 10
            text: I18n.t("apri la chat")

            MouseArea {
                id: openArea

                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: DashActions.openHermes()
            }
        }
    }

    // --- comando ambiguo: sceglie l'utente, il demone non ha eseguito nulla ---
    Repeater {
        model: root.phase === "choice" ? root.options : []

        Rectangle {
            id: option

            required property int index
            required property var modelData

            Layout.fillWidth: true
            implicitHeight: 30
            radius: 6
            color: optionArea.containsMouse ? "#161b22" : "transparent"
            border.width: 1
            border.color: optionArea.containsMouse ? "#388bfd" : "#30363d"

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
                    text: option.modelData.label ?? ""
                }

                Text {
                    Layout.maximumWidth: 150
                    elide: Text.ElideRight
                    color: option.modelData.shell ? "#e3b341" : "#8b949e"
                    font.pixelSize: 10
                    font.family: "monospace"
                    text: root.describe(option.modelData)
                }
            }

            MouseArea {
                id: optionArea

                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.activate(option.index)
            }
        }
    }

    // --- conferma di un comando da terminale ---
    // Niente viene eseguito finche' non si preme Esegui: il demone rifiuta i
    // comandi shell senza conferma esplicita, qualunque cosa chieda l'LLM.
    Rectangle {
        Layout.fillWidth: true
        visible: root.phase === "confirm"
        implicitHeight: confirmBox.implicitHeight + 16
        radius: 6
        color: "#161b22"
        border.width: 1
        border.color: "#e3b341"

        ColumnLayout {
            id: confirmBox

            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: 8
            spacing: 6

            Repeater {
                model: root.phase === "confirm" && root.pendingIndex >= 0 ? (root.options[root.pendingIndex].shell ?? []) : []

                Text {
                    required property string modelData

                    Layout.fillWidth: true
                    wrapMode: Text.Wrap
                    color: "#e3b341"
                    font.pixelSize: 10
                    font.family: "monospace"
                    text: "$ " + modelData
                }
            }

            RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: 2
                spacing: 6

                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: 26
                    radius: 6
                    color: runArea.containsMouse ? "#1f6feb" : "#21262d"
                    border.width: 1
                    border.color: "#388bfd"

                    Text {
                        anchors.centerIn: parent
                        color: "#f0f6fc"
                        font.pixelSize: 11
                        text: I18n.t("Esegui")
                    }

                    MouseArea {
                        id: runArea

                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.execute(root.pendingIndex, true)
                    }
                }

                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: 26
                    radius: 6
                    color: cancelArea.containsMouse ? "#21262d" : "transparent"
                    border.width: 1
                    border.color: "#30363d"

                    Text {
                        anchors.centerIn: parent
                        color: "#8b949e"
                        font.pixelSize: 11
                        text: I18n.t("Annulla")
                    }

                    MouseArea {
                        id: cancelArea

                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.cancel()
                    }
                }
            }
        }
    }

    // --- output di un comando da terminale ---
    Rectangle {
        Layout.fillWidth: true
        visible: root.output.length > 0
        implicitHeight: Math.min(outputText.implicitHeight + 12, 110)
        radius: 6
        color: "#161b22"
        border.width: 1
        border.color: "#30363d"
        clip: true

        Text {
            id: outputText

            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.margins: 6
            wrapMode: Text.Wrap
            // le ultime righe sono quelle che dicono com'e' finita: se
            // l'output non ci sta, si ancora in basso invece che in alto
            color: "#8b949e"
            font.pixelSize: 9
            font.family: "monospace"
            text: root.output
        }
    }

    Process {
        id: recordProc

        stdout: StdioCollector {
            onStreamFinished: {
                let data;
                try {
                    data = JSON.parse(this.text);
                } catch (e) {
                    root.phase = "error";
                    root.message = I18n.t("risposta illeggibile dal ponte");
                    return;
                }
                if (!data.ok) {
                    root.phase = "error";
                    root.message = data.error ?? I18n.t("avvio non riuscito");
                    return;
                }
                if (data.state === "recording") {
                    root.phase = "recording";
                    root.message = I18n.t("in ascolto… tocca per fermare");
                    // il seq della sessione appena aperta evita che la
                    // sorveglianza scambi l'esito precedente per il proprio
                    watchProc.command = ["python3", root.scriptPath, "watch", "300", String(data.seq ?? 0)];
                    watchProc.running = true;
                } else if (data.state === "transcribing") {
                    root.phase = "transcribing";
                    root.message = I18n.t("trascrizione…");
                }
            }
        }
    }

    // Segue la sessione fino all'esito: una riga JSON per ogni cambiamento.
    Process {
        id: watchProc

        stdout: SplitParser {
            onRead: line => {
                if (!line.trim().length)
                    return;
                let data;
                try {
                    data = JSON.parse(line);
                } catch (e) {
                    return;
                }
                if (!data.ok) {
                    root.phase = "error";
                    root.message = data.error ?? "errore";
                    return;
                }
                if (data.session)
                    root.applySession(data.session);
            }
        }
    }

    Process {
        id: chooseProc

        stdout: StdioCollector {
            onStreamFinished: {
                let data;
                try {
                    data = JSON.parse(this.text);
                } catch (e) {
                    root.phase = "error";
                    root.message = I18n.t("risposta illeggibile dal ponte");
                    return;
                }
                root.options = [];
                root.requestId = "";
                root.pendingIndex = -1;
                root.output = data.output ?? "";
                if (!data.ok || data.error) {
                    root.phase = "error";
                    root.message = data.error ?? I18n.t("esecuzione non riuscita");
                    return;
                }
                root.phase = "done";
                root.message = I18n.t("eseguito: %1").arg(data.executed ?? "");
            }
        }
    }

    Process {
        id: cancelProc
    }

    // La domanda in attesa di Hermes: il ponte lancia la sua riga di comando e
    // aspetta il turno intero — strumenti compresi — poi restituisce la
    // risposta, che e' gia' finita nel file che la finestra della chat guarda.
    Process {
        id: askProc

        stdout: StdioCollector {
            onStreamFinished: {
                // un'uccisione voluta parla a metà: non e' un errore da mostrare
                if (root.hermesAborting)
                    return;
                let data;
                try {
                    data = JSON.parse(this.text);
                } catch (e) {
                    root.phase = "error";
                    root.message = I18n.t("risposta illeggibile dal ponte");
                    return;
                }
                if (!data.ok || data.error) {
                    root.phase = "error";
                    root.message = data.error ?? I18n.t("hermes non ha risposto");
                    return;
                }
                // La risposta e' gia' nel file, e la finestra Hermes la mostra
                // gia' grazie a FileView: qui si fa solo salire la finestra,
                // perche' una risposta che resta nascosta in un'altra vista
                // sarebbe come non averla avuta.
                DashActions.openHermes();
                // E, se la voce e' accesa, si sente invece di leggerla: e'
                // `say`, non `speakNow`, perche' l'interruttore lo guarda Tts.
                Tts.say(data.reply ?? "");
                root.phase = "idle";
                root.message = "";
            }
        }
    }

    // Il reset della conversazione e' nella finestra Hermes, dove la chat si
    // vede: qui non restano comandi che toccano il file.
}