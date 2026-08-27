import QtQuick
import QtQuick.Layouts

// Il pannello sta in panels/: senza `import ".."` si caricherebbe lo stesso,
// ma SystemStats, Settings, I18n e i componenti della dashboard resterebbero
// indefiniti — vedi scripts/panels.py, che verifica la riga e lo dice.
import ".."

// Carico della scheda video: utilizzo, temperatura e andamento.
ColumnLayout {

    // L'id ferma il pannello nella configurazione salvata (le colonne
    // di dashboard.json lo citano) e lo distingue nel catalogo; il titolo
    // e' quello che la finestra Opzioni mostra. Dichiarati qui, il
    // catalogo e' tutto scoperto da panels/ e Settings non tiene elenchi.
    property string panelId: "gpu"
    property string panelTitle: "GPU"
    spacing: 8

    RowLayout {
        Layout.fillWidth: true
        spacing: 6

        Text {
            color: "#c9d1d9"
            font.pixelSize: 12
            text: "GPU"
        }

        Text {
            Layout.fillWidth: true
            elide: Text.ElideRight
            color: "#6e7681"
            font.pixelSize: 10
            text: SystemStats.gpuName
        }

        Text {
            color: "#8b949e"
            font.pixelSize: 11
            text: SystemStats.gpu ? `${SystemStats.gpu.temp}°C` : ""
        }

        Text {
            Layout.leftMargin: 8
            color: "#a371f7"
            font.pixelSize: 12
            font.bold: true
            text: SystemStats.gpu ? `${SystemStats.gpu.util}%` : "n/d"
        }
    }

    Sparkline {
        Layout.fillWidth: true
        implicitHeight: 42
        values: SystemStats.gpuHistory
        lineColor: Settings.colorFor("gpu", "#a371f7")
        series: [
            {
                id: "gpu",
                label: I18n.t("GPU"),
                fallback: "#a371f7"
            }
        ]
    }
}
