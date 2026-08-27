// La posizione del sole e gli orari in cui conviene girare il pannello.
//
// Tutto qui e' astronomia di almanacco, non approssimazioni: le equazioni sono
// quelle NOAA ("General Solar Position Calculations", le stesse della classe
// astral che Home Assistant usa per sun.sun), accurate a una frazione di grado
// — cioe' molto piu' di quanto serva: un grado di azimut vale meno di un
// minuto di orologio.
//
// Il criterio con cui si sceglie tra est, sud e ovest e' esatto e vale da solo,
// senza formule: il rendimento istantaneo di un pannello inclinato e'
// proporzionale al coseno dell'angolo fra la sua normale e il sole, e a parita'
// d'inclinazione quell'angolo si riduce alla differenza fra l'azimut del
// pannello e quello del sole. Fra tre orientamenti fissi (90°, 180°, 270°) va
// scelto sempre il piu' vicino: i punti di cambio sono dunque i momenti in cui
// l'azimut del sole attraversa 135° (est -> sud) e 225° (sud -> ovest). In quei
// momenti le due posizioni ricevono esattamente la stessa luce diretta, quindi
// lo scambio e' indifferente prima e obbligatorio dopo — nessuna euristica, e
// nessuna differenza fra mattino e pomeriggio perche' ai margini la situazione
// e' simmetrica.
//
// Le funzioni prendono e restituiscono millisecondi Unix come JavaScript li
// intende: i fusi orari esistono solo al confine, dove un Date viene formato o
// letto. Cosi' un passaggio all'ora legale nel mezzo della giornata sposta gli
// orari mostrati ma non i momenti reali dei cambi.

function mod360(degrees) {
    return ((degrees % 360) + 360) % 360;
}

function clamp(v, lo, hi) {
    return Math.max(lo, Math.min(hi, v));
}

function radians(deg) {
    return deg * Math.PI / 180;
}

// L'azimut del sole (da nord, in senso orario: est = 90) e l'elevazione
// (sopra l'orizzonte, positiva), al momento dato e alle coordinate date.
function position(ms, latDeg, lonDeg) {
    // Secoli Giuliani da J2000: la variabile indipendente di tutte le serie
    // che seguono.
    const jd = ms / 86400000 + 2440587.5;
    const t = (jd - 2451545.0) / 36525.0;

    // Longitudine media, anomalia media ed eccentricità dell'orbita.
    const meanLong = mod360(280.46646 + t * (36000.76983 + t * 0.0003032));
    const meanAnom = 357.52911 + t * (35999.05029 - 0.0001537 * t);
    const ecc = 0.016708634 - t * (0.000042037 + 0.0000001267 * t);

    // Equazione del centro: la correzione dovuta all'orbita ellittica.
    const mr = radians(meanAnom);
    const center = (1.914602 - t * (0.004817 + 0.000014 * t)) * Math.sin(mr)
        + (0.019993 - 0.000101 * t) * Math.sin(2 * mr)
        + 0.000289 * Math.sin(3 * mr);
    const trueLong = meanLong + center;

    // Longitudine apparente e obliquità dell'eclittica, entrambe corrette
    // della nutazione (le stesse espressioni del foglio NOAA).
    const omega = 125.04 - 1934.136 * t;
    const appLong = trueLong - 0.00569 - 0.00478 * Math.sin(radians(omega));
    const obl = 23 + (26 + (21.448 - t * (46.8150 + t * (0.00059 - t * 0.001813))) / 60) / 60
        + 0.00256 * Math.cos(radians(omega));

    // Declinazione: latitudine del punto verticale del sole.
    const decl = Math.asin(Math.sin(radians(obl)) * Math.sin(radians(appLong)));

    // Equazione del tempo, in minuti: quanto il sole vero corre avanti o
    // indietro rispetto a quello medio dei fusi. La serie di Spencer dà un
    // numero in radianti: senza la conversione in gradi viene fuori una
    // frazione di minuto invece di quasi due, e tutto il giorno slitta.
    let y = Math.tan(radians(obl / 2));
    y *= y;
    const eqTime = 4 * (180 / Math.PI) * (
        y * Math.sin(2 * radians(meanLong))
        - 2 * ecc * Math.sin(mr)
        + 4 * ecc * y * Math.sin(mr) * Math.cos(2 * radians(meanLong))
        - 0.5 * y * y * Math.sin(4 * radians(meanLong))
        - 1.25 * ecc * ecc * Math.sin(2 * mr));

    // Tempo solare vero e angolo orario (negativo la mattina). Il modulo
    // 1440 non e' decorativo: a est di Greenwich l'aggiunta della longitudine
    // fa passare il conto oltre la mezzanotte del giorno giuliano in corso.
    const utcMinutes = ((ms / 60000) % 1440 + 1440) % 1440;
    const tst = ((utcMinutes + eqTime + 4 * lonDeg) % 1440 + 1440) % 1440;
    const hourAngle = radians(tst / 4 - 180);

    const latR = radians(latDeg);
    const declR = decl;

    // Zenit per la legge dei coseni del triangolo celeste, poi elevazione.
    const cosZen = clamp(
        Math.sin(latR) * Math.sin(declR)
        + Math.cos(latR) * Math.cos(declR) * Math.cos(hourAngle),
        -1, 1);
    const elevation = 90 - Math.acos(cosZen) * 180 / Math.PI;

    // Azimut dal nord in senso orario: l'atan2 dà l'angolo dal sud meridiano,
    // il +180 lo riporta al nord da cui tutti misurano (come fa Home Assistant).
    const az = Math.atan2(
        Math.sin(hourAngle),
        Math.cos(hourAngle) * Math.sin(latR) - Math.tan(declR) * Math.cos(latR));

    return {
        azimuth: mod360(az * 180 / Math.PI + 180),
        elevation: elevation
    };
}

// L'orientamento da tenere adesso: il più vicino in senso circolare all'azimut
// del sole. "null" quando il chiamante preferisce decidere da sé cosa fare di
// notte; qui il sole non c'entra.
const ORIENTATIONS = [[90, "est"], [180, "sud"], [270, "ovest"]];

function orientationFor(azimuthDeg) {
    let best = null;
    let bestDist = Infinity;

    for (const entry of ORIENTATIONS) {
        // Distanza sul cerchio: mai piu' di 180°, anche attraversando il nord.
        const d = Math.abs((((azimuthDeg - entry[0]) % 360) + 540) % 360 - 180);
        if (d < bestDist) {
            bestDist = d;
            best = entry[1];
        }
    }

    return best;
}

// Raffina col metodo delle bisezioni l'istante in cui l'orientamento cambia,
// dentro un intervallo [t1, t2] che lo contiene per costruzione. Trenta giri
// portano un intervallo di dieci minuti sotto il nanosecondo; ci fermiamo a un
// secondo, che e' gia' mille volte piu' fine di qualunque orologio da muro.
function refineSwitch(t1, t2, lat, lon) {
    const o1 = orientationFor(position(t1, lat, lon).azimuth);

    while (t2 - t1 > 1000) {
        const mid = t1 + (t2 - t1) / 2;
        if (orientationFor(position(mid, lat, lon).azimuth) === o1)
            t1 = mid;
        else
            t2 = mid;
    }

    return t1 + (t2 - t1) / 2;
}

// Gli orari dei cambi di oggi: { toSouth, toWest }, millisecondi Unix oppure
// null dove il cambiamento non esiste (l'inverno delle alte latitudini può
// far nascere il sole oltre i 135°: quella giornata comincia già di sud, e
// "comincia di sud" e' la risposta giusta, non un errore).
//
// La scansione cammina a passi di dieci minuti sulla giornata locale (dalla
// mezzanotte alla mezzanotte): abbastanza fitto che nessun cambio possa
// nascondersi fra due campioni — l'azimut corre al massimo mezzo grado al
// minuto — ed economicissima (145 valutazioni, ripetute solo quando cambia il
// giorno). Ogni cambio trovato viene poi raffinato dalle bisezioni.
function daySchedule(localMidnightMs, latDeg, lonDeg) {
    const STEP = 10 * 60000;
    const DAY = 24 * 3600000;

    let result = { toSouth: null, toWest: null };
    let prevT = localMidnightMs;
    let prevO = null;
    const p0 = position(localMidnightMs, latDeg, lonDeg);
    if (p0.elevation > 0)
        prevO = orientationFor(p0.azimuth);

    for (let t = localMidnightMs + STEP; t <= localMidnightMs + DAY; t += STEP) {
        const p = position(t, latDeg, lonDeg);
        const o = p.elevation > 0 ? orientationFor(p.azimuth) : null;

        if (prevO !== null && o !== null && o !== prevO) {
            const when = refineSwitch(prevT, t, latDeg, lonDeg);
            if (o === "sud" && result.toSouth === null)
                result.toSouth = when;
            if (o === "ovest" && result.toWest === null)
                result.toWest = when;
        }

        prevT = t;
        // Anche quando e' null: la notte deve cancellare l'orientamento della
        // sera, senno' all'alba il passaggio ovest -> est sembrerebbe un cambio
        // da rifare invece che il sole che riparte da capo.
        prevO = o;
    }

    return result;
}
