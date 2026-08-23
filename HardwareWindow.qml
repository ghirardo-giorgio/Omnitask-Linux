import Quickshell

MemoryWindow {
    id: win

    title: I18n.t("Hardware")
    key: "hardware"
    defaultWidth: 720
    defaultHeight: 660
    color: "#0d1117"

    contentWidth: panel.implicitWidth
    contentHeight: panel.implicitHeight

    HardwarePanel {
        id: panel

        anchors.fill: parent
    }
}
