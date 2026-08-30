import QtQuick
import QtQuick.Shapes

// Il pavimento della stanza, disegnato da una serie di numeri.
//
// Invece di una linea piatta, il pet cammina sopra un grafico: lo storico della
// CO2 delle ultime ore, o il carico della CPU dell'ultimo minuto. Le colline
// sono le ore in cui la stanza era chiusa, e il pet le attraversa.
//
// 🔴 Il punto delicato non e' disegnare la curva: e' che il disegno e il
// TERRENO SU CUI CAMMINA IL PET siano la stessa curva. Se il disegno usa una
// spline e la camminata un'interpolazione lineare, il pet fluttua sopra le
// gobbe e affonda nelle valli — di poco, in modo continuo, e con l'aria di un
// guasto. Qui `curve` e `heightAt()` chiamano tutte e due `catmull()`: una
// funzione sola, quindi non possono essere in disaccordo.
Item {
    id: terrain

    // I numeri grezzi, nell'ordine in cui sono stati misurati. Vuoto = niente
    // terreno, e chi guarda torna al pavimento piatto.
    property var values: []

    // 🔴 Falso quando nessuno guarda, e non e' un dettaglio: lo storico della
    // CPU cambia OGNI SECONDO, e ogni cambiamento rifa' quaranta punti di
    // controllo, trecento punti di curva e la geometria dello Shape. A
    // dashboard nascosta sarebbe tutto lavoro per un disegno che nessuno vede,
    // una volta al secondo per ore. Con lo storico di Home Assistant il
    // problema non si porrebbe — cambia ogni pochi minuti — ma la guardia deve
    // valere per la sorgente peggiore, non per quella comoda.
    property bool running: true

    // La copia che il disegno usa davvero: insegue `values` solo mentre
    // qualcuno guarda, e altrimenti resta ferma sull'ultima forma vista. Cosi'
    // riaprendo la dashboard il pavimento c'e' gia', invece di comparire al
    // primo campione.
    property var liveValues: []

    onValuesChanged: {
        if (terrain.running)
            terrain.liveValues = terrain.values;
    }

    onRunningChanged: {
        if (terrain.running)
            terrain.liveValues = terrain.values;
    }

    Component.onCompleted: terrain.liveValues = terrain.values

    // Quanta parte dell'altezza puo' occupare il rilievo. Il resto e' cielo:
    // sopra il terreno ci deve stare il pet, che a scala 3 e' alto 216 px.
    property real rise: 0.4

    // Quanti punti di controllo. Meno di una trentina e la forma perde le
    // gobbe; molti di piu' e la curva diventa nervosa invece che smussata —
    // che e' il contrario di quello che serve a un pavimento.
    property int controls: 40

    // Quanti segmenti disegnati fra un controllo e l'altro. Otto e' gia'
    // indistinguibile da una curva vera a queste dimensioni.
    readonly property int slices: 8

    property color fillColor: "#161b22"
    property color lineColor: "#30363d"

    readonly property bool active: terrain.norm.length >= 2

    // ---- I punti di controllo, normalizzati e lisciati ---------------------
    //
    // Da qualunque scala arrivino i numeri — ppm, gradi, percentuali — escono
    // fra 0 e 1, dove 1 e' la cima del rilievo. La normalizzazione e' sui
    // valori DELLA SERIE e non su un fondoscala fisso, cosi' una giornata
    // tranquilla non e' un pavimento piatto ma un rilievo dolce: quello che
    // interessa qui e' la forma, non la misura, che sta gia' sulla barra.
    readonly property var norm: {
        const src = terrain.liveValues;
        if (!Array.isArray(src) || src.length < 2)
            return [];

        // Solo i numeri veri: lo storico di Home Assistant ha buchi dove il
        // recorder non ha registrato, e un null in mezzo aprirebbe una voragine
        // nel pavimento.
        const clean = src.filter(v => typeof v === "number" && isFinite(v));
        if (clean.length < 2)
            return [];

        let lo = Infinity, hi = -Infinity;
        for (const v of clean) {
            lo = Math.min(lo, v);
            hi = Math.max(hi, v);
        }
        // Serie piatta: un pavimento a meta' altezza invece di una divisione
        // per zero.
        if (hi - lo < 1e-9)
            return new Array(terrain.controls).fill(0.5);

        // Ricampionamento a `controls` punti, lineare sulla sorgente.
        const out = [];
        for (let i = 0; i < terrain.controls; i++) {
            const t = i / (terrain.controls - 1) * (clean.length - 1);
            const a = Math.floor(t);
            const b = Math.min(clean.length - 1, a + 1);
            const f = t - a;
            const v = clean[a] * (1 - f) + clean[b] * f;
            out.push((v - lo) / (hi - lo));
        }

        // Media mobile a tre: toglie i denti senza spianare le gobbe. La
        // smussatura vera la fa la spline qui sotto; questa serve solo a non
        // darle spigoli da inseguire.
        const smoothed = [];
        for (let i = 0; i < out.length; i++) {
            const a = out[Math.max(0, i - 1)];
            const b = out[i];
            const c = out[Math.min(out.length - 1, i + 1)];
            smoothed.push((a + 2 * b + c) / 4);
        }
        return smoothed;
    }

    // ---- La spline ---------------------------------------------------------
    //
    // Catmull-Rom: passa PER i punti di controllo invece di essere solo
    // attratta da loro, che e' quello che serve quando i punti sono misure —
    // una curva che non tocca il valore misurato racconterebbe una cosa che
    // non e' successa. Gli estremi si ripetono, cosi' il primo e l'ultimo
    // tratto hanno le quattro ascisse che la formula richiede.
    function catmull(u) {
        const p = terrain.norm;
        const n = p.length;
        if (n === 0)
            return 0.5;
        if (n === 1)
            return p[0];

        const t = Math.max(0, Math.min(1, u)) * (n - 1);
        const i = Math.min(n - 2, Math.floor(t));
        const f = t - i;

        const p0 = p[Math.max(0, i - 1)];
        const p1 = p[i];
        const p2 = p[i + 1];
        const p3 = p[Math.min(n - 1, i + 2)];

        const f2 = f * f;
        const f3 = f2 * f;
        return 0.5 * ((2 * p1) + (-p0 + p2) * f + (2 * p0 - 5 * p1 + 4 * p2 - p3) * f2 + (-p0 + 3 * p1 - 3 * p2 + p3) * f3);
    }

    // L'altezza del terreno a una frazione della larghezza, da 0 (in basso) a
    // 1 (in cima al rilievo). E' cio' che il pet usa per sapere dove mettere i
    // piedi, ed e' la stessa curva che si vede disegnata.
    function heightAt(fracX) {
        if (!terrain.active)
            return 0;
        return Math.max(0, Math.min(1, terrain.catmull(fracX)));
    }

    // La y in pixel della superficie, dentro questo Item.
    function surfaceY(fracX) {
        return terrain.height * (1 - terrain.rise * terrain.heightAt(fracX));
    }

    // ---- Il disegno --------------------------------------------------------
    //
    // Una PathPolyline con i punti gia' calcolati, invece di una catena di
    // PathCubic: i punti li devo avere comunque — sono gli stessi che il pet
    // calpesta — e cosi' non esistono due descrizioni della stessa curva.
    readonly property var curve: {
        if (!terrain.active || terrain.width <= 0)
            return [];
        const pts = [];
        const n = (terrain.norm.length - 1) * terrain.slices;
        for (let i = 0; i <= n; i++) {
            const u = i / n;
            pts.push(Qt.point(u * terrain.width, terrain.surfaceY(u)));
        }
        // Chiusura in basso: il rilievo e' una superficie piena, non un filo.
        pts.push(Qt.point(terrain.width, terrain.height));
        pts.push(Qt.point(0, terrain.height));
        return pts;
    }

    Shape {
        anchors.fill: parent
        visible: terrain.active
        // La curva cambia solo quando arriva un campione nuovo — ogni minuti,
        // non ogni fotogramma — quindi il rendering statico e' quello giusto:
        // niente ricostruzione della geometria a ogni frame.
        preferredRendererType: Shape.CurveRenderer

        ShapePath {
            fillColor: terrain.fillColor
            strokeColor: terrain.lineColor
            strokeWidth: 1

            PathPolyline {
                path: terrain.curve
            }
        }
    }
}
