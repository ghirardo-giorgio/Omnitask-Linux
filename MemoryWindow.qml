import QtQuick
import Quickshell
import Quickshell.Io

// Una finestra che nasce della misura giusta e ricorda quella scelta da chi la
// usa.
//
// ┌──────────────────────────────────────────────────────────────────────────┐
// │ ATTENZIONE — a chi legge questo file per «semplificarlo», umano o modello │
// │                                                                          │
// │ Qui non c'e' niente di ridondante. Ogni guardia e ogni timer sta al       │
// │ posto suo per un guasto vero, riprodotto e misurato: toglierne uno non    │
// │ rompe niente subito, rompe la memoria delle finestre qualche giorno       │
// │ dopo, e il nesso con la modifica non si vede piu'.                        │
// │                                                                          │
// │ I tre vincoli di Qt su cui si regge tutto — provati, non dedotti:         │
// │   1. `width` e `height` di una finestra NON sono scrivibili;              │
// │   2. `implicitWidth`/`implicitHeight` valgono solo se sono **dichiarati**  │
// │      e vengono letti quando la finestra viene mappata: assegnarli dopo    │
// │      non fa niente (provato: resta 100x100, il ripiego di Qt);            │
// │   3. l'unico modo di far crescere una finestra gia' viva e' `minimumSize`.│
// │                                                                          │
// │ Da cui: se la misura salvata non viene applicata alla mappatura, da QML   │
// │ non si rimedia piu'. Si rimedia dal compositor, ed e' l'ultimo blocco di  │
// │ questo file. Vedi anche AGENTS.md alla radice del progetto.               │
// └──────────────────────────────────────────────────────────────────────────┘
//
// Due regole, in quest'ordine:
//   1. se l'utente l'ha ridimensionata, alla riapertura torna com'era;
//   2. altrimenti si adatta al contenuto — accendere un pannello o aggiungere
//      un disco la fa crescere invece di far tagliare l'ultimo elemento.
//
// La misura si propone con `implicitWidth`/`implicitHeight` **dichiarati**:
// assegnarli a runtime non ha effetto (provato: la finestra resta a 100x100,
// la dimensione di ripiego di Qt), e `width`/`height` non sono scrivibili
// affatto. Una volta che l'utente ha ridimensionato, Qt smette di far seguire
// `width` all'implicita, quindi il binding non gli porta via il gesto.
FloatingWindow {
    id: win

    // nome con cui la misura viene salvata su disco
    required property string key
    required property int defaultWidth
    required property int defaultHeight
    // quanto vorrebbe essere il contenuto: se cresce, e l'utente non ha ancora
    // deciso niente, la finestra lo segue
    property int contentWidth: 0
    property int contentHeight: 0

    readonly property bool userSized: Settings.hasWindowSize(win.key)
    readonly property var saved: Settings.windowSize(win.key, Math.max(win.defaultWidth, win.contentWidth), Math.max(win.defaultHeight, win.contentHeight))

    implicitWidth: win.saved.width
    implicitHeight: win.saved.height
    // Il vincolo di dimensione minima e' l'unica cosa che fa davvero crescere
    // una finestra gia' creata: `implicitHeight` viene letto alla nascita, e
    // quando i pannelli finiscono di caricarsi (qualche istante dopo) la
    // finestra non lo rilegge piu' — nasceva a 720 mentre il contenuto ne
    // chiedeva 940, ed e' per questo che l'ultimo pannello risultava tagliato.
    //
    // Vincola solo finche' l'utente non ha scelto una misura sua: da quel
    // momento comanda lui, anche per rimpicciolire sotto il contenuto.
    minimumSize: win.userSized ? Qt.size(320, 240) : Qt.size(win.saved.width, win.saved.height)
    color: "#0d1117"

    onWidthChanged: win.noteResize()
    onHeightChanged: win.noteResize()

    function noteResize() {
        // Appena aperta la finestra passa per misure intermedie (il ripiego di
        // Qt, poi l'implicita, poi gli aggiustamenti del window manager per
        // decorazioni e vincoli dello schermo): nessuna di quelle e' una scelta
        // di chi guarda, e prenderle per buone marchiava la finestra come
        // "ridimensionata" da sola, un istante dopo l'apertura.
        if (!win.visible || settling.running)
            return;
        // La finestra che segue la propria dimensione implicita non sta
        // obbedendo a nessuno: e' il contenuto che e' cresciuto (un pannello in
        // piu', un disco aggiunto) e Qt l'ha adeguata. Prenderlo per un
        // ridimensionamento voluto marcherebbe la finestra e le impedirebbe per
        // sempre di adattarsi. Conta solo lo scarto dall'implicita, che
        // c'e' soltanto quando il bordo l'ha trascinato una mano.
        if (Math.abs(win.width - win.implicitWidth) < 2 && Math.abs(win.height - win.implicitHeight) < 2)
            return;
        saveSize.restart();
    }

    onVisibleChanged: {
        if (!win.visible)
            return;
        settling.restart();
        placeBack.restart();
        sizeCheck.restart();
    }


    Timer {
        id: settling

        // Gia' avviato alla costruzione, non da Component.onCompleted: i primi
        // cambiamenti di dimensione (il ripiego di Qt a 100 px, poi l'implicita,
        // poi gli aggiustamenti del window manager) arrivano PRIMA che il
        // componente sia completo, e senza questa guardia facevano scattare il
        // salvataggio — che finiva per registrare come "scelta dell'utente" la
        // prima misura casuale.
        running: true
        interval: 1500
    }

    // Un ridimensionamento col mouse produce decine di cambiamenti al secondo:
    // si scrive quando la mano si ferma, non a ogni pixel.
    Timer {
        id: saveSize

        interval: 600
        onTriggered: Settings.saveWindowSize(win.key, win.width, win.height)
    }

    // --- posizione ------------------------------------------------------
    // Dove si apre una finestra non lo decide QML: `WindowInterface` espone la
    // dimensione e lo schermo, non le coordinate. Su GNOME Wayland l'unico che
    // puo' spostarla e' il compositor, tramite l'estensione "Window Calls" —
    // senza quella, la finestra si apre dove vuole il window manager e questa
    // parte resta inerte.
    property string savedPlace: Settings.windowPlace(win.key)

    Timer {
        // La posizione si rilegge ogni tanto mentre la finestra e' aperta: non
        // esiste un segnale "l'utente mi ha spostato", e interrogare il
        // compositor a raffica per accorgersene sarebbe sproporzionato.
        running: win.visible
        interval: 4000
        repeat: true
        onTriggered: readPlace.running = true
    }

    // Il rettangolo che il compositor dice di avere dato a questa finestra:
    // e' quello del BORDO, decorazione compresa, mentre `win.width` e
    // `win.height` sono l'area cliente. La differenza fra i due e' la
    // decorazione, che cambia col tema e quindi si misura invece di
    // indovinarla — serve al ripristino della misura, qui sotto.
    property int frameX: 0
    property int frameY: 0
    property int frameWidth: 0
    property int frameHeight: 0
    // Vero solo per la lettura chiesta apposta per controllare la misura: le
    // altre, quelle ogni quattro secondi, servono a seguire la posizione.
    property bool sizeCheckPending: false

    Process {
        id: readPlace

        command: ["python3", PluginPaths.of("scripts/winplace.py"), "get", win.title]

        stdout: StdioCollector {
            onStreamFinished: {
                let data;
                try {
                    data = JSON.parse(this.text);
                } catch (e) {
                    return;
                }
                if (!data.ok || data.x === undefined)
                    return;

                Settings.saveWindowPlace(win.key, data.x, data.y);

                win.frameX = data.x;
                win.frameY = data.y;
                win.frameWidth = data.width ?? 0;
                win.frameHeight = data.height ?? 0;

                if (win.sizeCheckPending) {
                    win.sizeCheckPending = false;
                    win.fixSizeIfIgnored();
                }
            }
        }
    }

    Process {
        id: restorePlace

        command: ["python3", PluginPaths.of("scripts/winplace.py"), "set", win.title, win.savedPlace.split(",")[0] ?? "0", win.savedPlace.split(",")[1] ?? "0"]
    }

    // --- la misura che il compositor non ha rispettato ---------------------
    //
    // Il caso vero, misurato su questa macchina: la dashboard vive su uno
    // schermo verticale ed e' alta piu' del monitor primario. Se Mutter la
    // mappa li' — prima che `placeBack` la sposti — l'altezza viene tagliata
    // per farcela stare, e quel taglio resta anche dopo lo spostamento: la
    // finestra si riapre bassa, e nessuna proprieta' QML puo' piu' rialzarla
    // (vedi l'avvertimento in cima).
    //
    // Allora si guarda cos'e' successo davvero e, se non e' quello che si
    // voleva, si chiede al compositor — che e' lo stesso che l'ha stretta.
    // Una volta sola per apertura: se la misura salvata non ci sta nemmeno
    // sullo schermo giusto, insistere sarebbe un rimbalzo senza fine.
    function fixSizeIfIgnored() {
        if (!win.userSized || win.frameWidth <= 0 || !win.visible)
            return;

        const wantWidth = win.saved.width;
        const wantHeight = win.saved.height;

        // Gia' giusta: e' il caso normale, e non si tocca niente.
        if (Math.abs(win.width - wantWidth) < 2 && Math.abs(win.height - wantHeight) < 2)
            return;

        const borderWidth = win.frameWidth - win.width;
        const borderHeight = win.frameHeight - win.height;
        const place = win.savedPlace.length > 0 ? win.savedPlace.split(",") : [];
        const x = place.length === 2 ? place[0] : String(win.frameX);
        const y = place.length === 2 ? place[1] : String(win.frameY);

        restorePlace.command = ["python3", PluginPaths.of("scripts/winplace.py"),
            "set", win.title, x, y,
            String(wantWidth + borderWidth), String(wantHeight + borderHeight)];
        restorePlace.running = true;

        // Il ridimensionamento che sta per arrivare non e' un gesto di chi
        // guarda: senza questa riga verrebbe salvato come tale, e la finestra
        // si ricorderebbe per sempre la misura che stiamo correggendo.
        settling.restart();
    }

    Timer {
        id: sizeCheck

        // Dopo `placeBack` (400 ms): prima la finestra va sullo schermo suo,
        // poi si guarda se ci e' arrivata della misura giusta. Con margine per
        // il giro del compositor, che non e' istantaneo.
        interval: 1200
        onTriggered: {
            win.sizeCheckPending = true;
            readPlace.running = true;
        }
    }

    // Alla comparsa si rimette dove era stata lasciata. Con un attimo di
    // ritardo: il compositor deve prima averla mappata, altrimenti sposterebbe
    // una finestra che ancora non esiste per lui.
    Timer {
        id: placeBack

        interval: 400
        onTriggered: {
            if (win.savedPlace.length > 0)
                restorePlace.running = true;
        }
    }
}
