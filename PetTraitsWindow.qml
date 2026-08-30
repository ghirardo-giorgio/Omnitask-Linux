import Quickshell

// La finestra delle caratteristiche del pet, sullo stampo delle altre
// (ServicesWindow, ProcessesWindow, NetworkWindow...): una MemoryWindow con la
// sua chiave, che eredita da sola memoria di posizione e misura.
MemoryWindow {
    id: win

    title: I18n.t("Caratteristiche del pet")
    key: "pettraits"
    defaultWidth: 620
    defaultHeight: 560
    color: "#0d1117"

    PetTraitsPanel {
        id: panel

        anchors.fill: parent
    }
}
