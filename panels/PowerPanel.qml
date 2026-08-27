import QtQuick
import QtQuick.Layouts

// Il pannello sta in panels/: senza `import ".."` si caricherebbe lo stesso,
// ma SystemStats, Settings, I18n e i componenti della dashboard resterebbero
// indefiniti — vedi scripts/panels.py, che verifica la riga e lo dice.
import ".."

// Watt assorbiti da CPU e GPU, con la legenda che lega i nomi alle bande.
ColumnLayout {

    // L'id ferma il pannello nella configurazione salvata (le colonne
    // di dashboard.json lo citano) e lo distingue nel catalogo; il titolo
    // e' quello che la finestra Opzioni mostra. Dichiarati qui, il
    // catalogo e' tutto scoperto da panels/ e Settings non tiene elenchi.
    property string panelId: "power"
    property string panelTitle: "Consumo"
    spacing: 8

    RowLayout {
        Layout.fillWidth: true

        Text {
            Layout.fillWidth: true
            color: "#c9d1d9"
            font.pixelSize: 12
            text: I18n.t("Consumo")
        }

        Text {
            color: "#e3b341"
            font.pixelSize: 12
            font.bold: true
            text: `${SystemStats.power.total.toFixed(0)} W`
        }
    }

    PowerChart {
        Layout.fillWidth: true
        cpuValues: SystemStats.cpuWattHistory
        gpuValues: SystemStats.gpuWattHistory
        cpuColor: Settings.colorFor("powerCpu", "#3fb950")
        gpuColor: Settings.colorFor("powerGpu", "#a371f7")
        series: [
            {
                id: "powerCpu",
                label: I18n.t("Consumo CPU"),
                fallback: "#3fb950"
            },
            {
                id: "powerGpu",
                label: I18n.t("Consumo GPU"),
                fallback: "#a371f7"
            }
        ]
    }

    RowLayout {
        Layout.fillWidth: true
        spacing: 6

        Rectangle {
            implicitWidth: 7
            implicitHeight: 7
            radius: 1.5
            color: Settings.colorFor("powerCpu", "#3fb950")
        }

        Text {
            Layout.fillWidth: true
            elide: Text.ElideRight
            color: "#8b949e"
            font.pixelSize: 10
            // il nome al posto della sigla, che il colore del pallino gia'
            // lega alla banda giusta del grafico
            text: SystemStats.power.cpu !== null ? `${SystemStats.cpuShortName || "CPU"} ${SystemStats.power.cpu.toFixed(0)} W` : `${SystemStats.cpuShortName || "CPU"} n/d`
        }

        Rectangle {
            Layout.leftMargin: 6
            implicitWidth: 7
            implicitHeight: 7
            radius: 1.5
            color: Settings.colorFor("powerGpu", "#a371f7")
        }

        Text {
            Layout.fillWidth: true
            elide: Text.ElideRight
            color: "#8b949e"
            font.pixelSize: 10
            text: SystemStats.power.gpu !== null ? `${SystemStats.gpuShortName || "GPU"} ${SystemStats.power.gpu.toFixed(0)} W` : `${SystemStats.gpuShortName || "GPU"} n/d`
        }

        Text {
            color: "#6e7681"
            font.pixelSize: 10
            text: `picco ${SystemStats.cpuWattHistory.length ? Math.max(...SystemStats.cpuWattHistory.map((v, i) => v + (SystemStats.gpuWattHistory[i] ?? 0))).toFixed(0) : 0} W`
        }
    }
}
