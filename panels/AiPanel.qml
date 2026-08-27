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
    property string panelId: "ai"
    property string panelTitle: "Comando IA"
    spacing: 8

    AiCommand {
        Layout.fillWidth: true
        // la richiesta di nascondersi arriva alla shell passando dal singleton:
        // dentro un Loader un segnale non avrebbe nessuno a cui arrivare
        onBeforeExecute: DashActions.hideWindow()
    }
}
