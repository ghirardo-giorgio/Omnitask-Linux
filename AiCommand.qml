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

    // Chiede a chi ospita il pannello di togliere di mezzo la finestra.
    signal beforeExecute

    // idle | recording | transcribing | thinking | choice | confirm | executing | done | error
    property string phase: "idle"
    property string message: ""
    // frase dettata, come l'ha capita Whisper
    property string transcript: ""
    property var options: []
    property string requestId: ""
    // opzione da terminale in attesa di conferma
    property int pendingIndex: -1
    property string output: ""

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
    // configurato nel demone.
    function toggleRecording() {
        if (root.busy)
            return;
        if (!root.recording) {
            root.reset();
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

    // Ogni riga stampata da `watch` e' una fotografia della sessione.
    function applySession(session: var) {
        root.transcript = session.text ?? "";
        const phase = session.phase ?? "";
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
            text: I18n.t("COMANDO IA")
        }
    }

    // --- pulsante microfono ---
    Rectangle {
        Layout.fillWidth: true
        implicitHeight: 34
        radius: 6
        color: root.recording ? "#3d1418" : micArea.containsMouse && !root.busy ? "#161b22" : "transparent"
        border.width: 1
        border.color: root.recording ? "#f85149" : micArea.containsMouse && !root.busy ? "#388bfd" : "#30363d"
        opacity: root.busy ? 0.6 : 1

        RowLayout {
            anchors.centerIn: parent
            spacing: 8

            Rectangle {
                implicitWidth: 10
                implicitHeight: 10
                radius: root.recording ? 2 : 5
                color: root.recording ? "#f85149" : "#8b949e"

                Behavior on radius {
                    NumberAnimation {
                        duration: 120
                    }
                }
            }

            Text {
                color: root.recording ? "#f0f6fc" : "#c9d1d9"
                font.pixelSize: 12
                text: root.recording ? I18n.t("Ferma e interpreta") : root.busy ? "…" : I18n.t("Parla")
            }
        }

        MouseArea {
            id: micArea

            anchors.fill: parent
            hoverEnabled: true
            enabled: !root.busy
            cursorShape: Qt.PointingHandCursor
            onClicked: root.toggleRecording()
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
}
