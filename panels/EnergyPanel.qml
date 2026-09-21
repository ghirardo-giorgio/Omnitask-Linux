import QtQuick
import QtQuick.Layouts

// Il pannello sta in panels/: senza `import ".."` si caricherebbe lo stesso,
// ma SystemStats, Settings, I18n e i componenti della dashboard resterebbero
// indefiniti — vedi scripts/panels.py, che verifica la riga e lo dice.
import ".."

// Quanta energia ha bevuto il computer da quando l'hai acceso.
//
// E' la domanda che il pannello «Consumo» non risponde: quello dice i watt, e
// i watt sono una fotografia. Centoventi watt adesso non dicono niente su come
// e' andata la giornata, perche' la giornata e' l'integrale — i wattora — e un
// integrale non si ricostruisce guardando l'ultimo campione. Va accumulato
// mentre passa, e infatti lo accumula scripts/sysmon.py, non questo file.
//
// ---- Cosa e' misurato e cosa e' stimato -----------------------------------
//
// Misurato davvero: il package della CPU (contatore RAPL, esatto) e la scheda
// video (potenza istantanea di nvidia-smi, integrata a rettangoli). Sono i due
// grossi, ma NON sono il computer: mancano scheda madre, RAM, dischi, ventole,
// le perdite dell'alimentatore e il monitor.
//
// Quindi il numero grande e' una STIMA, costruita cosi':
//
//     (misurati + baseWatts x tempo) / psuEfficiency
//
// `baseWatts` e' il resto della macchina, che a una macchina fissa e' quasi
// costante e quindi si lascia stimare bene da un numero solo; `psuEfficiency`
// e' il rendimento dell'alimentatore, che spiega perche' alla presa arriva
// piu' di quanto i componenti consumano. Tutti e due stanno nei panelParams
// perche' dipendono dalla macchina: chi ha un wattmetro da presa li tara in
// dieci minuti, e chi non ce l'ha tiene i default, che sono ragionevoli per un
// fisso senza troppe ventole.
//
// La stima si ferma prima del monitor, di proposito: quello ha una sua presa e
// una sua accensione, e sommarlo qui vorrebbe dire inventare un numero che non
// segue nemmeno lo stesso orario.
//
// L'onesta' di tutto questo sta in `seconds`, che sysmon.py pubblica accanto
// ai totali: sono i secondi DAVVERO misurati, e quando sono meno del tempo
// acceso — dashboard aperta a giornata iniziata, macchina che ha dormito — il
// pannello lo scrive invece di far credere di aver visto tutto.
ColumnLayout {
    id: root

    // L'id ferma il pannello nella configurazione salvata (le colonne di
    // dashboard.json lo citano) e lo distingue nel catalogo; il titolo e'
    // quello che la finestra Opzioni mostra.
    property string panelId: "energy"
    property string panelTitle: "Energia"

    // La tendina della tariffa: chiusa, perche' i parametri si toccano una
    // volta e poi il pannello torna a essere un contatore.
    property bool tuning: false

    readonly property var defs: ({
            // Il resto del computer, in watt: scheda madre, RAM, dischi,
            // ventole. Trentacinque e' la stima buona per un fisso a riposo.
            baseWatts: 35,
            // Rendimento dell'alimentatore ai carichi normali. Un 80 Plus
            // Bronze sta sul 0,85, un Gold sul 0,90.
            psuEfficiency: 0.9,
            // Il prezzo del chilowattora, quello della bolletta.
            pricePerKwh: 0.32,
            // Il simbolo con cui si scrive quel prezzo: da lui dipendono anche
            // i decimali del costo, perche' lo yen non ne ha.
            currency: "€",
            // La tariffa della stagione alta, per i contratti che ne hanno una
            // (in Giappone e' la norma: le letture di luglio, agosto e
            // settembre costano di piu'). Zero vuol dire «una tariffa sola», ed
            // e' il caso di chi non ha stagioni: cosi' il campo esiste per
            // tutti e non cambia niente a chi non lo usa.
            summerPricePerKwh: 0,
            // In quali mesi vale, scritti come li scriverebbe una persona.
            summerMonths: "7,8,9",
            // Giri del disco per chilowattora. Un contatore di casa ne fa 600,
            // ma misura una casa: qui servono per vedere il disco muoversi.
            revPerKwh: 3000,
            hours: true
        })

    readonly property real baseWatts: Settings.panelParam("energy", "baseWatts", defs.baseWatts)
    readonly property real psuEfficiency: Math.max(0.1, Settings.panelParam("energy", "psuEfficiency", defs.psuEfficiency))
    readonly property real pricePerKwh: Settings.panelParam("energy", "pricePerKwh", defs.pricePerKwh)
    readonly property string currency: String(Settings.panelParam("energy", "currency", defs.currency))
    readonly property real summerPricePerKwh: Settings.panelParam("energy", "summerPricePerKwh", defs.summerPricePerKwh)
    readonly property string summerMonths: String(Settings.panelParam("energy", "summerMonths", defs.summerMonths))
    readonly property real revPerKwh: Settings.panelParam("energy", "revPerKwh", defs.revPerKwh)
    readonly property bool hours: Settings.panelParam("energy", "hours", defs.hours)

    readonly property var e: SystemStats.energy

    // ---- i conti ------------------------------------------------------------

    readonly property real measuredWh: (root.e.cpuWh ?? 0) + (root.e.gpuWh ?? 0)
    readonly property real restWh: root.baseWatts * (root.e.seconds ?? 0) / 3600
    readonly property real wallWh: (root.measuredWh + root.restWh) / root.psuEfficiency

    // I watt di adesso passati per la stessa stima del totale: se il disco
    // girasse sulla potenza misurata e l'odometro contasse quella stimata, i
    // due strumenti direbbero due cose diverse guardandosi in faccia.
    readonly property real wallWatts: ((SystemStats.power.total ?? 0) + root.baseWatts) / root.psuEfficiency

    // Che mese e', secondo l'orologio di chi misura: `now` arriva da
    // sysmon.py a ogni giro, quindi il primo del mese la tariffa cambia da
    // sola senza che nessuno riapra la dashboard.
    readonly property int month: ((root.e.now ?? 0) > 0 ? new Date(root.e.now * 1000) : new Date()).getMonth() + 1

    // I mesi estivi come li ha scritti l'utente: «7,8,9», o «7, 8, 9», o anche
    // con una virgola di troppo in fondo. Quello che non e' un mese si butta,
    // invece di far diventare la tariffa un caso da studiare.
    readonly property var summerList: {
        const out = [];

        for (const piece of root.summerMonths.split(",")) {
            const n = parseInt(piece.trim(), 10);

            if (n >= 1 && n <= 12)
                out.push(n);
        }

        return out;
    }

    readonly property bool summerNow: root.summerPricePerKwh > 0 && root.summerList.includes(root.month)
    readonly property real effectivePrice: root.summerNow ? root.summerPricePerKwh : root.pricePerKwh

    readonly property real cost: root.wallWh / 1000 * root.effectivePrice

    // Le migliaia e i decimali come li scrive la lingua scelta — 1.234,50 in
    // italiano, 1,234.50 altrove — con la stessa tabella di panels/SolarPanel.qml.
    readonly property var locales: ({
            it: "it_IT", en: "en_US", fr: "fr_FR", de: "de_DE", es: "es_ES", ja: "ja_JP"
        })
    readonly property string localeName: root.locales[I18n.lang] ?? "it_IT"

    // Quante cifre dopo la virgola vuole questa valuta. Lo yen non ha
    // centesimi: «128,00 ¥» non e' un prezzo scritto con precisione, e' un
    // prezzo scritto da chi non sa cos'e' uno yen.
    readonly property int moneyDecimals: ["¥", "円", "₩", "원"].includes(root.currency.trim()) ? 0 : 2

    function money(value: real): string {
        return `${value.toLocaleString(Qt.locale(root.localeName), 'f', root.moneyDecimals)} ${root.currency}`;
    }

    // Il PREZZO del chilowattora, che e' un'altra cosa dal costo: due decimali
    // sempre, perche' anche in yen la tariffa si scrive 27,32 — e arrotondarla
    // a 27 vorrebbe dire mostrare un numero che non sta su nessuna bolletta.
    function rate(value: real): string {
        return `${value.toLocaleString(Qt.locale(root.localeName), 'f', 2)} ${root.currency}`;
    }

    // Quanto dell'accensione e' stato davvero misurato.
    readonly property real awake: Math.max(1, (root.e.now ?? 0) - (root.e.bootAt ?? 0))
    readonly property real coverage: Math.min(1, (root.e.seconds ?? 0) / root.awake)
    // Sotto questa soglia il buco si scrive. Il tre per cento e' il margine
    // per i secondi persi fra l'avvio del sistema e l'avvio della dashboard,
    // che ci sono sempre e non sono un difetto da segnalare ogni volta.
    readonly property bool partial: root.coverage < 0.97

    function clock(epoch: real): string {
        return epoch > 0 ? Qt.formatDateTime(new Date(epoch * 1000), "HH:mm") : "—";
    }

    readonly property var series: [
        {
            id: "energy",
            label: I18n.t("Energia"),
            fallback: "#e3b341"
        },
        {
            id: "energyMark",
            label: I18n.t("Indice del contatore"),
            fallback: "#f85149"
        }
    ]

    readonly property color mainColor: Settings.colorFor("energy", "#e3b341")
    readonly property color markColor: Settings.colorFor("energyMark", "#f85149")

    spacing: 8

    Component.onCompleted: Settings.declarePanelParams("energy", defs)

    // ---- intestazione -------------------------------------------------------

    RowLayout {
        Layout.fillWidth: true

        Text {
            Layout.fillWidth: true
            color: "#c9d1d9"
            font.pixelSize: 12
            text: I18n.t("Energia")
        }

        Text {
            color: root.mainColor
            font.pixelSize: 12
            font.bold: true
            text: root.money(root.cost)
        }

        // L'ingranaggio della tariffa. Sta accanto al costo e non in cima al
        // pannello perche' e' quel numero che apre: chi lo guarda e lo trova
        // sbagliato ha il posto per correggerlo li' dove ha visto l'errore.
        Rectangle {
            implicitWidth: 20
            implicitHeight: 18
            radius: 5
            color: root.tuning || gearHover.hovered ? "#161b22" : "transparent"
            border.width: 1
            border.color: root.tuning ? "#30363d" : gearHover.hovered ? "#30363d" : "transparent"

            Text {
                anchors.centerIn: parent
                color: root.tuning ? "#c9d1d9" : gearHover.hovered ? "#c9d1d9" : "#6e7681"
                font.pixelSize: 11
                text: "⚙"
            }

            HoverHandler {
                id: gearHover

                cursorShape: Qt.PointingHandCursor
            }

            Tooltip {
                hovered: gearHover.hovered
                text: I18n.t("tariffa e parametri della macchina")
            }

            TapHandler {
                onSingleTapped: root.tuning = !root.tuning
            }
        }
    }

    // ---- la tendina della tariffa -------------------------------------------
    //
    // Si apre DENTRO il riquadro e non come scheda sospesa: il pannello vive in
    // una colonna che scorre, e una scheda sospesa uscirebbe dal riquadro (e'
    // la stessa ragione scritta in panels/IgrometroPanel.qml).
    ColumnLayout {
        Layout.fillWidth: true
        visible: root.tuning
        spacing: 4

        // Quale tariffa e' in vigore adesso, e perche'. Senza questa riga il
        // campo della tariffa estiva sembrerebbe ignorato tutto l'anno tranne
        // che d'estate, e non si saprebbe se e' rotto o se non e' il momento.
        Text {
            Layout.fillWidth: true
            elide: Text.ElideRight
            color: root.summerNow ? "#e3b341" : "#8b949e"
            font.pixelSize: 10
            text: root.summerNow ? I18n.t("tariffa estiva (%1): %2 per kWh").arg(Qt.locale(root.localeName).standaloneMonthName(root.month - 1)).arg(root.rate(root.effectivePrice)) : I18n.t("tariffa in vigore: %1 per kWh").arg(root.rate(root.effectivePrice))
        }

        ParamField {
            Layout.fillWidth: true
            panel: "energy"
            key: "pricePerKwh"
            label: I18n.t("Tariffa")
            unit: `${root.currency}/kWh`
            fallback: root.defs.pricePerKwh
            hint: I18n.t("il prezzo del chilowattora che paghi davvero, supplementi compresi")
            maximum: 1000
        }

        ParamField {
            Layout.fillWidth: true
            panel: "energy"
            key: "summerPricePerKwh"
            label: I18n.t("Tariffa estiva")
            unit: `${root.currency}/kWh`
            fallback: root.defs.summerPricePerKwh
            hint: I18n.t("zero se il contratto ha una tariffa sola tutto l'anno")
            maximum: 1000
        }

        ParamField {
            Layout.fillWidth: true
            panel: "energy"
            key: "summerMonths"
            label: I18n.t("Mesi estivi")
            fallback: root.defs.summerMonths
            hint: I18n.t("i mesi in cui vale la tariffa estiva, separati da virgola")
            numeric: false
        }

        ParamField {
            Layout.fillWidth: true
            panel: "energy"
            key: "currency"
            label: I18n.t("Valuta")
            fallback: root.defs.currency
            hint: I18n.t("il simbolo scritto dopo il costo: lo yen non ha decimali, l'euro sì")
            numeric: false
            fieldWidth: 44
        }

        ParamField {
            Layout.fillWidth: true
            panel: "energy"
            key: "baseWatts"
            label: I18n.t("Resto del computer")
            unit: "W"
            fallback: root.defs.baseWatts
            hint: I18n.t("scheda madre, RAM, dischi e ventole: quello che i contatori non vedono")
            decimals: 0
            maximum: 500
        }

        ParamField {
            Layout.fillWidth: true
            panel: "energy"
            key: "psuEfficiency"
            label: I18n.t("Rendimento alimentatore")
            fallback: root.defs.psuEfficiency
            hint: I18n.t("0,85 per un 80 Plus Bronze, 0,90 per un Gold")
            minimum: 0.1
            maximum: 1
        }

        ParamField {
            Layout.fillWidth: true
            panel: "energy"
            key: "revPerKwh"
            label: I18n.t("Giri per kWh")
            fallback: root.defs.revPerKwh
            hint: I18n.t("quanto in fretta gira il disco: è solo l'aspetto, non cambia i conti")
            decimals: 0
            minimum: 1
            maximum: 100000
        }

        // L'unico parametro che non e' un numero da scrivere: si accende e si
        // spegne, quindi e' un pallino da toccare e non un campo.
        Text {
            Layout.fillWidth: true
            elide: Text.ElideRight
            color: hoursHover.hovered ? "#58a6ff" : root.hours ? "#c9d1d9" : "#8b949e"
            font.pixelSize: 10
            text: `${root.hours ? "●" : "○"} ${I18n.t("Mostra la giornata")}`

            HoverHandler {
                id: hoursHover

                cursorShape: Qt.PointingHandCursor
            }

            TapHandler {
                onSingleTapped: Settings.setPanelParam("energy", "hours", !root.hours)
            }
        }
    }

    // ---- il contatore -------------------------------------------------------

    RowLayout {
        Layout.fillWidth: true
        spacing: 10

        ColumnLayout {
            spacing: 3

            EnergyDisc {
                Layout.alignment: Qt.AlignHCenter
                watts: root.wallWatts
                revPerKwh: root.revPerKwh
                discColor: root.mainColor
                markColor: root.markColor
            }

            Text {
                Layout.alignment: Qt.AlignHCenter
                color: "#8b949e"
                font.pixelSize: 10
                text: `${root.wallWatts.toFixed(0)} W`
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 3

            EnergyOdometer {
                value: root.wallWh
                digitColor: "#e6edf3"
                decimalColor: root.mainColor
            }

            Text {
                color: "#6e7681"
                font.pixelSize: 10
                text: "W·h"
            }
        }
    }

    // ---- la giornata --------------------------------------------------------

    EnergyHours {
        Layout.fillWidth: true
        visible: root.hours
        hours: root.e.hours ?? []
        baseWatts: root.baseWatts
        psuEfficiency: root.psuEfficiency
        barColor: root.mainColor
        series: root.series
    }

    // ---- la riga onesta -----------------------------------------------------

    Item {
        Layout.fillWidth: true
        implicitHeight: note.implicitHeight

        Text {
            id: note

            width: parent.width
            elide: Text.ElideRight
            color: "#6e7681"
            font.pixelSize: 10
            text: root.partial ? `${I18n.t("acceso alle %1").arg(root.clock(root.e.bootAt ?? 0))} · ${I18n.t("misurato da %1").arg(root.clock(root.e.startedAt ?? 0))}` : `${I18n.t("acceso alle %1").arg(root.clock(root.e.bootAt ?? 0))} · CPU ${(root.e.cpuWh ?? 0).toFixed(0)} · GPU ${(root.e.gpuWh ?? 0).toFixed(0)} Wh`
        }

        HoverHandler {
            id: hover
        }

        // Il conto per esteso: quello che il numero grande nasconde, e che chi
        // vuole tarare la stima deve poter leggere senza aprire il sorgente.
        Tooltip {
            hovered: hover.hovered
            text: [I18n.t("Stima alla presa"), I18n.t("misurati CPU %1 Wh e GPU %2 Wh").arg((root.e.cpuWh ?? 0).toFixed(1)).arg((root.e.gpuWh ?? 0).toFixed(1)), I18n.t("resto del computer stimato a %1 W: %2 Wh").arg(root.baseWatts.toFixed(0)).arg(root.restWh.toFixed(1)), I18n.t("rendimento alimentatore %1%").arg((root.psuEfficiency * 100).toFixed(0)), I18n.t("tariffa applicata %1 per kWh").arg(root.rate(root.effectivePrice)), I18n.t("misurato il %1% del tempo acceso").arg((root.coverage * 100).toFixed(0))].join("\n")
        }
    }
}
