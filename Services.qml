pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Elenco dei servizi systemd e azioni su di essi.
//
// I servizi utente si comandano senza privilegi; quelli di sistema passano da
// polkit, che su GNOME apre il dialogo di autenticazione. Qui non si tenta
// nessuna scorciatoia: si invoca systemctl e si lascia decidere a polkit.
Singleton {
    id: root

    property var user: []
    property var system: []
    property bool loading: false
    property string lastError: ""
    // Unita' su cui e' in corso un comando, per bloccare i doppi click.
    property var pending: ({})

    function list(scope: string): var {
        return scope === "user" ? root.user : root.system;
    }

    function refresh() {
        if (listProc.running)
            return;
        root.loading = true;
        listProc.running = true;
    }

    // verb: start | stop | enable | disable
    function act(scope: string, unit: string, verb: string) {
        if (root.pending[unit])
            return;

        const next = Object.assign({}, root.pending);
        next[unit] = verb;
        root.pending = next;
        root.lastError = "";

        actionProc.scope = scope;
        actionProc.unit = unit;
        actionProc.command = ["systemctl"].concat(scope === "user" ? ["--user"] : []).concat([verb, unit]);
        actionProc.running = true;
    }

    function clearPending(unit: string) {
        const next = Object.assign({}, root.pending);
        delete next[unit];
        root.pending = next;
    }

    Process {
        id: listProc

        command: ["python3", PluginPaths.of("scripts/services.py")]

        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const data = JSON.parse(this.text);
                    root.user = data.user ?? [];
                    root.system = data.system ?? [];
                } catch (e) {
                    root.lastError = "Elenco servizi illeggibile: " + e;
                }
                root.loading = false;
            }
        }
    }

    Process {
        id: actionProc

        property string scope: ""
        property string unit: ""

        stderr: StdioCollector {
            id: actionErr
        }

        onExited: code => {
            // polkit restituisce un errore anche quando l'utente annulla il
            // dialogo: e' un esito legittimo, non un guasto da segnalare.
            if (code !== 0) {
                const msg = actionErr.text.trim();
                root.lastError = msg.length ? msg.split("\n")[0] : `systemctl uscito con codice ${code}`;
            }
            root.clearPending(actionProc.unit);
            // Lo stato cambia dopo il comando: si rilegge sempre, anche in
            // caso di errore, per non lasciare a video un valore falso.
            root.refresh();
        }
    }

    Component.onCompleted: root.refresh()
}
