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
    property string panelId: "topgpu"
    property string panelTitle: "Classifica GPU"
    spacing: 8

    ProcList {
        title: "TOP GPU"
        accent: "#a371f7"
        emptyText: I18n.t("nessun processo sulla GPU")
        // A GPU ferma tutti i processi sono a 0% di SM: in quel caso la barra
        // segue la VRAM occupata, che e' l'unica cosa che li distingue.
        entries: {
            const list = SystemStats.topGpu;
            const busy = list.some(a => a.sm > 0);
            return list.map(a => ({
                        name: a.name,
                        value: busy ? a.sm : a.mem,
                        text: `${a.sm}%`,
                        sub: SystemStats.formatBytes(a.mem, false)
                    }));
        }
    }
}
