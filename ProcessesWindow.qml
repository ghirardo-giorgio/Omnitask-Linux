import Quickshell

MemoryWindow {
    id: win

    title: I18n.t("Processi")
    key: "processes"
    // elenco + sezione di dettaglio a destra: le misure stanno nel
    // ProcessesPanel, e dockShown dice sotto quale larghezza la sezione
    // si ripiega
    defaultWidth: 1220
    defaultHeight: 620
    color: "#0d1117"

    contentWidth: panel.implicitWidth
    contentHeight: panel.implicitHeight

    ProcessesPanel {
        id: panel

        anchors.fill: parent
    }
}
