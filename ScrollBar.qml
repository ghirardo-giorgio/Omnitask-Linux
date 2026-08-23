import QtQuick

// Barra di scorrimento per una ListView o Flickable: indica dove si e', e la
// si puo' afferrare.
//
// Larga abbastanza da prenderla col mouse senza mirare. I quattro pixel di
// prima bastavano a dire la posizione ma non a farci nulla, ed erano difficili
// perfino da vedere.
//
// Sta sopra il contenuto, non accanto: e' un velo, non una colonna. I pannelli
// che la usano tengono dodici pixel di margine a destra nelle loro righe, che
// e' quanto serve perche' non copra niente.
Rectangle {
    id: root

    required property var view

    readonly property real overflow: Math.max(0, root.view.contentHeight - root.view.height)
    // La corsa del cursore: quanto spazio ha per muoversi dentro la pista.
    readonly property real travel: Math.max(0, root.height - thumb.height)

    // Dove stava il contenuto quando la mano ha afferrato: gli spostamenti del
    // trascinamento si sommano a questo, non alla posizione corrente, che nel
    // frattempo cambia proprio perche' la stiamo muovendo.
    property real grabbedAt: 0

    width: 10
    color: barHover.hovered || grab.active ? "#161b22" : "transparent"
    visible: root.overflow > 0

    Behavior on color {
        ColorAnimation {
            duration: 120
        }
    }

    HoverHandler {
        id: barHover

        cursorShape: Qt.ArrowCursor
    }

    // Un colpo sulla pista porta il contenuto li', col cursore centrato sul
    // punto toccato. Sul cursore stesso non fa niente: sarebbe uno spostamento
    // di pochi pixel a ogni clic andato storto.
    TapHandler {
        onTapped: point => {
            if (point.position.y >= thumb.y && point.position.y <= thumb.y + thumb.height)
                return;
            if (root.travel <= 0)
                return;
            const target = (point.position.y - thumb.height / 2) / root.travel * root.overflow;
            root.view.contentY = Math.max(0, Math.min(root.overflow, target));
        }
    }

    Rectangle {
        id: thumb

        anchors.horizontalCenter: parent.horizontalCenter
        width: 6
        radius: 3

        // Proporzionale a quanto si vede del contenuto, con un minimo: su un
        // elenco di quattrocento processi la proporzione esatta sarebbe alta
        // tre pixel e non si prenderebbe. E con un massimo: quando il
        // contenuto ci sta tutto la formula esplode — misurato 2655 pixel su
        // una barra di 1159 con tredici righe in elenco — e anche se li' la
        // barra e' nascosta, un valore simile non deve girare per i binding.
        height: Math.min(root.height, Math.max(28, root.height * (root.view.height / Math.max(1, root.view.contentHeight))))

        y: root.overflow > 0 ? root.travel * Math.min(1, Math.max(0, root.view.contentY / root.overflow)) : 0

        color: grab.active ? "#58a6ff" : (thumbHover.hovered ? "#6e7681" : "#30363d")

        Behavior on color {
            ColorAnimation {
                duration: 120
            }
        }

        HoverHandler {
            id: thumbHover

            cursorShape: Qt.PointingHandCursor
        }

        DragHandler {
            id: grab

            target: null
            xAxis.enabled: false
            yAxis.enabled: true
            // Senza, il Flickable sotto si prende il trascinamento a meta'
            // corsa e la barra resta in mano a nessuno.
            grabPermissions: PointerHandler.CanTakeOverFromAnything

            onActiveChanged: {
                if (grab.active)
                    root.grabbedAt = root.view.contentY;
            }

            onTranslationChanged: {
                if (!grab.active || root.travel <= 0)
                    return;
                // Un pixel di cursore vale piu' di un pixel di contenuto: il
                // rapporto fra le due corse e' tutto quello che serve.
                const moved = root.grabbedAt + grab.translation.y * root.overflow / root.travel;
                root.view.contentY = Math.max(0, Math.min(root.overflow, moved));
            }
        }
    }
}
