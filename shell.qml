//@ pragma UseQApplication

import QtQuick
import Quickshell
import Quickshell.Io

ShellRoot {
    id: shell

    // La lingua scelta arriva a I18n da qui: il singleton delle traduzioni non
    // legge le impostazioni da se', cosi' i pannelli che traducono una parola
    // non si portano dietro anche la configurazione della dashboard.
    Binding {
        target: I18n
        property: "forced"
        value: Settings.language
    }

    // Su GNOME (Mutter) manca wlr-layer-shell, quindi si usa una finestra
    // normale. Su Hyprland/sway/niri sostituisci FloatingWindow con:
    //   PanelWindow { anchors { top: true; right: true; bottom: true } }
    MemoryWindow {
        id: win

        title: "Dashboard"
        key: "dashboard"
        defaultWidth: 740
        defaultHeight: 720

        // Non nascere con la misura per difetto: attende che Settings abbia
        // finito di leggere la configurazione (lettura asincrona), poi appare
        // con la dimensione salvata. Lo `saved`/`userSized` di MemoryWindow
        // sono `readonly`: se questa finestra, l'unica visibile all'avvio, si
        // mappasse prima che il file sia arrivato, si fisserebbero sui default
        // e la dashboard non ricorderebbe la dimensione al riavvio — mentre le
        // altre, nascoste e aperte dopo, la ricordano gia'.
        visible: Settings.ready

        contentWidth: dash.implicitWidth
        contentHeight: dash.implicitHeight

        Dashboard {
            id: dash

            anchors.fill: parent
        }
    }

    // Le finestre secondarie e le richieste che le aprono. Stanno in un file a
    // parte perche' servono anche al plugin Omarchy, dove non c'e' nessuno
    // ShellRoot: vedi PanelHost.qml.
    PanelHost {
        id: host

        onHideDashboard: win.visible = false
    }

    // Permette di mostrare/nascondere le finestre senza riavviare il processo:
    //   qs ipc call dashboard toggle
    // Comodo da legare a una scorciatoia di GNOME.
    IpcHandler {
        target: "dashboard"

        // Non chiamarle "show"/"hide": `show` e' gia' un sottocomando di
        // `qs ipc`, e verrebbe intercettato prima di arrivare qui.
        function open(): void {
            win.visible = true;
        }

        function close(): void {
            win.visible = false;
        }

        function toggle(): void {
            win.visible = !win.visible;
        }

        function status(): string {
            return win.visible ? "visible" : "hidden";
        }

        function services(): void {
            host.servicesWindow.visible = !host.servicesWindow.visible;
        }

        function processes(): void {
            host.processesWindow.visible = !host.processesWindow.visible;
        }

        function network(): void {
            host.networkWindow.visible = !host.networkWindow.visible;
        }

        function hardware(): void {
            host.hardwareWindow.visible = !host.hardwareWindow.visible;
        }

        // Dimensioni attuali delle finestre e misure memorizzate: serve a
        // capire, dopo un ridimensionamento col mouse, se QML se ne e' accorto.
        //   qs ipc call dashboard winsize
        function winsize(): string {
            return "dashboard " + win.width + "x" + win.height + " (implicita " + win.implicitWidth + "x" + win.implicitHeight + ")" + " | rete " + host.networkWindow.width + "x" + host.networkWindow.height + " (implicita " + host.networkWindow.implicitWidth + "x" + host.networkWindow.implicitHeight + ")" + " | salvate: " + Settings.windowList();
        }

        // --- superficie per il server MCP (vedi Query.qml) ---------------
        // Due ingressi distinti, e distinti apposta: `query` non tocca niente,
        // `haAct` e' l'unico che modifica qualcosa. Le altre funzioni qui
        // sopra sono interruttori — chiamare `panel` per leggere spegne il
        // pannello — e non vanno esposte a chi sta solo facendo domande.
        //
        // Entrambe prendono e restituiscono JSON come stringa:
        //   qs ipc call dashboard query '{"topic":"capabilities"}'
        function query(request: string): string {
            return Query.answer(request);
        }

        function haAct(request: string): string {
            return Query.act(request);
        }

        function options(): void {
            host.optionsWindow.visible = !host.optionsWindow.visible;
        }

        // La chat di Hermes, per chi la vuole senza passare dal pannello:
        //   qs ipc call dashboard hermes
        function hermes(): void {
            host.hermesWindow.visible = !host.hermesWindow.visible;
        }

        // Le caratteristiche del pet, come le altre finestre:
        //   qs ipc call dashboard pettraits
        // Serve anche a verificarla senza mouse — e' l'unico modo di far
        // caricare quel QML, che altrimenti resta in un Loader mai aperto.
        function pettraits(): void {
            host.petTraitsWindow.visible = !host.petTraitsWindow.visible;
        }

        // La finestra di un telefono, per nome — lo stesso del pannello:
        //   qs ipc call dashboard phone "moto g24"
        // Utile come scorciatoia, e come unico modo di aprirla senza mouse.
        function phone(device: string): string {
            if (device === "")
                return "manca il nome del telefono";

            host.phoneWindow.open(device);
            host.show(host.phoneWindow);
            return "aperta su " + device;
        }

        // La stessa finestra, aperta gia' sulla riassociazione — per quando e'
        // il telefono ad aver tolto l'autorizzazione:
        //   qs ipc call dashboard repair "moto g24"
        function repair(device: string): string {
            if (device === "")
                return "manca il nome del telefono";

            host.phoneWindow.open(device);
            host.phoneWindow.startRepair();
            host.show(host.phoneWindow);
            return "riassociazione di " + device;
        }

        // Accende o spegne un pannello per id (gli stessi del catalogo di
        // Settings): comodo da legare a una scorciatoia, es.
        //   qs ipc call dashboard panel homeassistant
        function panel(id: string): string {
            if (!Settings.entry(id))
                return "pannello sconosciuto: " + id + " (" + Settings.catalog.map(p => p.id).join(", ") + ")";
            Settings.toggle(id);
            var column = Settings.columnOf(id);
            return column === "" ? id + ": spento" : id + ": acceso a " + (column === "left" ? "sinistra" : "destra");
        }
    }
}
