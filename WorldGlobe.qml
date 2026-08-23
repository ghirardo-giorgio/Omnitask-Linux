import QtQuick
import Quickshell
import Quickshell.Io

// Globo terrestre con gli host a cui la macchina e' connessa.
//
// Proiezione ortografica — la Terra come la si vede da lontano, con una faccia
// nascosta — ma **inquadrata sugli host, non sull'osservatore**. Puntare la vista
// su di se' mette al centro l'unico emisfero dove non c'e' niente da guardare:
// con l'osservatore in Giappone e gli host in America i punti cadevano a 86-89°
// dal centro, cioe' schiacciati sulla circonferenza (`sin(89°)` vale 0,9998), e
// qualcuno finiva dietro. Cercando il punto di vista che li inquadra (vedi
// bestCenter) tornano tutti grandi al centro del disco.
//
// Le posizioni arrivano dal database locale di MaxMind tramite procmon.py:
// nessun indirizzo esce dalla macchina. Molte sono note solo a livello di
// nazione — quelle si disegnano vuote, non piene: vedi `approx`.
Canvas {
    id: root

    // [{ lat, lon, ip, name, country, approx, radius, pid, process, bytes }]
    property var hosts: []
    // pid da tenere in evidenza: gli host degli altri processi sbiadiscono
    property int highlightPid: 0

    // Da dove si guarda, quando non c'e' un tunnel di mezzo: l'ora di sistema
    // dice il fuso, il fuso dice la posizione (vedi il Process in fondo).
    // Nessuna geolocalizzazione del proprio IP, che vorrebbe dire chiedere a un
    // servizio esterno chi siamo.
    property real zoneLat: 0
    property real zoneLon: 0
    property bool zoneKnown: false

    // Dove riemerge il traffico con una VPN accesa: la posizione del server a
    // cui si e' connessi, che il database locale ricava dal suo indirizzo (vedi
    // vpn_exit in procmon.py). Non e' dove siamo, ma e' da dove il mondo ci
    // vede arrivare — che e' quello a cui le rotte disegnate qui rispondono.
    property real exitLat: 0
    property real exitLon: 0
    property bool exitKnown: false

    // L'uscita del tunnel ha la precedenza: mentre e' attiva, disegnare "casa"
    // dove si e' fisicamente racconterebbe rotte che non esistono.
    readonly property bool observerIsExit: root.exitKnown
    readonly property real observerLat: root.observerIsExit ? root.exitLat : root.zoneLat
    readonly property real observerLon: root.observerIsExit ? root.exitLon : root.zoneLon
    readonly property bool observerKnown: root.observerIsExit || root.zoneKnown

    // Centro della proiezione: il punto della Terra rivolto verso di noi.
    property real centerLat: 20
    property real centerLon: 0
    property bool dragging: false
    // Chi ha girato il globo a mano l'ha girato per un motivo: da quel momento
    // l'inquadratura automatica non tocca piu' la vista, finche' non si premono
    // i pulsanti.
    property bool userMoved: false

    property var rings: []
    property string mapError: ""
    property var hovered: null

    readonly property real radius: Math.min(width, height) / 2 - 6
    readonly property real cx: width / 2
    readonly property real cy: height / 2

    // Host raggruppati per posizione: il centroide di una nazione raccoglie
    // indirizzi a decine, e disegnarli uno sopra l'altro darebbe un punto solo
    // con l'aria di essere un host solo. Ogni gruppo sa anche **quali servizi**
    // stanno contattando quel posto, che e' l'informazione che si cerca
    // guardando la mappa.
    readonly property var clusters: {
        const groups = {};
        for (const host of root.hosts) {
            if (host.lat === undefined || host.lat === null)
                continue;
            const key = `${host.lat.toFixed(1)},${host.lon.toFixed(1)}`;
            const found = groups[key];
            if (found) {
                found.hosts.push(host);
                found.bytes += host.bytes ?? 0;
                if (host.process && !found.services.includes(host.process))
                    found.services.push(host.process);
            } else {
                groups[key] = {
                    lat: host.lat,
                    lon: host.lon,
                    country: host.country ?? "",
                    approx: host.approx ?? false,
                    hosts: [host],
                    services: host.process ? [host.process] : [],
                    bytes: host.bytes ?? 0
                };
            }
        }
        // i piu' attivi per primi: e' l'ordine in cui si assegnano le etichette
        // quando non c'e' spazio per tutte
        return Object.values(groups).sort((a, b) => b.bytes - a.bytes);
    }

    // Quali posti sono in gioco, non quanto traffico fanno: serve a ricalcolare
    // l'inquadratura solo quando cambia la geografia, non a ogni campione.
    readonly property string places: root.clusters.map(c => `${c.lat.toFixed(1)},${c.lon.toFixed(1)}`).sort().join(";")

    implicitWidth: 320
    implicitHeight: 320

    onHostsChanged: requestPaint()
    onHighlightPidChanged: requestPaint()
    // Accendere o spegnere una VPN sposta l'osservatore, e con lui l'origine di
    // tutte le rotte: va ridisegnato, e vale la pena riportare l'inquadratura
    // su quello che c'e' da vedere.
    onObserverLatChanged: requestPaint()
    onObserverLonChanged: requestPaint()
    onObserverIsExitChanged: root.frameHosts(false)
    onCenterLatChanged: requestPaint()
    onCenterLonChanged: requestPaint()
    onRingsChanged: requestPaint()
    onHoveredChanged: requestPaint()
    onPlacesChanged: root.frameHosts(false)

    function rad(deg: real): real {
        return deg * Math.PI / 180;
    }

    // Ortografica: x/y sul piano dello schermo, e il coseno della distanza
    // angolare dal centro — negativo significa "dietro il globo".
    function project(lat: real, lon: real): var {
        const phi = root.rad(lat);
        const lambda = root.rad(lon - root.centerLon);
        const phi0 = root.rad(root.centerLat);
        const cosC = Math.sin(phi0) * Math.sin(phi) + Math.cos(phi0) * Math.cos(phi) * Math.cos(lambda);
        return {
            x: root.cx + root.radius * Math.cos(phi) * Math.sin(lambda),
            y: root.cy - root.radius * (Math.cos(phi0) * Math.sin(phi) - Math.sin(phi0) * Math.cos(phi) * Math.cos(lambda)),
            visible: cosC >= 0
        };
    }

    // Distanza angolare in gradi fra due punti della sfera.
    function distance(lat1: real, lon1: real, lat2: real, lon2: real): real {
        const p1 = root.rad(lat1);
        const p2 = root.rad(lat2);
        const dl = root.rad(lon2 - lon1);
        const c = Math.sin(p1) * Math.sin(p2) + Math.cos(p1) * Math.cos(p2) * Math.cos(dl);
        return Math.acos(Math.min(1, Math.max(-1, c))) * 180 / Math.PI;
    }

    // Il punto di vista che inquadra piu' gruppi possibile.
    //
    // Non il baricentro dei loro vettori: con host su tre continenti quello cade
    // in mezzo all'Artico (misurato: 5 gruppi su 6 inquadrati, contro 6 su 6 di
    // questa ricerca). Si provano invece dei centri su una griglia di 15° e si
    // tiene quello con piu' gruppi entro 60° — oltre, `sin(c)` inizia a
    // schiacciarli sul bordo. A parita', vince la distanza media minore.
    function bestCenter(): var {
        if (root.clusters.length === 0)
            return null;
        let best = null;
        for (let lat = -75; lat <= 75; lat += 15) {
            for (let lon = -180; lon < 180; lon += 15) {
                let inside = 0;
                let total = 0;
                for (const cluster of root.clusters) {
                    const d = root.distance(lat, lon, cluster.lat, cluster.lon);
                    total += d;
                    if (d <= 60)
                        inside++;
                }
                const mean = total / root.clusters.length;
                if (best === null || inside > best.inside || (inside === best.inside && mean < best.mean))
                    best = {
                        lat: lat,
                        lon: lon,
                        inside: inside,
                        mean: mean
                    };
            }
        }
        return best;
    }

    // `force` distingue il pulsante (che rimette l'inquadratura automatica) dal
    // ricalcolo che arriva da solo quando cambiano gli host.
    function frameHosts(force: bool) {
        if (force)
            root.userMoved = false;
        else if (root.userMoved)
            return;
        const best = root.bestCenter();
        if (best === null) {
            // nessun host geolocalizzato: si guarda casa, che e' l'unica cosa
            // che si sa dov'e'
            root.centerOnObserver();
            return;
        }
        root.centerLat = best.lat;
        root.centerLon = best.lon;
    }

    function centerOnObserver() {
        if (!root.observerKnown)
            return;
        root.userMoved = false;
        root.centerLat = root.observerLat;
        root.centerLon = root.observerLon;
    }

    function clusterAt(px: real, py: real): var {
        let best = null;
        let bestDistance = 14 * 14;
        for (const cluster of root.clusters) {
            const point = root.project(cluster.lat, cluster.lon);
            if (!point.visible)
                continue;
            const dx = point.x - px;
            const dy = point.y - py;
            const distance = dx * dx + dy * dy;
            if (distance < bestDistance) {
                bestDistance = distance;
                best = cluster;
            }
        }
        return best;
    }

    // Etichetta di un gruppo: i servizi che contattano quel posto, piu' quanti
    // host ci sono se sono piu' di uno.
    function labelFor(cluster: var): string {
        const services = cluster.services.slice(0, 2).join(", ");
        const more = cluster.services.length > 2 ? ` +${cluster.services.length - 2}` : "";
        const count = cluster.hosts.length > 1 ? ` (${cluster.hosts.length})` : "";
        return services.length ? services + more + count : cluster.country + count;
    }

    // --- disegno --------------------------------------------------------
    function drawGraticule(ctx) {
        ctx.strokeStyle = "#1c2430";
        ctx.lineWidth = 1;
        // paralleli e meridiani ogni 30°: danno la rotondita' anche dove non
        // c'e' terra da mostrare
        for (let lat = -60; lat <= 60; lat += 30)
            root.strokePath(ctx, root.samples(lat, null));
        for (let lon = -180; lon < 180; lon += 30)
            root.strokePath(ctx, root.samples(null, lon));
    }

    function samples(lat: var, lon: var): var {
        const points = [];
        for (let t = -180; t <= 180; t += 4)
            points.push(lat === null ? root.project(t / 2, lon) : root.project(lat, t));
        return points;
    }

    // Traccia solo i tratti di faccia visibile: il salto da un punto nascosto
    // interrompe la linea invece di attraversare il globo da parte a parte.
    function strokePath(ctx, points: var) {
        let drawing = false;
        ctx.beginPath();
        for (const point of points) {
            if (!point.visible) {
                drawing = false;
                continue;
            }
            if (drawing)
                ctx.lineTo(point.x, point.y);
            else
                ctx.moveTo(point.x, point.y);
            drawing = true;
        }
        ctx.stroke();
    }

    function drawLand(ctx) {
        // mentre si trascina si disegna un punto su due: il gesto resta fluido
        // e la differenza a occhio non c'e'
        const step = root.dragging ? 2 : 1;
        ctx.strokeStyle = "#2f4a3a";
        ctx.fillStyle = "#16251d";
        ctx.lineWidth = 1;
        for (const ring of root.rings) {
            const points = [];
            for (let i = 0; i < ring.length; i += step)
                points.push(root.project(ring[i][1], ring[i][0]));
            // un contorno interamente visibile si puo' anche riempire; a cavallo
            // dell'orizzonte il riempimento taglierebbe attraverso il globo
            const whole = points.every(p => p.visible);
            if (whole && points.length > 2) {
                ctx.beginPath();
                ctx.moveTo(points[0].x, points[0].y);
                for (let i = 1; i < points.length; i++)
                    ctx.lineTo(points[i].x, points[i].y);
                ctx.closePath();
                ctx.fill();
                ctx.stroke();
            } else {
                root.strokePath(ctx, points);
            }
        }
    }

    // Geodetica fra due punti, campionata e proiettata: la rotta vera sulla
    // sfera, non una retta sullo schermo che passerebbe dentro il pianeta.
    function drawGeodesic(ctx, lat1: real, lon1: real, lat2: real, lon2: real) {
        const p1 = [Math.cos(root.rad(lat1)) * Math.cos(root.rad(lon1)), Math.cos(root.rad(lat1)) * Math.sin(root.rad(lon1)), Math.sin(root.rad(lat1))];
        const p2 = [Math.cos(root.rad(lat2)) * Math.cos(root.rad(lon2)), Math.cos(root.rad(lat2)) * Math.sin(root.rad(lon2)), Math.sin(root.rad(lat2))];
        const dot = Math.min(1, Math.max(-1, p1[0] * p2[0] + p1[1] * p2[1] + p1[2] * p2[2]));
        const omega = Math.acos(dot);
        if (omega < 1e-6)
            return;
        const points = [];
        const steps = 24;
        for (let i = 0; i <= steps; i++) {
            const t = i / steps;
            const a = Math.sin((1 - t) * omega) / Math.sin(omega);
            const b = Math.sin(t * omega) / Math.sin(omega);
            const v = [a * p1[0] + b * p2[0], a * p1[1] + b * p2[1], a * p1[2] + b * p2[2]];
            points.push(root.project(Math.atan2(v[2], Math.hypot(v[0], v[1])) * 180 / Math.PI, Math.atan2(v[1], v[0]) * 180 / Math.PI));
        }
        root.strokePath(ctx, points);
    }

    // Osservatore dietro il globo: un triangolo sul bordo dice da che parte sta,
    // senza obbligare a girarlo per saperlo.
    function drawOffscreenObserver(ctx) {
        const phi = root.rad(root.observerLat);
        const lambda = root.rad(root.observerLon - root.centerLon);
        const phi0 = root.rad(root.centerLat);
        const theta = Math.atan2(Math.cos(phi) * Math.sin(lambda), Math.cos(phi0) * Math.sin(phi) - Math.sin(phi0) * Math.cos(phi) * Math.cos(lambda));
        const x = root.cx + (root.radius - 3) * Math.sin(theta);
        const y = root.cy - (root.radius - 3) * Math.cos(theta);
        ctx.save();
        ctx.translate(x, y);
        ctx.rotate(theta);
        ctx.beginPath();
        ctx.moveTo(0, -5);
        ctx.lineTo(4, 3);
        ctx.lineTo(-4, 3);
        ctx.closePath();
        ctx.fillStyle = "#3fb950";
        ctx.fill();
        ctx.restore();
    }

    onPaint: {
        const ctx = getContext("2d");
        ctx.reset();

        // oceano
        ctx.beginPath();
        ctx.arc(root.cx, root.cy, root.radius, 0, Math.PI * 2);
        ctx.fillStyle = "#0b1a26";
        ctx.fill();
        ctx.strokeStyle = "#233240";
        ctx.lineWidth = 1;
        ctx.stroke();

        root.drawGraticule(ctx);
        root.drawLand(ctx);

        const home = root.observerKnown ? root.project(root.observerLat, root.observerLon) : null;

        // le rotte, sotto tutto il resto
        if (home !== null && home.visible) {
            for (const cluster of root.clusters) {
                const mine = root.highlightPid === 0 || cluster.hosts.some(h => h.pid === root.highlightPid);
                if (!mine)
                    continue;
                ctx.strokeStyle = Qt.rgba(0.34, 0.65, 1, 0.3);
                ctx.lineWidth = 1;
                root.drawGeodesic(ctx, root.observerLat, root.observerLon, cluster.lat, cluster.lon);
            }
        }

        // L'osservatore prima degli host: qualche host cade proprio qui sotto,
        // e coprirlo sarebbe il difetto che si sta correggendo.
        if (home !== null && home.visible) {
            // Verde = qui siamo davvero; ambra e cerchio tratteggiato = e' la
            // posizione da cui usciamo, non quella in cui stiamo. La differenza
            // conta: con la VPN accesa questo punto puo' essere su un altro
            // continente.
            const exit = root.observerIsExit;
            ctx.beginPath();
            ctx.arc(home.x, home.y, 4, 0, Math.PI * 2);
            ctx.fillStyle = exit ? "#d29922" : "#3fb950";
            ctx.fill();
            ctx.beginPath();
            ctx.arc(home.x, home.y, 8, 0, Math.PI * 2);
            ctx.strokeStyle = exit ? Qt.rgba(0.82, 0.6, 0.13, 0.6) : Qt.rgba(0.25, 0.72, 0.31, 0.5);
            ctx.lineWidth = 1;
            if (exit)
                ctx.setLineDash([2, 2]);
            ctx.stroke();
            ctx.setLineDash([]);
        } else if (root.observerKnown) {
            root.drawOffscreenObserver(ctx);
        }

        // punti degli host, e le etichette dei servizi finche' c'e' posto
        const placed = [];
        ctx.font = "9px sans-serif";
        for (const cluster of root.clusters) {
            const point = root.project(cluster.lat, cluster.lon);
            if (!point.visible)
                continue;

            const mine = root.highlightPid === 0 || cluster.hosts.some(h => h.pid === root.highlightPid);
            const alpha = mine ? 1 : 0.25;

            const size = Math.min(7, 3 + Math.log(cluster.hosts.length + 1) * 1.6);
            ctx.beginPath();
            ctx.arc(point.x, point.y, size, 0, Math.PI * 2);
            if (cluster.approx) {
                // posizione nota solo a livello di nazione: cerchio vuoto, per
                // non spacciare un centroide per un indirizzo preciso
                ctx.strokeStyle = Qt.rgba(0.34, 0.65, 1, alpha);
                ctx.lineWidth = 1.5;
                ctx.stroke();
            } else {
                ctx.fillStyle = Qt.rgba(0.34, 0.65, 1, alpha);
                ctx.fill();
            }

            // Un'etichetta per gruppo, se non finisce addosso a una gia'
            // scritta: il punto resta sempre, il testo e' quello che si
            // sacrifica quando i posti sono vicini.
            const crowded = placed.some(p => Math.hypot(p.x - point.x, p.y - point.y) < 16);
            if (!crowded && mine) {
                placed.push(point);
                ctx.fillStyle = Qt.rgba(0.79, 0.83, 0.85, alpha);
                ctx.fillText(root.labelFor(cluster), point.x + size + 3, point.y + 3);
            }
        }
    }

    // --- rotazione ------------------------------------------------------
    DragHandler {
        id: drag

        property real startLat: 0
        property real startLon: 0

        target: null

        onActiveChanged: {
            root.dragging = drag.active;
            if (drag.active) {
                drag.startLat = root.centerLat;
                drag.startLon = root.centerLon;
                // da qui in avanti comanda l'utente
                root.userMoved = true;
            } else {
                root.requestPaint();
            }
        }

        onTranslationChanged: {
            if (!drag.active)
                return;
            root.centerLon = drag.startLon - drag.translation.x * 0.5;
            // oltre gli 80° il polo passa dall'altra parte e il globo sembra
            // rovesciarsi: ci si ferma prima
            root.centerLat = Math.max(-80, Math.min(80, drag.startLat + drag.translation.y * 0.5));
        }
    }

    HoverHandler {
        id: hover

        onPointChanged: root.hovered = root.clusterAt(hover.point.position.x, hover.point.position.y)
        onHoveredChanged: {
            if (!hover.hovered)
                root.hovered = null;
        }
    }

    // Contorni delle terre emerse, generati da scripts/make_world.py.
    // Se mancano, resta il reticolo: meglio dirlo che lasciare all'utente il
    // dubbio di aver rotto qualcosa.
    FileView {
        id: world

        path: PluginPaths.of("world.json")
        onLoaded: {
            try {
                root.rings = JSON.parse(world.text()).rings ?? [];
                root.mapError = "";
            } catch (e) {
                root.rings = [];
                root.mapError = I18n.t("world.json illeggibile");
            }
        }
        onLoadFailed: {
            root.rings = [];
            root.mapError = "world.json: python3 scripts/make_world.py";
        }
    }

    Text {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        visible: root.mapError.length > 0
        color: "#d29922"
        font.pixelSize: 9
        font.family: "monospace"
        text: root.mapError
    }

    // Posizione dell'osservatore: la tabella dei fusi orari porta le coordinate
    // di ogni zona, quindi il fuso configurato basta a sapere da dove si guarda.
    Process {
        running: true
        command: ["sh", "-c", "TZ=$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone); grep -P \"\\t$TZ\\b\" /usr/share/zoneinfo/zone.tab | head -1 | cut -f2"]

        stdout: StdioCollector {
            onStreamFinished: {
                // formato ISO 6709 compatto: +353916+1394441 = 35°39'16\"N 139°44'41\"E
                const m = this.text.trim().match(/^([+-])(\d{2})(\d{2})(\d{2})?([+-])(\d{3})(\d{2})(\d{2})?/);
                if (!m)
                    return;
                root.zoneLat = (m[1] === "-" ? -1 : 1) * (Number(m[2]) + Number(m[3]) / 60 + Number(m[4] ?? 0) / 3600);
                root.zoneLon = (m[5] === "-" ? -1 : 1) * (Number(m[6]) + Number(m[7]) / 60 + Number(m[8] ?? 0) / 3600);
                root.zoneKnown = true;
                // se ci sono gia' host, l'inquadratura su di loro ha la
                // precedenza: sapere dov'e' casa non e' una ragione per
                // guardare da quella parte
                root.frameHosts(false);
            }
        }
    }

    // --- riquadro del gruppo sotto il puntatore --------------------------
    Rectangle {
        id: label

        readonly property var cluster: root.hovered

        visible: label.cluster !== null
        width: Math.min(root.width - 8, labelColumn.implicitWidth + 16)
        height: labelColumn.implicitHeight + 12
        x: Math.min(Math.max(4, hover.point.position.x + 12), root.width - width - 4)
        y: Math.min(Math.max(4, hover.point.position.y + 12), root.height - height - 4)
        radius: 6
        color: "#0d1117"
        border.width: 1
        border.color: "#30363d"

        Column {
            id: labelColumn

            x: 8
            y: 6
            spacing: 1

            Text {
                color: "#c9d1d9"
                font.pixelSize: 10
                font.bold: true
                text: label.cluster ? (label.cluster.country || I18n.t("posizione sconosciuta")) : ""
            }

            Text {
                visible: label.cluster ? label.cluster.services.length > 0 : false
                color: "#58a6ff"
                font.pixelSize: 9
                text: label.cluster ? label.cluster.services.join(", ") : ""
            }

            Repeater {
                model: label.cluster ? label.cluster.hosts.slice(0, 5) : []

                Text {
                    required property var modelData

                    color: "#8b949e"
                    font.pixelSize: 9
                    font.family: "monospace"
                    text: modelData.name && modelData.name.length > 0 ? modelData.name : modelData.ip
                }
            }

            Text {
                visible: label.cluster && label.cluster.hosts.length > 5
                color: "#6e7681"
                font.pixelSize: 9
                text: label.cluster ? I18n.t("e altri %1").arg(label.cluster.hosts.length - 5) : ""
            }

            Text {
                visible: label.cluster ? label.cluster.approx : false
                color: "#6e7681"
                font.pixelSize: 9
                text: label.cluster ? I18n.t("posizione approssimativa (±%1 km)").arg(label.cluster.hosts[0].radius ?? 0) : ""
            }
        }
    }
}
