import QtQuick
import Quickshell

// Le finestre secondarie della dashboard e le richieste che le aprono.
//
// Stava dentro shell.qml, che pero' esiste solo quando la dashboard e' la shell.
// Come plugin Omarchy la shell e' quella che ci ospita, e senza nessuno in
// ascolto su DashActions le voci "Servizi", "Processi", ... non aprirebbero
// niente. Tenendo qui sia le finestre sia le connessioni, shell.qml e Panel.qml
// se ne servono allo stesso modo e la logica resta scritta una volta sola.
Item {
    id: host

    // La dashboard non e' figlia di questo componente: la ospita chi ci sta
    // sopra — una finestra su GNOME, la superficie del pannello su Omarchy.
    // Per toglierla di mezzo mentre il comando IA preme i tasti si passa di qui.
    signal hideDashboard

    readonly property alias servicesWindow: servicesWin
    readonly property alias processesWindow: procsWin
    readonly property alias networkWindow: networkWin
    readonly property alias hardwareWindow: hardwareWin
    readonly property alias optionsWindow: optionsWin
    readonly property alias phoneWindow: phoneWin

    // Riporta a galla una finestra, qualunque stato QML si ritrovi.
    //
    // Chiusa dal window manager, `visible` a volte resta true: riassegnarlo non
    // farebbe nulla e la finestra non tornerebbe mai su. Passando da false si
    // riapre in ogni caso — verificato sul campo con la finestra Rete, dove il
    // solo `= true` lasciava il doppio clic senza effetto dopo la prima
    // chiusura. Vale per tutte, non solo per quella: e' lo stesso stato.
    function show(window: var) {
        window.visible = false;
        window.visible = true;
    }

    ServicesWindow {
        id: servicesWin

        visible: false
    }

    ProcessesWindow {
        id: procsWin

        visible: false
    }

    NetworkWindow {
        id: networkWin

        visible: false
    }

    HardwareWindow {
        id: hardwareWin

        visible: false
    }

    OptionsWindow {
        id: optionsWin

        visible: false
    }

    PhoneWindow {
        id: phoneWin

        visible: false
    }

    // Le richieste dei pannelli arrivano dal singleton invece che per segnale:
    // caricati da un Loader, non avrebbero nessuno a cui parlare.
    Connections {
        target: DashActions

        function onOpenServices(): void {
            host.show(servicesWin);
        }

        function onOpenProcesses(): void {
            host.show(procsWin);
        }

        function onOpenNetwork(): void {
            host.show(networkWin);
        }

        function onOpenHardware(): void {
            host.show(hardwareWin);
        }

        function onOpenOptions(): void {
            host.show(optionsWin);
        }

        // Il telefono si assegna prima di mostrare la finestra: e' il
        // cambio di `device` a far partire lo stato e lo scatto, e farlo
        // dopo vorrebbe dire aprirla sul telefono di prima.
        function onOpenPhone(device: string): void {
            phoneWin.open(device);
            host.show(phoneWin);
        }

        // La dashboard si toglie di mezzo mentre il comando IA preme i tasti;
        // si riapre con la scorciatoia (qs ipc call dashboard toggle).
        function onHideWindow(): void {
            host.hideDashboard();
        }
    }
}
