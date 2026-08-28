import QtQuick
import QtQuick.Layouts
import Quickshell

// Il contenuto della dashboard, separato dalla finestra che lo ospita: cosi'
// puo' stare dentro una FloatingWindow su GNOME o una PanelWindow su wlroots.
//
// Tre colonne — sinistra, centro, destra — e nessun pannello scritto qui
// dentro: cosa mostrare, in quale colonna e in che ordine lo dice Settings
// (modificabile dalla finestra Opzioni, persistito in
// ~/.config/quickshell/dashboard.json). Tutti i
// pannelli stanno in panels/ e il catalogo e' scoperto a ogni avvio: aggiungere
// un modulo significa metterci un file — questo non cambia.
Rectangle {
    id: root

    color: "#0d1117"
    // Quanto vorrebbe essere larga: 370 per colonna visibile. Quella di mezzo
    // quasi sempre non c'e', e allora sono i 740 di prima. Conta solo per chi
    // non ha ancora scelto una misura sua — una finestra gia' ridimensionata
    // resta dov'e', e si allarga a mano (vedi MemoryWindow).
    implicitWidth: 370 * (Settings.center.length > 0 ? 3 : 2)
    // Quanto vuole essere alta la dashboard: la colonna piu' alta piu' i
    // margini. Non un numero fisso, cosi' accendere un pannello (o aggiungere
    // un disco) fa crescere la finestra invece di far tagliare l'ultimo
    // elemento — vedi MemoryWindow, che la segue finche' l'utente non decide
    // una misura sua.
    implicitHeight: columns.implicitHeight + anchorsMargins * 2

    readonly property int anchorsMargins: 14

    // Sopra le colonne e fuori dal layout: e' il solo punto da cui si puo'
    // coprire tutta la dashboard, e i pannelli che lo aprono stanno dentro un
    // Loader (vedi DashActions).
    ColorPicker {
        id: picker
    }

    Connections {
        target: DashActions

        function onPickColor(series: var, x: real, y: real, point: var): void {
            picker.show(series, x, y, point);
        }
    }

    RowLayout {
        id: columns

        anchors.fill: parent
        anchors.margins: root.anchorsMargins
        spacing: 14

        Repeater {
            model: [Settings.left, Settings.center, Settings.right]

            ColumnLayout {
                id: column

                required property var modelData
                required property int index

                // 0 = sinistra, 1 = centro, 2 = destra. L'indice e non un
                // confronto fra gli array: quelli arrivano dal singleton e non
                // c'e' garanzia che due letture diano lo stesso oggetto da
                // confrontare.
                readonly property bool isRight: column.index === 2
                readonly property bool isCenter: column.index === 1

                // La colonna di mezzo vuota non si disegna, e un elemento non
                // visibile esce dal RowLayout: le altre due tornano a
                // dividersi lo spazio a meta' come quando le colonne erano
                // due, senza nessun caso particolare da scrivere qui.
                visible: !column.isCenter || column.modelData.length > 0

                Layout.fillWidth: true
                Layout.fillHeight: true
                // le colonne visibili si dividono lo spazio in parti uguali
                // qualunque sia la larghezza della finestra
                Layout.preferredWidth: 1
                Layout.alignment: Qt.AlignTop
                spacing: 8

                // L'ingranaggio delle opzioni, dove lo si cerca: in alto a
                // destra. In cima alla colonna e non sovrapposto al contenuto,
                // perche' il primo pannello a destra cambia con l'ordine scelto
                // dall'utente e coprirebbe ogni volta qualcosa di diverso.
                Rectangle {
                    Layout.alignment: Qt.AlignRight
                    visible: column.isRight
                    implicitWidth: 24
                    implicitHeight: 22
                    radius: 6
                    color: gearArea.containsMouse ? "#161b22" : "transparent"
                    border.width: 1
                    border.color: gearArea.containsMouse ? "#30363d" : "transparent"

                    Text {
                        anchors.centerIn: parent
                        color: gearArea.containsMouse ? "#c9d1d9" : "#6e7681"
                        font.pixelSize: 13
                        text: "⚙"
                    }

                    MouseArea {
                        id: gearArea

                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: DashActions.openOptions()
                    }
                }

                Repeater {
                    model: column.modelData

                    ColumnLayout {
                        id: slot

                        required property string modelData

                        readonly property string file: Settings.fileFor(slot.modelData)

                        // Un pannello dell'utente puo' non esserci: il file
                        // cancellato, oppure — all'avvio — non ancora scoperto,
                        // perche' la scansione di panels/ e' un processo e
                        // arriva qualche istante dopo. Senza questa guardia il
                        // Loader chiedeva ".qml" e riempiva il log di "File not
                        // found" a ogni partenza.
                        readonly property bool known: slot.file.length > 0

                        Layout.fillWidth: true
                        spacing: 0

                        Loader {
                            id: panel

                            Layout.fillWidth: true
                            // il pannello si dimensiona da se': dentro un Loader
                            // le sue Layout.* non contano, conta l'implicitHeight
                            source: slot.known ? slot.file + ".qml" : ""
                        }

                        // Un pannello di terzi che non si carica deve dirlo.
                        // Muto sarebbe peggio che assente: si accende dalle
                        // Opzioni, non compare niente, e non c'e' modo di
                        // capire se e' rotto o se non fa nulla di visibile.
                        // Il perche' preciso — riga e colonna — sta nel log.
                        Text {
                            Layout.fillWidth: true
                            visible: panel.status === Loader.Error || (!slot.known && !UserPanels.loading)
                            wrapMode: Text.Wrap
                            color: "#d29922"
                            font.pixelSize: 10
                            text: slot.known ? I18n.t("%1 non si carica: vedi qs -c dashboard log").arg(slot.file + ".qml") : I18n.t("pannello sconosciuto: %1").arg(slot.modelData)
                        }
                    }
                }

                // Lo spazio che avanza sta in fondo: la colonna resta impilata
                // dall'alto, senza buchi in mezzo.
                Item {
                    Layout.fillHeight: true
                }
            }
        }
    }
}
