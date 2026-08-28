import QtQuick

// Grafico a linea con area sfumata sotto. I valori piu' recenti stanno a destra.
Canvas {
    id: root

    property var values: []
    property real maxValue: 100
    property color lineColor: "#58a6ff"
    // Seconda serie opzionale, disegnata sopra la prima (es. upload sul download).
    property var values2: []
    property color lineColor2: "transparent"

    // Le serie disegnate, per il selettore di colore: [{ id, label, fallback }].
    property var series: []

    implicitHeight: 40
    onValuesChanged: requestPaint()
    onValues2Changed: requestPaint()
    // Anche i colori: qui il difetto non si vedrebbe, perche' i valori cambiano
    // ogni secondo e il ridisegno arriva comunque — ma su un grafico fermo (una
    // rete inattiva, un disco che non gira) il colore nuovo non comparirebbe.
    onLineColorChanged: requestPaint()
    onLineColor2Changed: requestPaint()

    // Tasto destro: apre il selettore di colore per le serie di questo grafico.
    // Sta qui e non in ogni pannello perche' ogni grafico e' uno di questi, e
    // ripetere lo stesso handler otto volte vorrebbe dire otto occasioni di
    // scriverlo diverso. Senza `series` l'handler resta spento, che e' il caso
    // dei grafici nelle altre finestre.
    TapHandler {
        enabled: root.series.length > 0
        acceptedButtons: Qt.RightButton
        onTapped: eventPoint => DashActions.pickColor(root.series, eventPoint.scenePosition.x, eventPoint.scenePosition.y, null)
    }


    function plot(ctx, series, color) {
        if (!series || series.length < 2)
            return;

        // Lo storico si riempie da destra: finche' e' corto il grafico
        // resta ancorato al bordo destro invece di allargarsi.
        const slot = root.width / (SystemStats.historyLength - 1);
        const scale = root.maxValue > 0 ? root.maxValue : 1;
        const xOf = i => root.width - (series.length - 1 - i) * slot;
        const yOf = v => root.height - Math.min(1, v / scale) * (root.height - 2) - 1;

        ctx.beginPath();
        ctx.moveTo(xOf(0), yOf(series[0]));
        for (let i = 1; i < series.length; i++)
            ctx.lineTo(xOf(i), yOf(series[i]));

        // Area: si chiude sul fondo prima di riempire.
        ctx.lineTo(xOf(series.length - 1), root.height);
        ctx.lineTo(xOf(0), root.height);
        ctx.closePath();

        const grad = ctx.createLinearGradient(0, 0, 0, root.height);
        grad.addColorStop(0, Qt.alpha(color, 0.35));
        grad.addColorStop(1, Qt.alpha(color, 0.02));
        ctx.fillStyle = grad;
        ctx.fill();

        ctx.beginPath();
        ctx.moveTo(xOf(0), yOf(series[0]));
        for (let i = 1; i < series.length; i++)
            ctx.lineTo(xOf(i), yOf(series[i]));
        ctx.strokeStyle = color;
        ctx.lineWidth = 1.5;
        ctx.lineJoin = "round";
        ctx.stroke();
    }

    onPaint: {
        const ctx = getContext("2d");
        ctx.reset();

        ctx.strokeStyle = "#21262d";
        ctx.lineWidth = 1;
        for (const frac of [0.5]) {
            ctx.beginPath();
            ctx.moveTo(0, root.height * frac);
            ctx.lineTo(root.width, root.height * frac);
            ctx.stroke();
        }

        root.plot(ctx, root.values, root.lineColor);
        root.plot(ctx, root.values2, root.lineColor2);
    }
}
