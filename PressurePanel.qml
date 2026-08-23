import QtQuick
import QtQuick.Layouts

// Quanto tempo i processi passano fermi ad aspettare, invece di lavorare.
//
// Non e' l'utilizzo visto da un'altra angolazione: un disco al 100% che serve
// una coda corta non fa male a nessuno, un disco al 30% con tutti in attesa sta
// strozzando la macchina. E' la metrica che risponde a "perche' adesso e'
// lento" quando CPU e RAM sembrano a posto.
ColumnLayout {
    id: root

    // Il grafico mostra l'istante (ricavato dal contatore cumulativo, vedi
    // pressure() in sysmon.py), il numero a destra la media di un minuto: uno
    // dice cosa sta succedendo, l'altro se sta succedendo da un po'.
    readonly property var rows: [
        {
            label: I18n.t("CPU"),
            id: "psiCpu",
            color: Settings.colorFor("psiCpu", "#3fb950"),
            fallback: "#3fb950",
            values: SystemStats.psiCpuHistory,
            values2: [],
            avg: SystemStats.pressure.cpu?.someAvg60 ?? 0
        },
        {
            label: I18n.t("Disco"),
            id: "psiIo",
            color: Settings.colorFor("psiIo", "#db6d28"),
            fallback: "#db6d28",
            values: SystemStats.psiIoHistory,
            // la seconda banda e' `full`: non "qualcuno aspetta" ma "nessuno
            // riesce a lavorare", che e' la differenza fra lento e fermo
            values2: SystemStats.psiIoFullHistory,
            avg: SystemStats.pressure.io?.someAvg60 ?? 0
        },
        {
            label: I18n.t("Memoria"),
            id: "psiMem",
            color: Settings.colorFor("psiMem", "#58a6ff"),
            fallback: "#58a6ff",
            values: SystemStats.psiMemHistory,
            values2: [],
            avg: SystemStats.pressure.memory?.someAvg60 ?? 0
        }
    ]

    spacing: 6

    Text {
        color: "#8b949e"
        font.pixelSize: 10
        font.letterSpacing: 1
        text: I18n.t("PRESSIONE")
    }

    Repeater {
        model: root.rows

        ColumnLayout {
            id: row

            required property var modelData

            Layout.fillWidth: true
            spacing: 1

            RowLayout {
                Layout.fillWidth: true
                spacing: 6

                Text {
                    Layout.fillWidth: true
                    color: "#c9d1d9"
                    font.pixelSize: 11
                    text: row.modelData.label
                }

                Text {
                    // sotto l'uno per cento non c'e' niente da vedere: resta
                    // grigio, cosi' l'occhio si ferma solo dove serve
                    color: row.modelData.avg >= 10 ? "#f85149" : row.modelData.avg >= 1 ? "#d29922" : "#6e7681"
                    font.pixelSize: 11
                    font.bold: row.modelData.avg >= 1
                    text: I18n.t("%1% nel minuto").arg(row.modelData.avg.toFixed(1))
                }
            }

            Sparkline {
                Layout.fillWidth: true
                implicitHeight: 30
                // fondoscala fisso: la pressione si legge in assoluto, non in
                // rapporto al proprio massimo recente — un picco del 2% su una
                // macchina tranquilla non deve riempire il grafico
                maxValue: 100
                values: row.modelData.values
                lineColor: row.modelData.color
                values2: row.modelData.values2
                // il rosso di `full` non si sceglie: non e' decorazione ma la
                // soglia oltre cui nessuno riesce piu' a lavorare
                lineColor2: "#f85149"
                series: [
                    {
                        id: row.modelData.id,
                        label: row.modelData.label,
                        fallback: row.modelData.fallback
                    }
                ]
            }
        }
    }

    Text {
        Layout.fillWidth: true
        Layout.topMargin: 2
        wrapMode: Text.Wrap
        color: "#484f58"
        font.pixelSize: 9
        text: I18n.t("tempo passato in attesa di una risorsa: sopra il 10% la macchina sta aspettando piu' di quanto lavori")
    }
}
