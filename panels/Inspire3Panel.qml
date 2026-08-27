import QtQuick
import QtQuick.Layouts

// Il pannello sta in panels/: senza `import ".."` si caricherebbe lo stesso,
// ma SystemStats, Settings, I18n e i componenti della dashboard resterebbero
// indefiniti — vedi scripts/panels.py, che verifica la riga e lo dice.
import ".."

// La batteria dell'Inspire 3 cosi' come Home Assistant la riceve dal
// dispositivo: una percentuale e l'orario dell'ultima sincronizzazione.
//
// Stesso disegno della batteria solare — lo stesso componente, BatteryGauge —
// perche' due batterie nella stessa colonna sono la stessa cosa disegnata due
// volte: chi guarda deve riconoscerle a colpo d'occhio come "batterie", e
// distinguersi solo per il titolo. In orizzontale sempre, come quella solare.
ColumnLayout {
    id: root

    // L'id finisce nelle colonne di dashboard.json; il titolo e' quello che
    // la finestra Opzioni mostra.
    property string panelId: "inspire"
    property string panelTitle: "Inspire 3"

    // I valori che prima erano scritti nel codice e adesso stanno nel file
    // di configurazione (sezione "panelParams" di dashboard.json): qui resta
    // solo il default, che il pannello registra al primo avvio.
    readonly property var defs: ({
            batteryEntity: "sensor.inspire_3_battery",
            syncEntity: "sensor.inspire_3_last_sync_time"
        })
    readonly property string batteryEntity: Settings.panelParam("inspire", "batteryEntity", defs.batteryEntity)
    readonly property string syncEntity: Settings.panelParam("inspire", "syncEntity", defs.syncEntity)

    Component.onCompleted: Settings.declarePanelParams("inspire", defs)

    // --- i numeri -----------------------------------------------------------
    // La percentuale arriva gia' pronta dal dispositivo: niente basi di
    // giornata ne' contatori da sottrarre, il sensore e' il numero. parseFloat
    // su "unavailable" da NaN, ed e' il modo piu' corto di dire che adesso
    // non c'e' nessuna lettura.
    readonly property real percentRaw: parseFloat(HomeAssistant.state(root.batteryEntity))
    readonly property bool hasData: isFinite(root.percentRaw)
    readonly property real fraction: root.hasData ? Math.max(0, Math.min(100, root.percentRaw)) / 100 : 0
    readonly property bool full: root.hasData && root.percentRaw >= 99.5
    readonly property string fillColor: root.full ? "#3fb950" : "#e3b341"

    // L'ultima sincronizzazione dice quanto e' fresco il numero: una batteria
    // letta tre giorni fa non e' uno stato, e' una nota di servizio. Un
    // orario non interpretabile vale come nessun orario.
    readonly property var syncedAt: {
        const raw = HomeAssistant.state(root.syncEntity);
        const when = raw ? new Date(raw) : null;
        return when && !isNaN(when.getTime()) ? when : null;
    }

    function syncLabel(when: date): string {
        const now = new Date();
        const sameDay = when.getFullYear() === now.getFullYear()
                && when.getMonth() === now.getMonth()
                && when.getDate() === now.getDate();

        // Oggi basta l'ora; altrimenti data e ora, in cifre: i nomi dei mesi
        // seguirebbero la locale del sistema e non quella scelta qui.
        return Qt.formatDateTime(when, sameDay ? "HH:mm" : "dd/MM HH:mm");
    }

    spacing: 8

    RowLayout {
        Layout.fillWidth: true
        spacing: 6

        Text {
            color: "#c9d1d9"
            font.pixelSize: 12
            text: "INSPIRE 3"
        }

        // Se Home Assistant non risponde dirlo qui costa una parola e spiega
        // perche' la batteria qui sotto non si muove.
        Text {
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignRight
            visible: !HomeAssistant.online
            elide: Text.ElideRight
            color: "#f85149"
            font.pixelSize: 10
            text: I18n.t("irraggiungibile")
        }
    }

    RowLayout {
        Layout.fillWidth: true
        spacing: 14

        // --- la batteria ----------------------------------------------------
        BatteryGauge {
            Layout.preferredWidth: 134
            Layout.preferredHeight: 58
            fraction: root.fraction
            fillColor: root.fillColor
            full: root.full
        }

        // --- i numeri accanto -------------------------------------------------
        // Allineati al bordo destro, come nel pannello solare: le due
        // batterie si leggono con lo stesso sguardo.
        ColumnLayout {
            Layout.fillWidth: true
            spacing: 4

            Text {
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignRight
                visible: root.hasData
                color: root.fillColor
                font.pixelSize: 26
                font.bold: true
                text: `${Math.round(root.percentRaw)}%`
            }

            Text {
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignRight
                visible: !root.hasData
                color: "#6e7681"
                font.pixelSize: 26
                font.bold: true
                text: I18n.t("n/d")
            }

            Text {
                elide: Text.ElideRight
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignRight
                color: "#8b949e"
                font.pixelSize: 11
                visible: root.syncedAt !== null
                text: root.syncedAt ? I18n.t("ultima sincronizzazione %1").arg(root.syncLabel(root.syncedAt)) : ""
            }

            Text {
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignRight
                visible: root.full
                color: "#3fb950"
                font.pixelSize: 11
                text: I18n.t("piena")
            }
        }
    }
}
