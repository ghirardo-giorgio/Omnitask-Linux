import QtQuick
import QtQuick.Layouts

// Il pannello sta in panels/: senza `import ".."` si caricherebbe lo stesso,
// ma SystemStats, Settings, I18n e i componenti della dashboard resterebbero
// indefiniti — vedi scripts/panels.py, che verifica la riga e lo dice.
import ".."

// Classifica RAM: da elenco a barre a torta. Le fette sono le prime sei
// app; l'occupato che nessuna di loro nomina e' la fetta grigia "altre
// app", il resto della capacita' la fetta verde "RAM libera".
ColumnLayout {

    // L'id ferma il pannello nella configurazione salvata (le colonne
    // di dashboard.json lo citano) e lo distingue nel catalogo; il titolo
    // e' quello che la finestra Opzioni mostra. Dichiarati qui, il
    // catalogo e' tutto scoperto da panels/ e Settings non tiene elenchi.
    property string panelId: "topram"
    property string panelTitle: "Classifica RAM"
    spacing: 8

    PieList {
        title: "TOP RAM"
        emptyText: I18n.t("in calcolo…")
        freeLabel: I18n.t("RAM libera")
        // sysmon ne manda sei per le torte, a prescindere da topCount:
        // il taglio a sei qui e' la guardia se un domani la configurazione
        // ne portasse di piu'.
        entries: SystemStats.topRam.slice(0, 6).map(a => ({
                    name: a.name,
                    value: a.bytes,
                    // Il carico CPU del processo accanto ai suoi byte: e'
                    // il numero che sysmon aggiunge a ogni entry di topRam
                    // (0 quando in quell'intervallo non ha toccato la CPU).
                    text: `${SystemStats.formatBytes(a.bytes, false)} · CPU ${(a.cpu ?? 0).toFixed(0)}%`
                }))
        // "libera" qui e' MemAvailable: totale meno usato, lo stesso
        // numero che il pannello RAM mette in percentuale.
        used: SystemStats.mem.used
        total: SystemStats.mem.total
    }
}
