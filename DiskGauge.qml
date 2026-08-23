import QtQuick

// Anello di riempimento di un disco: la percentuale al centro, il resto
// dell'anello e' lo spazio libero.
//
// Un anello invece di una barra perche' occupa poco in larghezza e si legge
// alla stessa velocita' anche di sfuggita: la quantita' di colore lungo il
// giro e' proporzionale al pieno, e non serve confrontarlo con niente.
Canvas {
    id: root

    property real percent: 0
    // oltre questa soglia lo spazio comincia a essere un problema: una tacca
    // fissa sull'anello dice dov'e' il limite, invece di lasciarlo indovinare
    property real warnAt: 90
    // capacita' nota, riempimento no: l'anello resta vuoto con un trattino al
    // centro invece di mostrare uno zero che sembrerebbe "disco libero"
    property bool unknown: false

    readonly property color fillColor: root.percent >= 90 ? "#f85149" : root.percent >= 75 ? "#d29922" : "#3fb950"

    implicitWidth: 52
    implicitHeight: 52

    onPercentChanged: requestPaint()
    onUnknownChanged: requestPaint()

    onPaint: {
        const ctx = getContext("2d");
        ctx.reset();

        const cx = width / 2;
        const cy = height / 2;
        const thickness = 6;
        const r = Math.min(width, height) / 2 - thickness / 2 - 1;
        // si parte da ore 12 e si gira in senso orario, come un quadrante
        const start = -Math.PI / 2;
        const end = start + Math.PI * 2 * Math.min(100, root.percent) / 100;

        ctx.lineWidth = thickness;
        ctx.lineCap = "butt";

        // lo spazio libero: l'anello intero, sotto
        ctx.beginPath();
        ctx.arc(cx, cy, r, 0, Math.PI * 2);
        ctx.strokeStyle = "#21262d";
        ctx.stroke();

        // lo spazio occupato
        if (!root.unknown) {
            ctx.beginPath();
            ctx.arc(cx, cy, r, start, end);
            ctx.strokeStyle = root.fillColor;
            ctx.stroke();
        }

        // la tacca della soglia, sopra tutto
        const warn = start + Math.PI * 2 * root.warnAt / 100;
        ctx.beginPath();
        ctx.arc(cx, cy, r, warn - 0.012, warn + 0.012);
        ctx.strokeStyle = "#0d1117";
        ctx.lineWidth = thickness;
        ctx.stroke();
    }

    Text {
        anchors.centerIn: parent
        color: root.unknown ? "#484f58" : root.fillColor
        font.pixelSize: 12
        font.bold: true
        text: root.unknown ? "—" : `${Math.round(root.percent)}%`
    }
}
