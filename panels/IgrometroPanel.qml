import QtQuick
import QtQuick.Layouts
// Quickshell per l'ambiente (la home, che serve a sciogliere la tilde), Io per
// i due processi: la lettura chiesta a mano e la calibrazione.
import Quickshell
import Quickshell.Io

// Il pannello sta in panels/: senza `import ".."` si caricherebbe lo stesso,
// ma SystemStats, Settings, I18n e i componenti della dashboard resterebbero
// indefiniti — vedi scripts/panels.py, che verifica la riga e lo dice.
import ".."

// L'igrometro di casa: uno strumento a molla, con la lancetta rossa e niente
// dentro da collegare. A leggerlo ci pensa la webcam
// (scripts/hygrometer.py, ogni dieci minuti per mano di systemd), e il numero
// arriva qui dopo essere passato da Home Assistant — la stessa strada del
// pannello solare, per la stessa ragione: lo storico lo tiene gia' il recorder
// di Home Assistant, e un secondo storico in casa sarebbe solo un secondo
// storico da tenere.
//
// Il colore della barra non e' decorazione: sotto il 30% l'aria e' secca,
// sopra il 65 comincia a essere troppo umida, e la fascia buona sta in mezzo.
// E' l'unica cosa che si fa guardando un igrometro — capire se si sta bene —
// quindi la dice il colore prima del numero.
ColumnLayout {
    id: root

    // L'id ferma il pannello nella configurazione salvata (le colonne di
    // dashboard.json lo citano) e lo distingue nel catalogo; il titolo e'
    // quello che la finestra Opzioni mostra.
    property string panelId: "igrometro"
    property string panelTitle: "Igrometro"

    // Configurazione (sezione "panelParams" di dashboard.json): l'entita'
    // pubblicata da scripts/hygrometer.py, la cartella del programma che sa
    // guardare il quadrante, e il terminale in cui aprire la calibrazione —
    // che di terminali ognuno ha il suo.
    readonly property var defs: ({
            entity: "sensor.igrometro_umidita",
            toolDir: "~/Documents/Development/Python/Igrometer",
            terminal: "ptyxis",
            chart: true
        })
    readonly property string entity: Settings.panelParam("igrometro", "entity", defs.entity)
    readonly property bool chart: Settings.panelParam("igrometro", "chart", defs.chart)
    readonly property string toolDir: Settings.panelParam("igrometro", "toolDir", defs.toolDir)
    readonly property string terminal: Settings.panelParam("igrometro", "terminal", defs.terminal)

    // Quale entita' si sta seguendo davvero. Serve per lasciarla andare: QML
    // non dice qual era il valore di prima quando una proprieta' cambia, e
    // senza questo appunto un'entita' cambiata a mano nel file resterebbe a
    // farsi scaricare lo storico per sempre.
    property string watched: ""

    function follow(): void {
        // Col grafico spento non si segue niente: "senza grafico" deve voler
        // dire anche senza la sua serie scaricata a ogni bucket.
        const wanted = root.chart ? root.entity : "";

        if (root.watched === wanted)
            return;

        if (root.watched.length)
            HomeAssistant.unwatchHistory(root.watched);

        root.watched = wanted;

        if (wanted.length)
            HomeAssistant.watchHistory(wanted);
    }

    Component.onCompleted: {
        Settings.declarePanelParams("igrometro", defs);
        // Lo storico di questa entita' non passa dall'elenco delle opzioni:
        // se lo chiede il pannello, e lo lascia andare quando sparisce.
        root.follow();
    }

    Component.onDestruction: {
        if (root.watched.length)
            HomeAssistant.unwatchHistory(root.watched);
    }

    onEntityChanged: root.follow()
    onChartChanged: root.follow()

    readonly property string home: Quickshell.env("HOME")
    // La tilde la scioglie la shell, e qui di shell non ce n'e': i comandi
    // partono da Quickshell direttamente, quindi il percorso va steso a mano.
    readonly property string dir: root.toolDir.startsWith("~") ? root.home + root.toolDir.slice(1) : root.toolDir
    // L'unico interprete con OpenCV dentro e' quello del venv dello strumento.
    readonly property string python: root.dir + "/.venv/bin/python"

    // --- il numero ----------------------------------------------------------
    // parseFloat su "unavailable" / "" da' NaN: e' il modo piu' corto di dire
    // che adesso una lettura non c'e', e il pannello lo mostra invece di
    // disegnare una barra inventata.
    readonly property var reading: HomeAssistant.states[root.entity]
    readonly property real humidity: parseFloat(HomeAssistant.state(root.entity))
    readonly property bool hasData: isFinite(root.humidity)

    // Quando e' stata presa: e' meta' della notizia. Un 53% di stamattina e un
    // 53% di adesso si somigliano solo a guardarli.
    readonly property string when: {
        if (!root.reading || !root.reading.last_updated)
            return "";

        const t = new Date(root.reading.last_updated);
        return isNaN(t.getTime()) ? "" : Qt.formatTime(t, "HH:mm");
    }

    // Quanto le tre letture di una misura si sono discostate fra loro: la
    // lancetta vista male salta, quella vista bene no. Sopra il punto e mezzo
    // vale la pena dirlo invece di lasciar credere a un decimo che non c'e'.
    readonly property real spread: {
        const s = HomeAssistant.attribute(root.entity, "dispersione");
        return s === undefined ? 0 : parseFloat(s);
    }

    // La taratura vecchia non ha il raggio del quadrante e il programma se lo
    // stima dalla ROI: funziona, ma e' una stima, e chi guarda deve poterlo
    // sapere — e' il motivo per cui il pulsante Calibra sta qui e non nascosto
    // in un terminale.
    readonly property bool roughCalibration: HomeAssistant.attribute(root.entity, "calibrazione") === "raggio stimato"

    readonly property string tone: {
        if (!root.hasData)
            return "#484f58";

        if (root.humidity < 30 || root.humidity > 70)
            return "#f85149";

        if (root.humidity < 40 || root.humidity > 60)
            return "#e3b341";

        return "#3fb950";
    }

    // --- la lettura chiesta a mano -----------------------------------------
    property bool busy: false
    property string outcome: ""
    property string outcomeColor: "#8b949e"

    function readNow(): void {
        if (root.busy)
            return;

        root.busy = true;
        root.outcome = I18n.t("lettura…");
        root.outcomeColor = "#d29922";
        meter.command = [root.python, PluginPaths.of("scripts/hygrometer.py")];
        meter.running = true;
        guard.restart();
    }

    // La calibrazione e' un lavoro a quattro mani con chi guarda: si trascina
    // il rettangolo del quadrante, si clicca il perno, poi i due estremi della
    // scala. Le finestre le apre OpenCV, ma i passi sono scritti sulla
    // console, e per questo va in un terminale invece che a schermo nudo.
    // Dentro la sua cartella, perche' li' salva la taratura.
    function calibrate(): void {
        wizard.command = [root.terminal, "--new-window", "-d", root.dir, "--",
            root.python, "main.py", "--recalibrate", "--no-log"];
        wizard.running = true;
        root.outcome = I18n.t("calibrazione aperta nel terminale");
        root.outcomeColor = "#58a6ff";
        forget.restart();
    }

    Process {
        id: meter

        stdout: StdioCollector {
            onStreamFinished: {
                guard.stop();
                root.busy = false;
                forget.restart();

                let data;

                try {
                    data = JSON.parse(this.text);
                } catch (e) {
                    data = null;
                }

                if (!data) {
                    root.outcome = I18n.t("nessuna risposta");
                    root.outcomeColor = "#f85149";
                    return;
                }

                if (data.ok) {
                    root.outcome = I18n.t("letto adesso");
                    root.outcomeColor = "#3fb950";
                    // Il numero qui accanto e' ancora quello di prima: lo porta
                    // Home Assistant, e il suo giro puo' essere lontano.
                    HomeAssistant.refresh();
                    return;
                }

                // Webcam occupata, lancetta fuori inquadratura, taratura da
                // rifare: lo script lo dice con parole sue, che sono piu'
                // precise di qualunque riassunto si possa fare qui.
                root.outcome = data.error || I18n.t("non riuscito");
                root.outcomeColor = "#d29922";
            }
        }
    }

    Process {
        id: wizard
    }

    // Se la lettura non torna, l'icona smette di girare lo stesso. E' lo
    // stesso conto che tiene systemd (TimeoutStartSec=60).
    Timer {
        id: guard

        interval: 60000

        onTriggered: {
            meter.running = false;
            root.busy = false;
            root.outcome = I18n.t("nessuna risposta");
            root.outcomeColor = "#f85149";
            forget.restart();
        }
    }

    // L'esito e' un lampo: un «letto adesso» di dieci minuti fa sembrerebbe
    // di adesso.
    Timer {
        id: forget

        interval: 8000
        onTriggered: root.outcome = ""
    }

    spacing: 8

    RowLayout {
        Layout.fillWidth: true
        spacing: 6

        Text {
            color: "#c9d1d9"
            font.pixelSize: 12
            text: "IGROMETRO"
        }

        Text {
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignRight
            visible: root.outcome !== "" || !HomeAssistant.online
            elide: Text.ElideRight
            color: root.outcome !== "" ? root.outcomeColor : "#f85149"
            font.pixelSize: 10
            text: root.outcome !== "" ? root.outcome : I18n.t("irraggiungibile")
        }

        // Leggi adesso, senza aspettare il giro dei dieci minuti: la freccia
        // circolare, che in questa dashboard vuol gia' dire «rileggi». Gira
        // mentre la webcam guarda, che e' l'unico modo onesto di dire che i
        // sei secondi di attesa sono previsti.
        Text {
            id: again

            color: root.busy ? "#d29922" : againHover.hovered ? "#58a6ff" : "#484f58"
            font.pixelSize: 12
            text: "⟳"

            RotationAnimator on rotation {
                running: root.busy
                from: 0
                to: 360
                duration: 1400
                loops: Animation.Infinite

                // Ferma resta storta di quanto era arrivata a girare: una
                // freccia inclinata di 47 gradi sembra un difetto di disegno.
                onRunningChanged: {
                    if (!this.running)
                        again.rotation = 0;
                }
            }

            HoverHandler {
                id: againHover

                cursorShape: root.busy ? Qt.ArrowCursor : Qt.PointingHandCursor
            }

            TapHandler {
                onSingleTapped: root.readNow()
            }

            Tooltip {
                hovered: againHover.hovered
                text: root.busy ? I18n.t("lettura in corso…") : I18n.t("Leggi adesso l'igrometro")
            }
        }

        // Calibra: il mirino, che e' quello che si va a fare — rimettere il
        // programma d'accordo con quello che la webcam inquadra. Si accende da
        // solo quando la taratura e' incompleta, cosi' la cosa da fare si vede
        // senza doverla cercare.
        Text {
            id: aim

            color: root.roughCalibration ? "#e3b341" : aimHover.hovered ? "#58a6ff" : "#484f58"
            font.pixelSize: 12
            text: "⌖"

            HoverHandler {
                id: aimHover

                cursorShape: Qt.PointingHandCursor
            }

            TapHandler {
                onSingleTapped: root.calibrate()
            }

            Tooltip {
                hovered: aimHover.hovered
                text: root.roughCalibration ? I18n.t("Taratura incompleta: calibra di nuovo")
                    : I18n.t("Calibra: apre la procedura in un terminale")
            }
        }
    }

    // Il numero grande, con la barra sotto: si legge da lontano, che e' come
    // si guarda un igrometro appeso al muro.
    RowLayout {
        Layout.fillWidth: true
        spacing: 10

        Text {
            color: root.tone
            font.pixelSize: 26
            font.letterSpacing: -1
            text: root.hasData ? root.humidity.toFixed(1) : "—"
        }

        Text {
            Layout.alignment: Qt.AlignBottom
            Layout.bottomMargin: 4
            color: "#8b949e"
            font.pixelSize: 12
            text: root.hasData ? "%RH" : ""
        }

        Item {
            Layout.fillWidth: true
        }

        // Ora della lettura e, se le tre misure non erano d'accordo, di quanto:
        // il secondo numero compare solo quando ha qualcosa da dire.
        Text {
            Layout.alignment: Qt.AlignBottom
            Layout.bottomMargin: 4
            horizontalAlignment: Text.AlignRight
            color: "#484f58"
            font.pixelSize: 10
            text: {
                if (!root.hasData || root.when === "")
                    return "";

                if (root.spread > 1.5)
                    return I18n.t("%1 · ballano %2 punti").arg(root.when).arg(root.spread.toFixed(1));

                return root.when;
            }
        }
    }

    // L'andamento: di un'umidita' interessa piu' la direzione che il numero —
    // se sale da quando si e' chiusa la finestra, se scende quando parte il
    // condizionatore. Le letture sono ogni dieci minuti e i bucket dello
    // storico da cinque, ma resample riporta avanti l'ultimo valore noto,
    // quindi la linea esce a gradini invece che tratteggiata.
    HistoryChart {
        Layout.fillWidth: true
        visible: root.chart
        values: HomeAssistant.history[root.entity] ?? []
        // Il tasto destro cancella la lettura sbagliata: e' il grafico dove
        // serve di piu', perche' la lancetta letta male da una foto sfocata
        // scrive un 90% che poi resta li' per sedici ore.
        haEntity: root.entity
        samples: HomeAssistant.historyRaw[root.entity] ?? []
        hours: HomeAssistant.historyHours
        decimals: 1
        lineColor: Settings.colorFor(`ha:${root.entity}`, root.tone)
        // Sotto i cinque punti percentuali il grafico ingrandirebbe il
        // tremolio della lancetta fino a farlo sembrare un temporale.
        minSpan: 5
        series: [
            {
                id: `ha:${root.entity}`,
                label: I18n.t("Igrometro"),
                fallback: root.tone
            }
        ]
    }

    StatBar {
        label: I18n.t("Aria")
        labelWidth: 34
        percent: root.hasData ? root.humidity : 0
        barColor: root.tone
        detail: root.hasData ? (root.humidity < 40 ? I18n.t("secca") : root.humidity > 60 ? I18n.t("umida") : I18n.t("giusta")) : I18n.t("nessuna lettura")
    }
}
