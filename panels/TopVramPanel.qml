import QtQuick
import QtQuick.Layouts

// Il pannello sta in panels/: senza `import ".."` si caricherebbe lo stesso,
// ma SystemStats, Settings, I18n e i componenti della dashboard resterebbero
// indefiniti — vedi scripts/panels.py, che verifica la riga e lo dice.
import ".."

// Classifica VRAM: da elenco a barre a torta, la stessa forma del cugino
// RAM. L'occupato che i processi nominati non coprono (driver, buffer) e'
// la fetta grigia, il resto della capacita' la fetta verde "VRAM libera".
ColumnLayout {

    // L'id ferma il pannello nella configurazione salvata (le colonne
    // di dashboard.json lo citano) e lo distingue nel catalogo; il titolo
    // e' quello che la finestra Opzioni mostra. Dichiarati qui, il
    // catalogo e' tutto scoperto da panels/ e Settings non tiene elenchi.
    property string panelId: "topvram"
    property string panelTitle: "Classifica VRAM"
    spacing: 8

    PieList {
        title: "TOP VRAM"
        emptyText: I18n.t("nessun processo sulla GPU")
        freeLabel: I18n.t("VRAM libera")
        // Stesso taglio del cugino RAM: sei fette, a prescindere da
        // topCount, che governa solo le classifiche CPU e GPU.
        entries: SystemStats.topVram.slice(0, 6).map(a => ({
                    name: a.name,
                    value: a.mem,
                    // Il carico SM del processo accanto ai suoi byte: sysmon
                    // lo manda gia' in ogni entry di topVram (campo `sm`,
                    // 0 quando il processo non sta disegnando).
                    text: `${SystemStats.formatBytes(a.mem, false)} · GPU ${(a.sm ?? 0).toFixed(0)}%`
                }))
        // Null di protezione: senza GPU la capacita' non si conosce, e la
        // torta si accontenta di raccontare quello che sa.
        used: SystemStats.gpu ? (SystemStats.gpu.memUsed ?? 0) : 0
        total: SystemStats.gpu ? (SystemStats.gpu.memTotal ?? 0) : 0
    }
}
