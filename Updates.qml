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

    readonly property bool canUpdateSystem: SystemStats.health.updates?.packagekit ?? false

    function updateSystem() {
        if (root.busy.length > 0)
            return;
        root.begin("system");
        // -y: non chiedere conferma nel terminale (l'ha gia' chiesta la
        // dashboard). -p: output a righe "Chiave: valore" invece delle
        // animazioni, che a un parser non servono.
        systemProc.command = ["pkcon", "-y", "-p", "update"];
        systemProc.running = true;
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
    }

    // Chiuso il comando, i conteggi che si vedono sono vecchi: far ripartire il
    // monitor li rilegge subito, invece di lasciarli sbagliati fino al prossimo
    // giro orario di health_worker.
    function finish(code: int, error: string) {
        root.busy = "";
        root.phase = "";
        root.progress = -1;
        if (code === 0) {
            root.message = I18n.t("aggiornamento completato");
            SystemStats.restart();
        } else {
            const first = error.trim().split("\n").filter(l => l.trim().length > 0);
            // polkit esce con errore anche quando si annulla il dialogo: e' un
            // esito legittimo, non un guasto da mostrare in rosso.
            root.message = first.length ? first[first.length - 1] : I18n.t("aggiornamento non riuscito (codice %1)").arg(code);
        }
    }

    Process {
        id: systemProc

        stdout: SplitParser {
            onRead: line => {
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
