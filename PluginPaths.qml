pragma Singleton

import QtQuick
import Quickshell

// Dove stanno i file di questo progetto: script Python, traduzioni, world.json.
//
// Non usa Quickshell.shellPath(), che risolve rispetto alla root della *shell in
// esecuzione*: va bene finche' shell.qml e' la shell, ma dentro un plugin la
// shell e' quella che ci ospita e ogni percorso finirebbe nella sua cartella.
// Qt.resolvedUrl() e' invece relativo a questo file, quindi risponde lo stesso
// in tutti e due i casi.
Singleton {
    id: paths

    // La cartella che contiene questo file, come percorso di filesystem: senza
    // lo schema file:// che Process e FileView non sanno leggere, e senza la
    // barra finale, che of() rimette da se'.
    readonly property string dir: {
        const u = Qt.resolvedUrl(".").toString();
        return (u.startsWith("file://") ? u.slice(7) : u).replace(/\/$/, "");
    }

    function of(rel: string): string {
        return paths.dir + "/" + rel;
    }
}
