pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// I pannelli che l'utente ha messo in panels/, scoperti a ogni avvio.
//
// Sono codice, non configurazione: un .qml puo' avviare processi, leggere file
// e parlare in rete, esattamente come i pannelli di casa e senza nessun
// confinamento. Chi ne installa uno scritto da altri sta eseguendo il
// programma di qualcun altro con i propri permessi. La finestra Opzioni lo
// dice invece di far finta che siano dati (vedi OptionsPanel).
//
// Perche' devono stare li' dentro e non dove capita: Quickshell registra i
// singleton per cartella di configurazione, e un file fuori si carica ma vede
// SystemStats, Settings e I18n tutti indefiniti — provato, e nessun import lo
// rimedia. Dentro, con `import ".."` in cima, funziona tutto.
Singleton {
    id: root

    property var entries: []
    property string directory: ""
    property string lastError: ""
    property bool loading: false

    // Le voci utilizzabili: quelle senza errore di forma. Le altre restano in
    // `entries` per essere mostrate col loro guasto, ma non entrano nel
    // catalogo — un pannello che non puo' caricarsi non deve comparire fra
    // quelli accendibili.
    readonly property var usable: root.entries.filter(p => !p.error)

    readonly property var broken: root.entries.filter(p => p.error)

    function refresh() {
        if (scan.running)
            return;
        root.loading = true;
        scan.running = true;
    }

    Process {
        id: scan

        command: ["python3", PluginPaths.of("scripts/panels.py")]

        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const data = JSON.parse(this.text);
                    root.entries = data.panels ?? [];
                    root.directory = data.directory ?? "";
                    root.lastError = data.ok ? "" : (data.error ?? "");
                } catch (e) {
                    root.lastError = "Elenco dei pannelli illeggibile: " + e;
                }
                root.loading = false;
            }
        }

        onExited: code => {
            if (code !== 0) {
                root.lastError = `panels.py uscito con codice ${code}`;
                root.loading = false;
            }
        }
    }

    // Una volta all'avvio. Non c'e' un osservatore sulla cartella: un pannello
    // nuovo si aggiunge copiando un file, cosa che si fa una volta ogni tanto
    // e non mentre si guarda la dashboard — e le Opzioni hanno il pulsante per
    // rileggere senza riavviare.
    Component.onCompleted: root.refresh()
}
