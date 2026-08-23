import QtQuick
import QtQuick.Layouts

// Memoria della scheda video: stesso trattamento della RAM, perche' e' quella
// che si riempie senza avvisare quando si caricano modelli.
ColumnLayout {
    spacing: 8

    RowLayout {
        Layout.fillWidth: true
        spacing: 6

        Text {
            color: "#c9d1d9"
            font.pixelSize: 12
            text: "VRAM"
        }

        Text {
            Layout.fillWidth: true
            elide: Text.ElideRight
            color: "#6e7681"
            font.pixelSize: 10
            text: SystemStats.gpu ? `${SystemStats.formatBytes(SystemStats.gpu.memUsed, false)} / ${SystemStats.formatBytes(SystemStats.gpu.memTotal, false)}` : "—"
        }

        Text {
            color: SystemStats.gpu && SystemStats.gpu.memPct > 90 ? "#f85149" : "#a371f7"
            font.pixelSize: 12
            font.bold: true
            text: SystemStats.gpu ? `${SystemStats.gpu.memPct.toFixed(0)}%` : "n/d"
        }
    }

    Sparkline {
        Layout.fillWidth: true
        implicitHeight: 42
        maxValue: 100
        values: SystemStats.vramHistory
        lineColor: Settings.colorFor("vram", "#a371f7")
        series: [
            {
                id: "vram",
                label: I18n.t("VRAM"),
                fallback: "#a371f7"
            }
        ]
    }
}
