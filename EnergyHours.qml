import QtQuick

// La giornata a fasce orarie: una barra per ogni ora da quando la macchina e'
// accesa, alta quanto i wattora bruciati in quell'ora.
//
// Risponde alla domanda che il totale non puo' rispondere — non «quanto», ma
// «quando». Un totale di trecento wattora e' lo stesso numero se sono usciti
// da otto ore di lavoro tranquillo o da due ore di compilazioni e sei di
// nulla, e sono due giornate diverse.
//
// L'ora in corso e' disegnata vuota, col solo contorno: e' l'unica barra
// incompleta del grafico, e senza quella distinzione la si leggerebbe ogni
// volta come un crollo dei consumi invece che come un'ora appena cominciata.
Canvas {
    id: root

    // [{ h: inizio ora in secondi epoch, wh: wattora misurati, s: secondi
    //    davvero misurati in quell'ora }]
    property var hours: []

    // La stessa stima che fa il pannello, applicata fascia per fascia: la
    // parte non misurata della macchina consuma anche nelle ore in cui la CPU
    // dormiva, quindi va aggiunta qui e non solo al totale — altrimenti le ore
    // di riposo sembrerebbero gratis.
    property real baseWatts: 0
    property real psuEfficiency: 1

    property color barColor: "#e3b341"

    // Le serie disegnate, per il selettore di colore col tasto destro.
    property var series: []

    // Quale fascia e' quella in corso: e' l'ultima della lista, e si fida
    // dell'ordine perche' sysmon.py le manda gia' ordinate (e' il motivo per
    // cui le manda come lista e non come oggetto).
    readonly property int lastHour: root.hours.length ? root.hours[root.hours.length - 1].h : 0

    implicitHeight: 44

    onHoursChanged: requestPaint()
    onBarColorChanged: requestPaint()
    onBaseWattsChanged: requestPaint()

    TapHandler {
        enabled: root.series.length > 0
        acceptedButtons: Qt.RightButton
        onTapped: eventPoint => DashActions.pickColor(root.series, eventPoint.scenePosition.x, eventPoint.scenePosition.y, null)
    }

    // I wattora stimati alla presa per una fascia.
    function wallOf(bucket: var): real {
        const measured = bucket.wh ?? 0;
        const rest = root.baseWatts * (bucket.s ?? 0) / 3600;
        return (measured + rest) / Math.max(0.1, root.psuEfficiency);
    }

    onPaint: {
        const ctx = getContext("2d");
        ctx.reset();

        const n = root.hours.length;

        // La riga della base resta anche a grafico vuoto: il pannello appena
        // aperto deve sembrare uno strumento acceso e senza dati, non uno
        // spazio bianco che non si sa se funziona.
        const labels = 11;
        const floorY = Math.round(height - labels) + 0.5;

        ctx.strokeStyle = "#1c2128";
        ctx.lineWidth = 1;
        ctx.beginPath();
        ctx.moveTo(0, floorY);
        ctx.lineTo(width, floorY);
        ctx.stroke();

        if (n === 0)
            return;

        let peak = 0;
        for (let i = 0; i < n; i++)
            peak = Math.max(peak, root.wallOf(root.hours[i]));

        if (peak <= 0)
            return;

        // Le barre non riempiono mai tutta l'altezza: il 15% di aria in cima
        // serve perche' la barra piu' alta non tocchi il bordo del pannello e
        // sembri tagliata.
        const top = 2;
        const span = floorY - top;
        const slot = width / n;
        // Sotto le sei fasce le barre diventerebbero larghe e goffe; sopra le
        // trenta si assottigliano fino a sparire. Il tetto le tiene leggibili
        // e il resto lo fa lo spazio fra l'una e l'altra.
        const gap = slot > 6 ? 2 : 1;
        const barW = Math.max(1, slot - gap);

        for (let i = 0; i < n; i++) {
            const bucket = root.hours[i];
            const value = root.wallOf(bucket);
            // Un pixel di altezza minima: un'ora in cui la macchina e' stata
            // accesa e non ha fatto niente ha consumato POCO, non zero, e una
            // barra invisibile la racconterebbe come un buco.
            const h = Math.max(1, Math.round(value / (peak * 1.15) * span));
            const x = Math.round(i * slot + gap / 2);
            const y = floorY - h;
            const partial = bucket.h === root.lastHour;

            if (partial) {
                ctx.strokeStyle = root.barColor;
                ctx.lineWidth = 1;
                ctx.strokeRect(x + 0.5, y + 0.5, Math.max(1, barW - 1), h - 1);
            } else {
                // Le ore piu' cariche piu' accese: la stessa informazione
                // dell'altezza, detta due volte, perche' su barre alte pochi
                // pixel la differenza di altezza da sola non si vede.
                ctx.fillStyle = Qt.alpha(root.barColor, 0.45 + 0.55 * (value / peak));
                ctx.fillRect(x, y, barW, h);
            }
        }

        // Le etichette: una ogni tre ore, e sempre la prima, che e' l'ora in
        // cui la macchina si e' accesa — il riferimento di tutto il grafico.
        ctx.fillStyle = "#6e7681";
        ctx.font = "9px sans-serif";
        ctx.textAlign = "center";
        ctx.textBaseline = "top";

        const every = n > 16 ? 3 : (n > 8 ? 2 : 1);

        for (let i = 0; i < n; i++) {
            if (i !== 0 && i % every !== 0)
                continue;

            const when = new Date(root.hours[i].h * 1000);
            const x = i * slot + slot / 2;

            // Un'etichetta a meta' fuori dal bordo si legge peggio di
            // un'etichetta che non c'e'.
            if (x < 9 || x > width - 9)
                continue;

            ctx.fillText(String(when.getHours()).padStart(2, "0"), x, floorY + 2);
        }
    }
}
