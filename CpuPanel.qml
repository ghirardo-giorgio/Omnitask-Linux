import QtQuick
import QtQuick.Layouts

// Carico della CPU: totale, andamento e barre per core.
ColumnLayout {
    id: root

    spacing: 8

    Text {
        color: "#8b949e"
        font.pixelSize: 10
        font.letterSpacing: 1
        text: I18n.t("SISTEMA")
    }

    RowLayout {
        Layout.fillWidth: true
        spacing: 6

        Text {
            color: "#c9d1d9"
            font.pixelSize: 12
            text: "CPU"
        }

        Text {
            Layout.fillWidth: true
            elide: Text.ElideRight
            color: "#6e7681"
            font.pixelSize: 10
            text: SystemStats.cpuName
        }

        // La temperatura sta qui e non in un pannello a parte: e' della CPU, e
        // si cerca dov'e' la CPU. Nel pannello Temperature restano le sonde che
        // non hanno una casa propria — quelle della scheda madre — piu' quelle
        // che si vogliono vedere in rapporto al proprio limite.
        Text {
            visible: SystemStats.cpuSensor !== null
            color: SystemStats.tempColor(SystemStats.cpuSensor)
            font.pixelSize: 11
            text: SystemStats.cpuSensor ? `${SystemStats.tempOf(SystemStats.cpuSensor).toFixed(0)} °C` : ""
        }

        // A che velocita' stanno andando i core, non solo quanto lavorano: 40%
        // a 2,2 GHz e 40% a 4,6 GHz sono due macchine diverse, e le barre qui
        // sotto le disegnano uguali.
        Text {
            visible: SystemStats.freq !== null
            color: "#8b949e"
            font.pixelSize: 10
            text: SystemStats.freq ? `${(SystemStats.freq.avg / 1000).toFixed(2)} GHz` : ""
        }

        Text {
            color: "#3fb950"
            font.pixelSize: 12
            font.bold: true
            text: `${SystemStats.cpu.toFixed(0)}%`
        }
    }

    Sparkline {
        Layout.fillWidth: true
        implicitHeight: 42
        values: SystemStats.cpuHistory
        lineColor: Settings.colorFor("cpu", "#3fb950")
        series: [
            {
                id: "cpu",
                label: I18n.t("CPU"),
                fallback: "#3fb950"
            }
        ]
    }

    CoreBars {
        Layout.fillWidth: true
        values: SystemStats.cores
    }

    // Chi decide la frequenza e fin dove puo' arrivare. Sta qui sotto e in
    // grigio perche' non cambia quasi mai: serve il giorno in cui la CPU sembra
    // lenta e la spiegazione e' che il governor e' rimasto su "powersave".
    Text {
        Layout.fillWidth: true
        visible: SystemStats.freq !== null && SystemStats.freq.governor.length > 0
        elide: Text.ElideRight
        color: "#484f58"
        font.pixelSize: 9
        text: SystemStats.freq ? I18n.t("%1 · picco %2 GHz su %3").arg(SystemStats.freq.governor).arg((SystemStats.freq.peak / 1000).toFixed(2)).arg((SystemStats.freq.max / 1000).toFixed(2)) : ""
    }
}
