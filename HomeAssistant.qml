pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Singleton che tiene in memoria lo stato di Home Assistant.
// La configurazione (url + token) sta in ~/.config/quickshell/home-assistant.json
// cosi' il token non finisce mai dentro il codice QML.
Singleton {
    id: root

    readonly property string baseUrl: cfg.url
    readonly property string token: cfg.token

    // Mappa entity_id -> oggetto stato restituito dalle API.
    property var states: ({})
    property bool online: false
    property string lastError: ""

    // --- posizione di casa ---------------------------------------------------
    // Latitudine e longitudine con cui Home Assistant fa i suoi conti: sono
    // quelle dell'integrazione Sun, cosi' chi ricalcola il sole in proprio
    // (il pannello Solare ne ricava gli orari di spostamento) parte dagli
    // stessi numeri di sun.sun invece di chiedere le coordinate una seconda
    // volta. Arrivano da /api/config, chiesta una volta per esecuzione: la
    // posizione di casa non e' una misura che cambia mentre si guarda.
    property real latitude: NaN
    property real longitude: NaN
    property bool locationFetched: false

    // --- storico -----------------------------------------------------------
    // Lo storico non viene accumulato dalla dashboard: lo tiene gia' il
    // recorder di Home Assistant, quindi i grafici sono completi anche al
    // primo avvio invece di riempirsi nell'arco di sedici ore.
    // Quanto storico mostrare: si regola dalle opzioni (vedi Settings).
    readonly property int historyHours: Settings.historyHours
    readonly property int historyBucketMinutes: 5
    readonly property int historyPoints: root.historyHours * 60 / root.historyBucketMinutes

    // entity_id -> array di historyPoints valori (null dove mancano dati).
    property var history: ({})
    // Entita' scelte nelle opzioni: la imposta il pannello Home Assistant, che
    // ci tiene sopra un Binding (vedi HaPanel). Chi non e' quel pannello non
    // deve scriverla — un Binding e' un padrone solo, e un secondo scrittore
    // verrebbe scavalcato al primo cambio delle opzioni, in silenzio.
    property var historyEntities: []

    // Le entita' chieste da un pannello per conto suo: l'igrometro vuole il
    // proprio storico senza passare per l'elenco delle opzioni, e cosi' potra'
    // fare qualunque altro pannello. Si aggiungono con watchHistory().
    property var historyExtra: []

    // Quelle di cui si scarica davvero lo storico: le due liste messe insieme,
    // senza ripetizioni.
    readonly property var historyWanted: {
        const out = root.historyEntities.slice();
        for (const id of root.historyExtra)
            if (!out.includes(id))
                out.push(id);
        return out;
    }

    onHistoryWantedChanged: root.refreshHistory(root.historyWanted)

    // Un pannello chiede lo storico di una sua entita' e, quando sparisce, lo
    // lascia andare: senza il rilascio, spegnere un pannello continuerebbe a
    // far scaricare la sua serie a ogni bucket, per sempre.
    function watchHistory(entityId: string) {
        if (!entityId || !entityId.length || root.historyExtra.includes(entityId))
            return;
        root.historyExtra = root.historyExtra.concat([entityId]);
    }

    function unwatchHistory(entityId: string) {
        if (!root.historyExtra.includes(entityId))
            return;
        root.historyExtra = root.historyExtra.filter(x => x !== entityId);
    }

    signal statesUpdated

    // Comodita': HomeAssistant.state("sensor.foo") -> "21.4"
    function state(entityId: string): string {
        const e = root.states[entityId];
        return e ? e.state : "";
    }

    function attribute(entityId: string, name: string): var {
        const e = root.states[entityId];
        return e && e.attributes ? e.attributes[name] : undefined;
    }

    function friendlyName(entityId: string): string {
        return root.attribute(entityId, "friendly_name") ?? entityId;
    }

    function unit(entityId: string): string {
        return root.attribute(entityId, "unit_of_measurement") ?? "";
    }

    // Scarica tutti gli stati. Chiamata dal Timer sotto.
    function refresh() {
        if (root.token === "") {
            root.lastError = "Token mancante in " + configFile.path;
            root.online = false;
            return;
        }

        root.request("GET", "/api/states", null, function (ok, data) {
            if (!ok) {
                root.online = false;
                return;
            }

            const map = {};
            for (const entity of data)
                map[entity.entity_id] = entity;

            root.states = map;
            // com'era la luce mentre era accesa: serve a riaccenderla uguale
            root.rememberLights(map);
            root.online = true;
            root.lastError = "";
            root.statesUpdated();

            // Al primo giro che trova Home Assistant raggiungibile, chiede
            // anche le coordinate. Se la chiamata fallisce si riprova al giro
            // dopo: finche' non sono arrivate chi ne ha bisogno resta senza.
            if (!root.locationFetched)
                root.request("GET", "/api/config", null, function (okCfg, cfg) {
                    if (!okCfg || !cfg)
                        return;

                    // Un'installazione senza posizione e' rara ma esiste:
                    // NaN dice a chi legge "niente coordinate", non 0,0 —
                    // che sarebbe un punto dell'oceano molto convincente.
                    root.latitude = isFinite(cfg.latitude) ? cfg.latitude : NaN;
                    root.longitude = isFinite(cfg.longitude) ? cfg.longitude : NaN;
                    root.locationFetched = true;
                });
        });
    }

    // Scarica lo storico delle entita' indicate e lo ricampiona a intervalli
    // regolari, cosi' i grafici hanno un asse dei tempi lineare.
    function refreshHistory(entityIds: var) {
        if (root.token === "" || !entityIds || entityIds.length === 0)
            return;

        const bucketMs = root.historyBucketMinutes * 60 * 1000;
        // Si parte da un multiplo esatto del bucket: i punti restano allineati
        // tra un aggiornamento e l'altro invece di scivolare.
        const start = Math.floor((Date.now() - root.historyHours * 3600 * 1000) / bucketMs) * bucketMs;
        const isoStart = new Date(start).toISOString();
        const path = `/api/history/period/${isoStart}?filter_entity_id=${entityIds.join(",")}&minimal_response&no_attributes`;

        root.request("GET", path, null, function (ok, series) {
            if (!ok || !series)
                return;

            const next = Object.assign({}, root.history);
            for (const points of series) {
                if (!points.length)
                    continue;
                next[points[0].entity_id] = root.resample(points, start, bucketMs);
            }
            root.history = next;
        });
    }

    // Gli stati di Home Assistant sono una funzione a gradini: dentro ogni
    // intervallo vale l'ultimo valore noto, non una media.
    function resample(points: var, start: real, bucketMs: real): var {
        const out = new Array(root.historyPoints).fill(null);

        for (const p of points) {
            const value = parseFloat(p.state);
            if (!isFinite(value))
                continue;  // "unavailable", "unknown", stati testuali

            const t = Date.parse(p.last_changed ?? p.last_updated);
            if (!isFinite(t))
                continue;

            const bucket = Math.floor((t - start) / bucketMs);
            if (bucket >= 0 && bucket < out.length)
                out[bucket] = value;
            else if (bucket < 0)
                out[0] = value;  // stato gia' in corso all'inizio della finestra
        }

        // Riporta avanti l'ultimo valore noto sugli intervalli senza cambi.
        let last = null;
        for (let i = 0; i < out.length; i++) {
            if (out[i] === null)
                out[i] = last;
            else
                last = out[i];
        }
        return out;
    }

    // Esegue un servizio, es. callService("light", "toggle", "light.salotto").
    // `data` aggiunge parametri al servizio (colore, luminosita', ...).
    function callService(domain: string, service: string, entityId: string, data: var) {
        const body = Object.assign({
            entity_id: entityId
        }, data ?? {});
        root.request("POST", `/api/services/${domain}/${service}`, body, function (ok) {
            // HA applica il comando in modo asincrono: rileggiamo poco dopo.
            if (ok)
                settleTimer.restart();
        });
    }

    // --- accensione delle luci ---------------------------------------------
    // `light.turn_on` senza parametri non dice nulla su colore e luminosita':
    // a decidere resta il dispositivo, che se non li ha conservati riaccende
    // come gli pare. Qui si tiene da parte com'era l'ultima volta che era
    // accesa e si rimanda tutto esplicitamente, cosi' spegnere e riaccendere
    // dalla dashboard restituisce la stessa luce di prima.

    // entity_id -> { brightness, rgb_color | color_temp_kelvin, effect }
    property var lightMemory: ({})

    function rememberLights(states: var) {
        const memory = Object.assign({}, root.lightMemory);
        let changed = false;
        for (const id in states) {
            if (!id.startsWith("light.") || states[id].state !== "on")
                continue;
            const a = states[id].attributes ?? {};
            const entry = {};
            if (a.brightness !== undefined && a.brightness !== null)
                entry.brightness = a.brightness;
            // un solo modo di colore per volta: mandarli entrambi farebbe
            // rifiutare la chiamata da Home Assistant
            if (a.color_mode === "color_temp" && a.color_temp_kelvin)
                entry.color_temp_kelvin = a.color_temp_kelvin;
            else if (a.rgb_color)
                entry.rgb_color = a.rgb_color;
            if (a.effect)
                entry.effect = a.effect;
            if (Object.keys(entry).length > 0) {
                memory[id] = entry;
                changed = true;
            }
        }
        if (changed)
            root.lightMemory = memory;
    }

    // Accende o spegne, restituendo alla luce i suoi ultimi valori noti.
    function toggleEntity(entityId: string) {
        const domain = entityId.split(".")[0];
        if (domain !== "light") {
            root.callService(domain, "toggle", entityId, null);
            return;
        }
        if (root.state(entityId) === "on") {
            root.callService("light", "turn_off", entityId, null);
            return;
        }
        // Molte luci ricordano da sole colore e luminosita' anche da spente, e
        // continuano a dichiararli fra i propri attributi: a quelle non si
        // manda nulla. Rispedire i valori che la dashboard ha in memoria — con
        // fino a un intero intervallo di polling di ritardo — vorrebbe dire
        // sovrascrivere con dati vecchi un colore appena cambiato altrove.
        const current = root.states[entityId];
        const attributes = current ? (current.attributes ?? {}) : {};
        const remembers = attributes.brightness !== undefined && attributes.brightness !== null;
        root.callService("light", "turn_on", entityId, remembers ? null : (root.lightMemory[entityId] ?? null));
    }

    function request(method: string, path: string, body: var, callback: var) {
        const xhr = new XMLHttpRequest();
        xhr.open(method, root.baseUrl + path);
        xhr.setRequestHeader("Authorization", "Bearer " + root.token);
        xhr.setRequestHeader("Content-Type", "application/json");

        xhr.onreadystatechange = function () {
            if (xhr.readyState !== XMLHttpRequest.DONE)
                return;

            if (xhr.status < 200 || xhr.status >= 300) {
                root.lastError = xhr.status === 0 ? `${root.baseUrl} irraggiungibile` : `HTTP ${xhr.status} su ${path}`;
                callback(false, null);
                return;
            }

            try {
                callback(true, xhr.responseText.length ? JSON.parse(xhr.responseText) : null);
            } catch (e) {
                root.lastError = "Risposta non valida: " + e;
                callback(false, null);
            }
        };

        xhr.send(body ? JSON.stringify(body) : "");
    }

    FileView {
        id: configFile

        path: `${Quickshell.env("HOME")}/.config/quickshell/home-assistant.json`
        watchChanges: true
        onFileChanged: reload()
        onLoaded: {
            root.refresh();
            root.refreshHistory(root.historyWanted);
        }
        // Al primo avvio il file non esiste: lo creiamo con i valori di default.
        onLoadFailed: error => {
            if (error === FileViewError.FileNotFound)
                writeAdapter();
        }

        // Qui stanno solo le credenziali. La frequenza di aggiornamento e le
        // entita' da mostrare sono preferenze come le altre e vivono in
        // dashboard.json (vedi Settings): un "pollInterval" rimasto in questo
        // file da una versione precedente non ha piu' effetto.
        JsonAdapter {
            id: cfg

            property string url: "http://homeassistant.local:8123"
            property string token: ""
        }
    }

    Timer {
        // la frequenza sta con le altre preferenze, in dashboard.json: qui
        // restano solo url e token (vedi Settings.haPollInterval)
        interval: Settings.haPollInterval
        running: true
        repeat: true
        onTriggered: root.refresh()
    }

    // Un nuovo punto dello storico esiste solo a ogni bucket: inutile
    // richiedere piu' spesso.
    Timer {
        interval: root.historyBucketMinutes * 60 * 1000
        running: root.historyWanted.length > 0
        repeat: true
        onTriggered: root.refreshHistory(root.historyWanted)
    }

    Timer {
        id: settleTimer

        interval: 400
        onTriggered: root.refresh()
    }
}
