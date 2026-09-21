import Quickshell

MemoryWindow {
    id: win

    title: I18n.t("Processi")
    key: "processes"
    // sei colonne numeriche: vedi ProcessesPanel per la misura
    defaultWidth: 920
    defaultHeight: 620
    color: "#0d1117"

    contentWidth: panel.implicitWidth
    contentHeight: panel.implicitHeight

    ProcessesPanel {
        id: panel

        anchors.fill: parent
    }
}
