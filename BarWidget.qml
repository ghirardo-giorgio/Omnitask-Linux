import QtQuick
import Quickshell

// Punto d'ingresso "bar-widget" del plugin Omarchy: il carico della CPU nella
// barra, e un clic per aprire la dashboard.
//
// Niente colori o font scritti qui dentro: `bar` li espone vivi e cambiano col
// tema di Omarchy. I ternari difensivi servono perche' il widget viene
// istanziato anche prima che la shell abbia assegnato `bar` — l'esempio nella
// documentazione dei bar-widget fa lo stesso.
Item {
    id: widget

    // Iniettate da omarchy-shell al caricamento del modulo.
    property var bar
    property string moduleName: "io.github.hal68000.dashboard"
    property var settings

    // Sul lato lungo della barra il testo decide la larghezza; sul lato corto
    // comanda la barra. Verticale, la barra e' stretta: si mostra il solo
    // numero, senza etichetta.
    readonly property bool vertical: bar ? bar.vertical === true : false

    implicitWidth: vertical ? (bar ? bar.barSize : 26) : label.implicitWidth + 10
    implicitHeight: vertical ? label.implicitHeight + 6 : (bar ? bar.barSize : 26)

    Text {
        id: label

        anchors.centerIn: parent

        text: widget.vertical ? `${SystemStats.cpu.toFixed(0)}` : `CPU ${SystemStats.cpu.toFixed(0)}%`
        color: widget.bar ? widget.bar.foreground : "white"
        font.family: widget.bar ? widget.bar.fontFamily : "monospace"
        font.pixelSize: 12
    }

    MouseArea {
        anchors.fill: parent

        hoverEnabled: true
        onClicked: widget.toggle()

        onEntered: {
            if (widget.bar)
                widget.bar.showTooltip(widget, `${SystemStats.cpuShortName} — ${SystemStats.cpu.toFixed(0)}%`);
        }

        onExited: {
            if (widget.bar)
                widget.bar.hideTooltip(widget);
        }
    }

    // Il pannello lo apre la shell, non noi: `summon` e `hide` sono i suoi
    // ingressi documentati. Se la shell dovesse invece iniettare un riferimento
    // diretto al pannello del plugin, e' qui che va usato — vedi la nota nel
    // README, il punto e' ancora da verificare su una macchina Omarchy.
    property bool open: false

    function toggle(): void {
        widget.open ? widget.close() : widget.show();
    }

    function show(): void {
        if (widget.bar)
            widget.bar.run(`omarchy-shell shell summon ${widget.moduleName} '{}'`);
        widget.open = true;
    }

    function close(): void {
        if (widget.bar)
            widget.bar.run(`omarchy-shell shell hide ${widget.moduleName}`);
        widget.open = false;
    }
}
