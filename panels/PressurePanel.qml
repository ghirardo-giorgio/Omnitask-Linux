import QtQuick
import QtQuick.Layouts

// Il pannello sta in panels/: senza `import ".."` si caricherebbe lo stesso,
// ma SystemStats, Settings, I18n e i componenti della dashboard resterebbero
// indefiniti — vedi scripts/panels.py, che verifica la riga e lo dice.
import ".."

// Quanto tempo i processi passano fermi ad aspettare, invece di lavorare.
//
// Non e' l'utilizzo visto da un'altra angolazione: un disco al 100% che serve
// una coda corta non fa male a nessuno, un disco al 30% con tutti in attesa sta
// strozzando la macchina. E' la metrica che risponde a "perche' adesso e'
// lento" quando CPU e RAM sembrano a posto.
ColumnLayout {
    id: root

    // L'id ferma il pannello nella configurazione salvata (le colonne
    // di dashboard.json lo citano) e lo distingue nel catalogo; il titolo
    // e' quello che la finestra Opzioni mostra. Dichiarati qui, il
    // catalogo e' tutto scoperto da panels/ e Settings non tiene elenchi.
    property string panelId: "pressure"
    property string panelTitle: "Pressione"

    // I valori che prima erano scritti nel codice e adesso stanno nel file
    // di configurazione (sezione "panelParams" di dashboard.json): qui
    // resta solo il default, che il pannello registra al primo avvio.
    readonly property var defs: ({
            warnPct: 1,
            badPct: 10
        })
    // Soglie sulla media di un minuto: oltre `warnPct` il numero si accende,
    // oltre `badPct` diventa rosso e in grassetto.
    readonly property real warnPct: Settings.panelParam("pressure", "warnPct", defs.warnPct)
    readonly property real badPct: Settings.panelParam("pressure", "badPct", defs.badPct)

    Component.onCompleted: Settings.declarePanelParams("pressure", defs)

    // Il grafico mostra l'istante (ricavato dal contatore cumulativo, vedi
    // pressure() in sysmon.py), il numero a destra la media di un minuto: uno
    // dice cosa sta succedendo, l'altro se sta succedendo da un po'.
    readonly property var rows: [
        {
            label: I18n.t("CPU"),
            id: "psiCpu",
            color: Settings.colorFor("psiCpu", "#3fb950"),
            fallback: "#3fb950",
            values: SystemStats.psiCpuHistory,
            values2: [],
            avg: SystemStats.pressure.cpu?.someAvg60 ?? 0
        },
        {
            label: I18n.t("Disco"),
            id: "psiIo",
            color: Settings.colorFor("psiIo", "#db6d28"),
            fallback: "#db6d28",
            values: SystemStats.psiIoHistory,
            // la seconda banda e' `full`: non "qualcuno aspetta" ma "nessuno
            // riesce a lavorare", che e' la differenza fra lento e fermo
            values2: SystemStats.psiIoFullHistory,
            avg: SystemStats.pressure.io?.someAvg60 ?? 0
        },
        {
            label: I18n.t("Memoria"),
            id: "psiMem",
            color: Settings.colorFor("psiMem", "#58a6ff"),
            fallback: "#58a6ff",
            values: SystemStats.psiMemHistory,
            values2: [],
            avg: SystemStats.pressure.memory?.someAvg60 ?? 0
        }
    ]

    // I primi tre di SystemStats.cgroups, e solo mentre la memoria e' sotto
    // pressione: `warnPct` e' la stessa soglia oltre cui il numero della
    // memoria si accende, quindi l'elenco compare esattamente quando la barra
    // comincia a chiedere «per colpa di chi».
    readonly property var culprits: {
        const psi = SystemStats.pressure.memory?.someAvg60 ?? 0;
        if (psi < root.warnPct)
            return [];
        return (SystemStats.cgroups ?? []).slice(0, 3);
    }

    function gb(bytes: real): string {
        return (bytes / 1073741824).toFixed(1) + " GB";
    }

    spacing: 6

    Text {
        color: "#8b949e"
        font.pixelSize: 10
        font.letterSpacing: 1
        text: I18n.t("PRESSIONE")
    }

    Repeater {
        model: root.rows

        ColumnLayout {
            id: row

            required property var modelData

            Layout.fillWidth: true
            spacing: 1

            RowLayout {
                Layout.fillWidth: true
                spacing: 6

                Text {
                    Layout.fillWidth: true
                    color: "#c9d1d9"
                    font.pixelSize: 11
                    text: row.modelData.label
                }

                Text {
                    // sotto la prima soglia non c'e' niente da vedere: resta
                    // grigio, cosi' l'occhio si ferma solo dove serve
                    color: row.modelData.avg >= root.badPct ? "#f85149" : row.modelData.avg >= root.warnPct ? "#d29922" : "#6e7681"
                    font.pixelSize: 11
                    font.bold: row.modelData.avg >= root.warnPct
                    text: I18n.t("%1% nel minuto").arg(row.modelData.avg.toFixed(1))
                }
            }

            Sparkline {
                Layout.fillWidth: true
                implicitHeight: 30
                // fondoscala fisso: la pressione si legge in assoluto, non in
                // rapporto al proprio massimo recente — un picco del 2% su una
                // macchina tranquilla non deve riempire il grafico
                maxValue: 100
                values: row.modelData.values
                lineColor: row.modelData.color
                values2: row.modelData.values2
                // il rosso di `full` non si sceglie: non e' decorazione ma la
                // soglia oltre cui nessuno riesce piu' a lavorare
                lineColor2: "#f85149"
                series: [
                    {
                        id: row.modelData.id,
                        label: row.modelData.label,
                        fallback: row.modelData.fallback
                    }
                ]
            }
        }
    }

    // ---- Chi la memoria ce l'ha ------------------------------------------
    //
    // 🔴 Le barre qui sopra dicono QUANTO si aspetta, mai per colpa di chi, ed
    // e' la domanda che si fa ogni volta che diventano rosse. La pressione per
    // cgroup — che sarebbe la risposta ovvia — non la da': misura quanto ognuno
    // ha ATTESO, quindi in cima ci finiscono la shell grafica e l'editor, cioe'
    // le vittime, mentre chi si e' preso la memoria per primo non aspetta
    // niente. Questa riga mostra invece chi la OCCUPA.
    //
    // La colonna che conta e' `shmem`: la cache il kernel la butta via quando
    // serve, la memoria condivisa no — si puo' solo swappare, una pagina alla
    // volta, mentre tutti gli altri aspettano.
    //
    // Compare solo quando la memoria e' davvero sotto pressione: a macchina
    // tranquilla sarebbe una classifica di cose normali, e tre righe in piu'
    // in un pannello che si guarda di sfuggita.
    ColumnLayout {
        Layout.fillWidth: true
        Layout.topMargin: 4
        spacing: 1
        visible: root.culprits.length > 0

        Text {
            color: "#8b949e"
            font.pixelSize: 9
            font.letterSpacing: 1
            text: I18n.t("CHI OCCUPA LA MEMORIA")
        }

        Repeater {
            model: root.culprits

            RowLayout {
                id: culprit

                required property var modelData

                Layout.fillWidth: true
                spacing: 6

                Text {
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                    color: "#c9d1d9"
                    font.pixelSize: 10
                    // Il comando quando c'e', il nome del cgroup quando manca:
                    // gli scope delle app grafiche si chiamano tutti
                    // `app-org.chromium.Chromium-<pid>.scope` — e' cosi' che si
                    // annuncia ogni applicazione Electron — e senza il comando
                    // un'app qualunque si legge «Chromium» e sembra il browser.
                    text: culprit.modelData.comm && culprit.modelData.comm.length > 0
                          ? culprit.modelData.comm
                          : culprit.modelData.name
                }

                // Quanta di quella memoria non si puo' buttare. Rossa quando e'
                // la maggior parte: e' la forma che ha il guaio, non la misura.
                Text {
                    visible: culprit.modelData.shmem > 0
                    color: culprit.modelData.shmem > culprit.modelData.mem / 2 ? "#f85149" : "#8b949e"
                    font.pixelSize: 10
                    text: I18n.t("%1 condivisa").arg(root.gb(culprit.modelData.shmem))
                }

                Text {
                    color: "#8b949e"
                    font.pixelSize: 10
                    font.bold: true
                    text: root.gb(culprit.modelData.mem)
                }
            }
        }
    }

    Text {
        Layout.fillWidth: true
        Layout.topMargin: 2
        wrapMode: Text.Wrap
        color: "#484f58"
        font.pixelSize: 9
        text: I18n.t("tempo passato in attesa di una risorsa: sopra il 10% la macchina sta aspettando piu' di quanto lavori")
    }
}
