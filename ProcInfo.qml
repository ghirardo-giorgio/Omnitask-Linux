import QtQuick
import QtQuick.Layouts

// Le informazioni di un processo, in due colonne etichetta/valore.
//
// Lo stesso blocco serve in due posti — il riquadro della finestra Processi e la
// riga aperta della finestra Rete — e le due viste devono raccontare la stessa
// cosa: chi guarda un indirizzo vuole sapere quale processo lo apre, e chi
// guarda un processo vuole sapere con chi parla.
ColumnLayout {
    id: root

    // l'oggetto restituito da `procs.py detail` (vedi Processes.detail)
    property var info: null
    property int labelWidth: 92

    readonly property var rows: {
        if (!root.info)
            return [];
        const out = [
            {
                label: I18n.t("utente"),
                value: root.info.user
            },
            {
                label: I18n.t("stato"),
                value: root.info.state
            },
            {
                label: I18n.t("processo padre"),
                value: root.info.ppid
            },
            {
                label: I18n.t("thread"),
                value: root.info.threads
            },
            {
                label: I18n.t("file aperti"),
                value: root.info.openFiles < 0 ? I18n.t("non leggibili") : String(root.info.openFiles)
            },
            {
                label: I18n.t("avviato"),
                value: new Date(root.info.startedAt * 1000).toLocaleString(Qt.locale(), "d MMM, HH:mm")
            }
        ];
        if (root.info.exe)
            out.push({
                label: I18n.t("eseguibile"),
                value: root.info.exe
            });
        if (root.info.cwd)
            out.push({
                label: I18n.t("cartella"),
                value: root.info.cwd
            });
        return out;
    }

    spacing: 1

    Repeater {
        model: root.rows

        RowLayout {
            id: line

            required property var modelData

            Layout.fillWidth: true
            spacing: 8

            Text {
                Layout.preferredWidth: root.labelWidth
                color: "#6e7681"
                font.pixelSize: 10
                text: line.modelData.label
            }

            Text {
                Layout.fillWidth: true
                // da sinistra: di un percorso lungo conta la fine, non l'inizio
                elide: Text.ElideLeft
                color: "#c9d1d9"
                font.pixelSize: 10
                text: line.modelData.value
            }
        }
    }
}
