pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Traduzioni dell'interfaccia.
//
// La chiave e' la stringa italiana, non un identificatore: nel codice si legge
// `I18n.t("Servizi systemd")` invece di una chiave tipo `tools.services`, l'italiano
// non ha bisogno di nessun dizionario, e a una traduzione mancante corrisponde
// l'italiano invece di una chiave tecnica o di uno spazio vuoto.
//
// Niente qsTr e niente .ts/.qm: Quickshell non espone un QTranslator da
// installare, e la toolchain di Qt Linguist vorrebbe dire aggiungere un passo di
// compilazione a un progetto che per il resto si ricarica a caldo. I dizionari
// sono JSON in lang/, e si correggono a mano mentre la dashboard gira.
//
// Non dipende da nient'altro, di proposito: cosi' un pannello che traduce una
// parola non si porta dietro anche la configurazione della dashboard. La lingua
// scelta gliela passa la shell (vedi il Binding in shell.qml).
Singleton {
    id: root

    readonly property var available: ["it", "en", "fr", "de", "es", "ja"]
    // codice imposto dalle impostazioni; vuoto = segui il sistema
    property string forced: ""

    // "en_US.UTF-8" -> "en"; una lingua che non abbiamo ricade sull'italiano,
    // che e' la lingua in cui sono scritte le chiavi
    readonly property string system: {
        const code = Qt.locale().name.split(/[_.]/)[0].toLowerCase();
        return root.available.includes(code) ? code : "it";
    }

    readonly property string lang: root.available.includes(root.forced) ? root.forced : root.system

    property var strings: ({})

    // Il binding che chiama questa funzione si rifa' da solo quando cambia
    // lingua: leggendo `strings` durante la valutazione, QML registra la
    // dipendenza anche attraverso la chiamata.
    function t(key: string): string {
        return root.strings[key] ?? key;
    }

    // Plurali: in cinque lingue non si risolvono aggiungendo una "s", quindi le
    // due forme sono due chiavi.
    function tn(n: int, one: string, many: string): string {
        return n === 1 ? root.t(one) : root.t(many).arg(n);
    }

    FileView {
        id: dictionary

        // lang/it.json esiste ed e' vuoto: tenere il percorso sempre valido
        // costa un file di due caratteri e toglie un caso speciale da qui.
        path: PluginPaths.of(`lang/${root.lang}.json`)
        watchChanges: true
        onFileChanged: reload()
        onLoaded: {
            try {
                root.strings = JSON.parse(dictionary.text());
            } catch (e) {
                root.strings = ({});
            }
        }
        // dizionario mancante: si resta all'italiano invece di mostrare stringhe
        // vuote
        onLoadFailed: root.strings = ({})
    }
}
