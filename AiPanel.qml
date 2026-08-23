import QtQuick
import QtQuick.Layouts

ColumnLayout {
    spacing: 8

    AiCommand {
        Layout.fillWidth: true
        // la richiesta di nascondersi arriva alla shell passando dal singleton:
        // dentro un Loader un segnale non avrebbe nessuno a cui arrivare
        onBeforeExecute: DashActions.hideWindow()
    }
}
