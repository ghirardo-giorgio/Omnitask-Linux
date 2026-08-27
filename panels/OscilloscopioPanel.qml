import QtQuick
import QtQuick.Layouts
import QtQuick.Window
import Quickshell.Io

// Il pannello sta in panels/: senza `import ".."` si caricherebbe lo stesso,
// ma SystemStats, Settings, I18n e i componenti della dashboard resterebbero
// indefiniti — vedi scripts/panels.py, che verifica la riga e lo dice.
import ".."

// L'oscilloscopio: quello che esce dalle casse, disegnato come lo disegnavano
// ProTracker e Winamp.
//
// La forma d'onda arriva gia' agganciata e gia' ridotta a punti da
// scripts/audioscope.py — il trigger e il campionamento stanno li' perche' sono
// aritmetica su decine di migliaia di campioni al secondo, e in QML sarebbero
// decine di migliaia di attraversamenti del ponte fra JavaScript e Qt. Qui
// resta il disegno, che e' una polilinea di un centinaio di punti.
//
// La cattura vive solo mentre il pannello si vede: l'audio scorre comunque, ma
// leggerlo e disegnarlo con la dashboard chiusa sarebbe un costo fisso pagato
// da nessuno (vedi `listening`).
ColumnLayout {
    id: root

    // L'id ferma il pannello nella configurazione salvata (le colonne di
    // dashboard.json lo citano); il titolo e' quello che la finestra Opzioni
    // mostra.
    property string panelId: "audioscope"
    property string panelTitle: "Oscilloscopio"

    // I numeri che si possono cambiare senza toccare il codice: stanno nella
    // sezione "panelParams" di dashboard.json.
    //
    // `fps` e' quello che costa: trenta fotogrammi al secondo sono un
    // oscilloscopio, quindici sono un'animazione: chi ha una macchina lenta, o
    // il pannello sempre aperto, cala questo prima di tutto il resto.
    readonly property var defs: ({
            fps: 30,
            points: 96,
            windowMs: 20,
            height: 56,
            device: ""
        })

    readonly property int fps: Math.max(5, Math.min(60, Settings.panelParam("audioscope", "fps", defs.fps)))
    readonly property int points: Math.max(8, Math.min(512, Settings.panelParam("audioscope", "points", defs.points)))
    readonly property int windowMs: Math.max(4, Math.min(200, Settings.panelParam("audioscope", "windowMs", defs.windowMs)))
    readonly property int scopeHeight: Math.max(24, Settings.panelParam("audioscope", "height", defs.height))

    // Vuoto vuol dire «quello che si sente adesso», cioe' il monitor del sink
    // di default, che e' il caso di tutti. Chi vuole guardare sempre la stessa
    // scheda — o un microfono — ci scrive il nome che `pactl list short
    // sources` gli da'.
    readonly property string device: Settings.panelParam("audioscope", "device", defs.device)

    Component.onCompleted: Settings.declarePanelParams("audioscope", defs)

    // --- lo stato che si disegna --------------------------------------------

    property var wave: []
    property real peak: 0
    property real rms: 0
    property bool silent: true
    property string sink: ""
    property string problem: ""

    // Il pannello e' in una colonna visibile *e* la finestra che lo ospita e'
    // aperta: la dashboard si nasconde senza distruggere niente (shell.qml fa
    // `win.visible = false`), quindi il solo `visible` del pannello resterebbe
    // vero e la cattura andrebbe avanti a finestra chiusa.
    readonly property bool listening: root.visible && root.Window.window !== null && root.Window.window.visible

    // Il nome del sink senza la meccanica intorno: "alsa_output.pci-0000_06_00.1
    // .hdmi-stereo.monitor" non dice niente a nessuno, "hdmi-stereo" si legge.
    readonly property string sinkLabel: {
        const raw = root.sink ?? "";
        if (!raw.length)
            return "";
        const cut = raw.replace(/\.monitor$/, "").split(".");
        return cut[cut.length - 1];
    }

    // dBFS invece della percentuale: e' la scala con cui si guarda un livello
    // audio, e distingue il -6 dal -30 che in percentuale sono due numeri
    // piccoli e uguali. Zero e' il massimo, sotto -60 non c'e' piu' niente.
    readonly property string levelLabel: {
        if (root.silent || root.peak <= 0)
            return "−∞ dB";
        const db = 20 * Math.log(root.peak) / Math.LN10;
        return `${db.toFixed(0)} dB`;
    }

    spacing: 8

    Text {
        color: "#8b949e"
        font.pixelSize: 10
        font.letterSpacing: 1
        text: I18n.t("AUDIO")
    }

    RowLayout {
        Layout.fillWidth: true
        spacing: 6

        Text {
            color: "#c9d1d9"
            font.pixelSize: 12
            text: I18n.t("Oscilloscopio")
        }

        Text {
            Layout.fillWidth: true
            elide: Text.ElideRight
            color: "#6e7681"
            font.pixelSize: 10
            text: root.problem.length > 0 ? root.problem : root.sinkLabel
        }

        // Il livello sta a destra come le percentuali degli altri pannelli, e
        // si spegne di colore quando non suona niente: il numero resta al suo
        // posto invece di sparire e far ballare la riga.
        Text {
            color: root.silent ? "#6e7681" : "#c9d1d9"
            font.pixelSize: 11
            font.family: "monospace"
            text: root.levelLabel
        }
    }

    Rectangle {
        Layout.fillWidth: true
        implicitHeight: root.scopeHeight
        radius: 6
        color: "#010409"
        border.width: 1
        border.color: "#21262d"
        clip: true

        // La linea dello zero: senza, una forma d'onda asimmetrica sembra
        // storta e non si capisce rispetto a cosa.
        Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.margins: 4
            height: 1
            color: "#161b22"
        }

        Canvas {
            id: scope

            anchors.fill: parent
            anchors.margins: 3

            readonly property color traceColor: Settings.colorFor("audioscope", "#3fb950")

            // Un fotogramma nuovo e' un ridisegno: il Canvas non si accorge da
            // solo che l'array e' cambiato.
            Connections {
                target: root

                function onWaveChanged(): void {
                    scope.requestPaint();
                }
            }

            onTraceColorChanged: scope.requestPaint()

            // Tasto destro sul grafico: il colore della traccia, come sugli
            // altri grafici della dashboard (vedi Sparkline).
            TapHandler {
                acceptedButtons: Qt.RightButton
                onTapped: eventPoint => DashActions.pickColor([
                        {
                            id: "audioscope",
                            label: I18n.t("Oscilloscopio"),
                            fallback: "#3fb950"
                        }
                    ], eventPoint.scenePosition.x, eventPoint.scenePosition.y)
            }

            onPaint: {
                const ctx = getContext("2d");
                ctx.reset();

                const w = width;
                const h = height;
                const mid = h / 2;
                const data = root.wave ?? [];

                // Silenzio: la linea di mezzo, e basta. Disegnare cento punti
                // tutti a zero darebbe lo stesso risultato costando cento volte
                // tanto, trenta volte al secondo.
                if (root.silent || data.length < 2) {
                    ctx.strokeStyle = Qt.alpha(scope.traceColor, 0.35);
                    ctx.lineWidth = 1;
                    ctx.beginPath();
                    ctx.moveTo(0, mid);
                    ctx.lineTo(w, mid);
                    ctx.stroke();
                    return;
                }

                // I punti arrivano interi fra -127 e 127: mezza altezza per il
                // pieno scala, meno un pixel perche' un picco a fondo scala non
                // finisca tagliato contro il bordo.
                const amp = mid - 1;
                const step = w / (data.length - 1);
                const yOf = v => mid - Math.max(-1, Math.min(1, v / 127)) * amp;

                ctx.beginPath();
                ctx.moveTo(0, yOf(data[0]));
                for (let i = 1; i < data.length; i++)
                    ctx.lineTo(i * step, yOf(data[i]));

                // Due passate sulla stessa polilinea: una larga e trasparente,
                // una sottile e piena. E' l'alone dei fosfori dei tubi — e
                // costa quanto un secondo tratto, mentre shadowBlur costerebbe
                // una sfocatura a fotogramma.
                ctx.lineJoin = "round";
                ctx.lineCap = "round";
                ctx.strokeStyle = Qt.alpha(scope.traceColor, 0.25);
                ctx.lineWidth = 3;
                ctx.stroke();
                ctx.strokeStyle = scope.traceColor;
                ctx.lineWidth = 1;
                ctx.stroke();
            }
        }
    }

    // --- la cattura ---------------------------------------------------------

    Process {
        id: audio

        running: root.listening

        command: [
            "python3",
            PluginPaths.of("scripts/audioscope.py"),
            "--fps",
            String(root.fps),
            "--points",
            String(root.points),
            "--window",
            String(root.windowMs),
            ...(root.device.length > 0 ? ["--device", root.device] : [])
        ]

        // Il pannello torna in vista dopo essere stato via: quello che si
        // vedeva era di prima, e non e' piu' vero.
        onRunningChanged: {
            if (!audio.running) {
                root.wave = [];
                root.silent = true;
                root.peak = 0;
                root.rms = 0;
            }
        }

        stdout: SplitParser {
            onRead: line => {
                let d;

                try {
                    d = JSON.parse(line);
                } catch (e) {
                    return;
                }

                if (d.error) {
                    root.problem = d.error;
                    root.silent = true;
                    root.wave = [];
                    return;
                }

                root.problem = "";
                root.sink = d.sink ?? root.sink;

                if (d.silent) {
                    root.silent = true;
                    root.peak = 0;
                    root.rms = 0;
                    root.wave = [];
                    return;
                }

                root.silent = false;
                root.peak = d.peak ?? 0;
                root.rms = d.rms ?? 0;
                root.wave = d.w ?? [];
            }
        }
    }
}
