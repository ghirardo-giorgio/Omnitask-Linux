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

    // --- meteo ---------------------------------------------------------------
    // Il meteo non si chiede a un servizio esterno: lo ha gia' Home Assistant,
    // per le stesse coordinate di casa da cui vengono sun.sun e il pannello
    // Solare. Nessuna citta' da scrivere nelle preferenze, quindi, e nessuna
    // seconda chiave da tenere aggiornata: si sposta la posizione in Home
    // Assistant e si sposta anche il meteo della dashboard.
    //
    // Lo stato attuale (condizione, temperatura, umidita', vento) arriva con
    // tutti gli altri stati dal polling normale: qui restano solo le
    // previsioni, che dalla versione 2024.4 di Home Assistant non sono piu'
    // un attributo dell'entita' ma la risposta del servizio
    // weather.get_forecasts — misurato, non dedotto: `weather.forecast_home`
    // non ha piu' l'attributo `forecast`, e chi lo cerca trova undefined.
    property var forecastDaily: []
    property var forecastHourly: []

    // Quale entita' meteo guardare. Di norma ce n'e' una sola e la si trova da
    // soli; chi ne ha piu' d'una la sceglie con il parametro "entity" del
    // pannello Meteo, in dashboard.json.
    readonly property string weatherEntity: {
        const forced = Settings.panelParam("weather", "entity", "");
        if (forced.length)
            return forced;
        const found = Object.keys(root.states).filter(id => id.startsWith("weather."));
        return found.length ? found.sort()[0] : "";
    }

    // Quanti pannelli stanno guardando le previsioni: a zero non si scarica
    // niente. Stesso motivo del watch sullo storico — un pannello spento non
    // deve continuare a far chiamare un servizio per sempre.
    property int forecastWatchers: 0

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

    // Le stesse serie prima del riporto in avanti: null dove il recorder non ha
    // registrato niente. Servono a sapere da quale lettura viene un punto —
    // `history` non lo dice piu', perche' un valore ripetuto per un'ora e la
    // lettura che l'ha prodotto li' dentro sono indistinguibili, e quello che
    // si cancella e' la lettura.
    property var historyRaw: ({})

    // L'istante da cui parte l'ultima serie scaricata. Serve a tradurre
    // l'indice di un punto nell'intervallo che copre: ricalcolarlo da
    // Date.now() darebbe un bucket diverso appena passano cinque minuti, e si
    // cancellerebbe la lettura accanto a quella indicata.
    property real historyStart: 0
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

    // Le previsioni si scaricano finche' qualcuno le guarda, come lo storico.
    function watchForecast() {
        root.forecastWatchers += 1;
        if (root.forecastWatchers === 1)
            root.refreshForecast();
    }

    function unwatchForecast() {
        root.forecastWatchers = Math.max(0, root.forecastWatchers - 1);
    }

    // L'entita' puo' arrivare dopo il pannello: al primo giro di stati non c'e'
    // ancora nessun "weather.*" da trovare, e senza questo le previsioni
    // resterebbero vuote fino allo scadere del timer.
    onWeatherEntityChanged: {
        if (root.forecastWatchers > 0)
            root.refreshForecast();
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
            root.tipHistory();
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

    /**
     * Porta la coda di ogni serie al valore che il pannello sta mostrando.
     *
     * Il numero grande e la fine della linea vengono da due posti aggiornati a
     * cadenze diverse: gli stati ogni `haPollInterval` (quindici secondi), lo
     * storico ogni bucket (cinque minuti). Fra un giro e l'altro il numero
     * avanza e la linea resta indietro, e lo scarto e' massimo proprio quando
     * il valore si muove in fretta — cioe' quando il grafico e' interessante
     * da guardare, che e' anche quando la differenza salta all'occhio.
     *
     * L'ultimo elemento e' per costruzione il bucket in corso: `start` e'
     * allineato al bucket e la serie copre `historyHours` fino ad adesso.
     * Scriverci il valore corrente non inventa un punto, riempie quello che il
     * recorder di Home Assistant non ha ancora avuto modo di raccontare.
     *
     * Sta qui e non nei pannelli perche' i grafici alimentati da HA sono piu'
     * d'uno: comporre `[...history, adesso]` in ognuno vorrebbe dire la stessa
     * riga ripetuta ovunque, e dimenticata nel prossimo pannello.
     */
    function tipHistory() {
        const ids = Object.keys(root.history);

        if (ids.length === 0)
            return;

        const next = {};
        let moved = false;

        for (const id of ids) {
            const series = root.history[id];

            if (!series || series.length === 0) {
                next[id] = series;
                continue;
            }

            const value = parseFloat(root.state(id));
            const last = series.length - 1;

            // Uno stato testuale o assente non deve cancellare la coda: meglio
            // l'ultimo punto noto che un buco introdotto da chi voleva
            // aggiornarlo.
            if (!isFinite(value) || series[last] === value) {
                next[id] = series;
                continue;
            }

            const copy = series.slice();
            copy[last] = value;
            next[id] = copy;
            moved = true;
        }

        // `history` e' una property var: senza riassegnarla i binding dei
        // grafici non scattano, ed e' lo stesso motivo per cui `refreshHistory`
        // costruisce `next` invece di scrivere in posto.
        if (moved)
            root.history = next;
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
            const raw = Object.assign({}, root.historyRaw);
            for (const points of series) {
                if (!points.length)
                    continue;
                const sampled = root.resample(points, start, bucketMs);
                raw[points[0].entity_id] = sampled;
                next[points[0].entity_id] = root.carry(sampled);
            }
            root.historyStart = start;
            root.historyRaw = raw;
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

        return out;
    }

    // Riporta avanti l'ultimo valore noto sugli intervalli senza cambi: uno
    // stato di Home Assistant vale finche' non ne arriva un altro, e senza
    // questo passaggio una temperatura ferma disegnerebbe una linea
    // tratteggiata invece di una linea. Sta fuori da `resample` perche' la
    // serie di prima serve ancora: e' quella che distingue una lettura dalla
    // sua ripetizione (vedi `historyRaw`).
    function carry(sampled: var): var {
        const out = sampled.slice();
        let last = null;
        for (let i = 0; i < out.length; i++) {
            if (out[i] === null)
                out[i] = last;
            else
                last = out[i];
        }
        return out;
    }

    // --- cancellare una lettura --------------------------------------------
    //
    // Un sensore che una volta sola legge quello che non c'e' — l'igrometro a
    // 90% mentre l'aria sta al 47 — lascia nel grafico una montagna che non e'
    // mai esistita, e la lascia per sedici ore. Toglierla dalla dashboard non
    // basterebbe: lo storico viene dal recorder di Home Assistant, e al
    // ricaricamento dopo la montagna e' li' di nuovo. Si cancella dov'e'
    // scritta, e la dashboard la rilegge.
    //
    // Il lavoro sporco lo fa `scripts/ha_history.py`, che ha le sue ragioni
    // scritte in cima: le API di Home Assistant non sanno cancellare un
    // singolo stato.

    // In corso, e com'e' andata l'ultima volta: -1 finche' non si e' cancellato
    // niente in questa sessione. Il menu che ha chiesto la cancellazione ci
    // resta sopra finche' non sa l'esito — sparire e basta lascerebbe il
    // dubbio, e un intervallo senza letture e' un esito normale, non un errore.
    property bool deleting: false
    property string deleteError: ""
    property int deletedRows: -1

    /**
     * Cancella la lettura che sta nel bucket `index` della serie di `entityId`.
     *
     * L'indice si traduce in intervallo con `historyStart`, cioe' con l'inizio
     * della serie che il grafico sta mostrando davvero: ricalcolarlo adesso
     * darebbe un bucket piu' avanti di quello indicato ogni volta che la
     * cancellazione arriva dopo il cambio di bucket.
     *
     * Alla riuscita si ricarica tutto lo storico e non solo questa entita':
     * `refreshHistory` riallinea l'inizio delle serie che scarica, e lasciare
     * indietro le altre vorrebbe dire due assi dei tempi diversi nella stessa
     * dashboard.
     */
    function deletePoint(entityId: string, index: int) {
        if (purge.running || !entityId || index < 0 || root.historyStart <= 0)
            return;

        const bucketMs = root.historyBucketMinutes * 60 * 1000;
        const from = root.historyStart + index * bucketMs;

        root.deleting = true;
        root.deleteError = "";
        root.deletedRows = -1;

        purge.command = ["python3", PluginPaths.of("scripts/ha_history.py"), "delete", "--entity", entityId, "--from", String(Math.round(from)), "--to", String(Math.round(from + bucketMs))];
        purge.running = true;
    }

    Process {
        id: purge

        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const data = JSON.parse(this.text);

                    if (data.ok) {
                        root.deletedRows = data.deleted ?? 0;
                        if (root.deletedRows > 0)
                            root.refreshHistory(root.historyWanted);
                    } else {
                        root.deleteError = data.error ?? "";
                    }
                } catch (e) {
                    root.deleteError = "risposta illeggibile: " + e;
                }
                root.deleting = false;
            }
        }

        onExited: code => {
            root.deleting = false;
            if (code !== 0 && root.deleteError === "")
                root.deleteError = `ha_history.py uscito con codice ${code}`;
        }
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

    /**
     * Scarica le previsioni giornaliere e orarie dell'entita' meteo.
     *
     * Passa da POST /api/services/weather/get_forecasts?return_response=true,
     * che e' l'unica via REST rimasta: il servizio restituisce i dati nella
     * risposta invece di scriverli in uno stato, e senza `return_response`
     * Home Assistant accetta la chiamata e non risponde niente.
     *
     * Le due richieste sono separate perche' il servizio ne accetta un tipo
     * per volta. Un'entita' che non sa fare le orarie (`supported_features`
     * senza il bit 2) risponde con un errore: si lascia la serie vuota e il
     * pannello mostra solo i giorni, invece di dichiarare guasto tutto il
     * meteo.
     */
    function refreshForecast() {
        const id = root.weatherEntity;

        if (root.token === "" || id === "")
            return;

        const ask = function (kind, apply) {
            root.request("POST", "/api/services/weather/get_forecasts?return_response=true", {
                entity_id: id,
                type: kind
            }, function (ok, data) {
                if (!ok || !data) {
                    apply([]);
                    return;
                }
                const answer = data.service_response ?? ({});
                const entry = answer[id] ?? ({});
                apply(entry.forecast ?? []);
            });
        };

        ask("daily", function (list) {
            root.forecastDaily = list;
        });
        ask("hourly", function (list) {
            root.forecastHourly = list;
        });
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

    // Le previsioni di met.no si rifanno una volta all'ora: chiederle ogni
    // quarto d'ora e' gia' piu' spesso di quanto cambino.
    Timer {
        interval: 15 * 60 * 1000
        running: root.forecastWatchers > 0 && root.weatherEntity !== ""
        repeat: true
        onTriggered: root.refreshForecast()
    }

    Timer {
        id: settleTimer

        interval: 400
        onTriggered: root.refresh()
    }
}
