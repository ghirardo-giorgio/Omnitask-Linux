pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Inventario dell'hardware, letto da scripts/hardware.py.
//
// Non e' un campionamento: una scheda PCI non compare mentre guardi, e il
// processore non cambia modello. Si legge alla prima apertura della finestra e
// poi solo se qualcuno preme aggiorna — a differenza di SystemStats, che gira
// ogni due secondi perche' misura differenze fra campioni.
//
// L'unica cosa che puo' cambiare davvero e' l'USB: una chiavetta infilata
// adesso non c'e' nell'elenco di prima. Per quello serve il pulsante.
Singleton {
    id: root

    property var board: ({})
    property var cpu: ({})
    property var memory: ({})
    property var graphics: []
    property var audio: ({
            cards: [],
            controllers: [],
            server: ""
        })
    property var network: []
    property var storage: []
    property var displays: []
    property var usb: []
    property var pci: []

    property bool loading: false
    property bool loaded: false
    property string lastError: ""

    function refresh() {
        if (probe.running)
            return;
        root.loading = true;
        root.lastError = "";
        probe.running = true;
    }

    // Si legge alla prima richiesta e non all'avvio della shell: la dashboard
    // parte con la sessione, e l'inventario serve solo a chi apre la finestra.
    function ensure() {
        if (!root.loaded && !root.loading)
            root.refresh();
    }

    Process {
        id: probe

        command: ["python3", PluginPaths.of("scripts/hardware.py")]

        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const data = JSON.parse(this.text);
                    root.board = data.board ?? ({});
                    root.cpu = data.cpu ?? ({});
                    root.memory = data.memory ?? ({});
                    root.graphics = data.graphics ?? [];
                    root.audio = data.audio ?? ({
                            cards: [],
                            controllers: [],
                            server: ""
                        });
                    root.network = data.network ?? [];
                    root.storage = data.storage ?? [];
                    root.displays = data.displays ?? [];
                    root.usb = data.usb ?? [];
                    root.pci = data.pci ?? [];
                    root.loaded = true;
                } catch (e) {
                    root.lastError = "Inventario hardware illeggibile: " + e;
                }
                root.loading = false;
            }
        }

        stderr: StdioCollector {
            id: probeErr
        }

        onExited: code => {
            if (code !== 0) {
                const msg = probeErr.text.trim();
                root.lastError = msg.length > 0 ? msg.split("\n").slice(-1)[0] : `hardware.py uscito con codice ${code}`;
                root.loading = false;
            }
        }
    }

    // --------------------------------------------------------- formattazione

    function bytes(value: var): string {
        if (value === undefined || value === null || value <= 0)
            return "—";
        return SystemStats.formatBytes(value, false);
    }

    // "AMD Ryzen 7 5700X 8-Core Processor" -> "AMD Ryzen 7 5700X": la coda
    // ripete quello che dice gia' il conteggio dei core, e in un elenco stretto
    // ruba lo spazio al modello.
    function trimCpu(name: string): string {
        return (name || "").replace(/\s*\d+-Core Processor\s*$/i, "").replace(/\s*(CPU|Processor)\s*@.*$/i, "").trim();
    }

    // La versione USB dice poco: un dispositivo 2.0 dentro una porta 3.0
    // dichiara comunque 2.00. La velocita' negoziata invece e' quella vera.
    function usbSpeed(mbit: var): string {
        if (!mbit)
            return "";
        if (mbit >= 10000)
            return "USB 3.1 (10 Gb/s)";
        if (mbit >= 5000)
            return "USB 3.0 (5 Gb/s)";
        if (mbit >= 480)
            return "USB 2.0 (480 Mb/s)";
        return `USB 1.1 (${mbit} Mb/s)`;
    }
}
