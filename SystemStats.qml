pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Statistiche della macchina locale.
//
// I dati arrivano da scripts/sysmon.py, che gira come processo persistente e
// stampa una riga JSON a intervalli regolari. In questo modo non viene avviato
// un nuovo processo a ogni aggiornamento della dashboard.
Singleton {
    id: root

    readonly property int historyLength: 60

    // ========================================================= CPU / GPU

    property var cores: []
    property real cpu: 0

    // Modelli hardware, normalmente costanti per tutta la vita del processo.
    property string cpuName: ""
    property string gpuName: ""

    readonly property string cpuShortName:
        root.cpuName.replace(/^(AMD|Intel|Apple)\s+/, "")

    readonly property string gpuShortName:
        root.gpuName.replace(/^(GeForce|Radeon|Arc)\s+/, "")

    // ========================================================= memoria

    property var mem: ({
        pct: 0,
        used: 0,
        total: 0,

        swapPct: 0,
        swapUsed: 0,
        swapTotal: 0,

        // Byte al secondo.
        swapIn: 0,
        swapOut: 0,

        majFaults: 0,

        // null se non esiste zram.
        zram: null
    })

    // ========================================================= rete

    property var net: ({
        rx: 0,
        tx: 0,
        iface: "—",
        interfaces: []
    })

    // null finché non arriva il primo campione oppure se la GPU non è leggibile.
    property var gpu: null

    // ========================================================= temperature

    // Tutti i sensori esposti dal kernel.
    //
    // [{ key, chip, label, disk, temp, crit, primary }]
    property var temps: []

    // Storico per ogni sensore.
    property var tempHistory: ({})

    // Le chiavi vengono aggiornate soltanto quando cambia realmente l'insieme
    // dei sensori. Questo evita che i Repeater ricreino tutti i delegati a ogni
    // campione.
    property var sensorKeys: []

    // Numero di campioni utilizzati per la media delle temperature.
    readonly property int tempSmoothing: 10

    // ========================================================= frequenza CPU

    // {
    //     cores,
    //     avg,
    //     low,
    //     peak,
    //     max,
    //     governor,
    //     driver,
    //     boost
    // }
    //
    // null dove cpufreq non è disponibile.
    property var freq: null
    property var freqHistory: []

    // ========================================================= pressure stall

    property var pressure: ({})

    property var psiCpuHistory: []
    property var psiIoHistory: []
    property var psiIoFullHistory: []
    property var psiMemHistory: []

    // ========================================================= stato sistema

    property var health: ({})

    // ========================================================= processi

    property var topCpu: []
    property var topGpu: []
    property var topVram: []
    property var topRam: []

    // ========================================================= consumo

    property var power: ({
        cpu: null,
        gpu: null,
        gpuLimit: null,
        total: 0
    })

    property var cpuWattHistory: []
    property var gpuWattHistory: []

    // ========================================================= storico generale

    property var cpuHistory: []
    property var gpuHistory: []
    property var memHistory: []

    // ========================================================= dischi

    // Ogni elemento rappresenta un disco fisico e può contenere:
    //
    // {
    //     name,
    //     model,
    //     total,
    //     formatted,
    //     used,
    //     free,
    //     pct,
    //     rotational,
    //     read,
    //     write,
    //     partitions: [...]
    // }
    property var disks: []

    // Storico read/write indicizzato per nome del disco.
    //
    // Esempio:
    //
    // {
    //     "sda": {
    //         read: [...],
    //         write: [...]
    //     }
    // }
    property var diskHistory: ({})

    // ========================================================= altri storici

    property var vramHistory: []
    property var netRxHistory: []
    property var netTxHistory: []

    // Fondoscala comune per download e upload.
    readonly property real netScale:
        Math.max(
            64 * 1024,
            ...root.netRxHistory,
            ...root.netTxHistory
        )

    // ========================================================= formattazione

    function formatBytes(bytes: real, perSecond: bool): string {
        const suffix = perSecond ? "/s" : "";

        if (bytes < 1024)
            return `${Math.round(bytes)} B${suffix}`;

        if (bytes < 1024 * 1024)
            return `${(bytes / 1024).toFixed(0)} KB${suffix}`;

        if (bytes < 1024 * 1024 * 1024)
            return `${(bytes / 1024 / 1024).toFixed(1)} MB${suffix}`;

        if (bytes < 1024 * 1024 * 1024 * 1024)
            return `${(
                bytes / 1024 / 1024 / 1024
            ).toFixed(1)} GB${suffix}`;

        return `${(
            bytes / 1024 / 1024 / 1024 / 1024
        ).toFixed(1)} TB${suffix}`;
    }

    // Durata leggibile.
    function formatDuration(seconds: real): string {
        const days = Math.floor(seconds / 86400);
        const hours = Math.floor(
            seconds % 86400 / 3600
        );
        const minutes = Math.floor(
            seconds % 3600 / 60
        );

        if (days > 0)
            return I18n.t("%1 g %2 h")
                .arg(days)
                .arg(hours);

        if (hours > 0)
            return I18n.t("%1 h %2 min")
                .arg(hours)
                .arg(minutes);

        return I18n.t("%1 min")
            .arg(minutes);
    }

    // ========================================================= sensori

    function sensor(key: string): var {
        return root.temps.find(
            t => t.key === key
        ) ?? null;
    }

    // Sensore principale della CPU.
    readonly property var cpuSensor:
        root.temps.find(
            t => t.cpu && t.main
        ) ?? null

    // Temperatura smussata tramite media degli ultimi campioni.
    function tempOf(sensor: var): real {
        if (!sensor)
            return 0;

        const history =
            root.tempHistory[sensor.key];

        if (!history || history.length === 0)
            return sensor.temp;

        const window =
            history.slice(-root.tempSmoothing);

        return window.reduce(
            (sum, value) => sum + value,
            0
        ) / window.length;
    }

    // Limite termico del sensore.
    function tempLimit(sensor: var): real {
        if (!sensor)
            return 90;

        return sensor.crit > 0
            ? sensor.crit
            : 90;
    }

    function tempColor(sensor: var): color {
        const ratio =
            sensor
            ? root.tempOf(sensor)
              / root.tempLimit(sensor)
            : 0;

        if (ratio >= 0.9)
            return "#f85149";

        if (ratio >= 0.75)
            return "#d29922";

        return "#3fb950";
    }

    // La barra parte da 20 °C per evitare che temperature normali occupino
    // una porzione troppo piccola della scala.
    function tempPercent(sensor: var): real {
        if (!sensor)
            return 0;

        const limit =
            root.tempLimit(sensor);

        return Math.max(
            0,
            Math.min(
                100,
                (
                    root.tempOf(sensor) - 20
                )
                / (limit - 20)
                * 100
            )
        );
    }

    // Sensore principale di un disco.
    function diskTemp(name: string): var {
        return root.temps.find(
            t =>
                t.disk === name
                && t.label === "Composite"
        )
        ?? root.temps.find(
            t => t.disk === name
        )
        ?? null;
    }

    // ========================================================= storico

    function push(
        history: var,
        value: real
    ): var {
        const next =
            history.concat([value]);

        return next.length > root.historyLength
            ? next.slice(
                next.length - root.historyLength
            )
            : next;
    }

    // ========================================================= restart

    // Il monitor legge alcuni parametri all'avvio.
    function restart() {
        monitor.running = false;
        monitor.running = true;
    }

    Connections {
        target: Settings

        function onTopCountChanged(): void {
            root.restart();
        }

        function onSampleIntervalChanged(): void {
            root.restart();
        }
    }

    // ========================================================= monitor

    Process {
        id: monitor

        running: true

        command: [
            "python3",
            PluginPaths.of(
                "scripts/sysmon.py"
            ),
            "--top",
            String(Settings.topCount),
            "--interval",
            String(Settings.sampleInterval)
        ]

        stdout: SplitParser {
            onRead: line => {
                let d;

                try {
                    d = JSON.parse(line);
                } catch (e) {
                    return;
                }

                // ================================================= CPU

                root.cores =
                    d.cores ?? [];

                root.cpu =
                    d.cpu ?? 0;

                root.cpuName =
                    d.cpuName ?? "";

                root.gpuName =
                    d.gpuName ?? "";

                // ================================================= memoria

                root.mem =
                    d.mem ?? ({
                        pct: 0,
                        used: 0,
                        total: 0,

                        swapPct: 0,
                        swapUsed: 0,
                        swapTotal: 0,

                        swapIn: 0,
                        swapOut: 0,

                        majFaults: 0,
                        zram: null
                    });

                // ================================================= rete

                root.net =
                    d.net ?? ({
                        rx: 0,
                        tx: 0,
                        iface: "—",
                        interfaces: []
                    });

                // ================================================= GPU

                root.gpu =
                    d.gpu ?? null;

                // ================================================= frequenza

                root.freq =
                    d.freq ?? null;

                // ================================================= pressure

                root.pressure =
                    d.pressure ?? ({});

                // ================================================= health

                root.health =
                    d.health ?? ({});

                // ================================================= temperature

                root.temps =
                    d.temps ?? [];

                if (root.temps.length > 0)
                    Settings.initSensors(
                        root.temps
                    );

                // ================================================= processi

                root.topCpu =
                    d.topCpu ?? [];

                root.topGpu =
                    d.topGpu ?? [];

                root.topVram =
                    d.topVram ?? [];

                root.topRam =
                    d.topRam ?? [];

                // ================================================= potenza

                if (d.power) {
                    root.power =
                        d.power;

                    root.cpuWattHistory =
                        root.push(
                            root.cpuWattHistory,
                            d.power.cpu ?? 0
                        );

                    root.gpuWattHistory =
                        root.push(
                            root.gpuWattHistory,
                            d.power.gpu ?? 0
                        );
                }

                // ================================================= dischi

                root.disks =
                    d.disks ?? [];

                if (d.disks) {
                    const history =
                        Object.assign(
                            {},
                            root.diskHistory
                        );

                    for (const disk of d.disks) {

                        // IMPORTANTE:
                        //
                        // Lo storico viene indicizzato con disk.name.
                        // Prima veniva letto usando disk.mount, mentre veniva
                        // salvato usando disk.name. Questo impediva di
                        // recuperare correttamente i campioni precedenti.

                        const previous =
                            history[disk.name]
                            ?? {
                                read: [],
                                write: []
                            };

                        history[disk.name] = {
                            read: root.push(
                                previous.read,
                                disk.read ?? 0
                            ),

                            write: root.push(
                                previous.write,
                                disk.write ?? 0
                            )
                        };
                    }

                    root.diskHistory =
                        history;
                }

                // ================================================= temperature

                if (d.temps) {
                    const temps =
                        Object.assign(
                            {},
                            root.tempHistory
                        );

                    for (
                        const sensor
                        of d.temps
                    ) {
                        temps[sensor.key] =
                            root.push(
                                temps[sensor.key] ?? [],
                                sensor.temp
                            );
                    }

                    root.tempHistory =
                        temps;

                    // Aggiorna le chiavi soltanto quando l'insieme dei sensori
                    // cambia realmente.
                    const keys =
                        d.temps.map(
                            t => t.key
                        );

                    if (
                        keys.length
                        !== root.sensorKeys.length

                        || keys.some(
                            (key, index) =>
                                key
                                !== root.sensorKeys[index]
                        )
                    ) {
                        root.sensorKeys =
                            keys;
                    }
                }

                // ================================================= frequenza CPU

                if (d.freq) {
                    root.freqHistory =
                        root.push(
                            root.freqHistory,
                            d.freq.avg ?? 0
                        );
                }

                // ================================================= PSI

                if (d.pressure) {
                    root.psiCpuHistory =
                        root.push(
                            root.psiCpuHistory,
                            d.pressure.cpu?.some ?? 0
                        );

                    root.psiIoHistory =
                        root.push(
                            root.psiIoHistory,
                            d.pressure.io?.some ?? 0
                        );

                    root.psiIoFullHistory =
                        root.push(
                            root.psiIoFullHistory,
                            d.pressure.io?.full ?? 0
                        );

                    root.psiMemHistory =
                        root.push(
                            root.psiMemHistory,
                            d.pressure.memory?.some ?? 0
                        );
                }

                // ================================================= storico generale

                root.cpuHistory =
                    root.push(
                        root.cpuHistory,
                        d.cpu ?? 0
                    );

                root.memHistory =
                    root.push(
                        root.memHistory,
                        d.mem?.pct ?? 0
                    );

                root.netRxHistory =
                    root.push(
                        root.netRxHistory,
                        d.net?.rx ?? 0
                    );

                root.netTxHistory =
                    root.push(
                        root.netTxHistory,
                        d.net?.tx ?? 0
                    );

                if (d.gpu) {
                    root.gpuHistory =
                        root.push(
                            root.gpuHistory,
                            d.gpu.util ?? 0
                        );

                    root.vramHistory =
                        root.push(
                            root.vramHistory,
                            d.gpu.memPct ?? 0
                        );
                }
            }
        }
    }
}