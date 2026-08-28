import QtQuick
import QtQuick.Layouts

// Il pannello sta in panels/: senza `import ".."` si caricherebbe lo stesso,
// ma SystemStats, Settings, I18n e i componenti della dashboard resterebbero
// indefiniti — vedi scripts/panels.py, che verifica la riga e lo dice.
import ".."

// Meteo attuale e previsioni, presi da Home Assistant.
//
// Nessuna citta' da scrivere da qualche parte: l'entita' meteo di Home
// Assistant e' gia' impostata sulle coordinate di casa — le stesse di sun.sun
// e del pannello Solare — e chi si sposta lo dice a Home Assistant una volta
// sola. Chi ha piu' di un'entita' "weather." sceglie la sua con il parametro
// "entity" in dashboard.json; vuoto vuol dire "quella che c'e'".
//
// Lo stato attuale viene dal polling normale degli stati (quindici secondi);
// le previsioni le scarica il singleton dal servizio weather.get_forecasts, e
// solo mentre questo pannello e' acceso (vedi watchForecast).
ColumnLayout {
    id: root

    // L'id ferma il pannello nella configurazione salvata (le colonne
    // di dashboard.json lo citano) e lo distingue nel catalogo; il titolo
    // e' quello che la finestra Opzioni mostra. Dichiarati qui, il
    // catalogo e' tutto scoperto da panels/ e Settings non tiene elenchi.
    property string panelId: "weather"
    property string panelTitle: "Meteo"

    readonly property var defs: ({
            entity: "",
            days: 5,
            hours: 6
        })

    readonly property string entityId: HomeAssistant.weatherEntity
    readonly property int days: Math.max(0, Math.min(7, Settings.panelParam("weather", "days", defs.days)))
    readonly property int hours: Math.max(0, Math.min(12, Settings.panelParam("weather", "hours", defs.hours)))

    // La condizione attuale e' lo stato dell'entita': "sunny", "rainy", ...
    readonly property string condition: HomeAssistant.state(root.entityId)
    readonly property string unit: HomeAssistant.attribute(root.entityId, "temperature_unit") ?? "°C"
    readonly property var outside: HomeAssistant.attribute(root.entityId, "temperature")
    readonly property var humidity: HomeAssistant.attribute(root.entityId, "humidity")
    readonly property var wind: HomeAssistant.attribute(root.entityId, "wind_speed")
    readonly property string windUnit: HomeAssistant.attribute(root.entityId, "wind_speed_unit") ?? "km/h"
    readonly property var uv: HomeAssistant.attribute(root.entityId, "uv_index")

    // Il nome del giorno e dell'ora seguono la lingua scelta nelle opzioni, non
    // quella del sistema: chi mette la dashboard in inglese su un sistema
    // italiano non vuole "mer" in mezzo a "Wed".
    readonly property var locales: ({
            it: "it_IT",
            en: "en_US",
            fr: "fr_FR",
            de: "de_DE",
            es: "es_ES",
            ja: "ja_JP"
        })
    readonly property string localeName: root.locales[I18n.lang] ?? "it_IT"

    // Le previsioni orarie partono dall'ora in corso: le prime voci della serie
    // possono essere gia' passate quando la risposta arriva da un quarto d'ora.
    readonly property var nextHours: {
        const now = Date.now();
        const list = HomeAssistant.forecastHourly.filter(f => new Date(f.datetime).getTime() > now - 1800000);
        return list.slice(0, root.hours);
    }

    readonly property var nextDays: HomeAssistant.forecastDaily.slice(0, root.days)

    // Glifo, colore e nome di ogni condizione di Home Assistant. Glifi di testo
    // e non emoji: le emoji arrivano colorate dal font e stonerebbero con il
    // resto della dashboard, che e' tutta monocromatica per riga.
    readonly property var looks: ({
            "sunny": ["☀", "#d29922", "sereno"],
            "clear-night": ["☾", "#8b949e", "notte serena"],
            "partlycloudy": ["⛅", "#c9a227", "poco nuvoloso"],
            "cloudy": ["☁", "#8b949e", "nuvoloso"],
            "fog": ["≡", "#6e7681", "nebbia"],
            "rainy": ["☂", "#58a6ff", "pioggia"],
            "pouring": ["☂", "#1f6feb", "pioggia forte"],
            "hail": ["❄", "#a5d6ff", "grandine"],
            "snowy": ["❄", "#a5d6ff", "neve"],
            "snowy-rainy": ["❄", "#79c0ff", "neve mista a pioggia"],
            "lightning": ["⚡", "#d29922", "temporale"],
            "lightning-rainy": ["⚡", "#e3b341", "temporale con pioggia"],
            "windy": ["≈", "#39c5cf", "vento"],
            "windy-variant": ["≈", "#39c5cf", "vento a raffiche"],
            "exceptional": ["!", "#f85149", "condizioni eccezionali"]
        })

    function look(name: string): var {
        return root.looks[name] ?? ["·", "#6e7681", name];
    }

    function glyph(name: string): string {
        return root.look(name)[0];
    }

    function tint(name: string): string {
        return root.look(name)[1];
    }

    function label(name: string): string {
        return name === "" ? "" : I18n.t(root.look(name)[2]);
    }

    // Una temperatura mancante e' "—" e non zero: sotto zero ci si va davvero,
    // e uno zero inventato sarebbe indistinguibile da una misura.
    function degrees(value: var, decimals: int): string {
        const n = parseFloat(value);
        return isFinite(n) ? `${n.toFixed(decimals)}°` : "—";
    }

    spacing: 8

    // Le previsioni si scaricano finche' il pannello e' acceso: spegnerlo le
    // lascia andare, invece di continuare a chiamare il servizio per sempre.
    Component.onCompleted: {
        Settings.declarePanelParams("weather", root.defs);
        HomeAssistant.watchForecast();
    }
    Component.onDestruction: HomeAssistant.unwatchForecast()

    RowLayout {
        Layout.fillWidth: true
        spacing: 8

        Rectangle {
            implicitWidth: 8
            implicitHeight: 8
            radius: 4
            color: HomeAssistant.online && root.entityId !== "" ? "#3fb950" : "#f85149"
        }

        Text {
            Layout.fillWidth: true
            color: "#8b949e"
            font.pixelSize: 10
            font.letterSpacing: 1
            text: I18n.t("METEO")
        }
    }

    Text {
        Layout.fillWidth: true
        visible: root.entityId === ""
        wrapMode: Text.Wrap
        color: "#484f58"
        font.pixelSize: 10
        text: I18n.t("nessuna entità meteo in Home Assistant")
    }

    // ------------------------------------------------------------- adesso
    RowLayout {
        Layout.fillWidth: true
        Layout.topMargin: 2
        visible: root.entityId !== ""
        spacing: 12

        Text {
            Layout.leftMargin: 4
            color: root.tint(root.condition)
            font.pixelSize: 34
            text: root.glyph(root.condition)
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 0

            Text {
                color: "#c9d1d9"
                font.pixelSize: 28
                text: root.degrees(root.outside, 1)
            }

            Text {
                Layout.fillWidth: true
                elide: Text.ElideRight
                color: "#8b949e"
                font.pixelSize: 11
                text: root.label(root.condition)
            }
        }

        // Il contorno della temperatura, incolonnato a destra: sono i numeri
        // che si guardano dopo aver deciso se fa caldo o freddo.
        ColumnLayout {
            Layout.alignment: Qt.AlignVCenter
            spacing: 1

            Text {
                Layout.alignment: Qt.AlignRight
                color: "#6e7681"
                font.pixelSize: 10
                text: isFinite(parseFloat(root.humidity)) ? `${I18n.t("umidità")} ${Math.round(root.humidity)}%` : ""
                visible: text !== ""
            }

            Text {
                Layout.alignment: Qt.AlignRight
                color: "#6e7681"
                font.pixelSize: 10
                text: isFinite(parseFloat(root.wind)) ? `${I18n.t("vento")} ${Math.round(root.wind)} ${root.windUnit}` : ""
                visible: text !== ""
            }

            Text {
                Layout.alignment: Qt.AlignRight
                color: parseFloat(root.uv) >= 6 ? "#d29922" : "#6e7681"
                font.pixelSize: 10
                text: isFinite(parseFloat(root.uv)) ? `UV ${parseFloat(root.uv).toFixed(1)}` : ""
                visible: text !== ""
            }
        }
    }

    // --------------------------------------------------------- prossime ore
    RowLayout {
        Layout.fillWidth: true
        Layout.topMargin: 4
        visible: root.nextHours.length > 0
        spacing: 0

        Repeater {
            model: root.nextHours

            ColumnLayout {
                id: hour

                required property var modelData

                Layout.fillWidth: true
                spacing: 1

                Text {
                    Layout.alignment: Qt.AlignHCenter
                    color: "#6e7681"
                    font.pixelSize: 9
                    text: Qt.formatTime(new Date(hour.modelData.datetime), "HH")
                }

                Text {
                    Layout.alignment: Qt.AlignHCenter
                    color: root.tint(hour.modelData.condition)
                    font.pixelSize: 14
                    text: root.glyph(hour.modelData.condition)
                }

                Text {
                    Layout.alignment: Qt.AlignHCenter
                    color: "#8b949e"
                    font.pixelSize: 10
                    text: root.degrees(hour.modelData.temperature, 0)
                }
            }
        }
    }

    // -------------------------------------------------------- prossimi giorni
    Repeater {
        model: root.nextDays

        RowLayout {
            id: day

            required property var modelData
            required property int index

            readonly property var when: new Date(day.modelData.datetime)
            readonly property real rain: parseFloat(day.modelData.precipitation)

            Layout.fillWidth: true
            spacing: 8

            Text {
                Layout.preferredWidth: 34
                color: day.index === 0 ? "#c9d1d9" : "#8b949e"
                font.pixelSize: 11
                // "oggi" invece del nome del giorno: la prima riga e' sempre la
                // giornata in corso, e leggerne il nome costringe a pensarci.
                text: day.index === 0 ? I18n.t("oggi") : day.when.toLocaleDateString(Qt.locale(root.localeName), "ddd")
            }

            Text {
                Layout.preferredWidth: 18
                horizontalAlignment: Text.AlignHCenter
                color: root.tint(day.modelData.condition)
                font.pixelSize: 14
                text: root.glyph(day.modelData.condition)
            }

            // La pioggia prevista sta dove c'e': una giornata asciutta lascia
            // la colonna vuota invece di scrivere "0 mm", che si legge come un
            // dato e invece e' l'assenza di uno.
            Text {
                Layout.fillWidth: true
                elide: Text.ElideRight
                color: "#58a6ff"
                font.pixelSize: 10
                text: isFinite(day.rain) && day.rain > 0 ? `${day.rain.toFixed(1)} mm` : ""
            }

            Text {
                color: "#6e7681"
                font.pixelSize: 11
                text: root.degrees(day.modelData.templow, 0)
            }

            Text {
                Layout.preferredWidth: 34
                horizontalAlignment: Text.AlignRight
                color: "#c9d1d9"
                font.pixelSize: 11
                text: root.degrees(day.modelData.temperature, 0)
            }
        }
    }

    Text {
        Layout.fillWidth: true
        visible: root.entityId !== "" && root.nextDays.length === 0
        wrapMode: Text.Wrap
        color: "#484f58"
        font.pixelSize: 10
        text: I18n.t("previsioni non disponibili")
    }
}
