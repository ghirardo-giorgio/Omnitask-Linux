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

            // Margine verticale, per non far toccare linea e bordi.
            const pad = (root.range.max - root.range.min) * 0.12;
            const lo = root.range.min - pad;
            const hi = root.range.max + pad;

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

    // Riferimenti temporali.
    Text {
        anchors.left: parent.left
        anchors.bottom: parent.bottom
        color: "#484f58"
        font.pixelSize: 9
        text: `-${root.hours}h`
    }

    Text {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        color: "#484f58"
        font.pixelSize: 9
        text: `-${Math.round(root.hours / 2)}h`
    }

    Text {
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        color: "#484f58"
        font.pixelSize: 9
        text: I18n.t("ora")
    }
}
