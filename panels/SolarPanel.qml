import QtQuick
import QtQuick.Layouts
// Process, per la lettura chiesta a mano: il timer di systemd fa la sua ogni
// dieci minuti, ma chi guarda adesso non ha voglia di aspettarne nove.
import Quickshell.Io

// Il pannello sta in panels/: senza `import ".."` si caricherebbe lo stesso,
// ma SystemStats, Settings, I18n e i componenti della dashboard resterebbero
// indefiniti — vedi scripts/panels.py, che verifica la riga e lo dice.
import ".."

// La carica solare del power bank, letta dal tester USB (scripts/solar_meter.py
// la pubblica su Home Assistant): disegnata per quello che e', una batteria
// che il sole riempie. Il colore cresce da sinistra come su ogni indicatore di
// carica e passa dal rosso all'oro al verde man mano che si riempie: l'occhio
// legge la notizia prima ancora di leggere i numeri.
//
// Al centro della batteria c'e' anche la cosa che si puo' fare per farla
// salire piu' in fretta: dove puntare il pannello adesso, e a che ora verra'
// il momento di girarlo. Il conto e' esatto, non una regoletta del pollice —
// vedere SolarMath.js per il perche'.
import "SolarMath.js" as SunMath
ColumnLayout {
    id: root

    // L'id ferma il pannello nella configurazione salvata (le colonne
    // di dashboard.json lo citano) e lo distingue nel catalogo; il titolo
    // e' quello che la finestra Opzioni mostra. Dichiarati qui, il
    // catalogo e' tutto scoperto da panels/ e Settings non tiene elenchi.
    property string panelId: "solar"
    property string panelTitle: "Solare"

    // I valori che prima erano scritti nel codice e adesso stanno nel file
    // di configurazione (sezione "panelParams" di dashboard.json): qui
    // resta solo il default, che il pannello registra al primo avvio.
    // Le entita' sono quelle pubblicate da scripts/solar_meter.py; la
    // capacita' e' quella del power bank collegato al tester.
    readonly property var defs: ({
            capacityMah: 10000,
            chargeEntity: "sensor.solare_usb_carica",
            powerEntity: "sensor.solare_usb_potenza"
        })
    // Capacita' della batteria in mAh: il pieno della barra.
    readonly property int capacityMah: Settings.panelParam("solar", "capacityMah", defs.capacityMah)
    // L'entita' che porta i mAh raccolti oggi e quella che porta i watt di adesso.
    readonly property string chargeEntity: Settings.panelParam("solar", "chargeEntity", defs.chargeEntity)
    readonly property string powerEntity: Settings.panelParam("solar", "powerEntity", defs.powerEntity)

    Component.onCompleted: Settings.declarePanelParams("solar", defs)

    // --- i numeri -----------------------------------------------------------
    // parseFloat su "unavailable" / "" dà NaN: e' il modo piu' corto di dire
    // che adesso non c'e' nessuna lettura, e il pannello la mostra come tale
    // invece di disegnare una batteria inventata.
    readonly property real chargeMah: parseFloat(HomeAssistant.state(root.chargeEntity))
    readonly property bool hasData: isFinite(root.chargeMah)
    readonly property real powerW: parseFloat(HomeAssistant.state(root.powerEntity))

    // Sta caricando finché dal tester passa potenza: sotto il sole di mezzogiorno
    // o sotto una nuvola cambia a ogni lettura, ed e' esattamente cio' che vuole
    // raccontare il lampeggio.
    readonly property bool charging: isFinite(root.powerW) && root.powerW > 0

    // Frazione di riempimento 0..1. La batteria si considera piena un soffio
    // prima del numero esatto (99,95%): l'OCR arrotonda a due decimali e far
    // restare ambra l'ultimo decimo di punto percentuale sarebbe un difetto
    // visibile tutto il tempo per risparmiarne uno che non esiste.
    readonly property real fraction: root.hasData ? Math.max(0, Math.min(1, root.chargeMah / root.capacityMah)) : 0
    readonly property bool full: root.hasData && root.chargeMah >= root.capacityMah * 0.9995
    readonly property int percent: Math.round(root.fraction * 100)

    // I colori del riempimento: la scala di ogni indicatore di carica — rosso
    // finche' ce n'e' poca, oro a meta' strada, verde quando ce n'e'
    // abbastanza. Le soglie sono un quarto e tre quarti; il 25 esatto e' gia'
    // oro e il 75 esatto e' gia' verde, perche' una soglia raggiunta e' una
    // soglia superata.
    //
    // Sul valore arrotondato e non sulla frazione: e' quello scritto qui
    // accanto a caratteri cubitali, e un «25%» dipinto di rosso perche' sotto
    // c'e' un 24,6 sembrerebbe un difetto invece di una precisione.
    //
    // Il verde non e' piu' solo della batteria piena, che resta comunque
    // riconoscibile: il bordo e il contatto si accendono (BatteryGauge, `full`)
    // e il respiro del riempimento si ferma.
    readonly property string fillColor: {
        if (root.percent < 25)
            return "#f85149";

        if (root.percent < 75)
            return "#e3b341";

        return "#3fb950";
    }

    // Le migliaia e i decimali si scrivono come vuole la lingua scelta:
    // 10.000 e 18,4 in italiano, 10,000 e 18.4 altrove. toLocaleString li fa
    // gratis, basta dargli la locale giusta.
    readonly property var locales: ({
            it: "it_IT", en: "en_US", fr: "fr_FR", de: "de_DE", es: "es_ES", ja: "ja_JP"
        })
    readonly property string localeName: root.locales[I18n.lang] ?? "it_IT"

    function group(n: int): string {
        return n.toLocaleString(Qt.locale(root.localeName), 'f', 0);
    }

    function decimal(n: real): string {
        return n.toLocaleString(Qt.locale(root.localeName), 'f', 1);
    }

    // --- dove puntare il pannello -------------------------------------------
    //
    // Il pannellino si sposta durante la giornata e tre sono le posizioni che
    // ha: est la mattina, sud a mezzogiorno, ovest nel pomeriggio. Quella
    // giusta non si stima a occhio: a parita' d'inclinazione il rendimento del
    // pannello dipende solo da quanto l'azimut del sole si avvicina a quello
    // della faccia rivolta al cielo, quindi ogni momento va scelta la
    // direzione piu' vicina — est 90°, sud 180°, ovest 270°. I momenti in cui
    // conviene girarlo cadono dunque dove l'azimut del sole attraversa i 135°
    // e i 225°: prima quel punto le due posizioni rendono uguale per
    // costruzione, dopo l'altra rende di piu'. E' geometria, non abitudine —
    // i calcoli e le eccezioni stanno in SolarMath.js.
    readonly property real sunAzimuth: parseFloat(HomeAssistant.attribute("sun.sun", "azimuth"))
    readonly property real sunElevation: parseFloat(HomeAssistant.attribute("sun.sun", "elevation"))

    // Di notte nessuna posizione batte le altre: la scritta tace invece di
    // consigliare un orientamento senza senso.
    readonly property bool dayTime: HomeAssistant.online && isFinite(root.sunAzimuth)
        && isFinite(root.sunElevation) && root.sunElevation > 0

    readonly property string orientation: root.dayTime ? SunMath.orientationFor(root.sunAzimuth) : ""
    readonly property string orientationLabel: ({
            est: "Est",
            sud: "Sud",
            ovest: "Ovest"
        })[root.orientation] ?? ""

    // Gli orari dei cambi di oggi ({ toSouth, toWest } in millisecondi Unix):
    // li calcola SolarMath.js dalle coordinate di casa, le stesse con cui
    // l'integrazione Sun alimenta sun.sun (HomeAssistant.latitude). La
    // scansione della giornata costa poco e vale fino a mezzanotte: si rifà
    // quando cambia il giorno o arrivano le coordinate, non a ogni battito.
    property var schedule: null
    property string builtKey: ""

    function refreshSchedule() {
        const lat = HomeAssistant.latitude;
        const lon = HomeAssistant.longitude;
        if (!isFinite(lat) || !isFinite(lon)) {
            root.builtKey = "";
            root.schedule = null;
            return;
        }

        const midnight = new Date();
        midnight.setHours(0, 0, 0, 0);
        const key = Qt.formatDate(midnight, "yyyy-MM-dd") + "|" + lat + "|" + lon;
        if (root.builtKey === key)
            return;

        root.builtKey = key;
        root.schedule = SunMath.daySchedule(midnight.getTime(), lat, lon);
    }

    Timer {
        interval: 15000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: root.refreshSchedule()
    }

    function hhmm(ms) {
        return Qt.formatTime(new Date(ms), "HH:mm");
    }

    // La riga che dice quando tornare a muovere il pannello: «Est → Sud alle
    // 10:12 · Sud → Ovest alle 13:15». Dove un passaggio non c'e' — l'inverno
    // delle alte latitudini comincia gia' di sud — resta solo l'altro; vuota
    // col sole sotto l'orizzonte o senza coordinate.
    readonly property string switchLine: {
        if (!root.schedule || !root.dayTime)
            return "";

        const parts = [];
        if (root.schedule.toSouth !== null && root.schedule.toSouth !== undefined)
            parts.push(I18n.t("Est → Sud alle %1").arg(root.hhmm(root.schedule.toSouth)));
        if (root.schedule.toWest !== null && root.schedule.toWest !== undefined)
            parts.push(I18n.t("Sud → Ovest alle %1").arg(root.hhmm(root.schedule.toWest)));
        return parts.join(" · ");
    }

    spacing: 8

    // --- la lettura chiesta a mano -----------------------------------------
    //
    // Gli stessi tre secondi del timer: scatto macro al display del tester,
    // OCR, e i valori in Home Assistant. Qui in piu' c'e' solo chi aspetta,
    // ed e' per questo che l'icona gira e la riga dice com'e' andata invece
    // di lasciare la batteria ferma senza spiegazioni.
    property bool reading: false
    property string outcome: ""
    property string outcomeColor: "#8b949e"

    // `force` salta il controllo dell'altezza del sole. Non e' il gesto
    // normale: di notte non c'e' niente da misurare e lo scatto e' solo usura
    // del telefono, ma chi ha una lampada puntata sul pannello o sta provando
    // l'inquadratura vuole la fotografia lo stesso.
    function readNow(force: bool): void {
        if (root.reading)
            return;

        root.reading = true;
        root.outcome = I18n.t("lettura…");
        root.outcomeColor = "#d29922";
        meter.command = ["python3", PluginPaths.of("scripts/solar_meter.py"),
            ...(force ? ["--force"] : [])];
        meter.running = true;
        // Il telefono puo' dormire e metterci a svegliarsi: e' lo stesso
        // conto che tiene systemd (TimeoutStartSec=180), e serve a non
        // lasciare l'icona a girare per sempre se lo scatto si pianta.
        guard.restart();
    }

    Process {
        id: meter

        stdout: StdioCollector {
            onStreamFinished: {
                guard.stop();
                root.reading = false;
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

                // «Non ho scattato» viene prima di «e' andata bene»: lo script
                // considera riuscito anche il giro in cui il sole era troppo
                // basso per valere una fotografia, e dirlo «letto» sarebbe la
                // sola cosa che chi guarda non deve credere.
                if (data.skipped) {
                    root.outcome = data.skipped;
                    root.outcomeColor = "#d29922";
                    return;
                }

                if (data.scartata) {
                    // Una lettura scartata e' il sistema che funziona: ha
                    // guardato il display e non si e' fidato di quello che ha
                    // letto. Il perche' sta nel log del servizio, non qui: in
                    // una riga alta dieci pixel non ci sta un'analisi.
                    root.outcome = I18n.t("lettura scartata");
                    root.outcomeColor = "#d29922";
                    return;
                }

                if (data.ok) {
                    root.outcome = I18n.t("letto adesso");
                    root.outcomeColor = "#3fb950";
                    // I numeri qui accanto sono ancora quelli di prima: li
                    // porta Home Assistant, e il suo giro di lettura puo'
                    // essere lontano un minuto.
                    HomeAssistant.refresh();
                    return;
                }

                root.outcome = data.error || I18n.t("non riuscito");
                root.outcomeColor = "#f85149";
            }
        }
    }

    // Se lo scatto non torna, l'icona smette di girare lo stesso.
    Timer {
        id: guard

        interval: 180000

        onTriggered: {
            meter.running = false;
            root.reading = false;
            root.outcome = I18n.t("nessuna risposta");
            root.outcomeColor = "#f85149";
            forget.restart();
        }
    }

    // L'esito e' un lampo, come nel pannello dei telefoni: un «letto adesso»
    // di dieci minuti fa sembrerebbe di adesso.
    Timer {
        id: forget

        interval: 8000
        onTriggered: root.outcome = ""
    }

    RowLayout {
        Layout.fillWidth: true
        spacing: 6

        Text {
            color: "#c9d1d9"
            font.pixelSize: 12
            text: "SOLARE"
        }

        // Al posto del solito dettaglio a destra c'e' lo stato della lettura:
        // se Home Assistant non risponde dirlo qui costa una parola e spiega
        // perche' la batteria qui sotto non si muove.
        //
        // L'esito di una lettura appena chiesta ha la precedenza: e' la
        // risposta a un clic dato un secondo fa, e dura otto secondi. Con Home
        // Assistant irraggiungibile lo scatto fallisce comunque, e il perche'
        // lo dice l'esito con parole piu' precise di «irraggiungibile».
        Text {
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignRight
            visible: root.outcome !== "" || !HomeAssistant.online
            elide: Text.ElideRight
            color: root.outcome !== "" ? root.outcomeColor : "#f85149"
            font.pixelSize: 10
            text: root.outcome !== "" ? root.outcome : I18n.t("irraggiungibile")
        }

        // Leggi adesso: la fotografia al display del tester, senza aspettare
        // il giro dei dieci minuti. Serve quando si e' appena spostato il
        // pannello al sole e si vuole vedere se e' cambiato qualcosa, o dopo
        // aver riquadrato l'inquadratura col mirino.
        //
        // La freccia circolare, che in questa dashboard vuol gia' dire
        // «rileggi»: gira mentre lo scatto e' in corso, che e' l'unico modo
        // onesto di dire che i dieci secondi di attesa sono previsti.
        Text {
            id: again

            color: {
                if (root.reading)
                    return "#d29922";
                return againHover.hovered ? "#58a6ff" : "#484f58";
            }
            font.pixelSize: 12
            text: "⟳"

            RotationAnimator on rotation {
                running: root.reading
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

                cursorShape: root.reading ? Qt.ArrowCursor : Qt.PointingHandCursor
            }

            // Col destro si scatta anche col sole sotto l'orizzonte. Un gesto
            // nascosto per una cosa che quasi sempre e' sbagliata — di notte
            // non c'e' niente da leggere — ma che serve a chi sta provando
            // l'inquadratura al chiuso, e che altrimenti si potrebbe fare solo
            // dal terminale.
            TapHandler {
                acceptedButtons: Qt.LeftButton | Qt.RightButton

                onSingleTapped: (eventPoint, button) => {
                    root.readNow(button === Qt.RightButton);
                }
            }

            Tooltip {
                hovered: againHover.hovered
                text: root.reading ? I18n.t("lettura in corso…")
                    : I18n.t("Leggi adesso il tester (destro: anche col sole basso)")
            }
        }
    }

    RowLayout {
        Layout.fillWidth: true
        spacing: 14

        // --- la batteria ----------------------------------------------------
        // Orizzontale, col contatto a destra: occupa una riga bassa e lascia
        // i numeri alla sua destra invece di sotto. Al centro dello spazio
        // vuoto c'e' la scritta che dice dove puntare il pannello adesso: e'
        // l'informazione su cui si agisce, quindi sta sul disegno stesso —
        // chi passa vede cosa fare senza leggere una riga in piu'.
        Item {
            Layout.preferredWidth: 134
            Layout.preferredHeight: 58

            BatteryGauge {
                anchors.fill: parent
                fraction: root.fraction
                fillColor: root.fillColor
                full: root.full
                pulsing: root.charging && !root.full && root.hasData
            }

            Column {
                anchors.centerIn: parent
                visible: root.orientationLabel !== ""

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    color: "#c9d1d9"
                    font.pixelSize: 7
                    font.letterSpacing: 1.4
                    font.capitalization: Font.AllUppercase
                    text: I18n.t("posiziona a")
                }

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    // Contorno scuro: dentro la batteria lo sfondo cambia col
                    // riempimento (rosso, oro, verde) e una scritta piatta non
                    // sarebbe leggibile su tutti.
                    color: "#f0f6fc"
                    style: Text.Outline
                    styleColor: "#161b22"
                    font.pixelSize: 14
                    font.bold: true
                    font.letterSpacing: 1
                    font.capitalization: Font.AllUppercase
                    text: I18n.t(root.orientationLabel)
                }
            }

            HoverHandler {
                id: gaugeHover
            }

            Tooltip {
                hovered: gaugeHover.hovered
                text: I18n.t("Il cambio avviene quando l'azimut del sole attraversa i 135° (est → sud) e poi i 225° (sud → ovest)")
            }
        }

        // --- i numeri accanto -------------------------------------------------
        // Tutti agganciati al bordo destro: la batteria e' il punto fermo a
        // sinistra, e chi confronta piu' batterie legge le cifre sempre nello
        // stesso posto invece di inseguirle.
        ColumnLayout {
            Layout.fillWidth: true
            spacing: 4

            Text {
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignRight
                visible: root.hasData
                color: root.fillColor
                font.pixelSize: 26
                font.bold: true
                text: `${root.percent}%`
            }

            Text {
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignRight
                visible: !root.hasData
                color: "#6e7681"
                font.pixelSize: 26
                font.bold: true
                text: I18n.t("n/d")
            }

            Text {
                elide: Text.ElideRight
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignRight
                color: "#8b949e"
                font.pixelSize: 11
                text: root.hasData ? `${root.group(Math.round(root.chargeMah))} / ${root.group(root.capacityMah)} mAh` : `— / ${root.group(root.capacityMah)} mAh`
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 4

                // Spintore: spinge fulmine, watt e "piena" contro il bordo
                // destro, dove stanno ormai tutte le altre scritte.
                Item {
                    Layout.fillWidth: true
                }

                Text {
                    visible: root.charging && !root.full
                    color: "#e3b341"
                    font.pixelSize: 11
                    // Il fulmine e' nello stesso blocco di simboli dell'ingranaggio
                    // della dashboard (Dashboard.qml): se quello si vede, anche questo.
                    text: "⚡"
                }

                Text {
                    visible: root.charging && !root.full
                    color: "#8b949e"
                    font.pixelSize: 11
                    text: `${root.decimal(root.powerW)} W`
                }

                Text {
                    visible: root.full
                    color: "#3fb950"
                    font.pixelSize: 11
                    text: I18n.t("piena")
                }
            }
        }
    }

    // Quando tornare a muovere il pannello. Allineata alle cifre come tutto
    // il resto: e' un orario, e gli orari di questa colonna si leggono sempre
    // nello stesso posto.
    Text {
        Layout.fillWidth: true
        horizontalAlignment: Text.AlignRight
        visible: root.switchLine !== ""
        elide: Text.ElideRight
        color: "#8b949e"
        font.pixelSize: 10
        text: root.switchLine
    }
}
