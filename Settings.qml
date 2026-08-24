pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Composizione della dashboard e parametri, persistiti in
// ~/.config/quickshell/dashboard.json (stesso schema di HomeAssistant.qml:
// FileView + JsonAdapter, col file creato coi default al primo avvio).
//
// Qui vive l'unico elenco di quali pannelli esistono: la dashboard lo usa per
// costruirsi, la finestra opzioni per farlo modificare. Aggiungere un pannello
// nuovo in futuro significa scrivere un file in panels/ e una riga nel catalogo.
Singleton {
    id: root

    // Vero da quando la configurazione e' disponibile (file letto, o default
    // scritti al primo avvio). La lettura del file di FileView e' asincrona, e
    // le finestre che si aprono all'avvio — la dashboard — si appoggiano a
    // questo per non nascere con la misura per difetto prima che il file arrivi:
    // in MemoryWindow lo `saved`/`userSized` sono `readonly`, e se la finestra
    // si mappasse a configurazione non ancora letta, fisserebbe per sempre la
    // dimensione di ripiego invece di quella salvata.
    property bool ready: false

    // `file` e' il nome del componente, tenuto distinto dall'id salvato su
    // disco: i file non possono chiamarsi come i singleton globali (un
    // HomeAssistant.qml oscurerebbe il singleton HomeAssistant).
    //
    // Il catalogo vero e' `catalog`, qui sotto: questo e' solo la parte di
    // casa, a cui si aggiungono i pannelli che l'utente ha messo in panels/.
    readonly property var builtinCatalog: [
        {
            id: "homeassistant",
            title: I18n.t("Home Assistant"),
            file: "HaPanel"
        },
        {
            id: "cpu",
            title: I18n.t("CPU"),
            file: "CpuPanel"
        },
        {
            id: "topcpu",
            title: I18n.t("Classifica CPU"),
            file: "TopCpuPanel"
        },
        {
            id: "ram",
            title: I18n.t("RAM"),
            file: "RamPanel"
        },
        {
            id: "topram",
            title: I18n.t("Classifica RAM"),
            file: "TopRamPanel"
        },
        {
            id: "gpu",
            title: I18n.t("GPU"),
            file: "GpuPanel"
        },
        {
            id: "topgpu",
            title: I18n.t("Classifica GPU"),
            file: "TopGpuPanel"
        },
        {
            id: "vram",
            title: I18n.t("VRAM"),
            file: "VramPanel"
        },
        {
            id: "topvram",
            title: I18n.t("Classifica VRAM"),
            file: "TopVramPanel"
        },
        {
            id: "power",
            title: I18n.t("Consumo"),
            file: "PowerPanel"
        },
        {
            id: "temps",
            title: I18n.t("Temperature"),
            file: "TempPanel"
        },
        {
            id: "pressure",
            title: I18n.t("Pressione"),
            file: "PressurePanel"
        },
        {
            id: "health",
            title: I18n.t("Stato sistema"),
            file: "HealthPanel"
        },
        {
            id: "disks",
            title: I18n.t("Dischi"),
            file: "DiskPanel"
        },
        {
            id: "net",
            title: I18n.t("Rete"),
            file: "NetPanel"
        },
        {
            id: "ai",
            title: I18n.t("Comando IA"),
            file: "AiPanel"
        },
        {
            id: "phones",
            title: I18n.t("Telefoni"),
            file: "PhonePanel"
        },
        {
            id: "heart",
            title: I18n.t("Battito"),
            file: "HeartPanel"
        },
        {
            id: "tools",
            title: I18n.t("Servizi e processi"),
            file: "ToolsPanel"
        }
    ]

    // I pannelli di casa piu' quelli aggiunti dall'utente. In coda e non
    // mescolati: l'elenco delle Opzioni segue quest'ordine, e i propri si
    // cercano in fondo, dove li si e' messi.
    readonly property var catalog: root.builtinCatalog.concat(UserPanels.usable)

    readonly property var left: cfg.left
    readonly property var right: cfg.right
    readonly property var haEntities: cfg.haEntities
    readonly property var haNoChart: cfg.haNoChart
    // solo di queste serve scaricare lo storico da Home Assistant
    readonly property var haChartEntities: cfg.haEntities.filter(id => !cfg.haNoChart.includes(id))
    readonly property int topCount: cfg.topCount
    readonly property int historyHours: cfg.historyHours
    readonly property int sampleInterval: cfg.sampleInterval
    readonly property int haPollInterval: cfg.haPollInterval
    readonly property int procInterval: cfg.procInterval
    readonly property string heartDevice: cfg.heartDevice
    readonly property int heartWindowHours: cfg.heartWindowHours
    readonly property string language: cfg.language
    readonly property var disks: cfg.disks
    readonly property var sensors: cfg.sensors
    readonly property var colors: cfg.colors
    readonly property var priorityRules: cfg.priorityRules
    // Nella forma che procmon.py si aspetta sulla riga di comando.
    readonly property string priorityArg: cfg.priorityRules.join(",")
    readonly property bool netHideLoopback: cfg.netHideLoopback
    readonly property bool netHideLan: cfg.netHideLan

    function setLanguage(code: string) {
        cfg.language = code;
        configFile.writeAdapter();
    }

    // Il telefono che ha il braccialetto al polso. Vuoto vuol dire "quello che
    // c'e'", e va bene finche' ne e' collegato uno solo: vedi heartDevice.
    function setHeartDevice(name: string) {
        cfg.heartDevice = name;
        configFile.writeAdapter();
    }

    // Vero se l'utente ha gia' scelto una misura per questa finestra: da quel
    // momento il contenuto non comanda piu'.
    // Elenco leggibile delle misure memorizzate, per la diagnosi da riga di
    // comando (vedi l'IPC winsize).
    function windowList(): string {
        return cfg.windows.length ? cfg.windows.join(", ") : "nessuna";
    }

    // "x,y" della finestra, o stringa vuota se non e' mai stata spostata.
    function windowPlace(key: string): string {
        for (const entry of cfg.places) {
            const parts = entry.split(":");
            if (parts[0] === key && parts.length === 3)
                return parts[1] + "," + parts[2];
        }
        return "";
    }

    function saveWindowPlace(key: string, x: int, y: int) {
        if (!key.length)
            return;
        const entry = `${key}:${Math.round(x)}:${Math.round(y)}`;
        if (cfg.places.includes(entry))
            return;
        cfg.places = cfg.places.filter(e => e.split(":")[0] !== key).concat([entry]);
        configFile.writeAdapter();
    }

    function hasWindowSize(key: string): bool {
        return cfg.windows.some(x => x.split(":")[0] === key);
    }

    // Dimensione salvata di una finestra, o quella di default se non c'e'.
    function windowSize(key: string, fallbackWidth: int, fallbackHeight: int): var {
        for (const entry of cfg.windows) {
            const parts = entry.split(":");
            if (parts[0] === key && parts.length === 3) {
                const w = parseInt(parts[1]);
                const h = parseInt(parts[2]);
                // una dimensione assurda (finestra ridotta a icona, schermo
                // scollegato) non deve restare incollata alla finestra
                if (w >= 320 && h >= 240)
                    return {
                        width: w,
                        height: h
                    };
            }
        }
        return {
            width: fallbackWidth,
            height: fallbackHeight
        };
    }

    function saveWindowSize(key: string, width: int, height: int) {
        // senza chiave la misura non si potrebbe piu' ritrovare, e resterebbe
        // nel file come una riga orfana
        if (!key.length || width < 320 || height < 240)
            return;
        const entry = `${key}:${Math.round(width)}:${Math.round(height)}`;
        const others = cfg.windows.filter(x => x.split(":")[0] !== key);
        // niente scrittura se la misura non e' cambiata: il ridimensionamento
        // ne genera a raffica, e il file non deve battere il disco per nulla
        if (others.length === cfg.windows.length - 1 && cfg.windows.includes(entry))
            return;
        cfg.windows = others.concat([entry]);
        configFile.writeAdapter();
    }

    function toggleDisk(mount: string) {
        cfg.disks = cfg.disks.includes(mount) ? cfg.disks.filter(x => x !== mount) : cfg.disks.concat([mount]);
        configFile.writeAdapter();
    }

    function toggleSensor(key: string) {
        cfg.sensors = cfg.sensors.includes(key) ? cfg.sensors.filter(x => x !== key) : cfg.sensors.concat([key]);
        configFile.writeAdapter();
    }

    // La prima scelta dei sensori, fatta una volta sola sulla macchina vera.
    //
    // I default nel JsonAdapter sono statici e non possono sapere quali chip
    // esistano qui: la lista arriva dal monitor, che marca come `primary` la
    // CPU e i dischi. Serve un flag a parte perche' senza non si distingue
    // "non ho mai scelto" da "li ho spenti tutti di proposito", e la seconda
    // volta che si apre la dashboard tornerebbero accesi.
    function initSensors(list: var) {
        if (cfg.sensorsInit)
            return;
        cfg.sensorsInit = true;
        cfg.sensors = list.filter(s => s.primary).map(s => s.key);
        configFile.writeAdapter();
    }

    // Priorita' ricordata di un programma, per nome. -1 = nessuna regola.
    function priorityFor(name: string): int {
        for (const entry of cfg.priorityRules) {
            const cut = entry.lastIndexOf(":");
            if (cut > 0 && entry.slice(0, cut) === name)
                return parseInt(entry.slice(cut + 1));
        }
        return -1;
    }

    // Da zero in su: normale, bassa, molto bassa. Zero e' una regola a tutti
    // gli effetti — dice "questo programma deve restare a priorita' normale" —
    // e serve a disdire una regola bassa senza doverla cancellare a mano.
    // I valori negativi no: alzare la priorita' vorrebbe i privilegi di
    // amministratore, e una regola che lo chiedesse resterebbe li' a fallire a
    // ogni giro senza che nessuno lo veda.
    function rememberPriority(name: string, nice: int) {
        if (!name.length || nice < 0)
            return;
        cfg.priorityRules = cfg.priorityRules.filter(e => e.slice(0, e.lastIndexOf(":")) !== name).concat([`${name}:${nice}`]);
        configFile.writeAdapter();
    }

    function forgetPriority(name: string) {
        if (root.priorityFor(name) < 0)
            return;
        cfg.priorityRules = cfg.priorityRules.filter(e => e.slice(0, e.lastIndexOf(":")) !== name);
        configFile.writeAdapter();
    }

    // Colore di una serie di grafico.
    //
    // Il default non sta qui ma nel pannello che disegna la serie, e arriva
    // come `fallback`: cosi' non c'e' una seconda copia della tavolozza da
    // tenere allineata, e togliere la scelta dell'utente fa tornare il colore
    // originale senza doverlo ricordare da nessuna parte.
    // Si taglia sull'ULTIMO due-punti, non sul primo: un colore "#rrggbb" non
    // ne contiene mai, un identificativo si — le entita' di Home Assistant
    // arrivano come "ha:sensor.qualcosa", e tagliando sul primo la chiave
    // diventerebbe "ha" e la scelta sparirebbe senza dire niente.
    function colorFor(id: string, fallback: string): string {
        for (const entry of cfg.colors) {
            const cut = entry.lastIndexOf(":");
            if (cut > 0 && entry.slice(0, cut) === id)
                return entry.slice(cut + 1);
        }
        return fallback;
    }

    function setColor(id: string, value: string) {
        if (!id.length || !/^#[0-9a-fA-F]{6}$/.test(value))
            return;
        cfg.colors = cfg.colors.filter(e => e.slice(0, e.lastIndexOf(":")) !== id).concat([`${id}:${value.toLowerCase()}`]);
        configFile.writeAdapter();
    }

    // Torna al default togliendo la voce, invece di riscriverci sopra il
    // colore originale: una voce uguale al default resterebbe nel file a
    // sporcare, e non si distinguerebbe piu' da una scelta deliberata.
    function resetColor(id: string) {
        if (!cfg.colors.some(e => e.slice(0, e.lastIndexOf(":")) === id))
            return;
        cfg.colors = cfg.colors.filter(e => e.slice(0, e.lastIndexOf(":")) !== id);
        configFile.writeAdapter();
    }

    function toggleNetFilter(which: string) {
        if (which === "loopback")
            cfg.netHideLoopback = !cfg.netHideLoopback;
        else
            cfg.netHideLan = !cfg.netHideLan;
        configFile.writeAdapter();
    }

    function entry(id: string): var {
        return root.catalog.find(p => p.id === id) ?? null;
    }

    function fileFor(id: string): string {
        const found = root.entry(id);
        return found ? found.file : "";
    }

    function titleFor(id: string): string {
        const found = root.entry(id);
        return found ? found.title : id;
    }

    // "left", "right", oppure "" se il pannello e' spento.
    function columnOf(id: string): string {
        if (cfg.left.includes(id))
            return "left";
        if (cfg.right.includes(id))
            return "right";
        return "";
    }

    function isVisible(id: string): bool {
        return root.columnOf(id) !== "";
    }

    // I pannelli spenti non compaiono in nessuna delle due liste: accenderne uno
    // vuol dire rimetterlo in fondo a una colonna.
    function toggle(id: string) {
        const column = root.columnOf(id);
        if (column === "")
            root.assign(id, cfg.left.length <= cfg.right.length ? "left" : "right");
        else
            root.assign(id, "");
    }

    function move(id: string, column: string) {
        if (root.columnOf(id) !== column)
            root.assign(id, column);
    }

    // Porta il pannello alla posizione `index` della sua colonna. La usa il
    // trascinamento nella finestra opzioni, che calcola l'indice di arrivo e lo
    // consegna una volta sola al rilascio: riscrivere il file a ogni pixel di
    // movimento sarebbe uno spreco e lascerebbe su disco stati intermedi.
    function moveTo(id: string, index: int) {
        const column = root.columnOf(id);
        if (column === "")
            return;
        const list = (column === "left" ? cfg.left : cfg.right).filter(x => x !== id);
        const target = Math.max(0, Math.min(list.length, index));
        list.splice(target, 0, id);
        root.store(column, list);
    }

    function moveEntityTo(entityId: string, index: int) {
        const list = cfg.haEntities.filter(x => x !== entityId);
        const target = Math.max(0, Math.min(list.length, index));
        list.splice(target, 0, entityId);
        cfg.haEntities = list;
        configFile.writeAdapter();
    }

    // Unico punto che tocca le due liste: toglie il pannello da dove sta e, se
    // `column` non e' vuota, lo aggiunge in fondo a quella richiesta.
    function assign(id: string, column: string) {
        const left = cfg.left.filter(x => x !== id);
        const right = cfg.right.filter(x => x !== id);
        if (column === "left")
            left.push(id);
        else if (column === "right")
            right.push(id);
        root.store("left", left);
        root.store("right", right);
    }

    function store(column: string, list: var) {
        if (column === "left")
            cfg.left = list;
        else
            cfg.right = list;
        configFile.writeAdapter();
    }

    function addEntity(entityId: string) {
        if (!entityId.length || cfg.haEntities.includes(entityId))
            return;
        cfg.haEntities = cfg.haEntities.concat([entityId]);
        // Di un sensore si vuole quasi sempre l'andamento; di una luce o di un
        // condizionatore il grafico sarebbe una riga piatta fra "on" e "off".
        // Si decide qui, alla prima aggiunta: dopo comanda l'utente.
        if (!isFinite(parseFloat(HomeAssistant.state(entityId))))
            cfg.haNoChart = cfg.haNoChart.concat([entityId]);
        configFile.writeAdapter();
    }

    function removeEntity(entityId: string) {
        cfg.haEntities = cfg.haEntities.filter(x => x !== entityId);
        cfg.haNoChart = cfg.haNoChart.filter(x => x !== entityId);
        configFile.writeAdapter();
    }

    // Il grafico dello storico si puo' spegnere per entita': vedi addEntity
    // per il valore di partenza.
    function chartEnabled(entityId: string): bool {
        return !cfg.haNoChart.includes(entityId);
    }

    function toggleChart(entityId: string) {
        cfg.haNoChart = root.chartEnabled(entityId) ? cfg.haNoChart.concat([entityId]) : cfg.haNoChart.filter(x => x !== entityId);
        configFile.writeAdapter();
    }

    // Intervallo ammesso di ogni parametro: un valore fuori scala (o non
    // numerico, se il file e' stato scritto a mano) verrebbe accettato in
    // silenzio e romperebbe la dashboard molto lontano da dove e' stato
    // introdotto.
    readonly property var limits: ({
            topCount: [1, 10],
            historyHours: [1, 48],
            sampleInterval: [500, 10000],
            haPollInterval: [1000, 300000],
            heartWindowHours: [1, 24],
            procInterval: [1000, 10000]
        })

    function setParam(name: string, value: real) {
        const range = root.limits[name];
        if (!range || !isFinite(value))
            return;
        cfg[name] = Math.round(Math.min(range[1], Math.max(range[0], value)));
        configFile.writeAdapter();
    }

    function limitsFor(name: string): var {
        return root.limits[name] ?? [0, 0];
    }

    FileView {
        id: configFile

        path: `${Quickshell.env("HOME")}/.config/quickshell/dashboard.json`
        watchChanges: true
        onFileChanged: reload()
        // Segnala che la configurazione e' pronta: e' da qui che le finestre
        // visibili all'avvio sanno di poter nascere con la misura giusta.
        onLoaded: root.ready = true
        // Al primo avvio il file non esiste: si scrive con i default, che sono
        // la dashboard cosi' com'era prima di diventare configurabile. Anche su
        // un errore di lettura si dichiara pronta, cosi' la dashboard compare
        // comunque (con i default) invece di restare nascosta.
        onLoadFailed: error => {
            if (error === FileViewError.FileNotFound)
                writeAdapter();
            root.ready = true;
        }

        JsonAdapter {
            id: cfg

            property var left: ["homeassistant", "cpu", "topcpu", "ram", "topram"]
            property var right: ["gpu", "topgpu", "vram", "topvram", "power", "net", "ai", "tools"]
            property var haEntities: ["sensor.ac_camera_mia_temperature", "sensor.co2_monitor_co2"]
            // entita' mostrate senza grafico, solo come riga di stato
            property var haNoChart: []
            property int topCount: 3
            property int historyHours: 16
            property int sampleInterval: 1000
            property int haPollInterval: 15000
            property int procInterval: 2000
            // quale telefono ha il braccialetto al polso. Vuoto va bene finche'
            // ne e' collegato uno solo: con due, `pick` si rifiuta di indovinare
            // e ha ragione, ma un pannello che chiede il battito a un telefono
            // che non ha mai visto un Fitbit sonderebbe per ore per niente.
            property string heartDevice: ""
            property int heartWindowHours: 2
            // lingua dell'interfaccia: vuoto = quella del sistema
            property string language: ""
            // filtri della finestra Rete, tenuti separati: nascondere il
            // dialogo della macchina con se stessa e nascondere quello con il
            // resto di casa sono due decisioni diverse
            // dischi da mostrare in dashboard, per nome di dispositivo
            property var disks: []
            // sensori di temperatura accesi, per chiave "disco-o-chip/etichetta"
            property var sensors: []
            // se la scelta iniziale dei sensori e' gia' stata fatta: vedi
            // initSensors, distingue "mai scelto" da "spenti di proposito"
            property bool sensorsInit: false
            // colori scelti per le serie dei grafici, come "serie:#rrggbb".
            // Ci finiscono solo quelli cambiati (vedi colorFor).
            property var colors: []
            // priorita' ricordate, come "nome:nice". Solo valori da zero in
            // su: vedi rememberPriority.
            property var priorityRules: []
            // dimensioni delle finestre, come "chiave:larghezza:altezza". Una
            // lista di stringhe e non una mappa annidata: JsonAdapter serializza
            // liste di stringhe senza sorprese, ed e' la forma gia' usata dal
            // resto del file.
            property var windows: []
            // posizioni delle finestre, come "chiave:x:y" (vedi MemoryWindow)
            property var places: []
            property bool netHideLoopback: false
            property bool netHideLan: false
        }
    }
}
