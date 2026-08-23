import QtQuick
import QtQuick.Layouts
import Quickshell

// Stato e storico delle entita' di Home Assistant scelte nelle opzioni.
ColumnLayout {
    id: root

    spacing: 8

    RowLayout {
        Layout.fillWidth: true
        spacing: 8

        Rectangle {
            implicitWidth: 8
            implicitHeight: 8
            radius: 4
            color: HomeAssistant.online ? "#3fb950" : "#f85149"
        }

        Text {
            Layout.fillWidth: true
            color: "#8b949e"
            font.pixelSize: 10
            font.letterSpacing: 1
            text: "HOME ASSISTANT"
        }
    }

    Repeater {
        model: Settings.haEntities

        ColumnLayout {
            id: entityBlock

            required property string modelData

            readonly property string unit: HomeAssistant.unit(modelData)

            // Il colore di partenza dipende dall'unita': arancio per i gradi,
            // ciano per la CO2, azzurro per il resto. Resta il default da cui
            // si parte, ma la scelta si ricorda per singola entita' e non per
            // unita': due sensori di temperatura in due stanze diverse si
            // vogliono poter distinguere a colpo d'occhio.
            readonly property string tone: entityBlock.unit === "°C" ? "#db6d28" : entityBlock.unit === "ppm" ? "#39c5cf" : "#58a6ff"

            Layout.fillWidth: true
            Layout.bottomMargin: 4
            spacing: 0

            EntityRow {
                entityId: entityBlock.modelData
            }

            HistoryChart {
                Layout.fillWidth: true
                // di una luce o di un termostato lo storico non dice nulla:
                // si spegne per entita' dalle opzioni
                visible: Settings.chartEnabled(entityBlock.modelData)
                values: HomeAssistant.history[entityBlock.modelData] ?? []
                hours: HomeAssistant.historyHours
                decimals: entityBlock.unit === "ppm" ? 0 : 1
                lineColor: Settings.colorFor(`ha:${entityBlock.modelData}`, entityBlock.tone)
                // il prefisso tiene le entita' lontane dalle serie di sistema:
                // un'entita' si chiama "sensor.qualcosa", ma nulla lo garantisce
                series: [
                    {
                        id: `ha:${entityBlock.modelData}`,
                        label: HomeAssistant.friendlyName(entityBlock.modelData),
                        fallback: entityBlock.tone
                    }
                ]
            }
        }
    }

    // Dice al singleton di quali entita' scaricare lo storico: solo quelle che
    // un grafico ce l'hanno davvero.
    Binding {
        target: HomeAssistant
        property: "historyEntities"
        value: Settings.haChartEntities
    }

    Text {
        Layout.fillWidth: true
        visible: Settings.haEntities.length === 0
        wrapMode: Text.Wrap
        color: "#484f58"
        font.pixelSize: 10
        text: I18n.t("nessuna entita' scelta (aggiungile dalle opzioni)")
    }
}
