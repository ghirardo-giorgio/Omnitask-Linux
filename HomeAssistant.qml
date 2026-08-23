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
    // Entita' di cui tenere lo storico: la imposta chi disegna i grafici.
    property var historyEntities: []
    onHistoryEntitiesChanged: root.refreshHistory(root.historyEntities)

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
            root.refreshHistory(root.historyEntities);
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
        running: root.historyEntities.length > 0
        repeat: true
        onTriggered: root.refreshHistory(root.historyEntities)
    }

    Timer {
        id: settleTimer

        interval: 400
        onTriggered: root.refresh()
    }
}
