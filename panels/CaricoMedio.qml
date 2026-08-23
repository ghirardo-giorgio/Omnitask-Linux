// Pannello d'esempio: il carico medio del sistema, letto da /proc/loadavg.
//
// Le due righe che contano sono l'`import ".."` qui sotto — senza, SystemStats
// e I18n restano indefiniti — e il fatto che la radice sia un elemento
// visuale che si dimensiona da se': dentro il Loader della dashboard le sue
// Layout.* non contano, conta l'implicitHeight.
import QtQuick
import QtQuick.Layouts
// I moduli di Quickshell vanno importati per nome: `import ".."` porta dentro
// i singleton e i componenti della dashboard (SystemStats, I18n, StatBar), non
// il resto della libreria.
import Quickshell.Io
import ".."

ColumnLayout {
    id: root

    // Titolo mostrato nelle Opzioni. Senza, si usa il nome del file.
    property string panelTitle: "Carico medio"

    property var load: [0, 0, 0]

    spacing: 6

    FileView {
        id: loadavg

        path: "/proc/loadavg"
        onLoaded: {
            const parts = loadavg.text().trim().split(/\s+/);
            root.load = [parseFloat(parts[0]), parseFloat(parts[1]), parseFloat(parts[2])];
        }
    }

    Timer {
        running: true
        interval: 5000
        repeat: true
        triggeredOnStart: true
        onTriggered: loadavg.reload()
    }

    RowLayout {
        Layout.fillWidth: true

        Text {
            Layout.fillWidth: true
            color: "#c9d1d9"
            font.pixelSize: 12
            text: root.panelTitle
        }

        Text {
            color: "#6e7681"
            font.pixelSize: 10
            text: SystemStats.cores.length + " thread"
        }
    }

    Repeater {
        model: [
            {
                label: "1 min",
                value: root.load[0]
            },
            {
                label: "5 min",
                value: root.load[1]
            },
            {
                label: "15 min",
                value: root.load[2]
            }
        ]

        StatBar {
            required property var modelData

            label: modelData.label
            labelWidth: 44
            // Cento per cento = un carico pari al numero di thread: oltre,
            // c'e' piu' lavoro in coda di quanto la macchina ne possa fare.
            percent: Math.min(100, modelData.value / Math.max(1, SystemStats.cores.length) * 100)
            detail: modelData.value.toFixed(2)
        }
    }
}
