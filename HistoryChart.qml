import QtQuick

// Grafico dello storico di un sensore: asse dei tempi lineare, scala verticale
// automatica sui valori presenti. I buchi (null) spezzano la linea invece di
// essere disegnati come zeri.
Item {
    id: root

    property var values: []
    property color lineColor: "#58a6ff"
    property int hours: 16
    property int decimals: 1
    // Ampiezza verticale minima. Senza, una serie piatta riempie il grafico
    // con il proprio rumore: un battito a riposo fra 58 e 62 disegnerebbe
    // montagne alte quanto quelle di una corsa. E' l'idea del minScale di
    // PowerChart, ma qui vale sull'intervallo e non sul fondoscala, perche'
    // questo grafico non parte da zero. Zero = come si e' sempre comportato.
    property real minSpan: 0
    // Le serie disegnate, per il selettore di colore: [{ id, label, fallback }].
    property var series: []

    // Tasto destro: apre il selettore di colore. Come in Sparkline e PowerChart
    // — sono i tre grafici del progetto, e l'handler sta in ognuno invece che
    // nei pannelli che li usano. Senza `series` resta spento.
    TapHandler {
        enabled: root.series.length > 0
        acceptedButtons: Qt.RightButton
        onTapped: eventPoint => DashActions.pickColor(root.series, eventPoint.scenePosition.x, eventPoint.scenePosition.y)
    }

    // Estremi effettivi della serie, usati sia dal disegno che dalle etichette.
    readonly property var range: {
        let min = Infinity;
        let max = -Infinity;
        for (const v of root.values) {
            if (v === null || !isFinite(v))
                continue;
            min = Math.min(min, v);
            max = Math.max(max, v);
        }
        if (!isFinite(min))
            return null;
        // Una serie piatta non deve diventare una divisione per zero.
        if (max - min < 1e-6)
            return {
                min: min - 0.5,
                max: max + 0.5
            };

        // L'ampiezza minima si aggiunge attorno al centro, non in cima: alzare
        // solo il massimo spingerebbe la linea verso il basso invece di
        // lasciarla dov'e'.
        if (max - min < root.minSpan) {
            const middle = (min + max) / 2;
            return {
                min: middle - root.minSpan / 2,
                max: middle + root.minSpan / 2
            };
        }

        return {
            min: min,
            max: max
        };
    }

    readonly property bool hasData: range !== null

    // Margine verticale, per non far toccare linea e bordi. Stava dentro il
    // disegno; adesso e' qui perche' serve anche a posare il pallino sotto il
    // puntatore esattamente sulla linea: due formule separate finirebbero
    // prima o poi per non essere piu' la stessa.
    readonly property real lo: root.hasData ? root.range.min - (root.range.max - root.range.min) * 0.12 : 0
    readonly property real hi: root.hasData ? root.range.max + (root.range.max - root.range.min) * 0.12 : 1

    // --- l'asse dei tempi ---------------------------------------------------
    //
    // Le etichette dicono l'ora dell'orologio, non quanto si e' indietro:
    // «08:40» risponde alla domanda che ci si fa davanti a un grafico — quando
    // e' successo — mentre «-4h» la lascia da calcolare. Tutti i grafici che
    // usano questo componente finiscono adesso (lo storico di Home Assistant,
    // il battito, il Fitbit), quindi l'estremo destro e' l'ora corrente e gli
    // altri si ricavano indietro.
    property real endTime: Date.now()

    // Mezzo minuto: piu' fitto non si vedrebbe, piu' rado l'ultima etichetta
    // comincerebbe a mentire di qualche minuto.
    Timer {
        interval: 30000
        running: true
        repeat: true
        onTriggered: root.endTime = Date.now()
    }

    // L'ora del campione i-esimo. Il primo campione sta `hours` ore indietro,
    // l'ultimo adesso, e in mezzo si divide in parti uguali.
    function timeAt(index: int): var {
        const n = root.values.length;
        const back = n > 1 ? (n - 1 - index) / (n - 1) : 0;
        return new Date(root.endTime - back * root.hours * 3600000);
    }

    function clockAt(index: int): string {
        return Qt.formatTime(root.timeAt(index), "HH:mm");
    }

    // L'ora di un punto dell'asse, indicato per frazione della finestra: 0 e'
    // il bordo sinistro, 1 adesso. Non passa per i campioni apposta — le
    // etichette dell'asse devono dire la stessa cosa anche quando lo storico
    // e' vuoto, dove un indice non c'e'.
    function clockBack(fraction: real): string {
        return Qt.formatTime(new Date(root.endTime - (1 - fraction) * root.hours * 3600000), "HH:mm");
    }

    // --- la lettura sotto il puntatore --------------------------------------
    //
    // Un grafico alto sessanta pixel non ha spazio per una scala fitta: il
    // valore esatto di un punto si legge passandoci sopra, che e' anche il
    // gesto con cui si cerca «quanto era, li'».
    HoverHandler {
        id: hover
    }

    readonly property bool valid: root.hasData && root.values.length > 1

    // L'indice sotto il puntatore, gia' spostato sul campione valido piu'
    // vicino: dentro un buco non c'e' niente da dire, ma un buco largo un
    // campione non deve far sparire la lettura mentre si scorre.
    readonly property int hoverIndex: {
        if (!root.valid || !hover.hovered || canvas.width <= 0)
            return -1;

        const x = hover.point.position.x;

        if (x < 0 || x > canvas.width)
            return -1;

        const n = root.values.length;
        const centre = Math.max(0, Math.min(n - 1, Math.round(x / canvas.width * (n - 1))));

        for (let d = 0; d <= 6; d++) {
            const after = centre + d;
            const before = centre - d;

            if (after < n && root.values[after] !== null && isFinite(root.values[after]))
                return after;

            if (before >= 0 && root.values[before] !== null && isFinite(root.values[before]))
                return before;
        }

        return -1;
    }

    readonly property real hoverValue: root.hoverIndex >= 0 ? root.values[root.hoverIndex] : 0
    readonly property real hoverX: root.hoverIndex >= 0 && root.values.length > 1 ? root.hoverIndex / (root.values.length - 1) * canvas.width : 0
    readonly property real hoverY: canvas.height - (root.hoverValue - root.lo) / (root.hi - root.lo) * canvas.height

    implicitHeight: 64

    onValuesChanged: canvas.requestPaint()
    // Un Canvas ridisegna solo quando glielo si chiede. Senza questa riga il
    // colore scelto resta inutilizzato fino al prossimo storico scaricato da
    // Home Assistant, che arriva di rado: sembra che la scelta non abbia avuto
    // effetto, mentre e' gia' salvata.
    onLineColorChanged: canvas.requestPaint()

    Canvas {
        id: canvas

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        height: parent.height - 13

        onPaint: {
            const ctx = getContext("2d");
            ctx.reset();

            const w = width;
            const h = height;

            // Griglia: tre linee orizzontali e una verticale a meta' finestra.
            ctx.strokeStyle = "#1c2128";
            ctx.lineWidth = 1;
            for (const f of [0, 0.5, 1]) {
                const y = Math.round(h * f) + 0.5;
                ctx.beginPath();
                ctx.moveTo(0, y);
                ctx.lineTo(w, y);
                ctx.stroke();
            }
            ctx.beginPath();
            ctx.moveTo(Math.round(w / 2) + 0.5, 0);
            ctx.lineTo(Math.round(w / 2) + 0.5, h);
            ctx.stroke();

            if (!root.range || root.values.length < 2)
                return;

            const lo = root.lo;
            const hi = root.hi;

            const xOf = i => i / (root.values.length - 1) * w;
            const yOf = v => h - (v - lo) / (hi - lo) * h;

            // I valori validi si raccolgono in segmenti contigui: ogni buco
            // interrompe la linea e chiude l'area riempita.
            const segments = [];
            let current = [];
            for (let i = 0; i < root.values.length; i++) {
                const v = root.values[i];
                if (v === null || !isFinite(v)) {
                    if (current.length)
                        segments.push(current);
                    current = [];
                } else {
                    current.push({
                        x: xOf(i),
                        y: yOf(v)
                    });
                }
            }
            if (current.length)
                segments.push(current);

            const grad = ctx.createLinearGradient(0, 0, 0, h);
            grad.addColorStop(0, Qt.alpha(root.lineColor, 0.30));
            grad.addColorStop(1, Qt.alpha(root.lineColor, 0.02));

            for (const seg of segments) {
                if (seg.length < 2)
                    continue;

                ctx.beginPath();
                ctx.moveTo(seg[0].x, seg[0].y);
                for (const p of seg)
                    ctx.lineTo(p.x, p.y);
                ctx.lineTo(seg[seg.length - 1].x, h);
                ctx.lineTo(seg[0].x, h);
                ctx.closePath();
                ctx.fillStyle = grad;
                ctx.fill();

                ctx.beginPath();
                ctx.moveTo(seg[0].x, seg[0].y);
                for (const p of seg)
                    ctx.lineTo(p.x, p.y);
                ctx.strokeStyle = root.lineColor;
                ctx.lineWidth = 1.5;
                ctx.lineJoin = "round";
                ctx.stroke();
            }
        }
    }

    // Estremi della scala verticale.
    Text {
        anchors.top: canvas.top
        anchors.right: canvas.right
        anchors.rightMargin: 2
        visible: root.hasData
        color: "#6e7681"
        font.pixelSize: 9
        text: root.hasData ? root.range.max.toFixed(root.decimals) : ""
    }

    Text {
        anchors.bottom: canvas.bottom
        anchors.right: canvas.right
        anchors.rightMargin: 2
        anchors.bottomMargin: 1
        visible: root.hasData
        color: "#6e7681"
        font.pixelSize: 9
        text: root.hasData ? root.range.min.toFixed(root.decimals) : ""
    }

    Text {
        anchors.centerIn: canvas
        visible: !root.hasData
        color: "#484f58"
        font.pixelSize: 10
        text: I18n.t("nessuno storico")
    }

    // --- il puntatore --------------------------------------------------------
    //
    // Riga verticale e pallino: la riga dice dove si sta guardando, il pallino
    // su quale valore. Sono elementi veri e non disegno sul Canvas, perche' un
    // Canvas si ridipinge tutto a ogni movimento del mouse e questi due si
    // spostano soltanto.
    Rectangle {
        visible: root.hoverIndex >= 0
        x: Math.round(root.hoverX)
        width: 1
        height: canvas.height
        color: Qt.alpha(root.lineColor, 0.45)
    }

    Rectangle {
        visible: root.hoverIndex >= 0
        x: root.hoverX - 3
        y: root.hoverY - 3
        width: 6
        height: 6
        radius: 3
        color: root.lineColor
        border.width: 1
        border.color: "#0d1117"
    }

    // --- i riferimenti temporali ---------------------------------------------
    //
    // Tre ore lungo l'asse: dove comincia il grafico, la meta', e adesso.
    // Mentre il mouse e' sopra lasciano il posto alla lettura del punto: la
    // striscia e' alta nove pixel, e due scritte sovrapposte non le legge
    // nessuno.
    Text {
        anchors.left: parent.left
        anchors.bottom: parent.bottom
        visible: root.hoverIndex < 0
        color: "#484f58"
        font.pixelSize: 9
        text: root.clockBack(0)
    }

    Text {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        visible: root.hoverIndex < 0
        color: "#484f58"
        font.pixelSize: 9
        text: root.clockBack(0.5)
    }

    Text {
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        visible: root.hoverIndex < 0
        color: "#484f58"
        font.pixelSize: 9
        // L'ultimo campione e' di adesso, e «ora» lo dice meglio dell'ora
        // esatta: e' l'unico punto dell'asse che non serve andare a cercare.
        text: I18n.t("ora")
    }

    // La lettura del punto: quando, e quanto. Sta nella striscia sotto il
    // grafico, sopra le etichette che si sono tolte di mezzo, e segue il
    // puntatore restando dentro i bordi.
    Text {
        id: readout

        anchors.bottom: parent.bottom
        x: Math.max(0, Math.min(root.width - implicitWidth, root.hoverX - implicitWidth / 2))
        visible: root.hoverIndex >= 0
        font.pixelSize: 9
        color: "#8b949e"
        textFormat: Text.StyledText
        text: root.hoverIndex < 0 ? "" : `${root.clockAt(root.hoverIndex)} · <font color="${root.lineColor}">${root.hoverValue.toFixed(root.decimals)}</font>`
    }
}
