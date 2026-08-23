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
}
