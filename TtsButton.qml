import QtQuick

// L'interruttore della voce: lo stesso nel pannello Comando IA e nella
// finestra della chat, perche' lo stato sta nel singleton Tts e non qui — due
// copie dello stesso interruttore devono muoversi insieme.
//
// Fa due cose con un clic solo, e l'etichetta dice quale: mentre la voce
// parla e' "zitto" e tronca la frase senza spegnere niente, altrimenti accende
// e spegne la lettura delle risposte. Chi vuole spegnerla mentre parla preme
// due volte: la prima e' quella che serve subito.
Rectangle {
    id: root

    readonly property color tint: Tts.phase === "error" ? "#f85149" : Tts.speaking ? "#d29922" : Tts.enabled ? "#3fb950" : "#6e7681"

    implicitWidth: row.implicitWidth + 14
    implicitHeight: 20
    radius: 6
    color: area.containsMouse ? "#161b22" : "transparent"
    border.width: 1
    border.color: area.containsMouse ? "#388bfd" : Tts.speaking ? "#d29922" : Tts.enabled ? "#2ea043" : "#30363d"

    Row {
        id: row

        anchors.centerIn: parent
        spacing: 5

        Canvas {
            id: icon

            width: 12
            height: 12
            anchors.verticalCenter: parent.verticalCenter

            // Il disegno dipende da due cose sole: il colore e se la voce e'
            // accesa. Ridipingere quando cambiano evita di lasciare in giro
            // un altoparlante barrato mentre parla.
            readonly property bool on: Tts.enabled || Tts.speaking

            onOnChanged: icon.requestPaint()

            Connections {
                function onTintChanged() {
                    icon.requestPaint();
                }

                target: root
            }

            onPaint: {
                const ctx = icon.getContext("2d");

                ctx.reset();
                ctx.fillStyle = root.tint;
                ctx.strokeStyle = root.tint;
                ctx.lineWidth = 1;

                // il corpo dell'altoparlante
                ctx.beginPath();
                ctx.moveTo(0.5, 4.5);
                ctx.lineTo(2.5, 4.5);
                ctx.lineTo(5.5, 1.5);
                ctx.lineTo(5.5, 10.5);
                ctx.lineTo(2.5, 7.5);
                ctx.lineTo(0.5, 7.5);
                ctx.closePath();
                ctx.fill();

                if (icon.on) {
                    // due onde: la voce esce
                    ctx.beginPath();
                    ctx.arc(5.5, 6, 2.6, -Math.PI / 3, Math.PI / 3);
                    ctx.stroke();
                    ctx.beginPath();
                    ctx.arc(5.5, 6, 4.6, -Math.PI / 3, Math.PI / 3);
                    ctx.stroke();
                } else {
                    // barrato: non esce niente
                    ctx.beginPath();
                    ctx.moveTo(7.5, 3.5);
                    ctx.lineTo(11.5, 8.5);
                    ctx.moveTo(11.5, 3.5);
                    ctx.lineTo(7.5, 8.5);
                    ctx.stroke();
                }
            }
        }

        Text {
            anchors.verticalCenter: parent.verticalCenter
            color: root.tint
            font.pixelSize: 10
            text: Tts.speaking ? I18n.t("zitto") : I18n.t("voce")
        }
    }

    MouseArea {
        id: area

        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: {
            if (Tts.speaking) {
                Tts.stop();
                return;
            }

            Tts.toggle();
        }
    }

    Tooltip {
        text: Tts.phase === "error" ? Tts.message : Tts.speaking ? I18n.t("interrompe la lettura") : Tts.enabled ? I18n.t("le risposte di Hermes vengono lette ad alta voce") : I18n.t("legge ad alta voce le risposte di Hermes")
        hovered: area.containsMouse
    }
}
