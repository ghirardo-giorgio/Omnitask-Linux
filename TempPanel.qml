import QtQuick
import QtQuick.Layouts

// I sensori di temperatura scelti nelle opzioni, uno per riga.
//
// La barra non va da zero a cento gradi ma da venti alla soglia dichiarata dal
// sensore stesso: e' l'unico fondoscala che vuol dire qualcosa, perche' "caldo"
// per un NVMe che si spegne a 95 gradi e per uno che regge fino a 130 non e' lo
// stesso numero. Chi non dichiara nulla ricade su 90 (vedi SystemStats.tempLimit).
//
// Il valore mostrato e' la mediana degli ultimi campioni e non l'ultimo
// arrivato: le sonde del die saltano di venti gradi in un secondo, e una barra
// che le insegue e' illeggibile (vedi SystemStats.tempOf).
ColumnLayout {
    id: root

    // Il modello sono le chiavi e non i sensori: `SystemStats.temps` e' un
    // array nuovo a ogni campione, e darlo in pasto al Repeater farebbe
    // ricostruire tutte le righe una volta al secondo — le barre scatterebbero
    // invece di scorrere, perche' un delegato appena creato non ha niente da
    // cui animarsi. Le chiavi cambiano solo quando una sonda va e viene.
    readonly property var chosen: SystemStats.sensorKeys.filter(k => Settings.sensors.includes(k))

    spacing: 6

    Text {
        color: "#8b949e"
        font.pixelSize: 10
        font.letterSpacing: 1
        text: I18n.t("TEMPERATURE")
    }

    Text {
        Layout.fillWidth: true
        visible: root.chosen.length === 0
        wrapMode: Text.Wrap
        color: "#484f58"
        font.pixelSize: 10
        text: I18n.t("nessun sensore scelto (aggiungili dalle opzioni)")
    }

    Repeater {
        model: root.chosen

        StatBar {
            id: row

            required property string modelData

            // Un disco staccato porta via la propria sonda: la riga sparisce
            // finche' non torna, senza uscire dalle preferenze.
            readonly property var probe: SystemStats.sensor(row.modelData)

            // Il nome piu' corto che resta univoco: di un disco basta il
            // dispositivo (la sonda "Composite" e' *la* sua temperatura), di
            // una CPU basta la sigla del sensore, che e' gia' un nome proprio.
            // Restano lunghi solo i sensori anonimi della scheda madre, che
            // senza il nome del chip non si distinguerebbero fra loro.
            readonly property string display: {
                if (!row.probe)
                    return "";
                const s = row.probe;
                if (s.disk)
                    return s.label === "Composite" ? s.disk : `${s.disk} · ${s.label}`;
                return s.label.startsWith("temp") ? `${s.chip} · ${s.label}` : s.label;
            }

            visible: row.probe !== null
            labelWidth: 108
            label: row.display
            percent: SystemStats.tempPercent(row.probe)
            barColor: SystemStats.tempColor(row.probe)
            detail: `${SystemStats.tempOf(row.probe).toFixed(1)} °C`
        }
    }
}
