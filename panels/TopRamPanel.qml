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
    property string panelId: "topram"
    property string panelTitle: "Classifica RAM"
    spacing: 8

    ProcList {
        title: "TOP RAM"
        accent: "#58a6ff"
        emptyText: I18n.t("in calcolo…")
        entries: SystemStats.topRam.map(a => ({
                    name: a.name,
                    value: a.bytes,
                    text: SystemStats.formatBytes(a.bytes, false)
                }))
    }
}
