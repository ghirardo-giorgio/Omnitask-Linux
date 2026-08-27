import QtQuick
import QtQuick.Layouts

// Il pannello sta in panels/: senza `import ".."` si caricherebbe lo stesso,
// ma SystemStats, Settings, I18n e i componenti della dashboard resterebbero
// indefiniti — vedi scripts/panels.py, che verifica la riga e lo dice.
import ".."

// Memoria della scheda video: stesso trattamento della RAM, perche' e' quella
// che si riempie senza avvisare quando si caricano modelli.
ColumnLayout {
    id: root

    // L'id ferma il pannello nella configurazione salvata (le colonne
    // di dashboard.json lo citano) e lo distingue nel catalogo; il titolo
    // e' quello che la finestra Opzioni mostra. Dichiarati qui, il
    // catalogo e' tutto scoperto da panels/ e Settings non tiene elenchi.
    property string panelId: "vram"
    property string panelTitle: "VRAM"

    // I valori che prima erano scritti nel codice e adesso stanno nel file
    // di configurazione (sezione "panelParams" di dashboard.json): qui
    // resta solo il default, che il pannello registra al primo avvio.
    readonly property var defs: ({ warnPct: 90 })
    // Soglia di riempimento oltre cui la percentuale diventa rossa.
    readonly property real warnPct: Settings.panelParam("vram", "warnPct", defs.warnPct)

    Component.onCompleted: Settings.declarePanelParams("vram", defs)

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
            color: SystemStats.gpu && SystemStats.gpu.memPct > root.warnPct ? "#f85149" : "#a371f7"
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
