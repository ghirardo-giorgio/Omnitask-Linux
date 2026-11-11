import QtQuick
import QtQuick.Layouts

// Classifica a torta: le fette sono le app nominate, la legenda a lato le
// riconosce per nome, byte e percentuale. Cio' che le app non coprono non
// viene buttata via: la parte occupata senza nome e' la fetta grigia
// «altre app», il resto della capacita' e' la fetta verde «libera». Una
// torta che raccontasse solo le app farebbe vedere un 100% tutto di app
// anche quando la meta' della memoria e' libera.
//
// I colori sono per app, scelti a partire dal nome: la classifica si
// rimescola a ogni aggiornamento e una fetta che cambia colore ogni dieci
// secondi si leggerebbe come un guasto del grafico, non come un sorpasso.
// Il verde se lo tiene la fetta libera, di proposito: si deve capire con
// la coda dell'occhio, senza leggere la legenda.
ColumnLayout {
    id: root

    property string title: ""
    // [{ name, value, text }] gia' ordinate, la piu' grossa per prima.
    property var entries: []
    // Quanto e' occupato: la parte che `entries` non copre e' la fetta
    // grigia "altre app".
    property real used: 0
    // La capacita' totale: quello che avanza dall'occupato e' la fetta
    // verde. 0 quando la capacita' non si conosce (niente GPU).
    property real total: 0
    property string emptyText: "—"
    property string otherLabel: I18n.t("altre app")
    // Ogni pannello dice come si chiama la sua memoria ("RAM libera",
    // "VRAM libera"); vuoto ricade su "libera".
    property string freeLabel: ""
    property color otherColor: "#6e7681"
    property color freeColor: "#3fb950"

    // Sette toni per sei fette: se il colore che esce dall'hash e' gia'
    // occupato se ne prende uno di riserva, cosi' due app non escono mai
    // dello stesso colore. Il verde resta fuori perche' e' gia' impegnato
    // dalla fetta libera.
    property var palette: [
        "#58a6ff",
        "#a371f7",
        "#d29922",
        "#f85149",
        "#f0883e",
        "#39c5cf",
        "#f778ba"
    ]

    spacing: 8

    // `items` sono le fette, `base` il denominatore: il piu' grosso fra la
    // capacita' dichiarata e l'occupato, perche' la somma PSS puo'
    // superare la RAM "usata" del kernel e la torta deve chiudersi lo
    // stesso.
    readonly property var slices: {
        const known = root.entries ?? [];
        const taken = [];
        const out = [];
        let sum = 0;

        for (const e of known) {
            // Il colore segue il nome, non la posizione in classifica.
            let h = 0;
            for (const c of String(e.name ?? ""))
                h = (h * 31 + c.charCodeAt(0)) % root.palette.length;

            while (taken.includes(root.palette[h]))
                h = (h + 1) % root.palette.length;

            taken.push(root.palette[h]);

            sum += e.value;
            out.push({
                name: e.name,
                value: e.value,
                text: e.text,
                color: root.palette[h]
            });
        }

        // L'occupato vero puo' essere piu' della somma delle app: il
        // kernel, e su una GPU i buffer che nessun processo dichiara,
        // occupano memoria che `entries` non nomina.
        const occupied = Math.max(sum, root.used);
        const base = Math.max(root.total, occupied);

        // Le fette grigia e verde aspettano che ci sia qualcuno da
        // nominare: da sole, prima che la classifica arrivi, sarebbero un
        // cerchio che dice gia' 100% a chi guarda.
        if (known.length > 0) {
            const other = occupied - sum;

            if (other > 0)
                out.push({
                    name: root.otherLabel,
                    value: other,
                    text: SystemStats.formatBytes(other, false),
                    color: root.otherColor
                });

            const free = base - occupied;

            if (free > 0)
                out.push({
                    name: root.freeLabel || I18n.t("libera"),
                    value: free,
                    text: SystemStats.formatBytes(free, false),
                    color: root.freeColor
                });
        }

        return {
            items: out,
            base: base
        };
    }

    Text {
        Layout.bottomMargin: 2
        color: "#8b949e"
        font.pixelSize: 10
        font.letterSpacing: 1
        text: root.title
    }

    RowLayout {
        Layout.fillWidth: true
        spacing: 10
        visible: root.slices.items.length > 0

        // La torta. Canvas perche' le fette sono archi: con i Rectangles
        // di EnergyDisc servirebbe uno ShapePath per fetta.
        Canvas {
            id: pie

            implicitWidth: 74
            implicitHeight: 74

            // Il ridisegno quando cambia la classifica: i colori sono
            // dentro `data`, quindi basta questo binding.
            property var data: root.slices
            onDataChanged: requestPaint()
            onWidthChanged: requestPaint()
            onHeightChanged: requestPaint()

            onPaint: {
                const ctx = getContext("2d");
                ctx.reset();

                const cx = width / 2;
                const cy = height / 2;
                const r = Math.min(cx, cy) - 1;
                const base = data.base;

                if (r <= 0 || base <= 0)
                    return;

                // Si parte dall'alto e si va a destra: la fetta piu' grossa
                // occupa il quadrante in alto a destra, il posto che l'occhio
                // guarda per primo.
                let angle = -Math.PI / 2;

                for (const s of data.items) {
                    const end = angle + (s.value / base) * Math.PI * 2;

                    ctx.beginPath();
                    ctx.moveTo(cx, cy);
                    ctx.arc(cx, cy, r, angle, end);
                    ctx.closePath();
                    ctx.fillStyle = s.color;
                    ctx.fill();

                    // Il divider: un taglio del colore del fondo, non una
                    // riga disegnata sopra — e' quello che separa due fette
                    // quando i colori sono vicini.
                    ctx.strokeStyle = "#0d1117";
                    ctx.lineWidth = 1.5;
                    ctx.stroke();

                    angle = end;
                }
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 3

            Repeater {
                model: root.slices.items

                Item {
                    required property var modelData

                    Layout.fillWidth: true
                    implicitHeight: 16

                    RowLayout {
                        anchors.fill: parent
                        spacing: 6

                        Rectangle {
                            width: 9
                            height: 9
                            radius: 4.5
                            Layout.alignment: Qt.AlignVCenter
                            color: parent.parent.modelData.color
                        }

                        Text {
                            Layout.fillWidth: true
                            elide: Text.ElideRight
                            color: "#c9d1d9"
                            font.pixelSize: 11
                            text: parent.parent.modelData.name
                        }

                        Text {
                            color: parent.parent.modelData.color
                            font.pixelSize: 10
                            font.bold: true
                            text: parent.parent.modelData.text
                        }

                        Text {
                            color: "#6e7681"
                            font.pixelSize: 10
                            text: root.slices.base > 0 ? `${Math.round(parent.parent.modelData.value / root.slices.base * 100)}%` : "—"
                        }
                    }
                }
            }
        }
    }

    Text {
        Layout.fillWidth: true
        visible: root.slices.items.length === 0
        color: "#484f58"
        font.pixelSize: 11
        text: root.emptyText
    }
}
