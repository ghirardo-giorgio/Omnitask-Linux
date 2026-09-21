pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Le caratteristiche del pet che non vengono dal gioco ma da un sensore.
//
// Fame, energia, felicita' e pulizia stanno dentro pet/Pet.js: decadono da
// sole e si curano con un pulsante. Queste no. Una caratteristica di qui si
// LEGGE — la CO2 della stanza, la temperatura della CPU — e si cura andando a
// cambiare la cosa vera: aprire la finestra, spegnere qualcosa. Sono due
// meccaniche diverse, ed e' il motivo per cui questa vive accanto a Pet.js e
// non dentro: quel file e' di terzi e resta verbatim (vedi pet/UPSTREAM.md).
//
// Questo singleton non decide niente sulla salute del pet: calcola un
// benessere da 0 a 100 per ogni caratteristica e lo pubblica. Chi ne trae le
// conseguenze e' panels/PetPanel.qml, che possiede l'orologio della malattia.
Singleton {
    id: root

    // La configurazione, come sta nel file.
    property var traits: []

    property bool loaded: false
    property string lastError: ""

    // ---- Perche' un file suo e non i panelParams ---------------------------
    //
    // Una caratteristica e' un oggetto con otto campi, e servirebbe un ARRAY DI
    // OGGETTI dentro dashboard.json. Quel file ha un precedente esplicito
    // contro: `windows`, `places`, `colors`, `priorityRules` e `favServices`
    // sono tutte liste di stringhe, con scritto il perche' («JsonAdapter
    // serializza liste di stringhe senza sorprese» — Settings.qml). I
    // panelParams arrivano a un livello di annidamento e si fermano li'.
    //
    // Un file a parte toglie la scommessa, ed e' anche stampato leggibile e
    // modificabile a mano — cosa che un array serializzato dentro un campo non
    // sarebbe. E' la stessa scelta di home-assistant.json.
    readonly property string path: `${Quickshell.env("HOME")}/.config/quickshell/pet-traits.json`

    // ---- Le sorgenti che si possono collegare ------------------------------
    //
    // Due famiglie, e nessuna delle due aggiunge una sonda: le entita' di Home
    // Assistant le sta gia' scaricando HomeAssistant ogni 15 secondi, e le
    // misure di sistema le sta gia' campionando sysmon.py per tutti gli altri
    // pannelli. Il monitor costa gia' circa il 5% di un core: una lettura in
    // piu' per far muovere un'animazione non varrebbe il prezzo.
    readonly property var systemSources: [
        {
            key: "cpu",
            label: I18n.t("CPU"),
            unit: "%"
        },
        {
            // Quanti telefoni risponde ADB adesso. Non e' una misura come le
            // altre — e' un conteggio, e sale di uno per volta — ma e'
            // esattamente la forma che serve alla meccanica «ogni tot»: con
            // passo 1 e verso «sale di», ogni telefono che si collega fa
            // cadere un oggetto, e uno che si scollega non fa niente.
            key: "adbPhones",
            label: I18n.t("Telefoni via ADB"),
            unit: ""
        },
        {
            key: "memPct",
            label: I18n.t("RAM occupata"),
            unit: "%"
        },
        {
            key: "cpuTemp",
            label: I18n.t("Temperatura CPU"),
            unit: "°C"
        },
        {
            key: "gpuTemp",
            label: I18n.t("Temperatura GPU"),
            unit: "°C"
        },
        {
            key: "gpuUtil",
            label: I18n.t("GPU"),
            unit: "%"
        },
        {
            key: "gpuMemPct",
            label: I18n.t("VRAM occupata"),
            unit: "%"
        },
        {
            key: "cpuWatt",
            label: I18n.t("Consumo CPU"),
            unit: "W"
        },
        {
            key: "gpuWatt",
            label: I18n.t("Consumo GPU"),
            unit: "W"
        },
        {
            key: "powerTotal",
            label: I18n.t("Consumo totale"),
            unit: "W"
        }
    ]

    // ---- Le molecole che si possono disegnare ------------------------------
    //
    // Molecole vere, non geometrie da comporre: si sceglie CO2 e viene la CO2,
    // con l'angolo e le proporzioni che ha. Una in piu' e' una voce di questo
    // elenco, non una riga di PetMolecule.qml — che disegna quello che trova
    // qui e non sa cosa sia un'anidride carbonica.
    //
    // Le coordinate sono in unita' di disegno, moltiplicate poi per la scala
    // del pet. `center: true` marca l'atomo che prende il secondo colore: e'
    // il carbonio nella CO2, l'ossigeno nell'acqua — cioe' quello attorno a cui
    // gli altri stanno, non necessariamente quello in mezzo alla fila.
    //
    // Gli angoli sono quelli veri, perche' costano uguali: 180° per la CO2
    // lineare, 104,5° per l'acqua, 116,8° per l'ozono.
    readonly property var molecules: [
        {
            id: "co2",
            label: "CO₂",
            hint: I18n.t("anidride carbonica, lineare"),
            shape: {
                atoms: [
                    { cx: -3.7, cy: 0, d: 3 },
                    { cx: 0, cy: 0, d: 2.2, center: true },
                    { cx: 3.7, cy: 0, d: 3 }
                ],
                bonds: [
                    { a: 0, b: 1, double: true },
                    { a: 1, b: 2, double: true }
                ]
            }
        },
        {
            id: "h2o",
            label: "H₂O",
            hint: I18n.t("acqua, piegata a 104,5°"),
            shape: {
                atoms: [
                    { cx: 0, cy: 0, d: 3, center: true },
                    { cx: -2.76, cy: 1.73, d: 1.7 },
                    { cx: 2.76, cy: 1.73, d: 1.7 }
                ],
                bonds: [
                    { a: 0, b: 1 },
                    { a: 0, b: 2 }
                ]
            }
        },
        {
            id: "o3",
            label: "O₃",
            hint: I18n.t("ozono, piegata a 116,8°"),
            shape: {
                atoms: [
                    { cx: 0, cy: 0, d: 2.6, center: true },
                    { cx: -3.05, cy: 1.5, d: 2.6 },
                    { cx: 3.05, cy: 1.5, d: 2.6 }
                ],
                bonds: [
                    { a: 0, b: 1 },
                    { a: 0, b: 2 }
                ]
            }
        },
        {
            id: "ch4",
            label: "CH₄",
            hint: I18n.t("metano, un centro e quattro"),
            shape: {
                atoms: [
                    { cx: 0, cy: 0, d: 2.6, center: true },
                    { cx: 0, cy: -3.1, d: 1.6 },
                    { cx: 0, cy: 3.1, d: 1.6 },
                    { cx: -3.1, cy: 0, d: 1.6 },
                    { cx: 3.1, cy: 0, d: 1.6 }
                ],
                bonds: [
                    { a: 0, b: 1 },
                    { a: 0, b: 2 },
                    { a: 0, b: 3 },
                    { a: 0, b: 4 }
                ]
            }
        },
        {
            id: "diatomic",
            label: "O₂",
            hint: I18n.t("biatomica: ossigeno, azoto"),
            shape: {
                atoms: [
                    { cx: -2.2, cy: 0, d: 3 },
                    { cx: 2.2, cy: 0, d: 3 }
                ],
                bonds: [
                    { a: 0, b: 1, double: true }
                ]
            }
        },
        {
            id: "particle",
            label: "•",
            hint: I18n.t("un granello solo: polveri, PM2.5"),
            shape: {
                atoms: [
                    { cx: 0, cy: 0, d: 3 }
                ],
                bonds: []
            }
        }
    ]

    function moleculeById(id: string): var {
        return root.molecules.find(m => m.id === id) ?? root.molecules[0];
    }

    // ---- Gli oggetti che possono cadere ------------------------------------
    //
    // L'altra meccanica: una caratteristica di ruolo "drop" non calcola un
    // benessere, guarda una soglia — e quando il valore ci resta oltre
    // abbastanza a lungo, dal cielo cade uno di questi. Il pet lo prende solo
    // se il suo girovagare ce lo porta sopra, quindi spesso non lo prende.
    //
    // Emoji e non sprite: `pet/assets/` e' verbatim (vedi pet/UPSTREAM.md) e
    // metterci dentro un PNG nostro vorrebbe dire un file in piu' da spiegare
    // al prossimo aggiornamento da monte. Un glifo di testo non ha ritaglio,
    // non ha licenza, e cresce col pet cambiando una sola pixelSize.
    //
    // 🔴 `gift` e' in punti UNA TANTUM, non all'ora come `effects`: e' la
    // differenza fra le due meccaniche, ed e' il motivo per cui la chiave si
    // chiama diversamente invece di riusare quella. Il metro sono le cure di
    // Pet.js — mangiare +40, giocare +30, lavare +35, dormire +50 — e un
    // oggetto ne vale circa un terzo: si sente, ma non sostituisce i pulsanti.
    //
    // 🔴 Il peperoncino e la ragnatela hanno il selettore emoji (U+FE0F)
    // attaccato apposta: quei due caratteri da soli hanno presentazione TESTO,
    // e senza il selettore uscirebbero monocromatici in mezzo a tutti gli
    // altri a colori. Chi aggiunge una voce qui lo controlli: la regola non e'
    // «gli emoji sono a colori», e' «alcuni lo sono solo se glielo si chiede».
    //
    // I glifi di macchina sono a tema apposta: le caratteristiche che li fanno
    // cadere leggono la macchina. Un fuoco che arriva perche' la CPU scotta si
    // capisce da solo, una mela per lo stesso motivo va spiegata.
    readonly property var builtinDropItems: [
        {
            id: "apple",
            glyph: "🍎",
            label: I18n.t("mela"),
            kind: "bonus",
            hint: I18n.t("sazia"),
            gift: { hunger: 14, energy: 0, happiness: 4, hygiene: 0 }
        },
        {
            id: "pear",
            glyph: "🍐",
            label: I18n.t("pera"),
            kind: "bonus",
            hint: I18n.t("sazia e rimette in forze"),
            gift: { hunger: 10, energy: 5, happiness: 2, hygiene: 0 }
        },
        {
            id: "pineapple",
            glyph: "🍍",
            label: I18n.t("ananas"),
            kind: "bonus",
            hint: I18n.t("sazia e mette allegria"),
            gift: { hunger: 8, energy: 0, happiness: 10, hygiene: 0 }
        },
        {
            id: "candy",
            glyph: "🍬",
            label: I18n.t("caramella"),
            kind: "bonus",
            hint: I18n.t("allegria, ma appiccica"),
            gift: { hunger: 4, energy: 4, happiness: 14, hygiene: -4 }
        },
        {
            id: "coffee",
            glyph: "☕",
            label: I18n.t("caffè"),
            kind: "bonus",
            hint: I18n.t("sveglia: ridà energia"),
            gift: { hunger: 2, energy: 14, happiness: 2, hygiene: 0 }
        },
        {
            id: "battery",
            glyph: "🔋",
            label: I18n.t("batteria carica"),
            kind: "bonus",
            hint: I18n.t("ricarica: molta energia"),
            gift: { hunger: 0, energy: 16, happiness: 0, hygiene: 0 }
        },
        {
            id: "ice",
            glyph: "🧊",
            label: I18n.t("ghiaccio"),
            kind: "bonus",
            hint: I18n.t("rinfresca: energia e buonumore"),
            gift: { hunger: 0, energy: 8, happiness: 4, hygiene: 0 }
        },
        {
            id: "gamepad",
            glyph: "🎮",
            label: I18n.t("videogioco"),
            kind: "bonus",
            hint: I18n.t("si gioca: mette allegria"),
            gift: { hunger: 0, energy: 0, happiness: 14, hygiene: 0 }
        },
        {
            id: "chili",
            glyph: "🌶️",
            label: I18n.t("peperoncino"),
            kind: "malus",
            hint: I18n.t("brucia: toglie energia"),
            gift: { hunger: 0, energy: -12, happiness: 0, hygiene: 0 }
        },
        {
            id: "mushroom",
            glyph: "🍄",
            label: I18n.t("fungo"),
            kind: "malus",
            hint: I18n.t("amaro: toglie allegria"),
            gift: { hunger: 0, energy: 0, happiness: -12, hygiene: 0 }
        },
        {
            id: "fishbone",
            glyph: "🐟",
            label: I18n.t("lisca"),
            kind: "malus",
            hint: I18n.t("sporca: toglie pulizia"),
            gift: { hunger: 2, energy: 0, happiness: 0, hygiene: -14 }
        },
        {
            id: "can",
            glyph: "🥫",
            label: I18n.t("lattina"),
            kind: "malus",
            hint: I18n.t("avanzi: toglie sazietà"),
            gift: { hunger: -12, energy: 0, happiness: 0, hygiene: 0 }
        },
        {
            id: "lemon",
            glyph: "🍋",
            label: I18n.t("limone"),
            kind: "malus",
            hint: I18n.t("aspro: toglie un po' di allegria"),
            gift: { hunger: 0, energy: 0, happiness: -10, hygiene: 0 }
        },
        {
            id: "bomb",
            glyph: "💣",
            label: I18n.t("bomba"),
            kind: "malus",
            hint: I18n.t("scoppia: toglie a tutte e quattro"),
            gift: { hunger: -8, energy: -8, happiness: -8, hygiene: -8 }
        },
        {
            id: "flame",
            glyph: "🔥",
            label: I18n.t("fiammata"),
            kind: "malus",
            hint: I18n.t("surriscalda: toglie energia"),
            gift: { hunger: 0, energy: -12, happiness: 0, hygiene: 0 }
        },
        {
            id: "bug",
            glyph: "🐛",
            label: I18n.t("baco"),
            kind: "malus",
            hint: I18n.t("un baco: toglie allegria"),
            gift: { hunger: 0, energy: 0, happiness: -12, hygiene: 0 }
        },
        {
            id: "lowbattery",
            glyph: "🪫",
            label: I18n.t("batteria scarica"),
            kind: "malus",
            hint: I18n.t("si scarica: toglie molta energia"),
            gift: { hunger: 0, energy: -14, happiness: 0, hygiene: 0 }
        },
        {
            id: "cobweb",
            glyph: "🕸️",
            label: I18n.t("ragnatela"),
            kind: "malus",
            hint: I18n.t("trascurato: toglie pulizia"),
            gift: { hunger: 0, energy: 0, happiness: 0, hygiene: -12 }
        }
    ]

    // ---- Gli oggetti aggiunti dall'utente ----------------------------------
    //
    // Quelli di serie sono dieci e stanno nel codice; questi arrivano da un
    // file, si aggiungono dalla finestra col pulsante «+ emoji» e valgono
    // esattamente quanto gli altri — stesso schema, stessi chip, stesso posto
    // nel catalogo.
    //
    // Un file suo e non pet-traits.json, che e' un array di CARATTERISTICHE:
    // mettere due specie di oggetti nello stesso elenco vorrebbe dire un
    // filtro in lettura per distinguerli, e la prima riga scritta a mano male
    // finirebbe per essere una caratteristica senza sensore. Stessa scelta,
    // stesse ragioni, dello sdoppiamento fra dashboard.json e questo file.
    readonly property string dropItemsPath: `${Quickshell.env("HOME")}/.config/quickshell/pet-drop-items.json`

    property var customDropItems: []

    // Il catalogo intero: prima quelli di serie, poi i propri. L'ordine e'
    // anche quello dei chip, e i propri in coda vuol dire che aggiungerne uno
    // non sposta quelli che si e' imparato dove stanno.
    readonly property var dropItems: root.builtinDropItems.concat(root.customDropItems)

    function dropItemById(id: string): var {
        return root.dropItems.find(d => d.id === id) ?? root.dropItems[0];
    }

    function isCustomDropItem(id: string): bool {
        return root.customDropItems.some(d => d.id === id);
    }

    // 🔴 Il glifo si ripulisce, non si valida: qui dentro puo' arrivare
    // qualunque cosa un incolla porti con se'. Via gli spazi e i caratteri di
    // controllo — uno «a capo» invisibile in mezzo a un chip lo manderebbe a
    // due righe senza che nessuno capisca perche' — e taglio a otto punti di
    // codice, che tengono anche le sequenze lunghe (👨‍💻 ne usa tre, una
    // bandiera due) senza lasciar incollare un paragrafo intero.
    //
    // Il taglio conta i PUNTI DI CODICE e non i caratteri: `slice(0, 8)` su
    // una stringa JavaScript taglia a meta' delle coppie surrogate, e mezzo
    // emoji e' un quadratino.
    function sanitizeGlyph(raw: var): string {
        if (typeof raw !== "string")
            return "";
        const clean = raw.replace(/[\s\u0000-\u001f\u007f]/g, "");
        return Array.from(clean).slice(0, 8).join("");
    }

    // Aggiunge un oggetto e ne torna l'id, o "" se non c'era niente da
    // aggiungere. L'id viene dal primo punto di codice del glifo: e' stabile,
    // si legge nel file («custom_1f355» e' la pizza) e non cambia se poi si
    // rinomina l'etichetta — la stessa regola degli id delle caratteristiche.
    function addDropItem(rawGlyph: var, rawLabel: var, kind: string): string {
        const glyph = root.sanitizeGlyph(rawGlyph);
        if (glyph.length === 0)
            return "";

        const taken = root.dropItems.map(d => d.id);
        const stem = `custom_${glyph.codePointAt(0).toString(16)}`;
        let id = stem;
        let n = 2;
        while (taken.includes(id)) {
            id = `${stem}_${n}`;
            n++;
        }

        const label = typeof rawLabel === "string" && rawLabel.trim().length > 0 ? rawLabel.trim().slice(0, 16) : glyph;
        const sign = kind === "malus" ? -1 : 1;

        root.saveDropItems(root.customDropItems.concat([
            {
                id: id,
                glyph: glyph,
                label: label,
                kind: kind === "malus" ? "malus" : "bonus",
                // Non zero: un oggetto che non fa niente e' indistinguibile da
                // un guasto, e chi lo prova la prima volta concluderebbe che
                // la cosa non funziona. Dieci punti di allegria sono un
                // effetto che si vede, ed e' il piu' innocuo dei quattro da
                // dare a un oggetto di cui non sappiamo niente. I numeri veri
                // si scrivono nei quattro campi sotto.
                gift: {
                    hunger: 0,
                    energy: 0,
                    happiness: 10 * sign,
                    hygiene: 0
                }
            }
        ]));

        return id;
    }

    function removeDropItem(id: string) {
        root.saveDropItems(root.customDropItems.filter(d => d.id !== id));
    }

    function saveDropItems(next: var) {
        root.customDropItems = next;
        dropItemsFile.setText(JSON.stringify(next, null, 2) + "\n");
    }

    // Il valore grezzo di una sorgente, o null se non si sa.
    //
    // 🔴 null e' un esito previsto, non un guasto: Home Assistant puo' essere
    // spento, un'entita' puo' essere sparita, un sensore puo' rispondere
    // "unavailable". Chi legge deve distinguere «non lo so» da «zero», perche'
    // uno zero finto qui vorrebbe dire un pet che si ammala per un sensore
    // rotto — vedi la nota su `wellness`.
    function rawValue(source: string): var {
        if (!source)
            return null;

        if (source.startsWith("ha:")) {
            const text = HomeAssistant.state(source.slice(3));
            if (text === "" || text === "unavailable" || text === "unknown")
                return null;
            const n = parseFloat(text);
            return isFinite(n) ? n : null;
        }

        if (source.startsWith("sys:")) {
            const key = source.slice(4);

            // Qualunque sensore hwmon, per chiave: sono gia' tutti in
            // SystemStats.temps, quindi collegare la sonda del chipset non
            // richiede una riga in piu' qui dentro.
            if (key.startsWith("temp:")) {
                const sensor = SystemStats.sensor(key.slice(5));
                return sensor ? SystemStats.tempOf(sensor) : null;
            }

            switch (key) {
            case "cpu":
                return SystemStats.cpu;
            // 🔴 null finche' la prima risposta non e' arrivata, e non zero:
            // zero vorrebbe dire «nessun telefono collegato», e la meccanica a
            // passo lo leggerebbe come una salita da 0 appena arriva la
            // risposta vera — un bonus regalato all'avvio per un telefono che
            // era gia' li'. E' la stessa distinzione fra «non lo so» e «zero»
            // che regge tutto il resto di questo file.
            case "adbPhones":
                return PhoneAdb.linksKnown ? PhoneAdb.connectedCount : null;
            case "memPct":
                return SystemStats.mem.pct;
            case "cpuTemp":
                return SystemStats.cpuSensor ? SystemStats.tempOf(SystemStats.cpuSensor) : null;
            case "gpuTemp":
                return SystemStats.gpu ? SystemStats.gpu.temp : null;
            case "gpuUtil":
                return SystemStats.gpu ? SystemStats.gpu.util : null;
            case "gpuMemPct":
                return SystemStats.gpu ? SystemStats.gpu.memPct : null;
            case "cpuWatt":
                return SystemStats.power.cpu;
            case "gpuWatt":
                return SystemStats.power.gpu;
            case "powerTotal":
                return SystemStats.power.total;
            }
        }

        return null;
    }

    function sourceUnit(source: string): string {
        if (!source)
            return "";
        if (source.startsWith("ha:"))
            return HomeAssistant.unit(source.slice(3));
        if (source.startsWith("sys:")) {
            if (source.startsWith("sys:temp:"))
                return "°C";
            const found = root.systemSources.find(s => `sys:${s.key}` === source);
            return found ? found.unit : "";
        }
        return "";
    }

    function sourceName(source: string): string {
        if (!source)
            return "";
        if (source.startsWith("ha:"))
            return HomeAssistant.friendlyName(source.slice(3));
        if (source.startsWith("sys:")) {
            if (source.startsWith("sys:temp:")) {
                const sensor = SystemStats.sensor(source.slice(9));
                return sensor ? sensor.label : source.slice(9);
            }
            const found = root.systemSources.find(s => `sys:${s.key}` === source);
            return found ? found.label : source.slice(4);
        }
        return source;
    }

    // ---- Il benessere ------------------------------------------------------
    //
    // Da 0 a 100, con la stessa scala delle quattro statistiche del gioco: cosi'
    // la barra si legge insieme alle altre e la soglia «a zero il pet sta male»
    // e' una sola per tutte.
    //
    // Tre versi, perche' i sensori non vogliono tutti la stessa cosa:
    //   low   meglio in basso  — CO2, temperatura della CPU
    //   high  meglio in alto   — una batteria
    //   band  meglio in mezzo  — l'umidita', che sbaglia da tutte e due le parti
    //
    // La rampa e' lineare fra `good` (100) e `bad` (0) e piatta oltre i due
    // estremi: fuori dal campo il pet non sta «meno di zero», sta male e basta.
    function rampDown(v, good, bad) {
        if (v <= good)
            return 100;
        if (v >= bad)
            return 0;
        return 100 * (bad - v) / (bad - good);
    }

    function wellnessOf(trait: var, value: var): var {
        // 🔴 Valore ignoto = benessere ignoto, non zero. E' la regola che
        // impedisce a un sensore staccato di uccidere il pet: chi legge trova
        // null e non lo conta, invece di trovare 0 e far partire l'orologio
        // della malattia su un dato che non c'e'.
        if (value === null || value === undefined || !isFinite(value))
            return null;

        const dir = trait.direction ?? "low";

        if (dir === "high")
            return root.rampDown(-value, -(trait.good ?? 0), -(trait.bad ?? 0));

        if (dir === "band") {
            // Due rampe, e vince la peggiore: un valore fuori da una delle due
            // parti sta male quanto se fosse fuori dall'altra.
            const low = root.rampDown(-value, -(trait.good ?? 0), -(trait.lowBad ?? 0));
            const high = root.rampDown(value, trait.goodHigh ?? trait.good ?? 0, trait.bad ?? 0);
            return Math.min(low, high);
        }

        return root.rampDown(value, trait.good ?? 0, trait.bad ?? 0);
    }

    // Le caratteristiche risolte: quello che il pannello e la finestra
    // disegnano. Si rifa' da solo quando cambia uno stato di Home Assistant o
    // un campione di sysmon, perche' legge le loro proprieta' dentro il binding.
    readonly property var list: root.traits.map(t => {
        const role = root.roleOf(t);
        const value = root.rawValue(t.source);
        // 🔴 Una caratteristica che fa cadere oggetti non ha benessere, e non
        // e' un dettaglio di presentazione: un benessere a zero la farebbe
        // contare fra le critiche e ammalerebbe il pet per una soglia che
        // serve a far cadere una mela. Si spegne QUI, una volta sola, invece
        // di chiedere a ognuno dei suoi lettori di ricordarsi di filtrare.
        const wellness = role === "drop" ? null : root.wellnessOf(t, value);
        const unit = t.unit && t.unit.length > 0 ? t.unit : root.sourceUnit(t.source);
        return {
            id: t.id,
            role: role,
            label: t.label && t.label.length > 0 ? t.label : root.sourceName(t.source),
            source: t.source,
            value: value,
            unit: unit,
            // Il numero vero accanto alla percentuale: un benessere all'82%
            // non dice cosa andare a cambiare, «1120 ppm» si'.
            text: value === null ? I18n.t("n/d") : `${root.pretty(value)}${unit ? " " + unit : ""}`,
            min: t.min ?? 0,
            max: t.max ?? 100,
            // Dove sta il valore dentro il campo della barra, da 0 a 1.
            fill: value === null ? 0 : Math.max(0, Math.min(1, (value - (t.min ?? 0)) / Math.max(1e-9, (t.max ?? 100) - (t.min ?? 0)))),
            wellness: wellness,
            critical: role === "wellness" && wellness !== null && wellness <= 0,
            particles: role === "wellness" && t.particles === true,
            // Se questa caratteristica si mostra come barra sua nella stanza.
            // Chi la spegne tiene solo l'effetto sulle quattro statistiche —
            // che e' il punto: un pet con otto barre non e' un pet, e' un
            // cruscotto.
            bar: role === "wellness" && t.bar !== false,
            // I pesi con cui muove le quattro statistiche del gioco, in punti
            // all'ora. Sempre tutti e quattro, cosi' chi legge non deve
            // controllare se una chiave c'e'.
            effects: role === "drop" ? ({
                    hunger: 0,
                    energy: 0,
                    happiness: 0,
                    hygiene: 0
                }) : root.effectsOf(t),
            // Tutto quello che serve a disegnare la nuvola, gia' risolto: la
            // forma vera al posto del suo nome, i colori con i loro ripieghi e
            // il passo. Cosi' PetMolecules non deve conoscere ne' il catalogo
            // ne' i default — disegna quello che gli arriva.
            particle: role !== "wellness" || t.particles !== true ? null : ({
                    shape: root.moleculeById(t.molecule ?? "co2").shape,
                    outerColor: t.outerColor ?? "#58a6ff",
                    centerColor: t.centerColor ?? "#8b949e",
                    bondColor: t.bondColor ?? "#8b949e",
                    step: t.particleStep > 0 ? t.particleStep : root.defaultStep(t.min ?? 0, t.max ?? 100),
                    base: t.particleBase !== undefined ? t.particleBase : (t.min ?? 0)
                }),
            // Tutto quello che serve alla caduta, gia' risolto — come
            // `particle` qui sopra: chi lo consuma non deve conoscere ne' il
            // catalogo ne' i ripieghi, e i minuti sono gia' millisecondi.
            drop: role !== "drop" ? null : ({
                    threshold: typeof t.threshold === "number" && isFinite(t.threshold) ? t.threshold : 0,
                    // Quattro modi di far cadere una cosa, non due. I primi due
                    // guardano DOVE STA il valore e vogliono che ci resti;
                    // "rise" e "fall" guardano invece QUANTO SI E' MOSSO, e
                    // cadono ogni `step` unita' percorse nella loro direzione.
                    // La differenza non e' cosmetica: una batteria che si
                    // carica passa da 20 a 80 una volta sola, quindi «sopra 50»
                    // vale un oggetto per ricarica, mentre «sale di 500 mAh» ne
                    // vale uno ogni 500 mAh — che e' il modo in cui si premia
                    // una cosa che si accumula invece di una che sta ferma.
                    when: t.dropWhen === "below" ? "below"
                        : (t.dropWhen === "rise" || t.dropWhen === "fall" ? t.dropWhen : "above"),
                    // Gia' risolto per chi consuma, come `item` e `gift`: la
                    // stessa ragione per cui i minuti qui sotto sono
                    // millisecondi. Chi legge non deve conoscere l'elenco dei
                    // modi per sapere quale delle due meccaniche gli tocca.
                    every: t.dropWhen === "rise" || t.dropWhen === "fall",
                    // Quante unita' del sensore valgono un oggetto. Il ripiego
                    // e' lo stesso passo che le molecole usano per contarsi —
                    // un quarantesimo del campo, arrotondato a 1/2/5 — perche'
                    // e' la stessa domanda: «ogni quanto, su questa scala, e'
                    // un numero che si capisce».
                    //
                    // 🔴 Mai zero o negativo: e' il divisore della meccanica,
                    // e un passo nullo vorrebbe dire un oggetto a ogni giro del
                    // timer per sempre.
                    step: typeof t.step === "number" && isFinite(t.step) && t.step > 0
                          ? t.step : root.defaultStep(t.min ?? 0, t.max ?? 100),
                    // Un minimo di un secondo perche' una soglia con attesa
                    // zero, scritta a mano, farebbe cadere un oggetto a ogni
                    // giro del timer finche' la condizione resta vera.
                    holdMs: Math.max(1000, (typeof t.holdMinutes === "number" && isFinite(t.holdMinutes) ? t.holdMinutes : 5) * 60000),
                    cooldownMs: Math.max(0, (typeof t.cooldownMinutes === "number" && isFinite(t.cooldownMinutes) ? t.cooldownMinutes : 10) * 60000),
                    item: root.dropItemById(t.item ?? "apple"),
                    gift: root.giftOf(t)
                })
        };
    })

    // ---- Gli effetti sulle quattro statistiche -----------------------------
    //
    // Le quattro statistiche del gioco — fame, energia, felicita', pulizia —
    // decadono da sole dentro Pet.js. Una caratteristica puo' spingerle o
    // tirarle, con un peso in PUNTI ALL'ORA per ognuna:
    //
    //     delta = peso × (benessere / 50 − 1) × ore
    //
    //   benessere 100 → +peso all'ora   (l'aria buona ricarica)
    //   benessere  50 → zero
    //   benessere   0 → −peso all'ora   (l'aria cattiva scarica)
    //
    // Il segno copre anche il caso storto ma sensato: in Pet.js `hunger` 100 e'
    // SAZIO, quindi un peso negativo sulla fame vuol dire «quando sta bene si
    // muove di piu' e gli viene fame».
    //
    // Per la misura, i tassi con cui il gioco scarica da solo (Pet.js): fame
    // 20, energia 12,5, felicita' 16,7, pulizia 25 punti all'ora. Un peso di
    // ±10 e' quindi meta' del decadimento naturale, cioe' un effetto forte.
    readonly property var statKeys: ["hunger", "energy", "happiness", "hygiene"]

    // ---- Il ruolo ----------------------------------------------------------
    //
    // Due meccaniche, e una caratteristica ne fa una sola:
    //   wellness  legge un sensore, calcola un benessere e spinge le quattro
    //             statistiche di qualche punto all'ora — quella di sempre
    //   drop      guarda una soglia e fa cadere un oggetto nella stanza
    //
    // 🔴 La migrazione e' tutta qui, in questa riga: campo assente = benessere.
    // Le caratteristiche scritte prima che i ruoli esistessero non hanno il
    // campo e restano quello che erano, senza che nessuno riscriva il file e
    // senza un passo di conversione da mantenere per sempre.
    function roleOf(trait: var): string {
        return trait && trait.role === "drop" ? "drop" : "wellness";
    }

    // I punti una tantum di un oggetto raccolto. Se la caratteristica non li ha
    // scritti valgono quelli del catalogo: un file corretto a mano puo' dire
    // solo `"item": "bomb"` ed e' gia' una configurazione completa.
    function giftOf(trait: var): var {
        const item = root.dropItemById(trait && trait.item ? trait.item : "apple");
        const raw = trait && trait.gift ? trait.gift : item.gift;
        const out = {};
        for (const k of root.statKeys) {
            const v = raw[k];
            out[k] = typeof v === "number" && isFinite(v) ? v : 0;
        }
        return out;
    }

    function effectsOf(trait: var): var {
        const raw = trait && trait.effects ? trait.effects : ({});
        const out = {};
        for (const k of root.statKeys) {
            const v = raw[k];
            out[k] = typeof v === "number" && isFinite(v) ? v : 0;
        }
        return out;
    }

    // Quanti punti all'ora sta applicando adesso questa caratteristica a questa
    // statistica. Serve al pannello per applicarli e alla finestra per
    // mostrarli — un peso scritto nel file non dice da solo se e' forte.
    //
    // Benessere ignoto = nessun effetto. E' la stessa regola del sensore
    // staccato che non fa ammalare il pet, applicata qui: di un valore che non
    // abbiamo non si deduce niente, ne' in bene ne' in male.
    function rateNow(trait: var, key: string): real {
        if (!trait || trait.wellness === null || trait.wellness === undefined)
            return 0;
        const w = trait.effects ? (trait.effects[key] ?? 0) : 0;
        if (w === 0)
            return 0;
        return w * (trait.wellness / 50 - 1);
    }

    // Il passo di partenza: quante unita' vere per una molecola.
    //
    // Scelto perche' in cima al campo si arrivi al tetto — quaranta molecole a
    // fondoscala — cosi' chi non lo tocca vede una nuvola che riempie la stanza
    // esattamente quando la barra e' piena. Per la CO2 su 400-2000 fa 40 ppm a
    // molecola, che e' anche il numero che si direbbe a mano.
    //
    // Arrotondato a una cifra tonda, perche' e' un numero che si legge nelle
    // opzioni e «40» si capisce mentre «41,03» fa solo sembrare che ci sia una
    // ragione dietro la seconda cifra.
    function defaultStep(min: real, max: real): real {
        const raw = Math.max(1e-6, (max - min) / 40);
        const mag = Math.pow(10, Math.floor(Math.log(raw) / Math.LN10));
        const n = raw / mag;
        const nice = n < 1.5 ? 1 : (n < 3.5 ? 2 : (n < 7.5 ? 5 : 10));
        return nice * mag;
    }

    // ---- Le due famiglie ---------------------------------------------------
    //
    // 🔴 Tutto quello che riguarda la salute del pet guarda `wellnessTraits` e
    // mai `list`. La rete c'e' gia' dentro `list` (una caratteristica "drop"
    // esce con benessere nullo e barra spenta), ma non basterebbe per
    // `anyUnknown`: quella diventerebbe VERA PER SEMPRE appena esiste una
    // caratteristica che fa cadere oggetti, e quella proprieta' esiste per
    // dire «una lettura e' mancata», non «c'e' qualcosa senza benessere».
    readonly property var wellnessTraits: root.list.filter(t => t.role === "wellness")

    // Quelle che fanno cadere oggetti. Le legge panels/PetPanel.qml, che
    // possiede l'orologio: qui non si decide quando cade niente.
    readonly property var dropTraits: root.list.filter(t => t.role === "drop")

    // Almeno una caratteristica e' a zero: al pannello serve solo questo per
    // far partire l'orologio.
    readonly property bool anyCritical: root.wellnessTraits.some(t => t.critical)

    // 🔴 E almeno una non si sa leggere. Serve perche' «non lo so» non e' una
    // guarigione: senza questa distinzione, una sola lettura mancata di Home
    // Assistant — un poll andato storto, un riavvio del contenitore — azzerava
    // un orologio che poteva avere ore dentro. Misurato: badMs passato da
    // 14.945 a 0 mentre la CO2 era sempre alta.
    //
    // La regola giusta e' in tre stati e non in due: qualcosa di critico fa
    // salire, tutto letto e a posto azzera, e un buco di lettura TIENE FERMO.
    readonly property bool anyUnknown: root.wellnessTraits.some(t => t.wellness === null)

    // La peggiore fra quelle che si sanno leggere, per il messaggio del
    // pannello: dire «qualcosa non va» senza dire cosa manderebbe a cercare.
    readonly property var worst: {
        let found = null;
        for (const t of root.wellnessTraits) {
            if (t.wellness === null)
                continue;
            if (found === null || t.wellness < found.wellness)
                found = t;
        }
        return found;
    }

    // TUTTE le caratteristiche che chiedono le molecole, non la prima.
    //
    // 🔴 Qui c'era un `find`, ed era un guasto: con CO2 e igrometro tutti e due
    // a molecole accese, l'igrometro non disegnava niente e nessuno diceva
    // perche'. La scusa era che due nuvole non si sarebbero distinte — vera
    // finche' le molecole erano tutte uguali, falsa da quando ognuna ha la sua
    // forma e i suoi colori: H2O ciano su viola accanto a CO2 blu su grigio si
    // riconoscono a colpo d'occhio.
    readonly property var particleTraits: root.wellnessTraits.filter(t => t.particles && t.value !== null)

    // Le caratteristiche che vogliono una barra nella stanza.
    //
    // ⚠️ NESSUNO LA LEGGE PIU', e non e' una svista: da quando le statistiche
    // stanno in una riga sola di icone in cima al pannello, le barre non
    // esistono — vedi la modifica 9 in pet/UPSTREAM.md. Il campo `bar` resta
    // nel catalogo e la sua spunta resta nelle opzioni per scelta, cosi' chi
    // ce l'ha acceso non se lo vede sparire dal file; semplicemente non
    // disegna niente. Chi rimette una vista per queste, riparta da qui.
    readonly property var barTraits: root.wellnessTraits.filter(t => t.bar)

    // ---- I valori di partenza di una caratteristica nuova ------------------
    //
    // Non zero e cento: una CO2 su un campo 0-100 sarebbe una barra sempre
    // piena, e chi la collega si troverebbe a doverla configurare prima di
    // capire se ha collegato quella giusta. Le unita' che si riconoscono hanno
    // il campo che ci si aspetta; per le altre si costruisce attorno al valore
    // di adesso, che e' il solo indizio disponibile.
    //
    // Sta nel singleton e non nella finestra che aggiunge perche' serve in due
    // posti: li' quando si aggiunge, e in PetTraitRow quando si cambia ruolo a
    // una caratteristica che c'e' gia' — che ha bisogno esattamente dei campi
    // che l'altro ruolo non ha mai scritto.
    function defaultsFor(source: string, value: real, role: string): var {
        const unit = root.sourceUnit(source);
        let base;

        if (unit === "ppm")
            base = {
                min: 400,
                max: 2000,
                direction: "low",
                good: 800,
                bad: 1600,
                particles: true,
                atoms: 3
            };
        else if (unit === "°C")
            base = {
                min: 20,
                max: 100,
                direction: "low",
                good: 60,
                bad: 90
            };
        else if (unit === "%")
            base = {
                min: 0,
                max: 100,
                direction: "low",
                good: 60,
                bad: 90
            };
        else if (unit === "W")
            base = {
                min: 0,
                max: Math.max(50, Math.ceil(value * 2 / 10) * 10),
                direction: "low",
                good: Math.ceil(value * 1.2),
                bad: Math.ceil(value * 2)
            };
        else {
            const top = Math.max(10, Math.ceil(Math.max(value * 2, value + 10)));
            base = {
                min: 0,
                max: top,
                direction: "low",
                good: Math.round(top * 0.4),
                bad: Math.round(top * 0.8)
            };
        }

        if (role !== "drop")
            return base;

        // La soglia di partenza e' il `bad` del benessere: e' gia' il numero
        // che vuol dire «qui le cose vanno male», e ricalcolarlo con un secondo
        // elenco di unita' vorrebbe dire due tabelle da tenere d'accordo.
        return {
            role: "drop",
            threshold: base.bad,
            dropWhen: base.direction === "high" ? "below" : "above",
            // Scritto anche quando il modo di partenza e' a soglia: chi passa
            // dopo a «sale di» trova gia' un passo sensato invece di uno zero
            // da correggere prima che la meccanica faccia qualcosa.
            step: root.defaultStep(base.min ?? 0, base.max ?? 100),
            holdMinutes: 5,
            cooldownMinutes: 10,
            item: "chili",
            gift: root.dropItemById("chili").gift
        };
    }

    function pretty(v: real): string {
        const a = Math.abs(v);
        if (a >= 100)
            return v.toFixed(0);
        if (a >= 10)
            return v.toFixed(1);
        return v.toFixed(2);
    }

    // ---- Scrittura ---------------------------------------------------------
    // Chiamate dalla finestra delle caratteristiche. Riscrivono il file intero:
    // sono manciate di oggetti, e una riscrittura sola tiene lontano il caso in
    // cui due modifiche parziali si incrociano.
    function save(next: var) {
        root.traits = next;
        file.setText(JSON.stringify(next, null, 2) + "\n");
    }

    function upsert(trait: var) {
        const next = root.traits.filter(t => t.id !== trait.id).concat([trait]);
        root.save(next);
    }

    function remove(id: string) {
        root.save(root.traits.filter(t => t.id !== id));
    }

    // Il gambo dell'id, dalla sorgente: lettere e numeri, il resto diventa un
    // trattino basso. E' stabile, si legge nel file e non cambia se poi si
    // rinomina l'etichetta — la stessa regola degli id degli oggetti.
    //
    // Sta qui e non nella finestra perche' adesso ha due chiamanti: la finestra
    // che aggiunge a mano e Query.petAct, che aggiunge per conto del server
    // MCP. Due copie della stessa regex vorrebbero dire due id diversi per la
    // stessa entita' a seconda di chi l'ha creata.
    function idFor(source: string): string {
        return source.replace(/^(ha:|sys:)/, "").replace(/[^a-zA-Z0-9]+/g, "_").replace(/^_+|_+$/g, "").slice(0, 24) || "trait";
    }

    // Un id che nessun'altra caratteristica ha gia': due con lo stesso id si
    // farebbero la gara per la stessa riga, e la seconda sparirebbe in silenzio.
    function freeId(base: string): string {
        const taken = root.traits.map(t => t.id);
        let id = base;
        let n = 2;
        while (taken.includes(id)) {
            id = `${base}${n}`;
            n++;
        }
        return id;
    }

    // Lo stesso trattamento del file delle caratteristiche, e per le stesse
    // ragioni scritte la' sotto: niente atomicWrites (l'inode cambierebbe e il
    // guardiano resterebbe attaccato a quello vecchio), e il file vuoto si
    // scrive lo stesso, perche' un FileView non puo' guardare un percorso che
    // non esiste.
    FileView {
        id: dropItemsFile

        path: root.dropItemsPath
        watchChanges: true
        printErrors: false
        preload: true

        onFileChanged: dropItemsFile.reload()

        onLoaded: {
            try {
                const parsed = JSON.parse(dropItemsFile.text());
                // Si tiene quello che ha un id e un glifo, e il resto si
                // butta: una riga sbagliata non deve portarsi dietro le altre.
                root.customDropItems = Array.isArray(parsed) ? parsed.filter(d => d && typeof d.id === "string" && typeof d.glyph === "string" && d.glyph.length > 0).map(d => ({
                            id: d.id,
                            glyph: root.sanitizeGlyph(d.glyph),
                            label: typeof d.label === "string" && d.label.length > 0 ? d.label.slice(0, 16) : d.glyph,
                            kind: d.kind === "malus" ? "malus" : "bonus",
                            hint: typeof d.hint === "string" ? d.hint : "",
                            gift: d.gift ?? ({})
                        })) : [];
            } catch (e) {
                root.customDropItems = [];
            }
        }

        onLoadFailed: error => {
            root.customDropItems = [];
            if (error === FileViewError.FileNotFound)
                dropItemsFile.setText("[]\n");
        }
    }

    FileView {
        id: file

        path: root.path
        watchChanges: true
        printErrors: false
        preload: true

        // Il file si puo' correggere a mano mentre la dashboard gira, come i
        // dizionari di I18n: si salva e la stanza cambia.
        //
        // 🔴 Niente `atomicWrites`. Una scrittura atomica sostituisce il file
        // con un rename, cioe' cambia l'inode, e chi stava guardando quello di
        // prima smette di vedere le modifiche successive. Qui il file e' nostro,
        // piccolo, e riscritto intero: l'atomicita' comprava poco e costava il
        // ricaricamento a caldo, che e' la ragione per cui questo file esiste
        // modificabile a mano.
        onFileChanged: file.reload()

        onLoaded: {
            try {
                const parsed = JSON.parse(file.text());
                // Un file scritto a mano puo' contenere qualunque cosa. Si
                // tiene quello che ha almeno un id e una sorgente e si butta il
                // resto, invece di rifiutare tutto: una riga sbagliata non deve
                // portarsi dietro le altre.
                root.traits = Array.isArray(parsed) ? parsed.filter(t => t && typeof t.id === "string" && typeof t.source === "string") : [];
                root.lastError = "";
            } catch (e) {
                root.traits = [];
                root.lastError = I18n.t("pet-traits.json illeggibile: %1").arg(e);
            }
            root.loaded = true;
        }

        // Nessun file: nessuna caratteristica. Non e' un guasto, e' il caso
        // normale di chi non ne ha ancora aggiunta una.
        //
        // 🔴 Ma il file vuoto si scrive lo stesso, ed e' una correzione, non
        // un vezzo: un FileView non puo' guardare un percorso che non esiste,
        // quindi senza questa riga un pet-traits.json creato DOPO l'avvio non
        // veniva mai letto — la caratteristica non compariva e nessuno diceva
        // perche'. Misurato: con le soglie gia' sul disco al riavvio
        // l'orologio partiva, scrivendole a caldo no.
        //
        // E' lo stesso rimedio che usano gia' Settings (`onLoadFailed` scrive i
        // default) e I18n, che tiene un lang/it.json vuoto apposta — «tenere il
        // percorso sempre valido costa un file di due caratteri e toglie un
        // caso speciale da qui».
        onLoadFailed: error => {
            root.traits = [];
            root.lastError = "";
            root.loaded = true;
            if (error === FileViewError.FileNotFound)
                file.setText("[]\n");
        }
    }
}
