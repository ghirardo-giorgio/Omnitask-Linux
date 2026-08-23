import Quickshell

MemoryWindow {
    id: win

    title: I18n.t("Rete")
    key: "network"
    // più larga e più alta delle altre: a destra ci stanno il globo e l'elenco
    // dei paesi, che nella misura di prima finiva tagliato
    defaultWidth: 1180
    defaultHeight: 680

    contentWidth: panel.implicitWidth
    contentHeight: panel.implicitHeight

    NetworkPanel {
        id: panel

        anchors.fill: parent
    }
}
