import QtQuick
import QtQuick.Layouts
import QtQuick.Window
import Quickshell
import Quickshell.Io

// Il pannello sta in panels/: senza `import ".."` si caricherebbe lo stesso,
// ma Settings, I18n, SystemStats e PetRoom resterebbero indefiniti — vedi
// scripts/panels.py, che verifica la riga e lo dice.
import ".."
// La stanza e il gioco stanno in pet/, in una cartella loro perche' sono
// codice di terzi: `import ".."` da' i singleton della radice, questo da'
// PetRoom. Vedi pet/UPSTREAM.md.
import "../pet"
import "../pet/Pet.js" as Pet

// Bitmochi: il pet a pixel che vive nella colonna.
//
// Il gioco e' di Ghaith Alsirawan (MIT, https://github.com/Gsirawan/Bitmochi),
// scritto come plugin per la shell di Omarchy. Qui dentro non e' installato:
// e' portato: pet/Pet.js e pet/Sprites.js arrivano verbatim, pet/PetRoom.qml
// con otto modifiche elencate in pet/UPSTREAM.md, e questo file sostituisce
// il Panel.qml del plugin — che era la finestra flottante di Omarchy, cosa che
// qui fa gia' la colonna della dashboard.
//
// La divisione del lavoro e' quella dell'originale e conviene rispettarla:
// Pet.js e' la simulazione (matematica pura, nessuna dipendenza da Qt),
// PetRoom.qml e' il disegno e i clic, e qui ci sta soltanto lo stato — il file
// su disco, i due timer, e chi decide quando il pet e' guardato.
ColumnLayout {
    id: panel

    // L'id ferma il pannello nella configurazione salvata e lo distingue nel
    // catalogo; il titolo e' quello che la finestra Opzioni mostra.
    property string panelId: "pet"
    property string panelTitle: "Bitmochi"

    // L'altezza della STANZA — la parte in cui il pet cammina — non
    // dell'intero pannello: le righe fisse sopra e sotto (nome, barre,
    // pulsanti) le misura PetRoom da se' e cambiano quando il pet cresce, e
    // sommarle qui vuol dire che la stanza resta della misura chiesta invece
    // di restringersi il giorno che compare la riga «non sta bene».
    // `particleMax` e' il tetto della nuvola di molecole: quante se ne
    // disegnano al massimo, qualunque cosa dica il sensore. Non e' una scelta
    // estetica ma un limite di costo — vedi PetMolecules.qml. Quante ce ne
    // siano davvero lo decide il passo della caratteristica («una molecola ogni
    // 50 ppm»), che sta con lei in pet-traits.json.
    readonly property var defs: ({
            roomHeight: 280,
            particleMax: 40,
            terrain: "",
            terrainColor: "",
            terrainOpacity: 0.35,
            background: "",
            backgroundDim: 0.35,
            dropSeconds: 6
        })
    readonly property int roomHeight: Settings.panelParam("pet", "roomHeight", defs.roomHeight)
    readonly property int particleMax: Settings.panelParam("pet", "particleMax", defs.particleMax)

    // Quanto un oggetto resta a terra prima di sparire. Sta nei panelParams e
    // non con la caratteristica perche' riguarda la STANZA: quanto tempo si ha
    // per raggiungere una cosa e' una regola del posto, uguale per la mela e
    // per il peperoncino, e sceglierla dieci volte sarebbe dieci occasioni di
    // sceglierla diversa senza volerlo.
    readonly property int dropSeconds: Settings.panelParam("pet", "dropSeconds", defs.dropSeconds)

    // ---- Il pavimento e il fondale ------------------------------------------
    //
    // `terrain` e' la serie su cui il pet cammina: `ha:<entita>` per lo storico
    // di Home Assistant, `sys:<chiave>` per una misura della dashboard, vuoto
    // per il pavimento piatto di prima. `background` e' un file di immagine.
    //
    // Stanno nei panelParams e non in pet-traits.json perche' sono due stringhe
    // sole e riguardano la STANZA, non una caratteristica: il pavimento e' uno
    // anche quando le caratteristiche sono cinque.
    readonly property string terrainSource: Settings.panelParam("pet", "terrain", defs.terrain)
    readonly property string background: Settings.panelParam("pet", "background", defs.background)
    readonly property real backgroundDim: Settings.panelParam("pet", "backgroundDim", defs.backgroundDim)

    // Vuoto = il colore del tema. Un default scritto qui come esadecimale
    // andrebbe bene finche' qualcuno non cambia il tema, e poi resterebbe
    // indietro senza che nessuno colleghi le due cose.
    readonly property string terrainColorName: Settings.panelParam("pet", "terrainColor", defs.terrainColor)
    readonly property real terrainOpacity: Settings.panelParam("pet", "terrainOpacity", defs.terrainOpacity)

    // La serie risolta. Gli storici ci sono gia' tutti e due: quello di Home
    // Assistant lo tiene HomeAssistant.history, quelli di sistema li campiona
    // sysmon per gli altri pannelli. Nessuna sonda nuova.
    readonly property var terrainValues: {
        const src = panel.terrainSource;
        if (!src)
            return [];
        if (src.startsWith("ha:"))
            return HomeAssistant.history[src.slice(3)] ?? [];
        switch (src) {
        case "sys:cpu":
            return SystemStats.cpuHistory;
        case "sys:mem":
            return SystemStats.memHistory;
        case "sys:gpu":
            return SystemStats.gpuHistory;
        case "sys:cpuWatt":
            return SystemStats.cpuWattHistory;
        case "sys:gpuWatt":
            return SystemStats.gpuWattHistory;
        }
        return [];
    }

    // 🔴 Lo storico di un'entita' si chiede con watchHistory() e si lascia
    // andare con unwatchHistory(). Scrivere `HomeAssistant.historyEntities` da
    // qui funzionerebbe finche' non si toccano le opzioni, e poi smetterebbe —
    // in silenzio. E' la regola di casa, vedi AGENTS.md e IgrometroPanel.
    property string watchedEntity: ""

    function followHistory() {
        const wanted = panel.terrainSource.startsWith("ha:") ? panel.terrainSource.slice(3) : "";
        if (panel.watchedEntity === wanted)
            return;
        if (panel.watchedEntity.length)
            HomeAssistant.unwatchHistory(panel.watchedEntity);
        panel.watchedEntity = wanted;
        if (wanted.length)
            HomeAssistant.watchHistory(wanted);
    }

    onTerrainSourceChanged: panel.followHistory()

    Component.onDestruction: {
        if (panel.watchedEntity.length)
            HomeAssistant.unwatchHistory(panel.watchedEntity);
    }

    // ---- Dove vive il pet ---------------------------------------------------
    // Stato mutevole, quindi ~/.local/state e non ~/.config, dove stanno le
    // impostazioni. Non e' il percorso ~/.local/state/omarchy/… di monte: qui
    // Omarchy non e' installato, e mettere il file nella cartella di un
    // programma che non c'e' sarebbe solo un posto in cui nessuno lo cerca.
    // Il file sopravvive allo spegnimento del pannello, generazione compresa.
    readonly property string stateDir: Quickshell.env("HOME") + "/.local/state/quickshell/dashboard"
    readonly property string statePath: panel.stateDir + "/pet.json"

    // 🔴 La lettura e' limitata perche' questo processo e' tutta la shell, non
    // solo questo pannello. E' la guardia dell'autore, e resta: pet.json e'
    // scrivibile dall'utente, e FileView.text() materializza qualunque cosa
    // trovi senza limite di dimensione — un file enorme finirebbe la memoria
    // prima che uno solo dei controlli di Pet.js venga eseguito, portandosi
    // dietro ogni altro pannello della dashboard. `head -c` non puo' darcene
    // piu' di tanti qualunque cosa ci sia su disco. La scrittura resta
    // FileView, per la sostituzione atomica.
    //
    // Gli altri due pezzi della guardia, con la stessa ragione dell'originale:
    //   * `timeout`, perche' una lettura non e' solo un rischio di dimensione.
    //     Al posto di pet.json si puo' mettere una FIFO, e allora una lettura
    //     senza scadenza non torna mai: il pannello resta per sempre su un
    //     uovo che non si schiude. Una lettura uccisa esce diversa da zero e
    //     finisce sul ramo «primo avvio», che e' la risposta giusta per un
    //     file che non e' un salvataggio.
    //   * `--`, perche' un percorso non possa mai essere letto come opzione.
    //
    // 64 KiB contro un pet.json vero di ~560 byte: largo abbastanza che nessun
    // salvataggio onesto ci arrivi, stretto abbastanza che arrivarci non costi
    // niente. Uno in piu' al comando, cosi' lo sforamento si vede invece di
    // essere troncato in silenzio.
    readonly property int maxStateBytes: 65536

    function collectedBytes(collector) {
        var d = collector.data;
        if (d && typeof d.byteLength === "number")
            return d.byteLength;
        return (collector.text || "").length;
    }

    // ---- Lo stato -----------------------------------------------------------
    // 🔴 Parte da un uovo fresco in modo sincrono, prima che qualunque lettura
    // abbia potuto rispondere: cosi' il primo disegno e' sempre l'uovo e mai un
    // riquadro vuoto che un istante dopo scatta su qualcos'altro. La lettura lo
    // sostituisce una volta sola, con quello che sanitizeState() decide di
    // potersi fidare.
    property var pet: Pet.freshEgg({})

    // 🔴 Falso finche' petReadProc non ha risposto, e niente puo' scrivere su
    // disco prima. Serve perche' `pet` qui sopra e' un SEGNAPOSTO: un uovo
    // fresco, con `awaitingFirstOpen: true`, costruito prima che la lettura
    // (asincrona) sia partita. Nella finestra fra i due, `watched` diventa vero
    // — la dashboard e' gia' a schermo quando il pannello si accende — e
    // markFirstOpen() scriveva quel segnaposto sopra il salvataggio vero,
    // cancellando il pet.
    //
    // E' successo davvero, misurando: un cucciolo di nome Toffi e' diventato un
    // uovo di nome Wobo spegnendo e riaccendendo il pannello. Nel plugin il
    // guasto non c'e' perche' li' il gelo si toglie quando l'utente APRE la
    // finestra, che e' molto dopo la lettura; qui il pannello e' gia' aperto
    // nel momento in cui nasce, e la stessa riga diventa una gara.
    property bool petLoaded: false

    readonly property bool memorialPending: panel.pet.memorialSeen === false

    // ---- I sensori muovono le quattro statistiche ---------------------------
    //
    // Le quattro statistiche del gioco decadono da sole dentro Pet.js. Una
    // caratteristica da sensore le spinge o le tira: la CO2 alta stanca, l'aria
    // buona rimette in forze, con un peso in punti all'ora per statistica che
    // sceglie chi configura (vedi PetTraits.rateNow).
    //
    // 🔴 Qui c'era un secondo orologio della malattia, tutto suo, e adesso non
    // c'e' piu'. Non e' una semplificazione per il gusto di togliere: due
    // strade verso la stessa morte volevano dire punire due volte lo stesso
    // guaio, e soprattutto una CO2 che uccide DI SUO e' una meccanica in piu'
    // da capire. Adesso la CO2 scarica l'energia, l'energia arriva a zero, e a
    // quel punto muore per la regola che il gioco ha sempre avuto — con la sua
    // finestra di dodici ore, la sua faccia malata e la sua cerimonia. Una sola
    // meccanica, quella originale, e nessuna riga di Pet.js toccata.
    //
    // Conseguenza da sapere: una caratteristica senza pesi non puo' piu' fare
    // male al pet. Resta una barra che informa, ed e' una scelta legittima.
    //
    // 🔴 `dt` e' il tempo DAVVERO OSSERVATO, tagliato a due giri di timer. Di un
    // sensore non sappiamo il passato: se la shell e' stata spenta tredici ore
    // non sappiamo se la CO2 era alta per tutte e tredici o per una sola, e
    // applicare quel divario vorrebbe dire scaricare il pet su un'ipotesi. Il
    // decadimento naturale invece attraversa i buchi eccome — quello lo calcola
    // Pet.js in forma chiusa, e sa quello che dice.
    //
    // Da cui anche il non-persistere: l'istante dell'ultima applicazione sta in
    // memoria e basta. Ripartire da adesso dopo un riavvio e' la risposta
    // giusta, non una scorciatoia — il primo `dt` e' zero.
    property real effectsLastAt: 0

    // Due giri del timer da 60 s. Piu' stretto perderebbe tempo vero durante un
    // rallentamento della shell, piu' largo comincerebbe a far contare i buchi.
    readonly property real effectsMaxStepMs: 120000

    // ---- Gli oggetti che cadono ---------------------------------------------
    //
    // La condizione «oltre la soglia da N minuti» si misura in TEMPO OSSERVATO,
    // con la stessa regola dei pesi qui sopra e per lo stesso motivo: se la
    // dashboard e' stata chiusa tre ore non sappiamo se la GPU era carica per
    // tutte e tre, e riaprirla non deve far piovere gli oggetti arretrati.
    // Da cui il non-persistere: riaprire riparte da zero minuti.
    //
    // 🔴 Il riposo INVECE e' un istante d'orologio e sopravvive alla chiusura.
    // Non e' un'incoerenza con la riga sopra: l'attesa misura quanto abbiamo
    // guardato, il riposo e' una regola sul mondo — «questo non si ripiglia
    // subito» — e chiudere la dashboard non deve poter essere il modo di
    // saltarla.
    property var dropHold: ({})
    property var dropCooldown: ({})

    // Gli oggetti a terra adesso. 🔴 Uno alla volta, ed e' un vincolo di
    // PetDrops e non un gusto: un Repeater su un array JavaScript ricrea tutti
    // i delegati a ogni riassegnazione, quindi il secondo oggetto farebbe
    // ricominciare da capo la caduta del primo.
    property var dropsInRoom: []
    property real dropSeenAt: 0
    property int dropSeq: 0

    // Due giri del timer da 5 s, piu' margine.
    readonly property real dropMaxStepMs: 12000
    // Il moltiplicatore che rende il pet piu' sveglio quando la macchina lavora
    // e piu' assonnato quando non fa niente. Tocca solo la velocita'
    // dell'animazione, mai una statistica.
    //
    // L'originale legge /proc/loadavg con un FileView e un timer da 20 s. Qui
    // il carico e' gia' misurato — SystemStats campiona per tutti gli altri
    // pannelli e costa il suo — e il carico istantaneo si ricava dalla CPU per
    // il numero di core. Una sonda in meno per lo stesso numero.
    readonly property real moodFactor: {
        const cores = SystemStats.cores.length;
        if (cores <= 0)
            return 1.0;
        return Pet.moodFactorFromLoad(cores * SystemStats.cpu / 100);
    }

    // ---- Chi sta guardando --------------------------------------------------
    // Nel plugin e' `opened` della finestra flottante; qui e' la finestra della
    // dashboard, che si accende e si spegne (qs ipc call dashboard toggle).
    // Stesso modo di panels/OscilloscopioPanel.qml, che ha lo stesso problema.
    readonly property bool watched: panel.visible && panel.Window.window !== null && panel.Window.window.visible

    // 🔴 L'unico posto in cui si toglie il gelo del primo sguardo (Pet.js:
    // freshEgg / reconcile / beginFirstOpen). Un uovo si schiude in 60-90
    // secondi da QUANDO LO SI GUARDA, non dall'avvio della shell — e questo
    // pannello viene costruito all'avvio, come nel plugin. Senza, chi accende
    // il computer alle 9 e apre la dashboard alle 11 trova un adulto e si e'
    // perso la schiusa, che e' tutto il punto della cosa.
    //
    // Idempotente: non fa niente su qualcosa che non sia un uovo in attesa,
    // quindi ogni chiamante puo' chiamarla senza guardare.
    function markFirstOpen() {
        if (!panel.petLoaded)
            return;
        if (panel.pet.awaitingFirstOpen !== true)
            return;
        panel.pet = Pet.beginFirstOpen(panel.pet, Date.now());
        panel.persistPet();
    }

    // La seconda cintura, oltre a `watched`. Il puntatore che entra nel
    // pannello e' la prova che la finestra e' a schermo e che c'e' qualcuno:
    // se `Window.window` dovesse rispondere male su questo compositore,
    // l'uovo si sblocca lo stesso al primo passaggio del mouse invece di
    // restare inerte per sempre.
    onWatchedChanged: {
        if (panel.watched)
            panel.markFirstOpen();
        else
            panel.clearDrops();
    }

    // 🔴 E la cerimonia non e' un caso raro: arriva proprio quando le
    // statistiche sono a zero, cioe' quando i dispetti stanno cadendo. Senza
    // questa riga un oggetto in volo alla morte del pet resterebbe appeso a
    // meta' schermo — PetDrops smette di animare, ma la riga nel modello c'e'
    // ancora — finche' qualcuno non chiude il pannello.
    onMemorialPendingChanged: {
        if (panel.memorialPending)
            panel.clearDrops();
    }

    HoverHandler {
        onHoveredChanged: {
            if (hovered)
                panel.markFirstOpen();
        }
    }

    function persistPet() {
        Qt.callLater(function () {
            petFile.setText(Pet.serializeState(panel.pet));
        });
    }

    function reconcileNow() {
        // Stessa ragione di markFirstOpen(): riconciliare il segnaposto lo
        // persiste, e il salvataggio vero non c'e' ancora. I due Timer qui
        // sotto girano da subito, quindi la guardia sta qui e non su di loro.
        if (!panel.petLoaded)
            return null;
        // 🔴 PRIMA della riconciliazione, non dopo: cosi' Pet.reconcile() vede
        // le statistiche gia' mosse dai sensori e, se una e' arrivata a zero,
        // timbra la malattia in questo stesso giro invece che al prossimo. E'
        // anche cio' che rende vera la frase «muore per la regola del gioco»:
        // il sickSince lo scrive Pet.js guardando i numeri, non lo scriviamo
        // noi guardando un sensore.
        panel.applyEffects();
        var result = Pet.reconcile(panel.pet, Date.now());
        panel.pet = result.state;
        panel.persistPet();
        return result;
    }

    // Sposta le quattro statistiche di quanto dicono i pesi delle
    // caratteristiche, per il tempo trascorso da quando ci si e' guardati.
    function applyEffects() {
        const now = Date.now();
        const dt = panel.effectsLastAt > 0 ? Math.min(Math.max(0, now - panel.effectsLastAt), panel.effectsMaxStepMs) : 0;
        panel.effectsLastAt = now;

        if (dt <= 0 || panel.pet.stage === "egg" || panel.memorialPending)
            return;

        const hours = dt / 3600000;
        const next = {};
        for (const k in panel.pet)
            next[k] = panel.pet[k];

        let moved = false;
        for (const key of PetTraits.statKeys) {
            let rate = 0;
            for (const trait of PetTraits.wellnessTraits)
                rate += PetTraits.rateNow(trait, key);
            if (rate === 0)
                continue;
            // Gli stessi estremi di Pet.js: una statistica non esce da 0-100,
            // altrimenti un peso forte ci metterebbe ore a tornare visibile
            // dopo essere andata a −400.
            next[key] = Math.max(0, Math.min(100, next[key] + rate * hours));
            moved = true;
        }

        if (moved)
            panel.pet = next;
    }

    // Guarda le soglie e, quando una e' rimasta vera abbastanza a lungo, fa
    // cadere il suo oggetto.
    function tickDrops() {
        const now = Date.now();
        const dt = panel.dropSeenAt > 0 ? Math.min(Math.max(0, now - panel.dropSeenAt), panel.dropMaxStepMs) : 0;
        panel.dropSeenAt = now;

        if (dt <= 0)
            return;

        // Le stesse guardie delle cure: un uovo non raccoglie niente, e
        // durante la cerimonia la stanza e' occupata da un cartellino.
        if (panel.memorialPending || panel.pet.stage === "egg")
            return;

        // Si RICOSTRUISCE invece di aggiornarlo: una caratteristica tolta dal
        // file sparisce da qui da sola, senza una riga che se ne ricordi.
        const hold = {};

        for (const t of PetTraits.dropTraits) {
            const prev = panel.dropHold[t.id] ?? 0;
            let ms;

            // Tre stati e non due, come per il benessere: vero sale, falso
            // azzera, e «non lo so» TIENE FERMO. Un poll di Home Assistant
            // andato storto non deve buttare via quattro minuti di attesa.
            if (t.value === null)
                ms = prev;
            else if (t.drop.when === "below" ? t.value < t.drop.threshold : t.value > t.drop.threshold)
                ms = prev + dt;
            else
                ms = 0;

            if (ms >= t.drop.holdMs && panel.dropsInRoom.length === 0 && now >= (panel.dropCooldown[t.id] ?? 0)) {
                panel.spawnDrop(t);
                ms = 0;
            }

            hold[t.id] = ms;
        }

        panel.dropHold = hold;
    }

    function spawnDrop(t) {
        panel.dropSeq++;
        // 🔴 La chiave e' unica per CADUTA e non per caratteristica: due
        // cadute della stessa sono due oggetti diversi, e un segnale in
        // ritardo sulla prima non deve poter raccogliere la seconda.
        panel.dropsInRoom = [
            {
                key: `${t.id}#${panel.dropSeq}`,
                trait: t.id,
                glyph: t.drop.item.glyph,
                kind: t.drop.item.kind,
                gift: t.drop.gift
            }
        ];
    }

    function startCooldown(traitId) {
        const t = PetTraits.dropTraits.find(x => x.id === traitId);
        const cool = {};
        for (const k in panel.dropCooldown)
            cool[k] = panel.dropCooldown[k];
        // La caratteristica puo' essere stata tolta mentre il suo oggetto era
        // per aria: dieci minuti di ripiego, e la voce sparira' da se' al
        // prossimo giro.
        cool[traitId] = Date.now() + (t ? t.drop.cooldownMs : 600000);
        panel.dropCooldown = cool;
    }

    // Un oggetto finisce: raccolto o scaduto, la differenza l'ha gia' fatta
    // chi chiama. Il riposo parte in tutti e due i casi — se partisse solo
    // dalla raccolta, una soglia rimasta vera farebbe ricadere un oggetto ogni
    // sei secondi finche' il pet non lo prende.
    function endDrop(key) {
        const d = panel.dropsInRoom.find(x => x.key === key);
        if (!d)
            return;
        panel.startCooldown(d.trait);
        // 🔴 Qt.callLater e non subito: chi ci chiama e' il delegato
        // dell'oggetto, e togliergli la riga di sotto lo DISTRUGGE mentre la
        // sua emissione di segnale e' ancora sullo stack.
        Qt.callLater(function () {
            panel.dropsInRoom = panel.dropsInRoom.filter(x => x.key !== key);
        });
    }

    function dropCaught(key) {
        const d = panel.dropsInRoom.find(x => x.key === key);
        if (!d)
            return;
        panel.applyGift(d.gift);
        panel.endDrop(key);
    }

    // La stanza si svuota, e la caratteristica va in riposo lo stesso:
    // altrimenti riaprire la dashboard farebbe ricadere subito la stessa cosa.
    function clearDrops() {
        for (const d of panel.dropsInRoom)
            panel.startCooldown(d.trait);
        panel.dropsInRoom = [];
        panel.dropSeenAt = 0;
    }

    // L'effetto una tantum di un oggetto raccolto.
    //
    // 🔴 Non passa da Pet.applyCare(): quella e' una CURA — alza careScore,
    // sposta lastSeen, e in un caso azzera lo sporco — mentre questo e' un
    // delta secco sulle quattro statistiche. E aggiungere un'azione «regalo»
    // dentro Pet.js vorrebbe dire una modifica in piu' a un file che resta
    // verbatim (vedi pet/UPSTREAM.md), da rimettere a mano ogni volta che a
    // monte esce una versione nuova.
    function applyGift(gift) {
        // Prima si riconcilia, per la stessa ragione delle cure: il regalo
        // cade su statistiche decadute fino a QUESTO istante.
        panel.reconcileNow();
        if (!panel.petLoaded || panel.memorialPending || panel.pet.stage === "egg")
            return;

        const next = {};
        for (const k in panel.pet)
            next[k] = panel.pet[k];

        let moved = false;
        for (const key of PetTraits.statKeys) {
            const v = gift ? gift[key] : 0;
            if (typeof v !== "number" || !isFinite(v) || v === 0)
                continue;
            // Gli stessi estremi di Pet.js e di applyEffects().
            next[key] = Math.max(0, Math.min(100, next[key] + v));
            moved = true;
        }

        if (!moved)
            return;

        // Come fa Pet.applyCare() alla sua ultima riga: senza, una mela che
        // tira la fame via da zero lascerebbe il pet con la faccia malata fino
        // al prossimo giro di reconcile — quindici secondi in cui il disegno
        // non e' d'accordo con i numeri. E' una funzione pura di Pet.js
        // chiamata da fuori: nessuna riga di quel file toccata.
        panel.pet = Pet.refreshSickAfterCare(next);
        panel.persistPet();
    }

    function applyCare(action) {
        // Prima si riconcilia, cosi' la cura cade su statistiche decadute fino a
        // QUESTO istante e non su quelle che il timer da 15 s ha calcolato fino
        // a quindici secondi fa. reconcileNow() e' idempotente e costa poco
        // (matematica in forma chiusa), quindi quando non e' cambiato niente
        // non costa niente.
        panel.reconcileNow();
        if (panel.memorialPending || panel.pet.stage === "egg")
            return;
        panel.pet = Pet.applyCare(panel.pet, action, Date.now());
        panel.persistPet();
    }

    function petClicked() {
        panel.reconcileNow();
        if (panel.memorialPending || panel.pet.stage === "egg")
            return;
        panel.pet = Pet.applyPet(panel.pet, Date.now());
        panel.persistPet();
    }

    // La cerimonia, una volta per morte: congedarla e' l'unica cosa che alza
    // memorialSeen, quindi una morte avvenuta mentre nessuno guardava si vede
    // per intero la volta dopo.
    //
    // 🔴 bornAt/stageEnteredAt tornano a QUESTO istante e non restano al
    // momento della morte. Il ramo uovo di Pet.reconcile() congela del tutto
    // l'orologio di un uovo rinato finche' memorialSeen e' falso — apposta,
    // perche' non si schiuda dietro il cartellino ancora a schermo — ma allora
    // bornAt e' fermo a quando la morte e' avvenuta davvero. Lasciandolo li',
    // la prima riconciliazione dopo il congedo vedrebbe la finestra di schiusa
    // gia' passata (leggere il cartellino richiede piu' di 60 secondi) e
    // schiuderebbe l'uovo nuovo sul posto, senza che nessuno lo veda
    // traballare.
    function dismissMemorial() {
        var next = {};
        for (var k in panel.pet)
            next[k] = panel.pet[k];
        next.memorialSeen = true;
        next.bornAt = Date.now();
        next.stageEnteredAt = next.bornAt;
        panel.pet = next;
        panel.persistPet();
    }

    Component.onCompleted: {
        Settings.declarePanelParams("pet", panel.defs);
        panel.followHistory();
        // La lettura del pet NON parte da qui: aspetta mkdirProc.onExited —
        // vedi quel Process per il perche'.
        mkdirProc.running = true;
    }

    Process {
        id: mkdirProc

        command: ["mkdir", "-p", panel.stateDir]
        // 🔴 Al primo avvio pet.json non esiste: la lettura fallisce quasi
        // subito e scrive un uovo fresco su disco all'istante. Quella scrittura
        // e questo mkdir, lanciati insieme, sono una gara vera: se la setText()
        // asincrona atterra prima che il mkdir abbia finito, il primo pet.json
        // non viene scritto e nessuno se ne accorge. Aspettare qui vuol dire
        // che la cartella c'e' di sicuro prima che il file sia letto o scritto.
        onExited: code => Qt.callLater(function () {
            petReadProc.running = true;
        })
    }

    // ---- Persistenza --------------------------------------------------------
    FileView {
        id: petFile

        path: panel.statePath
        watchChanges: false
        atomicWrites: true
        printErrors: false
        // Sola scrittura. La lettura e' petReadProc qui sotto: niente qui
        // chiama text() o reload(), e preload e' falso per difetto, quindi
        // questo FileView non tira mai il file in memoria.
    }

    Process {
        id: petReadProc

        command: ["timeout", "5", "head", "-c", String(panel.maxStateBytes + 1), "--", panel.statePath]

        stdout: StdioCollector {
            id: petReadOut

            waitForEnd: true
        }

        onExited: code => {
            // Un'uscita diversa da zero e' «il file non c'e' ancora», oppure una
            // lettura che e' stata uccisa: il primo avvio, per quanto se ne puo'
            // sapere. sanitizeState("") produce gia' lo stesso uovo fresco e
            // congelato che produrrebbe un file corrotto, quindi una via serve
            // per tutti e due i casi.
            var hadFile = code === 0;
            var raw = hadFile ? petReadOut.text : "";
            // Oltre il limite vuol dire che `head` si e' fermato al suo tetto e
            // su disco c'e' dell'altro. Non e' un salvataggio un po' troppo
            // grande, e' un salvataggio illeggibile: si rifiuta intero invece di
            // interpretarne un prefisso troncato, che vorrebbe dire fallire su
            // qualcosa di *plausibile* invece che su qualcosa di *ignoto*.
            if (hadFile && panel.collectedBytes(petReadOut) > panel.maxStateBytes) {
                hadFile = false;
                raw = "";
            }
            panel.pet = Pet.sanitizeState(raw);
            panel.petLoaded = true;
            // 🔴 Se la dashboard e' GIA' guardata quando lo stato arriva — la
            // lettura e' asincrona — nessun passaggio a visibile scattera' piu'
            // per togliere il gelo. Si toglie qui, o quell'uovo resta inerte a
            // schermo per sempre con un conto alla rovescia che non scende.
            if (panel.watched)
                panel.markFirstOpen();
            if (hadFile)
                panel.reconcileNow();
            else
                panel.persistPet();
        }
    }

    // Tiene le barre onestamente in calo mentre qualcuno guarda, senza un ciclo
    // per fotogramma: reconcile() e' matematica in forma chiusa su
    // (adesso - ultima volta vista), abbastanza a buon mercato da chiamarla
    // ogni 15 secondi e idempotente fra una chiamata e l'altra.
    Timer {
        interval: 15000
        running: panel.watched
        repeat: true
        onTriggered: panel.reconcileNow()
    }

    // 🔴 Questo timer resta incondizionato, e NON e' lui a far invecchiare un
    // uovo mai guardato. Le due cose valgono insieme, e valgono in Pet.js e non
    // qui: un pet gia' nato continua a decadere a dashboard chiusa (questo
    // timer), mentre un uovo che nessuno ha mai guardato non invecchia affatto
    // (il gelo di reconcile() torna prima di leggere qualunque orologio).
    // Legarlo a `watched` per «sistemare» l'uovo vorrebbe dire riprendersi il
    // guasto che questo timer esiste per evitare: un pet che, riaperta la
    // dashboard, sembra sano per ore dopo essersi ammalato.
    Timer {
        interval: 60000
        running: true
        repeat: true
        onTriggered: panel.reconcileNow()
    }

    // 🔴 Legato a `watched`, al contrario di quello qui sopra, e la differenza
    // e' voluta: il decadimento naturale attraversa i buchi perche' Pet.js lo
    // calcola in forma chiusa e sa quello che dice, mentre un oggetto che cade
    // e' un fatto che succede a schermo. Uno caduto mentre nessuno guardava
    // sarebbe caduto per nessuno — e sei secondi dopo non ci sarebbe piu'.
    Timer {
        interval: 5000
        running: panel.watched && panel.petLoaded
        repeat: true
        // Il primo giro ha dt zero e serve solo ad ancorare l'orologio: senza,
        // il primo intervallo osservato comincerebbe cinque secondi tardi.
        triggeredOnStart: true
        onTriggered: panel.tickDrops()
    }

    spacing: 0

    // L'ingranaggio che apre la finestra delle caratteristiche.
    //
    // Sta sopra la stanza e allineato a destra, dove la dashboard mette il suo
    // (Dashboard.qml). Un pannello sta dentro un Loader e non puo' aprire
    // niente da se': la richiesta passa da DashActions, che esiste per questo.
    Rectangle {
        id: gear

        Layout.alignment: Qt.AlignRight
        implicitWidth: 22
        implicitHeight: 20
        radius: 5
        color: gearHover.hovered ? "#161b22" : "transparent"
        border.width: 1
        border.color: gearHover.hovered ? "#30363d" : "transparent"

        Text {
            anchors.centerIn: parent
            color: gearHover.hovered ? "#c9d1d9" : "#6e7681"
            font.pixelSize: 12
            text: "⚙"
        }

        HoverHandler {
            id: gearHover

            cursorShape: Qt.PointingHandCursor
        }

        Tooltip {
            hovered: gearHover.hovered
            text: I18n.t("collega un sensore a una caratteristica del pet")
        }

        TapHandler {
            onSingleTapped: DashActions.openPetTraits()
        }
    }

    PetRoom {
        id: room

        Layout.fillWidth: true
        // L'altezza chiesta piu' quella che le righe fisse si prendono davvero.
        // chromeHeight le conta dalle sole righe VISIBILI — un uovo non mostra
        // ne' barre ne' pulsanti — quindi la stanza resta della misura chiesta
        // in ogni fase della vita del pet. Non c'e' ciclo: chromeHeight legge
        // le altezze implicite del testo, mai la nostra.
        Layout.preferredHeight: panel.roomHeight + room.chromeHeight

        // Il pet vero, senza copie: la malattia adesso e' quella di Pet.js e
        // basta, perche' e' li' che i sensori la producono — scaricando le
        // statistiche finche' una tocca zero. Prima serviva una copia con un
        // `sick` messo a mano; adesso sarebbe una bugia al salvataggio.
        pet: panel.pet
        moodFactor: panel.moodFactor
        memorialPending: panel.memorialPending

        // Le caratteristiche dai sensori: le barre in piu' e le nuvole. Solo
        // quelle che le hanno chieste — una caratteristica puo' agire sulle
        // statistiche senza occupare una riga della stanza.
        extraStats: PetTraits.barTraits
        particleTraits: PetTraits.particleTraits

        // Il pavimento e il fondale. Vuoti tutti e due, la stanza e' quella di
        // sempre: linea piatta e niente sfondo.
        terrainValues: panel.terrainValues
        terrainOpacity: panel.terrainOpacity
        backgroundDim: panel.backgroundDim
        background: panel.background ? "file://" + panel.background.replace("~", Quickshell.env("HOME")) : ""

        // Il binding si attiva solo con un colore scelto: senza, resta il
        // default di PetRoom, che segue il tema.
        terrainColor: panel.terrainColorName !== "" ? panel.terrainColorName : PetColor.foreground
        particleMax: panel.particleMax
        // 🔴 La finestra della malattia, passata da chi possiede la
        // simulazione: PetRoom non deve tenerne una seconda copia, o la cosa
        // disegnata comincia in silenzio a non essere piu' d'accordo con la
        // cosa simulata.
        sickWindowMs: Pet.DEATH_SICK_MS
        // I timer della stanza — passeggiata, battito di ciglia, conto alla
        // rovescia della schiusa — si legano a questo: il pannello resta
        // costruito per tutto il tempo in cui gira la shell, e senza
        // animerebbe un pet che nessuno sta guardando.
        panelOpen: panel.watched

        drops: panel.dropsInRoom
        dropSeconds: panel.dropSeconds

        onDropCaught: key => panel.dropCaught(key)
        onDropExpired: key => panel.endDrop(key)

        onCareRequested: action => panel.applyCare(action)
        onPetRequested: panel.petClicked()
        onMemorialDismissed: panel.dismissMemorial()
    }
}
