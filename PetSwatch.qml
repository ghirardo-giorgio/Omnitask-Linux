import QtQuick
import QtQuick.Layouts

// Un colore: la pastiglia che lo mostra, l'esadecimale che lo scrive, e
// qualche scelta pronta.
//
// Non usa ColorPicker.qml, che pure c'e': quello vive dentro Dashboard.qml
// perche' e' l'unico punto da cui si puo' coprire tutta la dashboard, e
// questa e' una finestra a parte dove quel meccanismo non arriva. Qui basta
// meno: un campo di sei cifre e otto colori che stanno bene sul fondo scuro.
ColumnLayout {
    id: swatch

    required property string label
    required property color value

    signal picked(color c)

    readonly property var presets: ["#58a6ff", "#3fb950", "#d29922", "#f85149", "#bc8cff", "#39c5cf", "#c9d1d9", "#6e7681"]

    spacing: 2

    Text {
        color: "#6e7681"
        font.pixelSize: 10
        text: swatch.label
    }

    RowLayout {
        spacing: 4

        Rectangle {
            implicitWidth: 18
            implicitHeight: 22
            radius: 4
            color: swatch.value
            border.width: 1
            border.color: "#30363d"
        }

        Rectangle {
            Layout.preferredWidth: 68
            implicitHeight: 22
            radius: 4
            color: "#161b22"
            border.width: 1
            border.color: hex.activeFocus ? "#58a6ff" : "#30363d"

            TextInput {
                id: hex

                anchors.fill: parent
                anchors.leftMargin: 6
                anchors.rightMargin: 6
                verticalAlignment: TextInput.AlignVCenter
                clip: true
                color: "#c9d1d9"
                font.pixelSize: 11
                font.family: "monospace"
                selectionColor: "#1f6feb"
                selectedTextColor: "#ffffff"
                maximumLength: 7
                // Solo cio' che puo' diventare un colore: il cancelletto e
                // sei cifre esadecimali. Filtrare qui evita di dover dire
                // "non e' un colore" dopo.
                validator: RegularExpressionValidator {
                    regularExpression: /#?[0-9a-fA-F]{0,6}/
                }
                text: String(swatch.value)

                Connections {
                    target: swatch

                    function onValueChanged() {
                        if (!hex.activeFocus)
                            hex.text = String(swatch.value);
                    }
                }

                function commit() {
                    const t = hex.text.startsWith("#") ? hex.text : "#" + hex.text;
                    if (/^#[0-9a-fA-F]{6}$/.test(t))
                        swatch.picked(t.toLowerCase());
                    else
                        hex.text = String(swatch.value);
                }

                onEditingFinished: hex.commit()
                Keys.onReturnPressed: hex.commit()
            }
        }

        Repeater {
            model: swatch.presets

            Rectangle {
                id: preset

                required property string modelData

                implicitWidth: 14
                implicitHeight: 14
                radius: 3
                color: preset.modelData
                border.width: 1
                border.color: presetHover.hovered ? "#c9d1d9" : "#30363d"

                HoverHandler {
                    id: presetHover

                    cursorShape: Qt.PointingHandCursor
                }

                TapHandler {
                    onSingleTapped: swatch.picked(preset.modelData)
                }
            }
        }
    }
}
