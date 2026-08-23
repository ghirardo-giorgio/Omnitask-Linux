import Quickshell

MemoryWindow {
    id: win

    title: I18n.t("Processi")
    key: "processes"
    defaultWidth: 840
    defaultHeight: 620
    color: "#0d1117"

    contentWidth: panel.implicitWidth
    contentHeight: panel.implicitHeight

    ProcessesPanel {
        id: panel

        anchors.fill: parent
    }
}
