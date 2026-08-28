import QtQuick

// Consumo nel tempo, ad aree impilate: la banda in basso e' la CPU, quella
// sopra la GPU, e il profilo superiore e' il totale.
Canvas {
    id: root

    property var cpuValues: []
    property var gpuValues: []
    property color cpuColor: "#3fb950"
    property color gpuColor: "#a371f7"
    property var series: []
    // Fondoscala minimo: senza, a macchina ferma il grafico amplificherebbe
    // oscillazioni di pochi watt facendole sembrare picchi.
    property real minScale: 60

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

    readonly property real peak: {
        let max = 0;
        for (let i = 0; i < cpuValues.length; i++)
            max = Math.max(max, (cpuValues[i] ?? 0) + (gpuValues[i] ?? 0));
        return max;
    }

    implicitHeight: 46
    onCpuValuesChanged: requestPaint()
    onCpuColorChanged: requestPaint()
    onGpuColorChanged: requestPaint()

    onPaint: {
        const ctx = getContext("2d");
        ctx.reset();

        const w = width;
        const h = height;

        ctx.strokeStyle = "#1c2128";
        ctx.lineWidth = 1;
        ctx.beginPath();
        ctx.moveTo(0, Math.round(h / 2) + 0.5);
        ctx.lineTo(w, Math.round(h / 2) + 0.5);
        ctx.stroke();

        const n = root.cpuValues.length;
        if (n < 2)
            return;

        const scale = Math.max(root.minScale, root.peak * 1.15);
        const slot = w / (SystemStats.historyLength - 1);
        const xOf = i => w - (n - 1 - i) * slot;
        const yOf = v => h - Math.min(1, v / scale) * (h - 1);

        // Si disegna prima l'area del totale col colore della GPU, poi sopra
        // quella della sola CPU: la sovrapposizione da' l'effetto impilato
        // senza dover costruire poligoni separati.
        function area(seriesAt, color, alpha) {
            ctx.beginPath();
            ctx.moveTo(xOf(0), h);
            for (let i = 0; i < n; i++)
                ctx.lineTo(xOf(i), yOf(seriesAt(i)));
            ctx.lineTo(xOf(n - 1), h);
            ctx.closePath();
            ctx.fillStyle = Qt.alpha(color, alpha);
            ctx.fill();

            ctx.beginPath();
            ctx.moveTo(xOf(0), yOf(seriesAt(0)));
            for (let i = 1; i < n; i++)
                ctx.lineTo(xOf(i), yOf(seriesAt(i)));
            ctx.strokeStyle = color;
            ctx.lineWidth = 1.2;
            ctx.lineJoin = "round";
            ctx.stroke();
        }

        area(i => (root.cpuValues[i] ?? 0) + (root.gpuValues[i] ?? 0), root.gpuColor, 0.45);
        area(i => root.cpuValues[i] ?? 0, root.cpuColor, 0.55);
    }
}
