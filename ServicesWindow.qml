import Quickshell

MemoryWindow {
    id: win

    // Esposte per comodita' di chi apre la finestra da fuori.
    property alias scope: panel.scope
    property alias query: panel.query

    title: I18n.t("Servizi")
    key: "services"
    defaultWidth: 560
    defaultHeight: 660
    color: "#0d1117"

    ServicesPanel {
        id: panel

        anchors.fill: parent
    }
}
