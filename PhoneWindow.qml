import QtQuick
import Quickshell

MemoryWindow {
    id: win

    // Il telefono da mostrare: lo imposta shell.qml quando arriva la richiesta
    // dal pannello, prima di rendere visibile la finestra.
    property alias device: view.device

    // Da usare al posto di assegnare `device`: vale anche quando il telefono
    // e' lo stesso di prima, che e' il caso in cui assegnarlo non farebbe
    // niente del tutto.
    function open(name: string): void {
        if (view.device === name)
            view.reload();
        else
            view.device = name;
    }

    // Da usare subito dopo `open` quando il telefono ha tolto l'autorizzazione:
    // apre la finestra gia' sulle istruzioni per rimetterla.
    function startRepair(): void {
        view.startRepair();
    }

    title: I18n.t("Telefono")
    key: "phone"
    // Ritratto, come lo schermo che deve contenere: piu' larga sarebbe tutta
    // cornice ai lati dell'immagine.
    defaultWidth: 420
    defaultHeight: 780

    contentWidth: view.implicitWidth
    contentHeight: view.implicitHeight

    PhoneView {
        id: view

        anchors.fill: parent
    }

    // Chiusa la finestra, la sessione non serve piu': le fotografie le paga la
    // batteria del telefono, e nessuno le sta guardando.
    //
    // Non si chiude all'istante perche' aprire la finestra la nasconde e la
    // rimostra in due righe (PanelHost.show, per via del window manager che
    // lascia `visible` a true dopo una chiusura): dare retta a quel lampeggio
    // vorrebbe dire spegnere la sessione appena accesa.
    Connections {
        target: win

        function onVisibleChanged(): void {
            if (win.visible)
                closing.stop();
            else
                closing.restart();
        }
    }

    Timer {
        id: closing

        interval: 300

        onTriggered: PhoneAdb.close()
    }
}
