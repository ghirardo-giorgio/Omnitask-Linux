import QtQuick
import Quickshell
import Quickshell.Io

// Una finestra che nasce della misura giusta e ricorda quella scelta da chi la
// usa.
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
                if (data.ok && data.x !== undefined)
                    Settings.saveWindowPlace(win.key, data.x, data.y);
            }
        }
    }

    Process {
        id: restorePlace

        command: ["python3", PluginPaths.of("scripts/winplace.py"), "set", win.title, win.savedPlace.split(",")[0] ?? "0", win.savedPlace.split(",")[1] ?? "0"]
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
