pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Elenco completo dei processi, ordinabile, con le azioni su un singolo pid.
//
// I dati arrivano da scripts/procmon.py, che gira come processo persistente:
// CPU, disco e rete sono differenze fra due campioni, e uno script che parte e
// muore non avrebbe un "prima" da cui calcolarle. Il filtro e l'ordinamento
// stanno qui in QML: riordinare qualche centinaio di righe costa meno che
// rifare il giro di /proc.
Singleton {
    id: root

    property var all: []
    property string query: ""
    // cpu | rss | gpu | vram | io | net | name
    property string sortKey: "cpu"
    property bool sortDesc: true
    // Di chi mostrare i processi: tutti | miei | root. Su questa macchina i
    // processi di root sono un quinto del totale e non hanno quasi mai CPU da
    // spendere: ordinati per consumo finiscono tutti in fondo a trecento
    // righe, cioe' in pratica non si vedono. Il filtro serve a chiederli.
    property string scope: "tutti"
    property string message: ""
    // spiega perche' la colonna rete e' vuota, quando lo e'
    property string netError: ""
    property bool netAvailable: root.netError === ""
    // e la stessa cosa per la colonna GPU
    property string gpuError: ""
    property bool gpuAvailable: root.gpuError === ""
    // connessioni che il kernel elenca ma che `ss` non ha saputo attribuire a
    // un processo: sono quelle degli altri utenti, root in testa
    property int orphanConns: 0
    property string connError: ""
    // il solo comando da incollare, senza la spiegazione che lo accompagna
    property string connFix: ""
    // un database di geolocalizzazione vecchio non sbaglia di qualche
    // chilometro: sbaglia paese, e proprio sugli indirizzi delle VPN
    property string geoError: ""
    property string geoFix: ""
    // Dove riemerge il traffico quando c'e' un tunnel attivo: null a VPN
    // spenta. { ip, iface, city, lat, lon, country, iso, radius, approx }
    property var vpnExit: null
    // pid su cui e' in corso una terminazione, per bloccare i doppi click
    property var pending: ({})
    // dettagli del processo sotto il puntatore (vedi describe/detailFor)
    property var detail: null
    property int detailPid: 0

    readonly property string scriptPath: PluginPaths.of("scripts/procs.py")

    // Chi sta usando la rete: prima chi ha traffico adesso, poi chi ha solo
    // connessioni aperte — un processo in attesa di risposta non trasmette
    // nulla, ma sta comunque parlando con qualcuno.
    readonly property var networkUsers: root.all.filter(p => (p.net !== null && p.net > 0) || (p.conns ?? 0) > 0).sort((a, b) => (b.net ?? 0) - (a.net ?? 0) || (b.conns ?? 0) - (a.conns ?? 0))

    // Quante connessioni passano da ciascuna interfaccia: { eno1: 12, tun0: 3 }.
    // Serve al filtro della finestra Rete, che col conteggio distingue le
    // interfacce su cui c'e' qualcosa da nascondere da quelle che portano
    // traffico non attribuibile a nessun processo di questa macchina.
    readonly property var connectionInterfaces: {
        const counts = ({});
        for (const process of root.all)
            for (const peer of (process.peers ?? []))
                if (peer.iface)
                    counts[peer.iface] = (counts[peer.iface] ?? 0) + (peer.count ?? 1);
        return counts;
    }

    // Ordine congelato mentre il puntatore e' sull'elenco o c'e' una selezione
    // (vedi updateFreeze):
    // i valori continuano ad aggiornarsi, le righe no.
    property bool frozen: false
    property var frozenOrder: []

    // Quanti processi ci sono per ogni proprietario, per il selettore: un
    // pulsante "root" che non filtra niente e' peggio che non averlo.
    readonly property int ownedCount: root.all.filter(p => p.owned).length
    readonly property int rootCount: root.all.filter(p => p.user === "root").length
    readonly property int othersCount: root.all.filter(p => root.isOther(p)).length

    // Ne' miei ne' di root: i demoni di servizio, che girano ognuno col suo
    // utente — dbus, avahi, polkitd, chrony. Sono pochi e stanno sepolti fra
    // centinaia di righe, ed e' proprio quando si va a cercare uno di quelli
    // che l'elenco intero e' d'intralcio.
    //
    // L'utente deve essere noto: procmon lascia il nome vuoto quando /proc/PID
    // sparisce mentre lo sta leggendo, e "non lo so" non e' "di qualcun
    // altro". Quei pochi restano in "Tutti", che e' il posto giusto per cio'
    // che non si sa classificare.
    function isOther(process: var): bool {
        return !process.owned && process.user !== "root" && (process.user ?? "").length > 0;
    }

    function inScope(process: var): bool {
        if (root.scope === "miei")
            return process.owned;
        if (root.scope === "root")
            return process.user === "root";
        if (root.scope === "altri")
            return root.isOther(process);
        return true;
    }

    // quanti processi restano dopo il solo filtro del proprietario: e' il
    // totale di riferimento del contatore, non quello di tutta la macchina
    readonly property int scopeCount: root.scope === "tutti" ? root.all.length : root.all.filter(p => root.inScope(p)).length

    readonly property var results: {
        const query = root.query.trim().toLowerCase();
        const scoped = root.scope === "tutti" ? root.all : root.all.filter(p => root.inScope(p));
        // il nome dell'utente entra nella ricerca insieme al resto: cosi' si
        // arriva anche agli utenti di servizio, che nel selettore non stanno
        const list = query.length === 0 ? scoped.slice() : scoped.filter(p => p.name.toLowerCase().includes(query) || p.cmdline.toLowerCase().includes(query) || (p.user ?? "").toLowerCase().includes(query));

        if (root.frozen && root.frozenOrder.length) {
            const rank = {};
            for (let i = 0; i < root.frozenOrder.length; i++)
                rank[root.frozenOrder[i]] = i;
            // i processi nati dopo il congelamento vanno in fondo, senza
            // spingere via quelli che l'utente sta guardando
            list.sort((a, b) => (rank[a.pid] ?? 99999) - (rank[b.pid] ?? 99999));
            return list;
        }

        const key = root.sortKey;
        const sign = root.sortDesc ? -1 : 1;
        list.sort((a, b) => {
            if (key === "name")
                return sign * a.name.localeCompare(b.name);
            // A GPU ferma sono tutti a 0% di SM: la parita' si rompe sulla VRAM
            // occupata, che e' l'unica cosa che li distingue (come in TopGpuPanel).
            if (key === "gpu")
                return sign * ((a.gpu ?? -1) - (b.gpu ?? -1) || (a.vram ?? -1) - (b.vram ?? -1));
            // i processi senza dato di rete (nethogs non li ha visti) restano
            // in fondo invece di mescolarsi a quelli fermi a zero
            const va = a[key] ?? -1;
            const vb = b[key] ?? -1;
            return sign * (va - vb);
        });
        return list;
    }

    // Cambiare proprietario e' come cambiare colonna d'ordinamento: e' una
    // richiesta esplicita di rifare l'elenco, e l'ordine congelato dall'hover
    // non deve trattenere righe che non c'entrano piu'.
    onScopeChanged: {
        root.frozen = false;
        // e subito ricongelato sul nuovo ordine, se c'e' ancora motivo: senza,
        // l'elenco resterebbe a ballare finche' il puntatore non esce e rientra
        root.updateFreeze();
    }

    // Vero mentre il puntatore sta sull'elenco: lo dice il pannello.
    property bool pointerOver: false

    // Ordinare per CPU vuol dire che le righe ballano a ogni campione: se
    // succede mentre si sta per premere la ✕ di un processo, si finisce per
    // chiuderne un altro. L'ordine resta fermo in due casi, e sono i due in
    // cui l'utente sta lavorando su una riga precisa: quando il puntatore e'
    // sull'elenco, e quando ci sono righe selezionate — quelle vanno tenute
    // dove sono anche se si porta il mouse altrove per premere un pulsante.
    function updateFreeze() {
        const want = root.pointerOver || root.selectedCount > 0;
        if (want === root.frozen)
            return;
        if (want)
            // calcolato prima di alzare il flag, cioe' con l'ordinamento vero
            root.frozenOrder = root.results.map(p => p.pid);
        root.frozen = want;
    }

    onPointerOverChanged: root.updateFreeze()
    onSelectedChanged: root.updateFreeze()

    // Cliccando due volte la stessa colonna si inverte il verso.
    function sortBy(key: string) {
        // scegliere una colonna e' una richiesta esplicita di riordinare: il
        // congelamento dell'hover non deve trattenere il vecchio ordine
        root.frozen = false;
        if (root.sortKey === key)
            root.sortDesc = !root.sortDesc;
        else {
            root.sortKey = key;
            // i nomi si leggono dalla A, i numeri dal piu' grande
            root.sortDesc = key !== "name";
        }
        // Ricongelato subito sull'ordine appena scelto: il puntatore e' ancora
        // sull'intestazione, e l'elenco non deve ripartire a ballare adesso.
        root.updateFreeze();
    }

    // --- selezione multipla ---------------------------------------------
    // pid selezionati, come mappa: l'appartenenza si chiede molte volte per
    // riga a ogni ridisegno, e un array la farebbe cercare ogni volta.
    property var selected: ({})
    readonly property int selectedCount: Object.keys(root.selected).length

    function isSelected(pid: int): bool {
        return root.selected[pid] !== undefined;
    }

    function toggleSelected(process: var) {
        const next = Object.assign({}, root.selected);
        if (next[process.pid] !== undefined)
            delete next[process.pid];
        else
            // si tiene anche il nome: quando l'azione partira', servira' a
            // verificare che dietro quel pid ci sia ancora lo stesso processo
            next[process.pid] = process.name;
        root.selected = next;
    }

    function clearSelected() {
        root.selected = ({});
    }

    // Seleziona in una volta tutti i processi che il filtro corrente lascia
    // passare: chiudere trecento righe una per una non e' l'uso che si fa
    // di un filtro. I processi selezionati fuori dal filtro restano tali.
    function selectAll() {
        const next = Object.assign({}, root.selected);
        for (const p of root.results)
            next[p.pid] = p.name;
        root.selected = next;
    }

    // Vero quando ogni risultato visibile e' selezionato: il pulsante che
    // seleziona tutti e' anche il posto dove deselezionarli tutti.
    readonly property bool allFilteredSelected: root.results.length > 0 && root.results.every(p => root.selected[p.pid] !== undefined)

    // Stessa azione su tutti i selezionati, in un solo avvio dello script: la
    // sequenza pid/nome viaggia come argomenti separati, cosi' nessun nome di
    // processo puo' rompere la riga di comando.
    function applyToSelected(action: string) {
        const pairs = [];
        for (const pid in root.selected) {
            pairs.push(pid);
            pairs.push(root.selected[pid]);
        }
        if (pairs.length === 0)
            return;
        root.message = "";
        manyProc.action = action;
        manyProc.command = ["python3", root.scriptPath, "signal-many", action].concat(pairs);
        manyProc.running = true;
    }

    // --- azioni su un processo ------------------------------------------
    function act(process: var, action: string) {
        if (root.pending[process.pid])
            return;
        const next = Object.assign({}, root.pending);
        next[process.pid] = action;
        root.pending = next;
        root.message = "";
        actionProc.command = ["python3", root.scriptPath, "signal", String(process.pid), process.name, action];
        actionProc.pid = process.pid;
        actionProc.running = true;
    }

    function setNice(process: var, value: int) {
        root.message = "";
        niceProc.command = ["python3", root.scriptPath, "nice", String(process.pid), process.name, String(value)];
        niceProc.running = true;
    }

    function setAffinity(process: var, cores: var) {
        root.message = "";
        affinityProc.command = ["python3", root.scriptPath, "affinity", String(process.pid), process.name, cores.join(",")];
        affinityProc.running = true;
    }

    function kill(process: var, force: bool) {
        if (root.pending[process.pid])
            return;

        const next = Object.assign({}, root.pending);
        next[process.pid] = force ? "kill" : "term";
        root.pending = next;
        root.message = "";
        // il nome viaggia col pid: se nel frattempo il processo e' morto e il
        // pid e' stato riciclato, lo script rifiuta invece di colpire un altro
        killProc.command = ["python3", root.scriptPath, "kill", String(process.pid), process.name].concat(force ? ["force"] : []);
        killProc.pid = process.pid;
        killProc.running = true;
    }

    function clearPending(pid: int) {
        const next = Object.assign({}, root.pending);
        delete next[pid];
        root.pending = next;
    }

    // Dettagli del processo sotto il puntatore: si leggono solo per lui, e
    // solo quando il puntatore si ferma (vedi il debounce nel pannello).
    function describe(pid: int) {
        if (pid === root.detailPid)
            return;
        root.detailPid = pid;
        root.detail = null;
        if (pid <= 0)
            return;
        detailProc.command = ["python3", root.scriptPath, "detail", String(pid)];
        detailProc.running = true;
    }

    // il monitor legge i parametri all'avvio: per cambiarli va fatto ripartire
    function restartMonitor() {
        monitor.running = false;
        monitor.running = true;
    }

    Process {
        id: monitor

        running: true
        command: ["python3", PluginPaths.of("scripts/procmon.py"), "--interval", String(Settings.procInterval), "--rules", Settings.priorityArg]

        stdout: SplitParser {
            onRead: line => {
                let data;
                try {
                    data = JSON.parse(line);
                } catch (e) {
                    return;
                }
                root.all = data.processes ?? [];
                root.netError = data.netError ?? "";
                root.gpuError = data.gpuError ?? "";
                root.orphanConns = data.orphanConns ?? 0;
                root.connError = data.connError ?? "";
                root.connFix = data.connFix ?? "";
                root.geoError = data.geoError ?? "";
                root.geoFix = data.geoFix ?? "";
                root.vpnExit = data.exit ?? null;
            }
        }
    }

    Connections {
        target: Settings

        function onProcIntervalChanged(): void {
            root.restartMonitor();
        }

        // Anche le regole di priorita' si leggono all'avvio, per la stessa
        // ragione: sono un argomento della riga di comando.
        function onPriorityRulesChanged(): void {
            root.restartMonitor();
        }
    }

    Process {
        id: killProc

        property int pid: 0

        stdout: StdioCollector {
            onStreamFinished: {
                let data;
                try {
                    data = JSON.parse(this.text);
                } catch (e) {
                    root.message = I18n.t("terminazione non riuscita");
                    root.clearPending(killProc.pid);
                    return;
                }
                root.message = data.ok ? I18n.t("terminato %1 (%2)").arg(data.name).arg(data.signal) : (data.error ?? I18n.t("terminazione non riuscita"));
                root.clearPending(killProc.pid);
            }
        }
    }

    Process {
        id: actionProc

        property int pid: 0

        stdout: StdioCollector {
            onStreamFinished: {
                let data;
                try {
                    data = JSON.parse(this.text);
                } catch (e) {
                    root.message = I18n.t("azione non riuscita");
                    root.clearPending(actionProc.pid);
                    return;
                }
                root.message = data.ok ? `${data.name}: ${data.signal}` : (data.error ?? I18n.t("azione non riuscita"));
                root.clearPending(actionProc.pid);
            }
        }
    }

    Process {
        id: manyProc

        property string action: ""

        stdout: StdioCollector {
            onStreamFinished: {
                let data;
                try {
                    data = JSON.parse(this.text);
                } catch (e) {
                    root.message = I18n.t("azione non riuscita");
                    return;
                }
                const done = (data.done ?? []).length;
                const errors = data.errors ?? [];
                // il conto di quelli riusciti, e il primo errore: se tre
                // processi su dieci non c'erano piu', dirlo dieci volte non
                // aiuta nessuno
                root.message = errors.length === 0 ? I18n.tn(done, "1 processo: %2", "%1 processi: %2").arg(data.signal) : `${done}/${done + errors.length} — ${errors[0]}`;
                root.clearSelected();
            }
        }
    }

    Process {
        id: niceProc

        stdout: StdioCollector {
            onStreamFinished: {
                let data;
                try {
                    data = JSON.parse(this.text);
                } catch (e) {
                    return;
                }
                root.message = data.ok ? I18n.t("%1: priorità %2").arg(data.name).arg(data.nice) : (data.error ?? "");
            }
        }
    }

    Process {
        id: affinityProc

        stdout: StdioCollector {
            onStreamFinished: {
                let data;
                try {
                    data = JSON.parse(this.text);
                } catch (e) {
                    return;
                }
                root.message = data.ok ? I18n.t("%1: %2 thread su %3").arg(data.name).arg(data.cores.length).arg(data.total) : (data.error ?? "");
            }
        }
    }

    Process {
        id: detailProc

        stdout: StdioCollector {
            onStreamFinished: {
                let data;
                try {
                    data = JSON.parse(this.text);
                } catch (e) {
                    return;
                }
                // nel frattempo il puntatore puo' essersi spostato altrove:
                // un dettaglio in ritardo non deve sovrascrivere quello buono
                if (data.ok && data.pid === root.detailPid)
                    root.detail = data;
            }
        }
    }
}
