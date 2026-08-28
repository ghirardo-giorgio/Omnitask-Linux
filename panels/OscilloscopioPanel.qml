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
            stereo: true,
            device: ""
        })

    readonly property int fps: Math.max(5, Math.min(60, Settings.panelParam("audioscope", "fps", defs.fps)))
    readonly property int points: Math.max(8, Math.min(512, Settings.panelParam("audioscope", "points", defs.points)))
    readonly property int windowMs: Math.max(4, Math.min(200, Settings.panelParam("audioscope", "windowMs", defs.windowMs)))
    readonly property int scopeHeight: Math.max(24, Settings.panelParam("audioscope", "height", defs.height))

    // Due canali invece del miscuglio dei due. Il riquadro si taglia in
    // verticale: ogni canale tiene tutta l'altezza — che e' quella che si
    // guarda, l'ampiezza — e cede meta' larghezza, cioe' meta' dei punti per
    // la stessa finestra di tempo. Chi vuole indietro il dettaglio orizzontale
    // alza `points`, non `height`.
    readonly property bool stereo: Settings.panelParam("audioscope", "stereo", defs.stereo) === true

    // Vuoto vuol dire «quello che si sente adesso», cioe' il monitor del sink
    // di default, che e' il caso di tutti. Chi vuole guardare sempre la stessa
    // scheda — o un microfono — ci scrive il nome che `pactl list short
    // sources` gli da'.
    readonly property string device: Settings.panelParam("audioscope", "device", defs.device)

    Component.onCompleted: Settings.declarePanelParams("audioscope", defs)

    // --- lo stato che si disegna --------------------------------------------

    // In mono `wave` e' l'unica traccia; in stereo e' il canale sinistro e
    // `waveRight` il destro.
    property var wave: []
    property var waveRight: []
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
        // storta e non si capisce rispetto a cosa. Tagliando in verticale
        // resta una sola, perche' lo zero dei due canali sta alla stessa
        // altezza e spezzarla in due non direbbe niente di piu'.
        Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.margins: 4
            height: 1
            color: "#161b22"
        }

        // Il taglio fra i due canali: piu' chiaro della linea dello zero,
        // perche' quello che separa deve leggersi prima di quello che misura.
        Rectangle {
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            x: Math.round(parent.width / 2)
            width: 1
            color: "#21262d"
            visible: root.stereo
        }

        // Quale meta' e' quale. «L» e «R» non passano da I18n apposta: sono la
        // sigla stampata sui connettori di qualunque apparecchio audio, non
        // due parole da tradurre.
        Text {
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.margins: 3
            color: "#30363d"
            font.pixelSize: 9
            text: "L"
            visible: root.stereo
        }

        Text {
            anchors.top: parent.top
            anchors.topMargin: 3
            x: Math.round(parent.width / 2) + 3
            color: "#30363d"
            font.pixelSize: 9
            text: "R"
            visible: root.stereo
        }

        Canvas {
            id: scope

            anchors.fill: parent
            anchors.margins: 3

            // Un colore per canale: "audioscope" resta l'id del sinistro —
            // e del mono — cosi' chi aveva gia' scelto il suo verde se lo
            // ritrova, e il destro nasce con un colore diverso perche' due
            // tracce identiche affiancate non si distinguerebbero a colpo
            // d'occhio.
            readonly property color traceColor: Settings.colorFor("audioscope", "#3fb950")
            readonly property color traceRight: Settings.colorFor("audioscope-right", "#58a6ff")

            // Un fotogramma nuovo e' un ridisegno: il Canvas non si accorge da
            // solo che l'array e' cambiato.
            Connections {
                target: root

                function onWaveChanged(): void {
                    scope.requestPaint();
                }
            }

            onTraceColorChanged: scope.requestPaint()
            onTraceRightChanged: scope.requestPaint()

            // Tasto destro sul grafico: il colore della traccia, come sugli
            // altri grafici della dashboard (vedi Sparkline). Il quarto
            // argomento e' la lettura sotto il puntatore, che qui non esiste:
            // l'oscilloscopio non viene da Home Assistant e non ha niente da
            // cancellare. Ometterlo non apriva il menu affatto.
            TapHandler {
                acceptedButtons: Qt.RightButton
                onTapped: eventPoint => DashActions.pickColor(root.stereo ? [
                        {
                            id: "audioscope",
                            label: I18n.t("Canale sinistro"),
                            fallback: "#3fb950"
                        },
                        {
                            id: "audioscope-right",
                            label: I18n.t("Canale destro"),
                            fallback: "#58a6ff"
                        }
                    ] : [
                        {
                            id: "audioscope",
                            label: I18n.t("Oscilloscopio"),
                            fallback: "#3fb950"
                        }
                    ], eventPoint.scenePosition.x, eventPoint.scenePosition.y, null)
            }

            // Una traccia sola, dentro la striscia che va da `x0` a `x0 + w`.
            // Sta in una funzione perche' con i canali separati la stessa cosa
            // si fa due volte, in due strisce affiancate e di due colori.
            function trace(ctx: var, data: var, x0: real, w: real, tint: color): void {
                // I punti arrivano interi fra -127 e 127: mezza altezza per il
                // pieno scala, meno un pixel perche' un picco a fondo scala non
                // finisca tagliato contro il bordo.
                const mid = height / 2;
                const amp = mid - 1;
                const step = w / (data.length - 1);
                const yOf = v => mid - Math.max(-1, Math.min(1, v / 127)) * amp;

                ctx.beginPath();
                ctx.moveTo(x0, yOf(data[0]));
                for (let i = 1; i < data.length; i++)
                    ctx.lineTo(x0 + i * step, yOf(data[i]));

                // Due passate sulla stessa polilinea: una larga e trasparente,
                // una sottile e piena. E' l'alone dei fosfori dei tubi — e
                // costa quanto un secondo tratto, mentre shadowBlur costerebbe
                // una sfocatura a fotogramma.
                ctx.lineJoin = "round";
                ctx.lineCap = "round";
                ctx.strokeStyle = Qt.alpha(tint, 0.25);
                ctx.lineWidth = 3;
                ctx.stroke();
                ctx.strokeStyle = tint;
                ctx.lineWidth = 1;
                ctx.stroke();
            }

            function flat(ctx: var, x0: real, w: real, tint: color): void {
                const mid = height / 2;
                ctx.strokeStyle = Qt.alpha(tint, 0.35);
                ctx.lineWidth = 1;
                ctx.beginPath();
                ctx.moveTo(x0, mid);
                ctx.lineTo(x0 + w, mid);
                ctx.stroke();
            }

            onPaint: {
                const ctx = getContext("2d");
                ctx.reset();

                const left = root.wave ?? [];
                const right = root.waveRight ?? [];

                // Due strisce affiancate, con un pixel di stacco sul taglio
                // perche' l'ultimo punto del sinistro non si appoggi al primo
                // del destro facendoli sembrare un tratto solo.
                const w = root.stereo ? width / 2 - 1 : width;
                const x1 = width / 2 + 1;

                // I due canali arrivano insieme o non arrivano: `right` pieno
                // e' l'unico segno che lo script gira con --stereo, e regge
                // anche l'istante fra il cambio di opzione e il primo
                // fotogramma nuovo, quando il pannello e' gia' diviso ma i dati
                // sono ancora quelli mescolati.
                const split = root.stereo && right.length > 1;

                // Silenzio: la linea di mezzo, e basta — una per striscia.
                // Disegnare cento punti tutti a zero darebbe lo stesso
                // risultato costando cento volte tanto, trenta volte al secondo.
                if (root.silent || left.length < 2) {
                    scope.flat(ctx, 0, w, scope.traceColor);

                    if (root.stereo)
                        scope.flat(ctx, x1, w, scope.traceRight);

                    return;
                }

                scope.trace(ctx, left, 0, w, scope.traceColor);

                if (split)
                    scope.trace(ctx, right, x1, w, scope.traceRight);
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
            ...(root.stereo ? ["--stereo"] : []),
            ...(root.device.length > 0 ? ["--device", root.device] : [])
        ]

        // Il pannello torna in vista dopo essere stato via: quello che si
        // vedeva era di prima, e non e' piu' vero.
        onRunningChanged: {
            if (!audio.running) {
                root.waveRight = [];
                root.wave = [];
                root.silent = true;
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
                    root.waveRight = [];
                    root.wave = [];
                    return;
                }

                root.problem = "";
                root.sink = d.sink ?? root.sink;

                if (d.silent) {
                    root.silent = true;
                    root.waveRight = [];
                    root.wave = [];
                    return;
                }

                root.silent = false;

                // Il destro prima del sinistro: il ridisegno lo innesca il
                // cambio di `wave`, e assegnarlo per ultimo fa arrivare al
                // Canvas due canali gia' della stessa finestra invece di
                // ridisegnare due volte, la prima con meta' fotogramma vecchio.
                root.waveRight = d.r ?? [];
                root.wave = d.l ?? d.w ?? [];
            }
        }
    }
}
