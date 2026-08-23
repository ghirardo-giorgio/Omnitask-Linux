pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Il telefono visto da ADB: lo schermo, i tasti, lo sblocco.
//
// Sopra scripts/phone_adb.py, come KdeConnect.qml sta sopra kdeconnect.py.
// I due singleton parlano di telefoni ma non della stessa cosa: KDE Connect
// elenca chi e' accoppiato per batteria e appunti, ADB chi ha il debug acceso.
// Un telefono puo' stare in uno e non nell'altro, ed e' il motivo per cui la
// finestra chiede sempre `status` prima di provare a fotografare: senza, un
// telefono senza debug darebbe un errore criptico invece di una spiegazione.
//
// I comandi passano da una coda con un solo processo per volta. Non e'
// prudenza astratta: `screenshot` impiega qualche secondo, e due scatti
// sovrapposti tornerebbero in ordine sparso, lasciando sullo schermo
// l'immagine piu' vecchia delle due.
Singleton {
    id: root

    readonly property var runner: ["python3", PluginPaths.of("scripts/phone_adb.py")]

    // Di chi parla la finestra adesso. E' il nome di KDE Connect: phone_adb.py
    // sa risolverlo da solo, per nome, indirizzo o serial.
    property string device: ""

    property bool busy: false
    // "device", "unauthorized", oppure vuoto quando ADB non lo vede affatto.
    property string adbState: ""
    property string address: ""
    // Cosa manca perche' il telefono sia pilotabile, con le parole che usa gia'
    // lo script: "debug wireless spento (Opzioni sviluppatore → …)".
    property string hint: ""
    property string lastError: ""
    // Esito dell'ultima azione, per la riga sotto i pulsanti.
    property string note: ""

    property string shot: ""
    property int shotWidth: 0
    property int shotHeight: 0
    // null finche' nessuno l'ha chiesto: "non lo so" e "sbloccato" sono due
    // risposte diverse e la seconda non va inventata.
    property var locked: null
    property var awake: null

    readonly property bool ready: root.adbState === "device"

    // Coda di lavori: { args, stdin, kind }.
    property var queue: []

    // Uno scatto appena si scopre che il telefono risponde. Chi apre la
    // finestra vuole vedere lo schermo, non un pulsante da premere; ma prima
    // dello `status` non si sa nemmeno se ADB lo conosce, quindi lo scatto
    // aspetta quella risposta invece di partire alla cieca e fallire.
    property bool wantShot: false

    // Una connessione wireless cade da sola: basta che il telefono dorma a
    // lungo o che il Wi-Fi si assopisca, e la sessione ADB non c'e' piu'
    // mentre il debug resta acceso. E' la situazione piu' comune di tutte, e
    // rimediarla e' un comando che la finestra puo' benissimo dare da se'
    // invece di limitarsi a suggerirlo.
    //
    // Un tentativo solo per apertura: se non riesce c'e' un motivo — telefono
    // spento, accoppiamento mai fatto — e riprovare in eterno non lo cambia.
    property bool triedConnect: false

    // Il telefono ha chiesto il PIN: lo swipe non e' bastato.
    signal pinNeeded

    function look(name: string): void {
        root.device = name;
        root.shot = "";
        root.note = "";
        root.lastError = "";
        root.locked = null;
        root.wantShot = true;
        root.triedConnect = false;
        root.refresh();
    }

    function refresh(): void {
        root.push(["status"], "status");
    }

    function connect(): void {
        root.triedConnect = true;
        root.push(["--device", root.device, "connect"], "connect");
        // Dopo il collegamento lo stato e' un altro, e con esso i pulsanti.
        root.refresh();
    }

    function capture(): void {
        root.push(["--device", root.device, "screenshot"], "shot");
    }

    function key(name: string): void {
        root.push(["--device", root.device, "key", name], "action");
        // Un tasto cambia quello che c'e' sullo schermo: la foto di prima non
        // vale piu', e chiederne una nuova e' esattamente cio' che farebbe chi
        // guarda dopo aver premuto.
        root.capture();
    }

    // "on"/"off", oppure vuoto per sapere soltanto com'e'.
    function display(state: string): void {
        root.push(["--device", root.device, "display", state], "display");

        // A schermo acceso si rifa' la foto, a schermo spento no: quello che
        // ci sarebbe da fotografare e' nero, e la foto di prima — lasciata li'
        // — racconterebbe un telefono ancora acceso.
        if (state !== "off")
            root.capture();
    }

    function tap(x: int, y: int): void {
        root.push(["--device", root.device, "tap", String(Math.round(x)), String(Math.round(y))], "action");
        root.capture();
    }

    // Con `pin` vuoto si prova la sola sveglia piu' scorrimento, che su un
    // telefono senza blocco basta e avanza. Il PIN si chiede solo se dopo
    // quello il keyguard e' ancora li': domandarlo per abitudine a chi non ne
    // ha uno sarebbe chiedere una cosa che non esiste.
    function unlock(pin: string): void {
        if (pin === "")
            root.push(["--device", root.device, "unlock"], "unlock");
        else
            root.push(["--device", root.device, "unlock", "--stdin"], "unlock", pin);

        root.capture();
    }

    function push(args: var, kind: string, stdin: string): void {
        if (root.device === "" && kind !== "status")
            return;

        root.queue = [...root.queue, {
            args: args,
            kind: kind,
            stdin: stdin ?? ""
        }];
        root.pump();
    }

    function pump(): void {
        if (job.running || root.queue.length === 0)
            return;

        const next = root.queue[0];
        root.queue = root.queue.slice(1);

        job.kind = next.kind;
        job.pending = next.stdin;
        job.command = [...root.runner, ...next.args];
        // Lo stdin si apre solo quando c'e' qualcosa da scriverci: lasciarlo
        // aperto a vuoto fa restare lo script in attesa di un input che non
        // arrivera' mai.
        job.stdinEnabled = next.stdin !== "";
        root.busy = true;
        job.running = true;
    }

    Process {
        id: job

        property string kind: ""
        property string pending: ""

        // Il PIN si scrive qui e non negli argomenti: la riga di comando di un
        // processo e' leggibile da chiunque faccia `ps` mentre gira, e finisce
        // nel journal. Appena scritto si chiude lo stdin, che per lo script e'
        // il segnale di aver ricevuto tutto.
        onStarted: {
            if (job.pending === "")
                return;

            job.write(job.pending);
            job.pending = "";
            job.stdinEnabled = false;
        }

        stdout: StdioCollector {
            onStreamFinished: {
                var data;

                try {
                    data = JSON.parse(this.text);
                } catch (e) {
                    root.lastError = I18n.t("risposta illeggibile da phone_adb.py");
                    return;
                }

                if (job.kind === "status")
                    root.absorbStatus(data);
                else if (job.kind === "shot")
                    root.absorbShot(data);
                else if (job.kind === "connect")
                    root.absorbConnect(data);
                else if (job.kind === "display")
                    root.absorbDisplay(data);
                else
                    root.absorbAction(data);
            }
        }

        onExited: code => {
            root.busy = false;

            if (code !== 0 && root.lastError === "" && root.note === "")
                root.lastError = `phone_adb.py: codice ${code}`;

            root.pump();
        }
    }

    function absorbStatus(data: var): void {
        if (!data.ok) {
            root.lastError = data.error ?? "";
            return;
        }

        const wanted = (data.devices ?? []).find(d => d.name === root.device || d.ip === root.device);

        if (!wanted) {
            root.adbState = "";
            root.address = "";
            root.hint = I18n.t("ADB non conosce questo telefono");
            return;
        }

        root.adbState = wanted.adb ?? "";
        root.address = wanted.ip ?? "";
        root.lastError = "";

        // Il suggerimento riguarda questo telefono, non il primo dell'elenco.
        const mine = (data.hints ?? []).filter(h => h.indexOf(root.device) === 0);
        root.hint = root.adbState === "device" ? "" : (mine.length > 0 ? mine[0] : "");

        if (root.wantShot && root.adbState === "device") {
            root.wantShot = false;
            root.capture();
            return;
        }

        // Debug acceso ma nessuna sessione: e' il caso in cui `connect`
        // risolve tutto, quindi lo si prova invece di scriverlo e basta.
        if (root.adbState === "" && wanted.wireless_debugging && !root.triedConnect)
            root.connect();
    }

    function absorbShot(data: var): void {
        if (!data.ok) {
            root.lastError = data.error ?? "";
            return;
        }

        root.shot = data.path ?? "";
        root.lastError = "";
    }

    function absorbAction(data: var): void {
        if (data.locked !== undefined)
            root.locked = data.locked;

        root.note = data.ok ? (data.note ?? I18n.t("fatto")) : (data.error ?? I18n.t("non riuscito"));

        if (!data.ok)
            root.lastError = data.error ?? "";

        // Sveglia e scorrimento non sono bastati: da qui in poi serve un
        // segreto, e a chiederlo e' il telefono, non l'interfaccia.
        if (job.kind === "unlock" && data.locked === true)
            root.pinNeeded();
    }

    function absorbDisplay(data: var): void {
        root.awake = data.awake ?? null;

        if (data.locked !== undefined && data.locked !== null)
            root.locked = data.locked;

        if (data.awake === false)
            root.shot = "";

        root.note = data.awake === false ? I18n.t("schermo spento") : "";
    }

    function absorbConnect(data: var): void {
        root.note = data.ok ? I18n.t("collegato") : "";
        root.lastError = data.ok ? "" : (data.results && data.results.length > 0 ? (data.results[0].hint ?? data.results[0].error ?? "") : (data.error ?? ""));
    }
}
