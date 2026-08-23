import QtQuick
import QtQuick.Layouts

// Memoria di sistema: andamento invece della sola barra, cosi' si vede se sta
// salendo o se e' ferma li' da un pezzo.
ColumnLayout {
    spacing: 8

    RowLayout {
        Layout.fillWidth: true
        spacing: 6

        Text {
            color: "#c9d1d9"
            font.pixelSize: 12
            text: "RAM"
        }

        Text {
            Layout.fillWidth: true
            elide: Text.ElideRight
            color: "#6e7681"
            font.pixelSize: 10
            text: `${SystemStats.formatBytes(SystemStats.mem.used, false)} / ${SystemStats.formatBytes(SystemStats.mem.total, false)}`
        }

        Text {
            color: SystemStats.mem.pct > 90 ? "#f85149" : "#58a6ff"
            font.pixelSize: 12
            font.bold: true
            text: `${SystemStats.mem.pct.toFixed(0)}%`
        }
    }

    Sparkline {
        Layout.fillWidth: true
        implicitHeight: 42
        // fondoscala fisso al 100%: la memoria si legge in rapporto al totale,
        // non al proprio massimo recente
        maxValue: 100
        values: SystemStats.memHistory
        lineColor: Settings.colorFor("ram", "#58a6ff")
        series: [
            {
                id: "ram",
                label: I18n.t("RAM"),
                fallback: "#58a6ff"
            }
        ]
    }

    // Lo swap, ma guardato dal verso giusto.
    //
    // Quanto swap sia *occupato* non vuol dire quasi niente: pagine parcheggiate
    // li' da giorni non danno fastidio a nessuno. Quello che rallenta la
    // macchina e' il traffico — pagine che entrano e escono adesso — e su zram
    // conta anche quanta RAM vera si sta risparmiando, perche' li' lo "swap" e'
    // memoria compressa, non disco.
    RowLayout {
        Layout.fillWidth: true
        visible: SystemStats.mem.swapTotal > 0
        spacing: 6

        Text {
            color: "#8b949e"
            font.pixelSize: 10
            text: I18n.t("swap")
        }

        Text {
            Layout.fillWidth: true
            elide: Text.ElideRight
            color: "#6e7681"
            font.pixelSize: 10
            text: SystemStats.mem.zram ? I18n.t("%1 in %2 · ×%3").arg(SystemStats.formatBytes(SystemStats.mem.zram.orig, false)).arg(SystemStats.formatBytes(SystemStats.mem.zram.compressed, false)).arg(SystemStats.mem.zram.ratio.toFixed(1)) : SystemStats.formatBytes(SystemStats.mem.swapUsed, false)
        }

        // Il traffico si accende solo quando c'e': uno zero permanente in due
        // colori insegnerebbe a non guardare piu' questa riga.
        Text {
            visible: SystemStats.mem.swapIn > 0 || SystemStats.mem.swapOut > 0
            color: "#d29922"
            font.pixelSize: 10
            text: `↓ ${SystemStats.formatBytes(SystemStats.mem.swapIn, true)}  ↑ ${SystemStats.formatBytes(SystemStats.mem.swapOut, true)}`
        }

        Text {
            color: SystemStats.mem.swapPct > 50 ? "#d29922" : "#6e7681"
            font.pixelSize: 10
            text: `${SystemStats.mem.swapPct.toFixed(0)}%`
        }
    }
}
