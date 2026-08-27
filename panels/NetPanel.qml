import QtQuick
import QtQuick.Layouts

// Il pannello sta in panels/: senza `import ".."` si caricherebbe lo stesso,
// ma SystemStats, Settings, I18n e i componenti della dashboard resterebbero
// indefiniti — vedi scripts/panels.py, che verifica la riga e lo dice.
import ".."

ColumnLayout {
    id: root

    // L'id ferma il pannello nella configurazione salvata (le colonne
    // di dashboard.json lo citano) e lo distingue nel catalogo; il titolo
    // e' quello che la finestra Opzioni mostra. Dichiarati qui, il
    // catalogo e' tutto scoperto da panels/ e Settings non tiene elenchi.
    property string panelId: "net"
    property string panelTitle: "Rete"

    spacing: 8

    // Doppio clic: apre l'elenco di chi sta usando la rete. Doppio e non
    // singolo perche' il pannello non ha altre azioni e un clic per sbaglio
    // non deve far comparire una finestra.
    //
    // Handler e non MouseArea: dentro un layout un item con anchors ha
    // geometria indefinita — il layout lo dispone come una riga e le anchors
    // lo tirano altrove — e smette di ricevere i clic al primo ricalcolo. Gli
    // input handler non sono item e non entrano nel layout.
    TapHandler {
        acceptedButtons: Qt.LeftButton
        onDoubleTapped: DashActions.openNetwork()
    }

    HoverHandler {
        cursorShape: Qt.PointingHandCursor
    }

    RowLayout {
        Layout.fillWidth: true

        Text {
            Layout.fillWidth: true
            elide: Text.ElideRight
            color: "#c9d1d9"
            font.pixelSize: 12
            // L'interfaccia da cui vengono i numeri qui accanto, e basta: con
            // una VPN accesa diventa il tunnel da sola.
            text: I18n.t("Rete") + ` · ${SystemStats.net.iface}`
        }

        Text {
            color: Settings.colorFor("netRx", "#58a6ff")
            font.pixelSize: 11
            text: `↓ ${SystemStats.formatBytes(SystemStats.net.rx, true)}`
        }

        Text {
            Layout.leftMargin: 8
            color: Settings.colorFor("netTx", "#db6d28")
            font.pixelSize: 11
            text: `↑ ${SystemStats.formatBytes(SystemStats.net.tx, true)}`
        }
    }

    Sparkline {
        Layout.fillWidth: true
        implicitHeight: 42
        maxValue: SystemStats.netScale
        values: SystemStats.netRxHistory
        lineColor: Settings.colorFor("netRx", "#58a6ff")
        values2: SystemStats.netTxHistory
        lineColor2: Settings.colorFor("netTx", "#db6d28")
        series: [
            {
                id: "netRx",
                label: I18n.t("Download"),
                fallback: "#58a6ff"
            },
            {
                id: "netTx",
                label: I18n.t("Upload"),
                fallback: "#db6d28"
            }
        ]
    }
}
