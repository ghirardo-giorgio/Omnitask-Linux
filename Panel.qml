import QtQuick
import Quickshell

// Punto d'ingresso "panel" del plugin Omarchy: la dashboard intera come
// superficie del pannello.
//
// Il contenuto e' lo stesso Dashboard.qml che su GNOME sta dentro una finestra
// (vedi shell.qml). Quel file e' scritto apposta per non sapere da cosa e'
// ospitato — Rectangle con implicitWidth/implicitHeight guidati dal contenuto —
// quindi qui non serve adattarlo, solo dargli un posto dove stare.
Item {
    id: panel

    // Iniettate da omarchy-shell al caricamento del modulo. Vanno dichiarate
    // anche se non tutte servono: e' il contratto con cui la shell ci carica.
    property var bar
    property string moduleName: "io.github.ghirardo-giorgio.omnitask-linux"
    property var settings

    implicitWidth: dash.implicitWidth
    implicitHeight: dash.implicitHeight

    // Come in shell.qml: I18n non legge le impostazioni da se', cosi' i
    // pannelli che traducono una parola non si portano dietro anche la
    // configurazione della dashboard.
    Binding {
        target: I18n
        property: "forced"
        value: Settings.language
    }

    Dashboard {
        id: dash

        anchors.fill: parent
    }

    // Le finestre secondarie (Servizi, Processi, Rete, Hardware, Opzioni,
    // Telefono) e le richieste che le aprono: le stesse di shell.qml.
    PanelHost {
        id: host

        onHideDashboard: panel.visible = false
    }
}
