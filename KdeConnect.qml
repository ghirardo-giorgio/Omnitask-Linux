pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Batteria e stato di connessione dei telefoni accoppiati, via KDE Connect.
//
// Lo stato lo tiene un demone che gira gia' per conto suo (kdeconnectd, o
// GSConnect come ripiego): qui non si parla col telefono, si chiede al demone
// cosa sa. Vedi scripts/kdeconnect.py per quale dei due risponde e perche'.
//
// Interrogato a intervalli e non in ascolto sul bus: la percentuale di una
// batteria si muove di un punto ogni parecchi minuti, e restare in ascolto
// vorrebbe dire un processo vivo come sysmon per un dato che cambia cosi'
// piano. Il prezzo e' che un cavo appena infilato si vede con mezzo minuto di
// ritardo.
//
// E si interroga solo mentre qualcuno guarda. Il pannello si annuncia quando
// nasce e si toglie quando muore (watch/unwatch): a pannello spento non parte
// nessun processo, e accenderlo fa scattare subito una lettura invece di
// lasciare la prima riga vuota per mezzo minuto. E' anche il modo in cui un
// telefono accoppiato adesso compare da solo: l'elenco non e' scritto da
// nessuna parte, si richiede ogni volta al demone.
Singleton {
    id: root

    readonly property int pollInterval: 30000

    // Quanti pannelli sono a video adesso. Non un semplice booleano: la
    // dashboard puo' averne piu' d'uno (le due colonne sono indipendenti), e
    // il primo che si chiude non deve spegnere la lettura per l'altro.
    property int watchers: 0

    function watch() {
        root.watchers++;
    }

    function unwatch() {
        root.watchers = Math.max(0, root.watchers - 1);
    }

    property var devices: []
    property string source: ""
    property bool loading: false
    property string lastError: ""
    // Vero da quando e' arrivata la prima risposta: prima di allora un elenco
    // vuoto vuol dire "non lo so ancora", non "nessun telefono".
    property bool loaded: false

    // Solo quelli che sono davvero tuoi. Senza il filtro comparirebbe anche
    // questa stessa macchina: con GSConnect e kdeconnectd accesi insieme, ognuno
    // vede l'altro come un dispositivo separato e non accoppiato.
    readonly property var paired: root.devices.filter(d => d.paired)

    readonly property var online: root.paired.filter(d => d.reachable)

    // Il piu' scarico fra quelli che riportano la carica: e' quello che
    // interessa, ed e' l'unico numero che sta in una riga sola.
    readonly property var lowest: {
        const known = root.online.filter(d => d.battery);
        if (known.length === 0)
            return null;
        return known.reduce((worst, d) => d.battery.percent < worst.battery.percent ? d : worst);
    }

    // `scan` chiede al demone di riannunciarsi sulla rete prima di leggere:
    // e' come si accorge di un telefono acceso adesso o accoppiato un minuto
    // fa. Costa un broadcast, quindi lo fa l'accensione del pannello e la
    // rilettura chiesta a mano, non il giro dei trenta secondi.
    function refresh(scan: bool) {
        if (probe.running)
            return;
        root.loading = true;
        probe.command = scan ? [...root.reader, "--rescan"] : root.reader;
        probe.running = true;
    }

    readonly property var reader: ["python3", PluginPaths.of("scripts/kdeconnect.py")]

    // Il passaggio da nessuno a qualcuno che guarda: e' l'accensione del
    // pannello, ed e' li' che si va a cercare invece di aspettare il giro.
    onWatchersChanged: {
        if (root.watchers === 1)
            root.refresh(true);
    }

    // Niente `triggeredOnStart`: la prima lettura la fa gia' onWatchersChanged,
    // e con la scansione attiva che qui non serve. Questo tiene solo il dato
    // fresco mentre il pannello resta a video.
    Timer {
        running: root.watchers > 0
        interval: root.pollInterval
        repeat: true
        onTriggered: root.refresh(false)
    }

    Process {
        id: probe

        command: root.reader

        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const data = JSON.parse(this.text);
                    root.devices = data.devices ?? [];
                    root.source = data.source ?? "";
                    root.lastError = data.ok ? "" : (data.error ?? "");
                    root.loaded = true;
                } catch (e) {
                    root.lastError = "Stato dei dispositivi illeggibile: " + e;
                }
                root.loading = false;
            }
        }

        onExited: code => {
            if (code !== 0) {
                root.lastError = `kdeconnect.py uscito con codice ${code}`;
                root.loading = false;
            }
        }
    }

    // --------------------------------------------------------------- azioni

    // Esito dell'ultima azione, per dispositivo: { text, ok }. Sta qui e non
    // nel pannello perche' l'azione dura piu' del clic — parte un processo, e
    // la risposta arriva dopo — e il pannello nel frattempo puo' essere stato
    // ricostruito da un aggiornamento dell'elenco.
    property var actionStatus: ({})

    function setStatus(id: string, text: string, ok: bool) {
        const next = Object.assign({}, root.actionStatus);
        next[id] = {
            text: text,
            ok: ok
        };
        root.actionStatus = next;
        forget.restart();
    }

    // direction: "send" | "receive"
    function clipboard(id: string, direction: string) {
        if (action.running)
            return;
        action.device = id;
        action.command = [...root.reader, direction === "send" ? "--send" : "--receive", id];
        root.setStatus(id, direction === "send" ? I18n.t("invio…") : I18n.t("richiesta…"), true);
        action.running = true;
    }

    // L'esito e' un lampo, non uno stato: sparisce da solo, altrimenti resta
    // a video un "inviata" di dieci minuti fa che sembra di adesso.
    Timer {
        id: forget

        interval: 4000
        onTriggered: root.actionStatus = ({})
    }

    Process {
        id: action

        property string device: ""

        stdout: StdioCollector {
            onStreamFinished: {
                var data;
                try {
                    data = JSON.parse(this.text);
                } catch (e) {
                    root.setStatus(action.device, I18n.t("risposta illeggibile"), false);
                    return;
                }
                if (data.ok)
                    root.setStatus(action.device, data.action === "send" ? I18n.t("inviata") : I18n.t("ricevuta"), true);
                else
                    root.setStatus(action.device, data.error ?? I18n.t("non riuscita"), false);
            }
        }
    }

    // Come si chiamano i due demoni per chi legge, non per il bus.
    readonly property string sourceLabel: {
        const names = root.source.split("+").map(s => s === "kdeconnectd" ? "KDE Connect" : (s === "gsconnect" ? "GSConnect" : s)).filter(s => s.length > 0);
        return names.join(" + ");
    }

    // Scarica sotto il 15%, in riserva sotto il 30: le stesse soglie che usa
    // Android per l'avviso di batteria bassa.
    function batteryColor(percent: int): string {
        if (percent <= 15)
            return "#f85149";
        if (percent <= 30)
            return "#d29922";
        return "#3fb950";
    }

    function icon(type: string): string {
        return type === "phone" ? "▮" : (type === "tablet" ? "▭" : "▣");
    }
}
