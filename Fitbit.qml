pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Battito e numeri del braccialetto, letti da Health Connect sul telefono.
//
// La catena e' lunga: il Fitbit manda il battito all'app Fitbit su una
// connessione Bluetooth sempre aperta, l'app lo travasa in Health Connect a
// blocchi, e HealthBridge — l'app ponte, in ~/Documents/Development/Android —
// lo rilegge da li' quando `scripts/phone_adb.py heart` glielo chiede.
//
// Il travaso e' il punto lento: fra il polso e questo grafico passano venti o
// trenta minuti, e non e' un difetto che si possa correggere da qui. Per
// questo il pannello dice sempre quanto e' vecchio il dato — un battito di
// mezz'ora fa presentato come "adesso" sarebbe una bugia, e l'unica differenza
// fra le due cose e' quell'etichetta.
//
// Sta fuori da PhoneAdb apposta: quella chiude la sessione trecento
// millisecondi dopo che si chiude la finestra del telefono, e uno storico che
// sparisce chiudendo una finestra non e' uno storico.
Singleton {
    id: root

    // Un minuto, per vedere con che grana Health Connect consegna davvero.
    //
    // Il ragionamento di prima diceva cinque minuti, e non era sbagliato:
    // sondare piu' spesso di quanto i dati cambino vuol dire tante letture per
    // lo stesso identico grafico, cinque secondi di telefono ciascuna. Ma
    // quanto spesso cambino e' esattamente cio' che non si sa: il travaso
    // dell'app Fitbit arriva a blocchi ogni quindici o trenta minuti, e non e'
    // detto che dentro un blocco i campioni non siano fitti. A un minuto lo si
    // vede; a cinque non lo si vedrebbe mai.
    //
    // Il polling e' idempotente e i punti sono indicizzati per istante, quindi
    // chiedere piu' spesso non duplica niente: nel peggiore dei casi si
    // rilegge lo stesso blocco. Se il grafico non guadagna dettaglio, questo
    // numero torna a 300000 senza altre conseguenze.
    readonly property int pollInterval: 60000

    // Quanti pannelli guardano adesso. Non un booleano: le due colonne della
    // dashboard sono indipendenti, e il primo che si chiude non deve spegnere
    // la lettura per l'altro.
    property int watchers: 0

    function watch() {
        root.watchers++;
    }

    function unwatch() {
        root.watchers = Math.max(0, root.watchers - 1);
    }

    readonly property int windowMinutes: Settings.heartWindowHours * 60
    readonly property string device: Settings.heartDevice

    property bool loading: false
    property bool loaded: false
    property string lastError: ""

    // I telefoni fra cui phone_adb.py si e' rifiutato di indovinare. Arrivano
    // insieme all'errore perche' il pannello ne faccia dei pulsanti: chiedere
    // di scegliere e non dare da scegliere e' meta' messaggio.
    property var choices: []

    // L'ultimo battito che Health Connect conosce, e quanti secondi fa e'
    // stato misurato: le due cose vanno sempre insieme.
    property var latest: null
    property int lagSeconds: -1

    property var today: null

    // I punti, indicizzati per istante. Una mappa e non un elenco perche' i
    // blocchi arrivano all'indietro: un travaso delle 10:30 puo' contenere i
    // campioni delle 10:05, e accodarli li disegnerebbe come se fossero
    // adesso. Cosi' invece ogni punto trova il suo posto per data, e rileggere
    // la stessa finestra due volte non cambia niente — che e' anche cio' che
    // rende innocuo un ritardo o un giro saltato.
    property var points: ({})

    // La serie densa che il grafico vuole: un valore per minuto, `null` dove
    // non e' mai arrivato niente. I buchi restano buchi apposta — HistoryChart
    // li usa per spezzare la linea, e uno zero al posto di un buco
    // racconterebbe un arresto cardiaco ogni volta che il braccialetto e' sul
    // comodino.
    readonly property var values: {
        const out = [];
        const step = 60;
        const now = Math.floor(Date.now() / 1000);
        const first = Math.floor((now - root.windowMinutes * 60) / step) * step;

        for (let at = first; at <= now; at += step) {
            const found = root.points[at];
            out.push(found === undefined ? null : found.avg);
        }
        return out;
    }

    readonly property var span: {
        const known = root.values.filter(v => v !== null);
        if (known.length === 0)
            return null;
        return {
            min: Math.min(...known),
            max: Math.max(...known),
            avg: known.reduce((sum, v) => sum + v, 0) / known.length
        };
    }

    function absorb(data) {
        // Fusione, non sostituzione: quello che arriva copre i minuti che
        // porta, e lascia stare gli altri. Cosi' una lettura corta non
        // cancella un'ora gia' raccolta.
        const merged = Object.assign({}, root.points);
        const horizon = Math.floor(Date.now() / 1000) - root.windowMinutes * 60;

        for (const point of data.points ?? []) {
            if (point.avg !== null && point.avg !== undefined)
                merged[point.t] = point;
        }

        // Il vecchio esce per data, non per posizione: e' l'unico criterio che
        // regge quando i punti arrivano fuori ordine.
        for (const key of Object.keys(merged)) {
            if (Number(key) < horizon)
                delete merged[key];
        }

        root.points = merged;
        root.latest = data.latest ?? null;
        root.lagSeconds = data.lag_seconds ?? -1;
        root.loaded = true;
    }

    readonly property var runner: ["python3", PluginPaths.of("scripts/phone_adb.py")]

    function args(command) {
        const out = [...root.runner];
        if (root.device)
            out.push("--device", root.device);
        out.push(command);
        return out;
    }

    // Finche' la configurazione non e' arrivata non si sa a quale telefono
    // chiedere: `heartDevice` e' ancora vuoto, e con due telefoni collegati
    // phone_adb.py si rifiuta di indovinare — giustamente, ma l'utente si
    // troverebbe davanti un errore che riguarda solo il primo istante di vita
    // della dashboard. Il pannello nasce prima della fine della lettura perche'
    // e' `left`/`right` a farlo nascere, e quelle sono dichiarate prima di
    // `heartDevice` nello stesso JsonAdapter.
    function refresh() {
        if (heart.running || !Settings.ready)
            return;

        root.loading = true;
        heart.command = [...root.args("heart"), "--minutes", String(root.windowMinutes)];
        heart.running = true;
    }

    function refreshToday() {
        if (daily.running || !Settings.ready)
            return;

        daily.command = root.args("today");
        daily.running = true;
    }

    function start() {
        root.refresh();
        root.refreshToday();
    }

    onWatchersChanged: {
        if (root.watchers === 1)
            root.start();
    }

    // Il giro che non e' partito all'apertura parte adesso.
    Connections {
        target: Settings

        function onReadyChanged() {
            if (Settings.ready && root.watchers > 0)
                root.start();
        }
    }

    Timer {
        running: root.watchers > 0
        interval: root.pollInterval
        repeat: true
        onTriggered: root.refresh()
    }

    // I numeri della giornata cambiano ancora piu' piano del battito, e il
    // sonno una volta per notte: mezz'ora e' gia' generosa.
    Timer {
        running: root.watchers > 0
        interval: 1800000
        repeat: true
        onTriggered: root.refreshToday()
    }

    // Un telefono spento non deve voler dire un processo al minuto per
    // sempre: dopo un errore l'attesa raddoppia fino a mezz'ora, e la prima
    // risposta buona la rimette com'era. Il polling e' idempotente, quindi
    // saltare dei giri non lascia buchi permanenti — quello che si e' perso
    // torna alla lettura dopo.
    property int backoff: 0

    Timer {
        id: retry
        interval: Math.min(1800000, root.pollInterval * Math.pow(2, root.backoff))
        repeat: false
        onTriggered: root.refresh()
    }

    Process {
        id: heart

        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const data = JSON.parse(this.text);

                    if (data.ok) {
                        root.absorb(data);
                        root.lastError = "";
                        root.choices = [];
                        root.backoff = 0;
                    } else {
                        root.lastError = data.error ?? "";
                        root.choices = data.choices ?? [];
                        root.backoff = Math.min(3, root.backoff + 1);
                        if (root.watchers > 0)
                            retry.restart();
                    }
                } catch (e) {
                    root.lastError = "risposta illeggibile: " + e;
                }
                root.loading = false;
            }
        }

        onExited: code => {
            if (code !== 0) {
                root.loading = false;
                if (!root.lastError)
                    root.lastError = `phone_adb.py uscito con codice ${code}`;
            }
        }
    }

    Process {
        id: daily

        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const data = JSON.parse(this.text);
                    if (data.ok)
                        root.today = data;
                } catch (e) {
                    // Il riepilogo e' un di piu': se non arriva, il battito
                    // vale comunque e non c'e' niente da dire all'utente.
                }
            }
        }
    }
}
