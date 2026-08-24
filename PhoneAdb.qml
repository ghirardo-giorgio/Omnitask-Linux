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

    // L'accoppiamento come lo ricorda questo PC, e la finestra del codice come
    // la sta mostrando il telefono adesso. Servono al ri-accoppiamento: senza
    // il secondo non c'e' modo di dire «sta chiedendo il codice» invece di
    // «aprine la schermata», che e' la differenza fra un'istruzione e una gia'
    // eseguita.
    property bool paired: false
    property bool pairingOpen: false

    // A che punto sta un ri-accoppiamento: "" quando non ce n'e' uno in corso,
    // "authorize" quando manca solo il consenso sullo schermo del telefono,
    // "code" quando servono le sei cifre. Lo decide lo script guardando adb,
    // non l'interfaccia tirando a indovinare.
    property string repairStep: ""
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

    // --- la sessione ------------------------------------------------------
    //
    // Un processo che resta aperto finche' la finestra lo e': manda i frame e
    // riceve i gesti sulla stessa pipe. Finche' vive, tocchi e tasti passano
    // di li' invece di far nascere un processo per volta — cinque centesimi di
    // secondo invece di un quarto, che su un trascinamento e' la differenza
    // fra un gesto e una successione di scatti.
    property bool sessionUp: false

    // «Segui»: le fotografie si susseguono da sole. Spento non chiude niente,
    // mette in pausa le catture e lascia aperto il canale dei gesti.
    property bool following: false
    property real fps: 2

    // Quanto e' costato l'ultimo frame: e' l'unico modo onesto di dire quanto
    // e' vecchio quello che si sta guardando.
    property int frameMs: 0

    // scrcpy c'e' su questa macchina? Riguarda il PC, non il telefono.
    property bool mirrorAvailable: false

    // Il telefono ha chiesto il PIN: lo swipe non e' bastato.
    signal pinNeeded

    // --- lo stato ADB di tutti, per il pannello --------------------------
    //
    // ADB e KDE Connect sono due collegamenti indipendenti, e sapere di uno
    // non dice niente dell'altro: un telefono col cavo attaccato risponde ad
    // adb mentre KDE Connect lo da' per irraggiungibile perche' l'app sul
    // telefono non e' aperta. Il pannello disegna i due stati separati, e per
    // farlo gli serve questo.
    //
    // Mappa nome → { adb, via, ip, connected }. Il nome e' quello di KDE
    // Connect: phone_adb.py unisce i due elenchi sull'indirizzo, quindi le
    // chiavi combaciano con quelle del pannello.
    property var links: ({})

    // Vero da quando e' arrivata la prima risposta: prima di allora "nessuno
    // stato" vuol dire "non lo so ancora", che non e' "non collegato".
    property bool linksKnown: false

    // I soli nomi, per chi deve farne una scelta. `links` non basta: ha per
    // chiave anche gli indirizzi, e un selettore con dentro "192.168.50.134"
    // accanto a "moto g24" chiederebbe di scegliere due volte lo stesso
    // telefono.
    property var phones: []

    // Lo stato di un telefono per nome, o null. Funzione e non accesso
    // diretto alla mappa perche' il nome puo' non esserci, e `undefined`
    // dentro un binding e' un errore silenzioso invece di un pallino grigio.
    function link(name: string): var {
        return root.links[name] ?? null;
    }

    // Una guardata svelta: niente ascolto mDNS, solo cosa ha adb adesso.
    // Trecentocinquanta millisecondi, che e' quello che la rende ripetibile
    // ogni trenta secondi mentre il pannello e' a video.
    //
    // Fuori dalla coda dei comandi: quella e' del telefono che si sta
    // guardando nella finestra, e un pallino del pannello non deve mettersi
    // in fila dietro a uno screenshot ne' accendere `busy`.
    function peek(): void {
        if (peeker.running)
            return;

        peeker.running = true;
    }

    function look(name: string): void {
        // Cambiare telefono con una sessione aperta vorrebbe dire guardare uno
        // e comandare l'altro: prima si chiude quella di prima.
        root.stopSession();
        root.device = name;
        root.shot = "";
        root.note = "";
        root.lastError = "";
        root.locked = null;
        root.wantShot = true;
        root.triedConnect = false;
        // Un ri-accoppiamento riguarda il telefono su cui e' cominciato, non
        // quello che si sta guardando adesso.
        root.repairStep = "";
        root.refresh();
    }

    function refresh(): void {
        root.push(["status"], "status");
    }

    // Una riga alla sessione. Torna false quando non c'e' nessuna sessione,
    // cosi' chi chiama sa di dover prendere la strada lunga invece di credere
    // di aver fatto qualcosa.
    function send(line: string): bool {
        if (!root.sessionUp)
            return false;

        session.write(line + "\n");

        if (root.following)
            idle.restart();

        return true;
    }

    function startSession(): void {
        if (session.running || root.device === "" || !root.ready)
            return;

        // Lo stato iniziale va negli argomenti, non in un comando scritto
        // subito dopo: la prima cattura parte prima che lo stdin sia buono per
        // scriverci, e un «pause» che arriva secondo e' un «pause» che non si
        // vede.
        session.command = [
            ...root.runner, "--device", root.device, "live",
            "--fps", String(root.fps),
            ...(root.following ? [] : ["--paused"]),
        ];
        session.running = true;
    }

    function stopSession(): void {
        if (!session.running)
            return;

        // Prima si chiede, poi si insiste: `quit` fa finire il giro in corso e
        // ripulire i due file, il segnale che arriva dopo e' solo la garanzia
        // che il processo non resti in giro se lo stdin fosse gia' chiuso.
        root.send("quit");
        session.running = false;
        root.sessionUp = false;
    }

    // Da chiamare quando la finestra si chiude: nessuno guarda piu', e le
    // fotografie costano batteria a chi le fa.
    function close(): void {
        root.stopSession();
        root.shot = "";
        root.wantShot = false;
    }

    function connect(): void {
        root.triedConnect = true;
        root.push(["--device", root.device, "connect"], "connect");
        // Dopo il collegamento lo stato e' un altro, e con esso i pulsanti.
        root.refresh();
    }

    // Rimette in gioco un telefono che ha tolto l'autorizzazione. Quale delle
    // due autorizzazioni sia — la chiave RSA o l'accoppiamento wireless — lo
    // stabilisce lo script, e torna in `repairStep`.
    function repair(): void {
        root.note = "";
        root.lastError = "";
        root.push(["--device", root.device, "repair"], "repair");
    }

    // Le sei cifre che il telefono sta mostrando. Vanno negli argomenti e non
    // su stdin come il PIN: il codice e' gia' scritto sullo schermo del
    // telefono, vale trenta secondi, e non e' un segreto da proteggere.
    function pairWith(code: string): void {
        root.note = "";
        root.lastError = "";
        root.push(["--device", root.device, "pair", code], "pair");
    }

    function capture(): void {
        if (root.send("shot"))
            return;

        root.push(["--device", root.device, "screenshot"], "shot");
    }

    function key(name: string): void {
        // Con la sessione lo scatto lo fa lo script appena il tasto e' partito:
        // chiederglielo da qui vorrebbe dire due fotografie della stessa cosa.
        if (root.send(`key ${name}`))
            return;

        root.push(["--device", root.device, "key", name], "action");
        // Un tasto cambia quello che c'e' sullo schermo: la foto di prima non
        // vale piu', e chiederne una nuova e' esattamente cio' che farebbe chi
        // guarda dopo aver premuto.
        root.capture();
    }

    // Le tre fasi di un dito appoggiato, mosso e sollevato. Esistono solo con
    // la sessione: a processo per evento un trascinamento sarebbe una
    // successione di diapositive, e non e' un gesto.
    function drag(phase: string, x: int, y: int): void {
        root.send(`${phase} ${Math.round(x)} ${Math.round(y)}`);
    }

    // Uno scorrimento: parte da dove sta il puntatore e va verso l'alto o il
    // basso. Corto e svelto, perche' e' quello che fa un dito sulla rotella.
    function scroll(x: int, y: int, dy: int): void {
        const to = Math.round(y + dy);
        root.swipe(x, y, x, to, 120);
    }

    // Fermo e a lungo: la pressione lunga si ottiene con uno scorrimento che
    // non va da nessuna parte, che e' il modo consueto di chiederla ad `input`.
    function longPress(x: int, y: int, ms: int): void {
        root.swipe(x, y, x, y, Math.max(ms, 600));
    }

    function swipe(x1: int, y1: int, x2: int, y2: int, ms: int): void {
        const args = [Math.round(x1), Math.round(y1), Math.round(x2), Math.round(y2), Math.round(ms)].map(String);

        if (root.send("swipe " + args.join(" ")))
            return;

        root.push(["--device", root.device, "swipe", ...args], "action");
        root.capture();
    }

    // Il testo digitato sulla tastiera del PC, in blocco: una lettera per
    // comando vorrebbe dire un viaggio di andata e ritorno per lettera.
    function type(text: string): void {
        if (text === "")
            return;

        if (root.send("text " + text))
            return;

        root.push(["--device", root.device, "text", text], "action");
        root.capture();
    }

    function follow(on: bool): void {
        root.following = on;
        root.send(on ? "resume" : "pause");
    }

    function mirror(): void {
        // Due catture dello stesso schermo sono batteria buttata: chi apre
        // scrcpy guarda quello, non le fotografie di qui.
        if (root.following)
            root.follow(false);

        root.push(["--device", root.device, "mirror"], "action");
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
        // Anche per la sessione il PIN viaggia su stdin: e' una riga scritta in
        // una pipe, non un argomento che chiunque legge con `ps`.
        if (root.send("pin" + (pin === "" ? "" : " " + pin)))
            return;

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
        id: peeker

        command: [...root.runner, "status", "--quick"]

        stdout: StdioCollector {
            onStreamFinished: {
                let data;

                try {
                    data = JSON.parse(this.text);
                } catch (e) {
                    return;
                }

                if (!data.ok)
                    return;

                const map = {};
                const names = [];

                for (const device of data.devices ?? []) {
                    const entry = {
                        adb: device.adb ?? "",
                        via: device.via ?? "",
                        ip: device.ip ?? "",
                        connected: device.connected ?? false,
                    };

                    if (device.name) {
                        map[device.name] = entry;
                        names.push(device.name);
                    }

                    // Anche per indirizzo: un telefono che adb vede e KDE
                    // Connect no arriva senza nome, e senza questa chiave
                    // resterebbe fuori da ogni ricerca.
                    if (device.ip)
                        map[device.ip] = entry;
                }

                root.links = map;
                root.phones = names;
                root.linksKnown = true;
            }
        }
    }

    // Il processo che resta aperto: frame in arrivo, gesti in partenza.
    Process {
        id: session

        // Senza stdin aperto lo script vede subito la fine del canale e chiude:
        // per lui uno stdin chiuso vuol dire che dall'altra parte non c'e' piu'
        // nessuno, ed e' proprio cosi' che deve comportarsi.
        stdinEnabled: true

        onStarted: root.sessionUp = true

        onExited: {
            root.sessionUp = false;
            root.following = false;
        }

        stdout: SplitParser {
            onRead: line => root.absorbLive(line)
        }
    }

    // «Segui» non resta acceso per sempre: un pannello lasciato aperto
    // continuerebbe a chiedere fotografie a un telefono che intanto si scarica.
    // Ogni gesto rimanda il momento in cui si ferma.
    Timer {
        id: idle

        interval: 60000
        running: root.following

        onTriggered: {
            root.follow(false);
            root.note = I18n.t("in pausa: un minuto senza toccare niente");
        }
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
                else if (job.kind === "repair")
                    root.absorbRepair(data);
                else if (job.kind === "pair")
                    root.absorbPair(data);
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

    // Le righe della sessione: un frame, un cambio di stato, un guaio.
    function absorbLive(line: string): void {
        let data;

        try {
            data = JSON.parse(line);
        } catch (e) {
            return;
        }

        if (data.event === "frame") {
            root.shot = data.path ?? "";
            root.shotWidth = data.width ?? 0;
            root.shotHeight = data.height ?? 0;
            root.frameMs = data.ms ?? 0;
            root.lastError = "";
            return;
        }

        if (data.event === "state") {
            if (data.paused !== undefined)
                root.following = !data.paused;

            if (data.fps !== undefined)
                root.fps = data.fps;

            return;
        }

        if (data.event === "unlock") {
            if (data.locked !== undefined && data.locked !== null)
                root.locked = data.locked;

            root.note = data.ok ? (data.note ?? I18n.t("fatto")) : "";

            if (!data.ok)
                root.lastError = data.error ?? "";

            if (data.locked === true)
                root.pinNeeded();

            return;
        }

        if (data.event === "ready") {
            root.fps = data.fps ?? root.fps;
            return;
        }

        if (data.event === "miss" || data.event === "error")
            root.lastError = data.error ?? "";
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
            root.paired = false;
            root.pairingOpen = false;
            root.hint = I18n.t("ADB non conosce questo telefono");
            return;
        }

        root.adbState = wanted.adb ?? "";
        root.address = wanted.ip ?? "";
        root.paired = wanted.paired ?? false;
        root.pairingOpen = wanted.pairing_open ?? false;
        root.lastError = "";

        // Il suggerimento riguarda questo telefono, non il primo dell'elenco.
        const mine = (data.hints ?? []).filter(h => h.indexOf(root.device) === 0);
        root.hint = root.adbState === "device" ? "" : (mine.length > 0 ? mine[0] : "");

        root.mirrorAvailable = data.mirror ?? false;

        if (root.wantShot && root.adbState === "device") {
            root.wantShot = false;
            // La sessione scatta da se' appena e' in piedi: chiedere anche uno
            // screenshot a parte vorrebbe dire due fotografie della stessa cosa.
            root.startSession();
            return;
        }

        // Debug acceso ma nessuna sessione: e' il caso in cui `connect`
        // risolve tutto, quindi lo si prova invece di scriverlo e basta.
        //
        // Vale anche quando il telefono non sta annunciando niente ma una
        // porta buona e' gia' nota: un telefono assopito smette di annunciare
        // pur restando raggiungibile, e li' fermarsi vorrebbe dire scrivere
        // "debug wireless spento" a chi ce l'ha acceso.
        if (root.adbState === "" && !root.triedConnect && root.repairStep === ""
            && (wanted.wireless_debugging || (wanted.known_port ?? 0) > 0))
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

    // La preparazione del ri-accoppiamento. Lo stato fresco arriva qui dentro
    // insieme al passo da fare: lo script ha appena ascoltato la rete, e
    // chiedergli subito dopo uno `status` vorrebbe dire pagare due volte gli
    // stessi due secondi e mezzo.
    function absorbRepair(data: var): void {
        if (!data.ok) {
            root.repairStep = "";
            root.lastError = data.error ?? "";
            root.hint = data.hint ?? "";
            return;
        }

        root.repairStep = data.step ?? "";
        root.adbState = data.adb ?? "";
        root.address = data.ip ?? root.address;
        root.paired = data.paired ?? false;
        root.pairingOpen = data.pairing_open ?? false;
        root.note = data.note ?? "";
        root.lastError = "";

        // Il consiglio di prima parlava di un accoppiamento che adesso non
        // c'e' piu': lasciarlo li' vorrebbe dire contraddire le istruzioni
        // scritte due centimetri piu' su.
        root.hint = data.hint ?? "";
    }

    function absorbPair(data: var): void {
        if (!data.ok) {
            root.lastError = data.error ?? "";
            // Il codice cambia a ogni apertura della finestra: e' quasi sempre
            // questo, e dirlo qui evita di far riprovare lo stesso codice.
            root.note = data.hint ?? "";
            return;
        }

        // Lo script si e' gia' ricollegato da se' dopo il pairing: da qui in
        // poi e' un telefono come un altro, e lo `status` che segue lo trova
        // pronto e fa partire la sessione.
        root.repairStep = "";
        root.pairingOpen = false;
        root.paired = true;
        root.note = I18n.t("accoppiato");
        root.lastError = "";
        root.triedConnect = false;
        root.wantShot = true;
        root.refresh();
    }

    function absorbConnect(data: var): void {
        root.note = data.ok ? I18n.t("collegato") : "";
        root.lastError = data.ok ? "" : (data.results && data.results.length > 0 ? (data.results[0].hint ?? data.results[0].error ?? "") : (data.error ?? ""));
    }
}
