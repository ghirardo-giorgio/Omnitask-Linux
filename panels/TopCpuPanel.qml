import QtQuick
import QtQuick.Layouts

// Il pannello sta in panels/: senza `import ".."` si caricherebbe lo stesso,
// ma SystemStats, Settings, I18n e i componenti della dashboard resterebbero
// indefiniti — vedi scripts/panels.py, che verifica la riga e lo dice.
import ".."

ColumnLayout {

    // L'id ferma il pannello nella configurazione salvata (le colonne
    // di dashboard.json lo citano) e lo distingue nel catalogo; il titolo
    // e' quello che la finestra Opzioni mostra. Dichiarati qui, il
    // catalogo e' tutto scoperto da panels/ e Settings non tiene elenchi.
    property string panelId: "topcpu"
    property string panelTitle: "Classifica CPU"
    spacing: 8

    ProcList {
        title: "TOP CPU"
        accent: "#3fb950"
        emptyText: I18n.t("nessun processo attivo")
        entries: SystemStats.topCpu.map(a => ({
                    name: a.name,
                    value: a.pct,
                    text: `${a.pct.toFixed(1)}%`
                }))
    }
}
