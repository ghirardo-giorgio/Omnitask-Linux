#!/usr/bin/env python3
"""Il pannellino solare in Home Assistant, leggendone il display a fotografie.

Il tester USB fra il pannello e la power bank sa tutto — tensione, corrente,
potenza, energia raccolta — e non lo dice a nessuno: non ha radio, non ha
porta dati, ha solo uno schermo. L'unico modo di portarne fuori i numeri e'
guardarlo, ed e' quello che si fa qui: uno scatto macro col telefono
appoggiato davanti (scripts/phone_adb.py, comando `photo`), l'OCR dell'app
companion, e i valori finiscono in Home Assistant accanto ai sensori di CO2.

Il problema di leggere un display a fotografie e' che l'OCR sbaglia, e sbaglia
in silenzio. Su questo schermo si e' gia' visto Ω diventare 2, Wh diventare 0h,
003 diventare D03 e 0.728 diventare 0.78: un valore plausibile e falso, che in
un grafico non si distingue da una nuvola di passaggio.

La difesa non e' un OCR migliore, e' la fisica. Il tester mostra quattro
grandezze legate da due relazioni:

    P = V · I        R = V / I

Con tre numeri e due vincoli non serve fidarsi di nessuno: si prova a credere
a due valori per volta e si guarda quale terna li rispetta entrambi. Nella
lettura delle 11:55 la corrente era stata letta 0.78 invece di 0.728, e si e'
smascherata da sola — con 0.78 nessuna delle due relazioni tornava, con il
valore ricavato da P/V tornavano tutte e due. Chi non supera i vincoli non
viene corretto a naso: si riscatta una volta, e se insiste si butta via.

I contatori del tester (Wh, mAh) si lasciano correre. Pubblicati come
`total_increasing`, e' Home Assistant a riconoscere gli azzeramenti e a
ricavare gli incrementi, quindi non c'e' niente da ricordarsi di resettare a
mano ogni mattina davanti al display.
"""
import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from datetime import date, datetime, timedelta

import phone_adb

HA_CONFIG = os.path.expanduser("~/.config/quickshell/home-assistant.json")

# Il rettangolo da leggere non si impone a ogni scatto: lo tiene il telefono.
#
# Imporlo e' quello che si faceva prima, e aveva un difetto che si vedeva solo
# usandolo: chi sposta il tester o il telefono riquadra l'area col mirino
# (`phone_adb.py aim`), l'app se la salva, e dieci minuti dopo il timer
# rimetteva quella scritta qui — cioe' il lavoro appena fatto spariva senza
# dire niente. Adesso lo scatto parte senza rettangolo, l'app usa il suo, e
# quello che ha usato si registra qui sotto.
#
# Questo resta come seme: serve la primissima volta, o se all'app venissero
# cancellati i dati e si ritrovasse senza. Non e' piu' l'ultima parola.
DEFAULT_ROI = "0.23148148,0.446875,0.71481484,0.6856771"
DEFAULT_DEVICE = "OPG02_jp_kdi"

# Dove si tiene il conto della giornata: il contatore del tester a inizio
# giornata, e l'ultimo letto.
#
# Il tester conta da quando e' stato acceso l'ultima volta — 56 mila mAh e
# passa — e quel numero non risponde alla domanda che ci si fa guardando il
# grafico, che e' "quanto ha raccolto oggi". La differenza col valore di
# stamattina invece si', ed e' quella che si pubblica.
#
# Un appunto locale e non un'attributo in Home Assistant: le entita' create da
# /api/states spariscono a ogni riavvio di Home Assistant, e perdere l'inizio
# giornata a meta' pomeriggio vorrebbe dire ripartire da zero buttando via le
# ore di sole gia' raccolte.
DAY_RECORD = os.path.join(
    os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache"),
    "quickshell",
    "solar-day.json",
)

# Dove si registra il rettangolo che il telefono sta usando davvero. E' un
# appunto, non una configurazione: la verita' e' sul telefono, e se il file
# sparisce si perde solo la rete di sicurezza per quando l'app non ce l'ha
# piu'.
ROI_RECORD = os.path.join(
    os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache"),
    "quickshell",
    "solar-roi.json",
)

# Quanto puo' sbagliare l'OCR prima che la lettura sia da buttare. La potenza
# e' stretta perche' il tester la calcola lui dalle altre due e quindi torna
# sempre esatta; la resistenza e' larga perche' e' arrotondata a un decimale,
# e a queste correnti un decimale vale gia' l'uno per cento.
POWER_TOLERANCE = 0.02
RESISTANCE_TOLERANCE = 0.05

# Da che altezza del sole in su vale la pena guardare il tester. Zero significa
# esattamente dall'alba al tramonto: sopra l'orizzonte si misura, sotto no.
#
# Si puo' alzare con --min-elevation per saltare il sole radente, che dietro un
# vetro non produce niente di misurabile; resta un'opzione e non un default,
# perche' tagliare i primi e gli ultimi minuti di giornata e' una scelta di chi
# guarda i dati, non dello script che li raccoglie.
MIN_ELEVATION = 0.0

PREFIX = "sensor.solare_usb_"

# entita' -> (unita', device_class, state_class). L'ordine e' quello in cui
# compaiono nel cruscotto.
SENSORS = {
    "tensione": ("V", "voltage", "measurement"),
    "corrente": ("A", "current", "measurement"),
    "potenza": ("W", "power", "measurement"),
    "energia": ("Wh", "energy", "total_increasing"),
    # `total` e non `total_increasing`: quello che si pubblica e' la raccolta
    # di oggi, che a mezzanotte torna a zero, e un `total_increasing` che
    # scende verrebbe letto come un contatore ripartito — cioe' come un'altra
    # giornata intera da sommare.
    "carica": ("mAh", None, "total"),
    "temperatura": ("°C", "temperature", "measurement"),
}


# ------------------------------------------------------------ home assistant


def ha_config():
    """Url e token, dallo stesso file che legge HomeAssistant.qml.

    Non una copia della configurazione: proprio quel file. Un token in due
    posti e' un token che prima o poi ne vale mezzo.
    """
    try:
        with open(HA_CONFIG) as handle:
            data = json.load(handle)
    except (OSError, ValueError) as exc:
        raise SystemExit(f"configurazione di Home Assistant illeggibile ({HA_CONFIG}): {exc}")

    if not data.get("url") or not data.get("token"):
        raise SystemExit(f"url o token mancanti in {HA_CONFIG}")

    return data["url"].rstrip("/"), data["token"]


def ha_call(path, payload=None, timeout=15):
    """Una chiamata alle API di Home Assistant, GET o POST secondo il payload."""
    url, token = ha_config()
    body = json.dumps(payload).encode() if payload is not None else None

    request = urllib.request.Request(
        url + path,
        data=body,
        headers={
            "Authorization": "Bearer " + token,
            "Content-Type": "application/json",
        },
        method="POST" if payload is not None else "GET",
    )

    with urllib.request.urlopen(request, timeout=timeout) as answer:
        return json.load(answer)


def sun():
    """Dove sta il sole adesso, secondo Home Assistant.

    L'elevazione la calcola gia' l'integrazione Sun per la posizione di casa:
    rifarne il conto qui vorrebbe dire chiedere all'utente le coordinate che
    ha gia' dato una volta.
    """
    try:
        state = ha_call("/api/states/sun.sun")
    except (urllib.error.URLError, OSError, ValueError) as exc:
        return {"ok": False, "error": str(exc)}

    attributes = state.get("attributes", {})

    return {
        "ok": True,
        "above": state.get("state") == "above_horizon",
        "elevation": attributes.get("elevation"),
        "azimuth": attributes.get("azimuth"),
    }


def publish(reading, sky, dry_run=False, dark=False):
    """Scrive le entita' in Home Assistant, una POST per sensore.

    Le entita' nascono qui e non da un'integrazione: /api/states le crea al
    primo colpo. Il prezzo e' che un riavvio di Home Assistant se le dimentica
    finche' non arriva la lettura dopo — dieci minuti di buco al massimo, che
    e' meno di quanto costerebbe tirare in casa un broker MQTT per sei numeri.
    """
    written = {}

    for name, (unit, device_class, state_class) in SENSORS.items():
        value = reading.get(name)

        if value is None:
            continue

        # La carica esce come raccolta di oggi, non come contatore del tester:
        # 56 mila mAh non rispondono a "quanto ha raccolto stamattina", e la
        # differenza col valore di inizio giornata si'. Il numero del tester
        # resta fra gli attributi, che e' dove serve — a controllare che il
        # conto torni, non a guardarlo su un grafico.
        started = None

        if name == "carica":
            value, started = daily_charge(value, persist=not dry_run)

        attributes = {
            "friendly_name": "Solare " + name,
            "unit_of_measurement": unit,
            "state_class": state_class,
            # L'elevazione viaggia con ogni campione perche' e' l'unica cosa
            # che rende confrontabili le dieci del mattino di oggi con quelle
            # di novembre: la potenza da sola non dice se il pannello ha reso
            # poco o se il sole era basso.
            "sun_elevation": sky.get("elevation"),
            "sun_azimuth": sky.get("azimuth"),
            "source_image": reading.get("image", ""),
            # Uno zero letto sul display e uno zero dedotto da un display
            # spento valgono lo stesso nel grafico ma non nella diagnosi: chi
            # guarda un pomeriggio piatto deve poter sapere quale dei due era.
            "lettura": "display spento" if dark else "display acceso",
        }

        if device_class:
            attributes["device_class"] = device_class

        if started is not None:
            attributes["totale_tester"] = round(reading[name], 4)
            attributes["inizio_giornata"] = round(started, 4)
            # Un `total` senza `last_reset` e' un totale che Home Assistant non
            # sa quando ricomincia, e a mezzanotte vedrebbe un salto all'ingiu'
            # invece di una giornata nuova.
            attributes["last_reset"] = midnight()

        payload = {"state": round(value, 4), "attributes": attributes}
        entity = PREFIX + name

        if dry_run:
            written[entity] = payload["state"]
            continue

        try:
            ha_call("/api/states/" + entity, payload)
            written[entity] = payload["state"]
        except (urllib.error.URLError, OSError, ValueError) as exc:
            return {"ok": False, "error": f"{entity}: {exc}", "written": written}

    return {"ok": True, "written": written}


def count_discard(reason, dry_run=False):
    """Tiene il conto delle letture buttate via.

    Un buco nel grafico si nota solo se qualcuno lo guarda; questo contatore
    invece si puo' allarmare. Se sale di colpo di solito non e' l'OCR: e' il
    telefono che si e' spostato e inquadra mezzo display.
    """
    entity = PREFIX + "letture_scartate"

    if dry_run:
        return

    try:
        current = ha_call("/api/states/" + entity)
        total = int(float(current.get("state", 0)))
    except (urllib.error.URLError, OSError, ValueError):
        total = 0

    try:
        ha_call("/api/states/" + entity, {
            "state": total + 1,
            "attributes": {
                "friendly_name": "Solare letture scartate",
                "state_class": "total_increasing",
                "last_reason": reason,
            },
        })
    except (urllib.error.URLError, OSError, ValueError):
        pass


def load_day():
    """L'appunto della giornata, o {} se non c'e' o non si legge."""
    try:
        with open(DAY_RECORD, encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        return {}

    return data if isinstance(data, dict) else {}


def save_day(data):
    """Scrive l'appunto, sostituendolo invece di riscriverlo sul posto."""
    tmp = DAY_RECORD + ".tmp"

    try:
        os.makedirs(os.path.dirname(DAY_RECORD), exist_ok=True)

        with open(tmp, "w", encoding="utf-8") as handle:
            json.dump(data, handle, ensure_ascii=False)

        os.replace(tmp, DAY_RECORD)
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass


def daily_charge(raw, persist=True):
    """I mAh raccolti da stamattina: il contatore di adesso meno quello di allora.

    Torna (oggi, inizio). La prima lettura del giorno fissa l'inizio, e da li'
    in poi ogni lettura e' una sottrazione — che e' esattamente la differenza
    fra il valore di ieri sera e quello di adesso, visto che di notte il
    pannello non produce e il contatore non si muove.

    Il tester si puo' azzerare da solo (basta staccarlo e riattaccarlo) e allora
    il contatore riparte da sotto: qui si riconosce dal fatto che scende, e
    l'inizio si sposta li' invece di far comparire un numero negativo. Quello
    che si perde in quel caso e' la raccolta prima dell'azzeramento, che il
    tester non sa piu' nemmeno lui.
    """
    today = date.today()
    day = load_day()

    if day.get("giorno") != today.isoformat() or not isinstance(day.get("inizio"), (int, float)):
        # Giornata nuova. L'inizio e' il contatore di ieri sera, non quello di
        # adesso: fra l'ultima lettura di ieri e la prima di oggi il tester ha
        # continuato a contare, e far ripartire il conto da adesso vorrebbe
        # dire buttare via quei mAh invece di attribuirli a un giorno.
        #
        # Vale pero' solo se ieri si e' letto davvero: dopo una settimana di
        # pioggia o di macchina spenta, l'ultimo valore e' di sette giorni fa,
        # e usarlo come inizio farebbe comparire oggi una punta che e' la
        # raccolta di tutta la settimana.
        before = day.get("ultimo")
        yesterday = day.get("giorno") == (today - timedelta(days=1)).isoformat()
        start = before if (yesterday and isinstance(before, (int, float))) else raw

        day = {"giorno": today.isoformat(), "inizio": float(start)}

    if raw < day["inizio"]:
        day["inizio"] = raw

    day["ultimo"] = raw

    if persist:
        save_day(day)

    return max(0.0, raw - day["inizio"]), day["inizio"]


def held_charge():
    """L'ultimo contatore del tester visto, o None.

    Serve quando il display e' spento: la carica pubblicata e' quella di oggi,
    e rileggerla da Home Assistant per ripubblicarla vorrebbe dire sottrarle
    l'inizio giornata una seconda volta. Il contatore vero e' qui.
    """
    held = load_day().get("ultimo")

    return float(held) if isinstance(held, (int, float)) else None


def midnight():
    """Mezzanotte di oggi, con il fuso: e' il `last_reset` della raccolta."""
    return datetime.now().astimezone().replace(
        hour=0, minute=0, second=0, microsecond=0).isoformat()


def last_value(name):
    """L'ultimo valore numerico di un sensore, o None se non c'e'.

    Serve a ripubblicare un contatore identico a se stesso mentre il tester e'
    spento. Il valore si rilegge da Home Assistant invece di tenerne una copia
    da questa parte: la copia sarebbe una seconda verita' da tenere allineata,
    e basterebbe un riavvio dello script per perderla.
    """
    try:
        current = ha_call("/api/states/" + PREFIX + name)
        return float(current.get("state"))
    except (urllib.error.URLError, OSError, ValueError, TypeError):
        return None


# ------------------------------------------------------------------ lettura


def clean(text):
    """Toglie gli spazi che l'OCR semina dentro i numeri.

    "0. 20" e "675. 506" sono un numero solo spezzato da uno spazio che sullo
    schermo non c'e': nasce dai puntini dei caratteri a matrice, che l'OCR
    legge come separatori. Si chiude il buco prima di guardare i valori,
    altrimenti ogni espressione regolare deve prevederlo.
    """
    text = text.replace(",", ".")
    text = re.sub(r"(\d)\s*\.\s*(\d)", r"\1.\2", text)

    return text


def number(match):
    """Il numero di un match, con lo spazio accettato come virgola.

    Quando l'OCR perde il punto decimale lascia un buco al suo posto — "0 78"
    per 0.728, "03 545" per 003.545 — e il buco e' informazione: dice dove il
    punto stava. Trattarlo come separatore recupera un ordine di grandezza
    giusto, che ai vincoli basta per lavorare.
    """
    if match is None:
        return None

    try:
        return float(match.group(1).replace(" ", "."))
    except (TypeError, ValueError, AttributeError):
        return None


def parse(text):
    """Dal testo dell'OCR ai valori del display, senza ancora giudicarli.

    Qui si estrae quello che si riesce a leggere e basta: le correzioni le fa
    dopo `reconcile`, che ha i vincoli per farle. Un parser che tira a
    indovinare da solo e' un parser che produce numeri credibili e sbagliati.
    """
    text = clean(text)
    found = {}

    # Sul display ci sono quattro tensioni — V-, D+, D-, V+ — e solo l'ultima
    # e' quella di alimentazione, affiancata da corrente e potenza. Cercare
    # "la prima V del testo" pesca D+ e produce un 0.20 al posto di un 4.87.
    #
    # La riga giusta si riconosce dal fatto che porta tre numeri, e sono in
    # ordine: tensione, corrente, potenza. Le unita' non servono a trovarla, ed
    # e' bene cosi' — a seconda di come cade la luce lo stesso schermo si legge
    # "0 810A 003 7334" o "D S224 DI3 7HBW", e una regola che si appoggia alla
    # A o alla W funziona a scatti alterni.
    triple = re.compile(r"(\d{1,3}[.\s]\d{1,4})")
    supply = ""
    values = []

    for line in text.splitlines():
        here = triple.findall(line)

        if len(here) >= 3:
            supply, values = line, here
            break

    if values:
        found["tensione"] = number(re.match(r"(.*)", values[0]))
        found["corrente"] = number(re.match(r"(.*)", values[1]))
        found["potenza"] = number(re.match(r"(.*)", values[2]))
    else:
        # Riga di alimentazione irriconoscibile: si ripiega sulle unita'. Da
        # sole non bastano — questo e' il caso in cui la lettura probabilmente
        # verra' scartata — ma tanto vale provarci.
        found["tensione"] = number(re.search(r"(\d+[.\s]\d+)\s*V", text))
        found["corrente"] = number(re.search(r"(\d+[.\s]\d+)\s*[Aa]", text))
        found["potenza"] = number(re.search(r"(\d{1,3}[.\s]\d+)\s*[WN](?![hHnN])", text))

    # L'energia porta l'unita' piu' maltrattata di tutte: Wh diventa 0h, Wn,
    # WN, wh a seconda di come cade la luce sui pixel.
    energy = re.search(r"(\d+\.\d+)\s*(?:Wh|Wn|WN|wh|0h|Oh)\b", text, re.I)
    found["energia"] = number(energy)

    # La m di mAh non e' negoziabile: senza, "675.5060h" — che e' l'energia
    # con la Wh mal letta — si presenta come 5060 mAh e viene creduta.
    if found["energia"] is None:
        # Persa anche la Wh, resta la forma del numero: sulla colonna di
        # destra la resistenza ha un decimale (006.6) e l'energia ne ha tre
        # (003.220). Sono due righe di sole cifre e si distinguono per quello.
        for line in text.splitlines():
            if line == supply or re.search(r"[VA]|m\s*[Aa]", line):
                continue

            spelled = re.search(r"(\d{1,3}\.\d{3})", line)

            if spelled:
                found["energia"] = number(spelled)
                break

    capacity = re.search(r"(\d{4,6})\s*[mn]\s*[AaHh]{1,2}", text)
    found["carica"] = number(capacity)

    # La temperatura e' scritta due volte, in gradi e in Fahrenheit, e le due
    # si controllano a vicenda: F = C · 9/5 + 32. E' la stessa idea di P = V·I
    # applicata all'angolo in basso a destra, e serve perche' qui l'OCR perde
    # volentieri la cifra delle decine ("6C/035F" per 36 °C / 096 °F). Senza
    # il controllo si pubblicherebbe un 6 al posto di un 36.
    # Fra il numero e la C ci puo' stare il simbolo dei gradi, ma non altre
    # cifre: senza quel divieto il "05" dei secondi viene preso per gradi e la
    # coppia da controllare e' gia' quella sbagliata in partenza.
    pair = re.search(r"(\d{1,3})\s*[^\d/]{0,2}[Cc]\s*/\s*(\d{1,3})\s*.?[Ff]", text)

    if pair:
        celsius, fahrenheit = float(pair.group(1)), float(pair.group(2))

        if abs(celsius * 9 / 5 + 32 - fahrenheit) <= 2:
            found["temperatura"] = celsius

    # La resistenza non ha un'unita' che l'OCR sappia leggere: Ω finisce in 2,
    # Q, O o niente. La si riconosce dalla forma — tre cifre, un decimale, e
    # nessuna unita' nota accanto — e comunque serve solo come arbitro, non
    # come dato da pubblicare.
    for line in text.splitlines():
        if re.search(r"[VAW]|m?Ah|:", line):
            continue

        ohm = re.search(r"(\d{3}\.\d)", line)

        if ohm:
            found["resistenza"] = number(ohm)
            break

    elapsed = re.search(r"(\d{4})\s*:\s*(\d{2})\s*:\s*(\d{2})", text)

    if elapsed:
        found["tempo"] = "%s:%s:%s" % elapsed.groups()

    return found


def reconcile(found):
    """Decide quale terna V/I/P credere, usando i vincoli invece dell'OCR.

    Tre ipotesi, una per ogni coppia di valori di cui fidarsi: la terza
    grandezza si ricalcola e si guarda se il risultato rispetta anche R = V/I.
    Vince quella con il residuo piu' basso, e solo se sta nelle tolleranze.

    Serve la resistenza per arbitrare. Quando manca ci si accontenta di
    P = V · I, che smaschera comunque il caso piu' comune — una cifra persa
    nella corrente — perche' la potenza sul display e' calcolata dal tester e
    non dall'OCR di nessuno.
    """
    v, i, p = found.get("tensione"), found.get("corrente"), found.get("potenza")
    r = found.get("resistenza")

    if not v or not i or v <= 0 or i <= 0:
        return None, "tensione o corrente illeggibili"

    if not p and not r:
        # Senza potenza ne' resistenza non resta nessun vincolo da rispettare,
        # e una tensione con una corrente sono due numeri che stanno insieme
        # per definizione: si accetterebbe qualunque cosa. Meglio un buco nel
        # grafico che un punto di cui non si sa niente.
        return None, "ne' potenza ne' resistenza leggibili: nessun controllo possibile"

    def residuals(cv, ci, cp):
        """Di quanto questa terna smentisce il display."""
        on_power = abs(cp - p) / p if p else None
        on_resistance = abs((cv / ci) - r) / r if r and ci else None

        return on_power, on_resistance

    def acceptable(on_power, on_resistance):
        if on_power is not None and on_power > POWER_TOLERANCE:
            return False

        if on_resistance is not None and on_resistance > RESISTANCE_TOLERANCE:
            return False

        return True

    def score_of(on_power, on_resistance):
        return on_resistance if on_resistance is not None else (on_power or 0.0)

    best = None

    # Prima ipotesi: l'OCR ha letto bene. Va verificata come le altre, ma se
    # regge vince a prescindere dai decimali — preferire una ricostruzione
    # perche' il suo residuo e' piu' piccolo di un millesimo vorrebbe dire
    # marcare come "corretta" una lettura che non aveva niente che non andasse.
    straight = residuals(v, i, v * i)

    if acceptable(*straight):
        best = (score_of(*straight), "V·I", v, i, v * i)
    elif p:
        # Le altre due letture degli stessi tre numeri: si crede a due valori
        # e si ricalcola il terzo, poi si guarda chi rispetta anche R = V/I.
        for source, cv, ci, cp in (("P/V", v, p / v, p), ("P/I", p / i, i, p)):
            on_power, on_resistance = residuals(cv, ci, cp)

            if not acceptable(on_power, on_resistance):
                continue

            score = score_of(on_power, on_resistance)

            if best is None or score < best[0]:
                best = (score, source, cv, ci, cp)

    if best is None:
        return None, "nessuna combinazione rispetta P = V·I e R = V/I"

    score, source, cv, ci, cp = best

    reading = {
        "tensione": round(cv, 3),
        "corrente": round(ci, 3),
        "potenza": round(cp, 3),
        "energia": found.get("energia"),
        "carica": found.get("carica"),
        "temperatura": found.get("temperatura"),
    }

    quality = {
        "fonte": source,
        "residuo": round(score, 4),
        "resistenza_letta": found.get("resistenza"),
        "tempo_tester": found.get("tempo", ""),
        # True solo quando i numeri letti non stavano in piedi da soli: e' il
        # segnale che l'OCR ha sbagliato qualcosa e la fisica l'ha rimesso a
        # posto, non un'etichetta da appiccicare a ogni lettura.
        "corretto": source != "V·I",
    }

    return reading, quality


def recorded_roi():
    """Il rettangolo registrato l'ultima volta, o "" se non ce n'e' uno.

    Un file illeggibile vale come un file assente: la lettura di adesso non
    dipende da questo appunto, e farla fallire per un JSON troncato sarebbe
    peggio del guasto che si vuole evitare.
    """
    try:
        with open(ROI_RECORD, encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        return ""

    roi = data.get("roi", "") if isinstance(data, dict) else ""

    return roi if isinstance(roi, str) else ""


def record_roi(roi):
    """Segna il rettangolo che il telefono ha appena usato.

    Si riscrive solo quando cambia: e' un file toccato ogni dieci minuti da un
    timer, e riscriverlo identico a se stesso sarebbe usura senza motivo. Il
    momento in cui cambia e' invece un'informazione — e' quando qualcuno ha
    riquadrato col mirino — e vale la pena averla scritta.
    """
    if not roi or roi == recorded_roi():
        return

    tmp = ROI_RECORD + ".tmp"

    try:
        os.makedirs(os.path.dirname(ROI_RECORD), exist_ok=True)

        with open(tmp, "w", encoding="utf-8") as handle:
            json.dump({"roi": roi, "seen": time.strftime("%Y-%m-%d %H:%M:%S")},
                      handle, ensure_ascii=False)

        os.replace(tmp, ROI_RECORD)
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass


def capture(device, roi, dry_run=False):
    """Uno scatto e la sua interpretazione, o il motivo per cui non si usa."""
    shot = phone_adb.do_photo(mode="macro", target=device, roi=roi, full=True)

    if not shot.get("ok"):
        return None, {"errore": shot.get("error", "scatto fallito")}

    # Quello che il telefono ha davvero inquadrato, che con `roi` vuoto e' il
    # rettangolo suo. Registrarlo qui vuol dire che una riquadratura fatta col
    # mirino resta scritta anche da questa parte, senza doverla ricopiare a
    # mano in nessun file.
    used = shot.get("roi") or ""
    record_roi(used)

    text = shot.get("text", "")

    # Nessun testo nell'immagine non vuol dire "lettura difficile": vuol dire
    # che non c'era niente da leggere. Il tester spegne il display da solo
    # quando resta senza alimentazione, e continuare a parlare di cifre
    # illeggibili manderebbe a cercare il guasto nell'OCR invece che nel cavo.
    if len(text.strip()) < 8:
        return None, {"errore": "il display del tester e' spento o al buio",
                      "buio": True,
                      "roi": used,
                      "immagine": shot.get("path", "")}

    found = parse(text)
    reading, quality = reconcile(found)

    if reading is None:
        return None, {"errore": quality, "letto": found, "roi": used,
                      "immagine": shot.get("path", "")}

    reading["image"] = shot.get("path", "")
    quality["took_ms"] = shot.get("took_ms")
    quality["roi"] = used

    return reading, quality


def measure(device, roi, dry_run=False, retries=1):
    """La lettura buona, riscattando una volta se la prima non convince.

    Il secondo tentativo esiste perche' il caso piu' frequente e' banale: una
    messa a fuoco che non ha agganciato, o il display che ha aggiornato i
    numeri mentre l'otturatore era aperto. Ripetere costa tre secondi e salva
    il campione; insistere oltre no, perche' un'inquadratura sbagliata non
    migliora riprovando.
    """
    problems = []

    for attempt in range(retries + 1):
        reading, quality = capture(device, roi, dry_run)

        if reading:
            quality["tentativi"] = attempt + 1
            return reading, quality

        problems.append(quality)

        # Il telefono non ha nessun rettangolo: l'app e' stata reinstallata, o
        # le hanno cancellato i dati. La prima foto ha inquadrato la scrivania,
        # e senza rimediare il timer continuerebbe a fotografarla ogni dieci
        # minuti. Il secondo tentativo glielo rimette — quello registrato, e
        # solo in mancanza di quello il seme scritto qui dentro.
        if not roi and quality.get("roi") == "":
            roi = recorded_roi() or DEFAULT_ROI

    # Display spento a ogni tentativo: il tester non ha corrente, quindi non ne
    # passa nemmeno al carico. Zero e' la misura vera, e vale la pena
    # pubblicarla — in un grafico un buco vuol dire "non so", che e' un'altra
    # cosa dal pannello staccato.
    #
    # Un solo scatto nero non basterebbe: la messa a fuoco puo' fallire e una
    # foto mossa e' nera quanto un display spento. Serve che lo siano tutti.
    if problems and all(p.get("buio") for p in problems):
        dark = {
            "tensione": 0.0,
            "corrente": 0.0,
            "potenza": 0.0,
            # Fuori la temperatura: quella del tester non e' zero perche' il
            # display e' spento, semplicemente non si sa piu' quanto vale.
            "image": problems[-1].get("immagine", ""),
        }

        # I due contatori si riscrivono **identici**, mai azzerati e mai
        # ricalcolati. Sono `total_increasing`: uno zero direbbe a Home
        # Assistant che il contatore e' ripartito e gli farebbe sommare
        # un'altra volta l'intera giornata, mentre lo stesso valore ripetuto
        # non conta niente.
        #
        # Riscriverlo invece di ometterlo tiene viva l'entita': quelle create
        # da /api/states spariscono al riavvio di Home Assistant, e tensione e
        # potenza tornerebbero al primo ciclo perche' vengono pubblicate anche
        # a zero, mentre i contatori tornerebbero solo alla prossima giornata
        # di sole — cioe' quando il valore di ieri non serve piu' a nessuno.
        if not dry_run:
            held = last_value("energia")

            if held is not None:
                dark["energia"] = held

        # La carica no: quella pubblicata e' la raccolta di oggi, e rileggerla
        # da Home Assistant per riscriverla vorrebbe dire passarla di nuovo
        # dalla sottrazione — cioe' toglierle l'inizio giornata due volte, e
        # spostare l'inizio stesso su un numero che non e' un contatore. Il
        # contatore del tester sta nell'appunto della giornata, e da li' si
        # rilegge tale e quale.
        held = held_charge()

        if held is not None:
            dark["carica"] = held

        return dark, {
            "fonte": "display spento",
            "buio": True,
            "tentativi": len(problems),
        }

    return None, {"errore": "lettura non affidabile", "tentativi": problems}


# --------------------------------------------------------------------- main


def run(device, roi, dry_run=False, force=False, from_text="", min_elevation=MIN_ELEVATION):
    # Il testo finto serve alle prove: si controlla il parser e i vincoli
    # senza chiedere niente al telefono, e soprattutto si puo' provare una
    # lettura sbagliata, che dal vero non si sa come farsi dare.
    if from_text:
        found = parse(from_text)
        reading, quality = reconcile(found)

        if reading is None:
            return {"ok": False, "scartata": True, "motivo": quality, "letto": found}

        return {"ok": True, "lettura": reading, "qualita": quality, "letto": found}

    sky = sun()

    if not sky.get("ok"):
        return {"ok": False, "error": "Home Assistant non risponde: " + sky.get("error", "")}

    if not force:
        elevation = sky.get("elevation") or -90

        if not sky.get("above") or elevation < min_elevation:
            # Nessuno scatto e nessun errore: di notte non c'e' niente da
            # misurare, e svegliare il telefono ogni dieci minuti per
            # fotografare uno zero sarebbe solo usura.
            return {
                "ok": True,
                "skipped": "sole troppo basso (%.1f°)" % elevation,
                "elevation": elevation,
            }

    reading, quality = measure(device, roi, dry_run)

    if reading is None:
        count_discard(str(quality.get("errore", "")), dry_run)
        return {"ok": False, "scartata": True, "motivo": quality}

    sent = publish(reading, sky, dry_run, quality.get("buio", False))

    return {
        "ok": sent.get("ok", False),
        "buio": quality.get("buio", False),
        "lettura": reading,
        "qualita": quality,
        "sole": {"elevazione": sky.get("elevation"), "azimut": sky.get("azimuth")},
        "inviato": sent.get("written", {}),
        "dry_run": dry_run,
        "error": sent.get("error", ""),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--device", default=DEFAULT_DEVICE, help="quale telefono fotografa")
    parser.add_argument("--roi", default="",
                        help="forza il rettangolo per questo scatto; vuoto = "
                             "quello che ha il telefono (riquadralo col mirino: "
                             "phone_adb.py aim)")
    parser.add_argument("--dry-run", action="store_true", help="legge e stampa, senza scrivere in HA")
    parser.add_argument("--force", action="store_true", help="scatta anche col sole basso")
    parser.add_argument("--from-text", default="", help="interpreta questo testo invece di scattare")
    parser.add_argument("--min-elevation", type=float, default=MIN_ELEVATION,
                        help="altezza del sole sotto la quale non si scatta (default: alba/tramonto)")
    args = parser.parse_args()

    payload = run(args.device, args.roi, args.dry_run, args.force, args.from_text,
                  args.min_elevation)

    print(json.dumps(payload, ensure_ascii=False, indent=2 if sys.stdout.isatty() else None))

    if payload.get("ok"):
        return 0

    # Tre esiti, non due. Una lettura scartata e' il sistema che funziona —
    # ha guardato, non si e' fidato, e l'ha detto — e trattarla come un
    # fallimento dipinge di rosso in systemd un servizio che sta lavorando
    # come deve. Il codice 1 resta per i guasti veri: Home Assistant
    # irraggiungibile, telefono assente, script rotto.
    return 2 if payload.get("scartata") else 1


if __name__ == "__main__":
    sys.exit(main())
