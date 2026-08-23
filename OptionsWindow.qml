import Quickshell

MemoryWindow {
    id: win

    title: I18n.t("Opzioni dashboard")
    key: "options"
    defaultWidth: 620
    defaultHeight: 700
    color: "#0d1117"

    contentWidth: panel.implicitWidth
    contentHeight: panel.implicitHeight

    OptionsPanel {
        id: panel

        anchors.fill: parent
    }
}
