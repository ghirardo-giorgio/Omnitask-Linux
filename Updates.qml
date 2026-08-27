pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Applica gli aggiornamenti, di sistema e flatpak.
//
// Per i pacchetti di sistema si passa da PackageKit (`pkcon`) e non da dnf, apt
// o zypper: e' l'astrazione che quei tre condividono, quindi qui non c'e' un
// ramo per distribuzione da scrivere e da tenere aggiornato. Il conteggio degli
// aggiornamenti continua invece ad arrivare da sysmon.py, che interroga
// direttamente il gestore: e' la lista che l'utente vedrebbe dal terminale.
//
// Nessuna scorciatoia sui privilegi, come per i servizi (vedi Services.qml): si
// invoca il comando e si lascia decidere a polkit. La dashboard non tocca mai i
// pacchetti — parla al demone di PackageKit, che e' quello che fa il lavoro e
// che sopravvive alla chiusura della finestra.
Singleton {
    id: root

    // "" quando non sta girando niente, altrimenti "system" o "flatpak".
    property string busy: ""
    // fase corrente dichiarata da pkcon ("Downloading packages", "Installing")
    property string phase: ""
    // -1 quando non si sa: pkcon la stampa solo in certe fasi
    property real progress: -1
    property string message: ""
    // pkcon e' uscito con successo senza aver aggiornato niente: la sua lista
    // era vuota. E' l'unica differenza fra «fatto» e «non c'era niente da
    // fare», e senza saperla il pannello direbbe «completato» lasciando il
    // conteggio dov'era.
    property bool nothingToDo: false

    readonly property bool canUpdateSystem: SystemStats.health.updates?.packagekit ?? false

    // pkcon traduce le proprie righe: in una sessione giapponese "Status"
    // diventa "状態" e il parser qui sotto non trova piu' niente da leggere.
    // L'unica lingua che non cambia e' nessuna lingua — quello che si mostra
    // a video lo traduce I18n, non il comando.
    readonly property var plainOutput: ({
            LC_ALL: "C",
            LANG: "C"
        })

    // Prima la lista, poi l'aggiornamento.
    //
    // PackageKit tiene una cache dei metadati tutta sua
    // (/var/cache/PackageKit) e non quella di dnf, da cui viene invece il
    // conteggio che si vede nel pannello. Le due divergono: il 26 agosto 2026
    // il pannello contava sette aggiornamenti che pkcon non vedeva, con la sua
    // copia dei metadati ferma a due giorni prima. `pkcon update` usciva
    // subito con successo senza aver fatto niente, e da fuori era un pulsante
    // che non rispondeva.
    //
    // `force` e non il refresh normale: quello rispetta metadata_expire e in
    // quel caso non aveva riscaricato niente — settecento millisecondi e via.
    // Qualche secondo prima di un'operazione che ne dura molti di piu'.
    function updateSystem() {
        if (root.busy.length > 0)
            return;
        root.begin("system");
        root.phase = I18n.t("rileggo la lista dei pacchetti…");
        refreshProc.running = true;
    }

    function updateFlatpak() {
        if (root.busy.length > 0)
            return;
        root.begin("flatpak");
        flatpakProc.command = ["flatpak", "update", "-y", "--noninteractive"];
        flatpakProc.running = true;
    }

    function begin(what: string) {
        root.busy = what;
        root.phase = "";
        root.progress = -1;
        root.message = "";
        root.nothingToDo = false;
    }

    // Chiuso il comando, i conteggi che si vedono sono vecchi: far ripartire il
    // monitor li rilegge subito, invece di lasciarli sbagliati fino al prossimo
    // giro orario di health_worker.
    function finish(code: int, error: string) {
        root.busy = "";
        root.phase = "";
        root.progress = -1;
        if (code === 0) {
            // Dirlo e non tacerlo: se PackageKit non ha trovato niente mentre
            // il pannello conta ancora dei pacchetti, il pulsante ha
            // funzionato ed e' la sua lista a non combaciare con quella di
            // dnf. Sono due cose diverse da riparare, e chi guarda deve poter
            // capire quale delle due sta guardando.
            root.message = root.nothingToDo
                ? I18n.t("PackageKit non aveva niente da aggiornare")
                : I18n.t("aggiornamento completato");
            SystemStats.restart();
        } else {
            const first = error.trim().split("\n").filter(l => l.trim().length > 0);
            // polkit esce con errore anche quando si annulla il dialogo: e' un
            // esito legittimo, non un guasto da mostrare in rosso.
            root.message = first.length ? first[first.length - 1] : I18n.t("aggiornamento non riuscito (codice %1)").arg(code);
        }
    }

    Process {
        id: refreshProc

        command: ["pkcon", "refresh", "force"]
        environment: root.plainOutput

        // Un refresh andato male non ferma l'aggiornamento: puo' essere un
        // repository irraggiungibile su venti, e i pacchetti degli altri
        // diciannove si aggiornano lo stesso. Se il guasto e' serio lo dira'
        // l'update un attimo dopo, con parole sue.
        onExited: {
            root.phase = "";
            // -y: non chiedere conferma nel terminale (l'ha gia' chiesta la
            // dashboard). -p: output a righe "Chiave: valore" invece delle
            // animazioni, che a un parser non servono.
            systemProc.command = ["pkcon", "-y", "-p", "update"];
            systemProc.running = true;
        }
    }

    Process {
        id: systemProc

        environment: root.plainOutput

        stdout: SplitParser {
            onRead: line => {
                // La riga che pkcon scrive quando la sua lista e' vuota. Non ha
                // due punti e non e' una fase: si guarda prima di tutto il
                // resto, altrimenti finirebbe scartata come rumore.
                if (line.indexOf("There are no updates") >= 0) {
                    root.nothingToDo = true;
                    return;
                }

                // "Chiave:\tvalore", con la tabulazione: si divide sui due
                // punti e si toglie lo spazio che resta.
                const cut = line.indexOf(":");
                if (cut < 0)
                    return;
                const key = line.slice(0, cut).trim();
                const value = line.slice(cut + 1).trim();
                if (key === "Status")
                    root.phase = value;
                else if (key === "Percentage")
                    root.progress = parseInt(value);
            }
        }

        stderr: StdioCollector {
            id: systemErr
        }

        onExited: code => root.finish(code, systemErr.text)
    }

    Process {
        id: flatpakProc

        environment: root.plainOutput

        stdout: SplitParser {
            onRead: line => {
                const text = line.trim();
                // flatpak non ha un formato a chiavi: la riga piu' recente e'
                // gia' la cosa piu' utile da mostrare
                if (text.length > 0)
                    root.phase = text;
            }
        }

        stderr: StdioCollector {
            id: flatpakErr
        }

        onExited: code => root.finish(code, flatpakErr.text)
    }
}
