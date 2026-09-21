#!/usr/bin/env python3
"""Espone la dashboard all'app telefono, sulla rete locale.

La dashboard sa gia' rispondere a qualunque domanda su questa macchina --
`qs ipc call dashboard query` -- ma risponde su un socket unix, che dal
telefono non si raggiunge. Questo demone sta in mezzo: interroga la
dashboard, tiene le connessioni dei telefoni e spinge gli aggiornamenti.

Il protocollo e' quello del demone Stenografa (righe JSON separate da "\\n",
token, TLS self-signed con pinning dell'impronta, rate limit sui tentativi
di autenticazione): non per gusto di uniformita', ma perche' quel giro e'
gia' stato debuggato in casa e l'app telefono lo implementa gia'.

Cosa NON fa: campionare. Non legge /proc, non lancia nvidia-smi, non tiene
storici propri. Tutti i numeri vengono dalla dashboard viva, che li ha gia'
caldi -- CPU, disco e rete sono differenze fra due campioni, e un processo
appena nato non ne ha nessuna.

L'unica eccezione e' kdeconnect.py, che si esegue direttamente perche' non
e' differenziale e risponde anche a dashboard spenta: e' lo stesso taglio
che fa gia' dashboard_mcp.py.
"""

import argparse
import json
import os
import secrets
import socket
import subprocess
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

CONFIG_DIR = os.path.expanduser("~/.config/quickshell")
CONFIG_PATH = os.path.join(CONFIG_DIR, "phone-bridge.json")
CERT_PATH = os.path.join(CONFIG_DIR, "bridge-cert.pem")
KEY_PATH = os.path.join(CONFIG_DIR, "bridge-key.pem")
CERT_DAYS = 3650

# 8765-8767 sono di Stenografa, 8420 di MacroCam, 8421 di HealthBridge,
# 8024 del TTS: questa e' la prima libera dopo le loro.
DEFAULT_PORT = 8770
LISTEN_HOST = "0.0.0.0"

# Come si parla alla dashboard.
#
# --any-display non e' decorazione: `qs ipc` considera viva un'istanza solo
# se condivide la connessione al display di CHI CHIAMA, quindi senza
# WAYLAND_DISPLAY nell'ambiente risponde "no running instances" mentre la
# dashboard e' li' sullo schermo. Un demone avviato da systemd --user quella
# variabile non ce l'ha per forza. E' lo stesso guasto misurato in
# dashboard_mcp.py, e i flag vanno DOPO `ipc`.
IPC_CONFIG = "dashboard"
IPC_FLAGS = ["-c", IPC_CONFIG, "--any-display"]
IPC_TIMEOUT = 15

KDECONNECT = os.path.join(HERE, "kdeconnect.py")

# Tentativi di autenticazione falliti tollerati per indirizzo, e finestra su
# cui si contano: un token di cinque cifre si indovina in centomila prove, e
# senza freno una manciata di secondi basterebbe.
AUTH_MAX_ATTEMPTS = 5
AUTH_WINDOW_SECONDS = 60

# Quanto vale il tempo per ogni sorgente, in millisecondi. Le differenze non
# sono arbitrarie: rispecchiano quanto spesso il dato sotto cambia davvero
# (vedi le stesse cadenze nella dashboard). Interrogare `health` due volte
# al secondo vorrebbe dire rileggere SMART, che si aggiorna ogni cinque
# minuti.
SOURCE_PERIODS = {
    "overview": 2000,
    "series": 2000,
    "health": 30000,
    "pressure": 30000,
    "home_assistant": 15000,
    "connections": 10000,
    "top_gpu": 10000,
    "phones": 30000,
}

# Quali sorgenti servono a ciascun modulo dell'app, e quali serie storiche
# disegna. Gli id sono gli stessi dei pannelli del desktop, cosi' una
# configurazione si legge da tutte e due le parti.
#
# E' questa tabella a far risparmiare banda e batteria: un telefono che
# guarda la sola CPU non fa interrogare ne' `connections` (che porta con se'
# reverse DNS e geolocalizzazione) ne' Home Assistant.
MODULES = {
    "cpu": (["overview"], ["cpu"]),
    "topcpu": (["overview"], []),
    "ram": (["overview"], ["memory"]),
    "topram": (["overview"], []),
    "gpu": (["overview"], ["gpu"]),
    "topgpu": (["top_gpu"], []),
    "vram": (["overview"], ["vram"]),
    "topvram": (["top_gpu"], []),
    "power": (["overview"], ["power_cpu", "power_gpu"]),
    "net": (["overview"], ["net_rx", "net_tx"]),
    "connections": (["connections"], []),
    "temps": (["health"], []),
    "disks": (["health"], []),
    "health": (["health"], []),
    "pressure": (["pressure"], ["psi_cpu", "psi_io", "psi_mem"]),
    "freq": (["overview"], ["freq"]),
    "homeassistant": (["home_assistant"], []),
    "solar": (["home_assistant"], []),
    "weather": (["home_assistant"], []),
    "igrometro": (["home_assistant"], []),
    "inspire": (["home_assistant"], []),
    "heart": ([], ["heart"]),
    "phones": (["phones"], []),
}


# Le sorgenti che servono a calcolare l'attivita', e che vengono interrogate
# anche quando nessuno le sta guardando: la vista dinamica deve sapere che la
# CPU e' schizzata mentre il telefono e' su un'altra pagina, altrimenti non
# potrebbe mai farcela entrare.
#
# `home_assistant` e' nell'elenco e non costa quanto sembra: la dashboard
# interroga Home Assistant ogni quindici secondi per conto suo comunque, e da
# qui si legge quello che ha gia' in memoria. Senza, un braccialetto scarico e
# un'umidita' fuori norma non entrerebbero mai.
ACTIVITY_SOURCES = [
    "overview", "health", "pressure", "phones", "home_assistant",
    # Le connessioni non costano un campionamento nuovo -- la dashboard tiene
    # quei dati caldi comunque -- ma senza chiederle il loro punteggio non si
    # calcolava mai, e il modulo restava "senza punteggio" per sempre.
    "connections",
]

# Le serie storiche che servono ai punteggi. Frequenza e battito non stanno in
# `overview`: la prima non e' fra i suoi campi, il secondo arriva da Fitbit.
# Stanno tutti e due qui, e questa e' l'unica ragione per cui la sorveglianza
# chiede anche le serie.
ACTIVITY_METRICS = ["freq", "heart"]

# Le entita' di Home Assistant da cui dipendono `solar`, `igrometro` e
# `inspire`. Hanno nomi fissi -- li pubblicano scripts/solar_meter.py e
# scripts/hygrometer.py -- e vanno chieste sempre, altrimenti quei tre moduli
# non hanno da cui calcolarsi. Misurato: senza, il ponte chiedeva
# `entities: []`, che per Query.qml vuol dire "nessuna" e non "tutte", e
# tornavano zero entita'.
ACTIVITY_ENTITIES = [
    "sensor.solare_usb_potenza",
    "sensor.igrometro_umidita",
    "sensor.inspire_3_battery",
]

# Un nome che non e' un modulo, usato dove i moduli si contano: sta
# nell'insieme richiesto come se fosse uno di loro e vale quelle sorgenti
# li'. Con l'underscore davanti perche' un client non deve poterlo chiedere
# per nome -- lo chiede con `activity`, e la differenza conta: il segnaposto
# e' un dettaglio di come il ponte tiene i conti, non parte del protocollo.
_ACTIVITY = "_activity"

# I fondoscala di chi non ne ha uno naturale. Una percentuale si giudica da
# sola; otto megabyte al secondo no, finche' non si dice rispetto a cosa.
ACTIVITY_SCALES = {
    # Una rete di casa in gigabit arriva a ~110 MB/s, ma il traffico che vale
    # la pena guardare comincia molto prima. Dieci, non cinque: misurato qui,
    # un download qualunque tocca i 18 MB/s a raffiche, e con la soglia a
    # cinque la rete sarebbe rimasta piantata in cima alla vista per tutto il
    # tempo, che e' il modo piu' rapido di rendere inutile una classifica.
    "net_bytes_per_second": 10 * 1024 * 1024,
    # CPU piu' GPU sotto carico su questa classe di macchine.
    "power_watts": 400,
    # Peer pubblici contemporanei: un browser aperto ne fa una decina.
    "connection_peers": 20,
    # Sopra il battito a riposo di un adulto seduto.
    "heart_bpm": 100,
    # Sotto questa carica un telefono e' un problema che si avvicina.
    "phone_battery_percent": 30,
    # Un braccialetto sotto il venti percento va messo in carica stasera.
    "band_battery_percent": 20,
    # Il tester solare che eroga: sopra questi watt sta facendo qualcosa.
    "solar_watts": 5,
}

# Le classifiche seguono il modulo che spiegano: quando la CPU e' al 94 la
# domanda dopo e' sempre "chi", e un punto meno le fa comparire subito sotto
# invece che in fondo all'elenco -- o peggio, in un'altra pagina.
# I moduli per cui esiste una formula. Gli altri non entrano mai nella vista
# dinamica, e l'app li toglie dalla lista delle soglie invece di mostrarne la
# riga con l'interruttore morto: una riga che non si puo' toccare non e'
# informazione, e' un ostacolo.
#
# Sta scritto qui e non nell'app perche' e' il ponte a saperlo: la formula e'
# sua. Viaggia con l'autenticazione, accanto all'elenco dei moduli.
SCORABLE = [
    "cpu", "topcpu", "ram", "topram", "gpu", "topgpu", "vram", "topvram",
    "power", "freq", "net", "connections", "temps", "disks", "health",
    "pressure", "heart", "phones", "solar", "igrometro", "inspire",
]

RANKING_OF = {
    "topcpu": "cpu",
    "topram": "ram",
    "topgpu": "gpu",
    "topvram": "vram",
}


# Quanto puo' salire un carico misurato su un fondoscala di comodo.
#
# Otto megabyte al secondo e ottanta danno lo stesso punteggio, perche' il
# fondoscala della rete non e' un massimo ma una soglia di interesse: quel
# valore vuol dire "sta scaricando parecchio", non "non puo' fare di piu'".
# Un disco che SMART da' per spacciato invece e' davvero il caso peggiore che
# esista, e deve poter stare sopra. Da cui i cinque punti di distanza.
LOAD_CEILING = 95.0

# Quanti pacchetti scartati prima di considerarli una notizia. Sotto questa
# quantita' e' il normale funzionamento di una scheda di rete.
DROPPED_PACKETS_WORTH_TELLING = 100


def _pct(value, full_scale, ceiling=100.0):
    """Un valore sul suo fondoscala, in percentuale, senza sforare."""
    if value is None or not full_scale:
        return None
    return max(0.0, min(ceiling, float(value) / float(full_scale) * 100.0))


def _entity(cache, entity_id):
    """Lo stato numerico di un'entita' di Home Assistant, o None."""
    ha = cache.get("home_assistant") or {}
    for entity in ha.get("entities") or []:
        if entity.get("entity_id") == entity_id:
            try:
                return float(entity.get("state"))
            except (TypeError, ValueError):
                return None
    return None


def activity_scores(cache):
    """Da quello che si sa della macchina a quanto ogni modulo merita di
    essere guardato adesso: un numero da 0 a 100 per modulo.

    Non e' solo "quanto sta lavorando". Un disco che SMART da' per spacciato
    non sta lavorando affatto ed e' la cosa piu' urgente che ci sia, mentre
    una CPU al 90% durante una compilazione e' esattamente cio' che ci si
    aspetta. Le due cose finiscono nella stessa scala apposta: la domanda a
    cui la vista dinamica risponde e' "cosa guardo adesso", e ha una risposta
    sola.

    Chi non ha un'urgenza sensata non compare nel risultato e non entra mai
    nella vista: Home Assistant nel suo insieme e il meteo sono cose che si
    consultano, non che chiamano.

    Funzione pura: dentro c'e' la cache delle risposte, fuori i punteggi.
    """
    scores = {}
    overview = cache.get("overview") or {}
    health = cache.get("health") or {}
    pressure = cache.get("pressure") or {}

    def put(module, value):
        if value is not None:
            scores[module] = round(float(value), 1)

    # --- carico ---------------------------------------------------------
    cpu = overview.get("cpu") or {}
    put("cpu", cpu.get("busy_percent"))

    memory = overview.get("memory") or {}
    put("ram", memory.get("used_percent"))

    gpu = overview.get("gpu")
    if isinstance(gpu, dict):
        put("gpu", gpu.get("busy_percent"))
        used, total = gpu.get("vram_used_bytes"), gpu.get("vram_total_bytes")
        if used is not None and total:
            put("vram", _pct(used, total))

    net = overview.get("network") or {}
    busiest = max(net.get("rx_bytes_per_second") or 0, net.get("tx_bytes_per_second") or 0)
    if net:
        put("net", _pct(busiest, ACTIVITY_SCALES["net_bytes_per_second"], LOAD_CEILING))

    put("power", _pct(overview.get("power_watts"), ACTIVITY_SCALES["power_watts"], LOAD_CEILING))

    # --- attesa ---------------------------------------------------------
    waiting = pressure.get("waiting") or {}
    if waiting:
        # Gia' una percentuale di tempo passato ad aspettare invece che a
        # lavorare: non c'e' niente da normalizzare.
        put("pressure", max(
            waiting.get("cpu") or 0,
            waiting.get("io") or 0,
            waiting.get("memory") or 0,
        ))

    # --- anomalie -------------------------------------------------------
    # Ogni sensore contro il PROPRIO critico, non contro cento: una CPU a 80
    # gradi e' vicina al limite, un disco a 80 e' oltre.
    hottest = None
    for sensor in health.get("temperatures_celsius") or []:
        celsius, critical = sensor.get("celsius"), sensor.get("critical_at")
        if celsius is None or not critical:
            continue
        ratio = _pct(celsius, critical)
        if ratio is not None and (hottest is None or ratio > hottest):
            hottest = ratio
    put("temps", hottest)

    disks = health.get("disks") or []
    if disks:
        worst = 0.0
        for disk in disks:
            verdict = (disk.get("health") or {}).get("verdict")
            # Un disco che sta morendo batte qualunque disco pieno: lo spazio
            # si libera, un disco in avaria no.
            if verdict == "failing":
                worst = 100.0
            elif verdict == "warning":
                worst = max(worst, 85.0)
            full = disk.get("used_percent")
            if full is not None and full >= 0:
                worst = max(worst, float(full))
        put("disks", worst)

    trouble = 0.0
    if (health.get("oom_kills_since_dashboard_started") or 0) > 0:
        trouble = 90.0
    errors = health.get("network_errors") or {}
    if isinstance(errors, dict):
        # Un errore vero conta subito; un pacchetto scartato no. Misurato
        # qui: due `rxDropped` in tre ore di uptime facevano gridare al
        # guasto una macchina che stava benissimo -- ogni scheda di rete ne
        # scarta qualcuno, ed e' rumore finche' non diventa una quantita'.
        if (errors.get("rxErrors") or 0) + (errors.get("txErrors") or 0) > 0:
            trouble = max(trouble, 70.0)
        elif (errors.get("rxDropped") or 0) + (errors.get("txDropped") or 0) > DROPPED_PACKETS_WORTH_TELLING:
            trouble = max(trouble, 50.0)
    if (health.get("smart_access") or "") != "ok" and health.get("smart_access") is not None:
        trouble = max(trouble, 60.0)
    if health:
        put("health", trouble)

    connections = cache.get("connections") or {}
    if connections.get("ok"):
        peers = len(connections.get("peers") or [])
        put("connections", _pct(peers, ACTIVITY_SCALES["connection_peers"], LOAD_CEILING))

    # --- corpo e dintorni -----------------------------------------------
    battery = None
    for device in (cache.get("phones") or {}).get("devices") or []:
        level = (device.get("battery") or {}).get("percent")
        if device.get("reachable") and level is not None:
            battery = level if battery is None else min(battery, level)
    if battery is not None:
        floor = ACTIVITY_SCALES["phone_battery_percent"]
        # Piu' e' scarico, piu' e' urgente: la scala e' rovesciata.
        put("phones", max(0.0, (floor - battery) / floor * 100.0))

    band = _entity(cache, "sensor.inspire_3_battery")
    if band is not None:
        floor = ACTIVITY_SCALES["band_battery_percent"]
        put("inspire", max(0.0, (floor - band) / floor * 100.0))

    watts = _entity(cache, "sensor.solare_usb_potenza")
    if watts is not None:
        put("solar", _pct(watts, ACTIVITY_SCALES["solar_watts"], LOAD_CEILING))

    humidity = _entity(cache, "sensor.igrometro_umidita")
    if humidity is not None:
        # Zero dentro la fascia di comfort, cento fuori da 30-70: e' la
        # distanza dallo stare bene, non un livello.
        if 40 <= humidity <= 60:
            put("igrometro", 0.0)
        else:
            edge = 40 if humidity < 40 else 60
            put("igrometro", _pct(abs(humidity - edge), 10, LOAD_CEILING))

    # --- dalle serie storiche -------------------------------------------
    # Frequenza e battito non stanno in `overview`: si leggono dall'ultimo
    # punto della loro serie. Il battito ha dei buchi -- il braccialetto sta
    # sul comodino -- quindi si cerca l'ultimo valore vero, non l'ultimo
    # posto della lista.
    series = (cache.get("series") or {}).get("series") or {}

    def latest(metric):
        values = (series.get(metric) or {}).get("values") or []
        for value in reversed(values):
            if value is not None:
                return value
        return None

    frequency = series.get("freq") or {}
    top_speed = frequency.get("max") or 0
    put("freq", _pct(latest("freq"), top_speed, LOAD_CEILING))

    beats = latest("heart")
    if beats is not None:
        # Sopra il battito a riposo comincia a essere una notizia; sotto,
        # e' semplicemente qualcuno seduto.
        put("heart", _pct(beats, ACTIVITY_SCALES["heart_bpm"], LOAD_CEILING))

    # --- le classifiche seguono il loro modulo --------------------------
    for ranking, parent in RANKING_OF.items():
        if parent in scores:
            put(ranking, max(0.0, scores[parent] - 1))

    return scores


def log(message):
    """Una riga per volta su stderr, con l'ora. stdout resta libero perche'
    e' li' che finisce il JSON quando si prova il demone a mano."""
    sys.stderr.write("%s  %s\n" % (time.strftime("%H:%M:%S"), message))
    sys.stderr.flush()


# =============================================================================
# CONFIGURAZIONE E TOKEN
# =============================================================================

def load_config():
    """Legge (o crea) ~/.config/quickshell/phone-bridge.json.

    Il token si genera al primo avvio e si stampa nel log: e' l'unico modo
    che ha l'utente di conoscerlo, come per Stenografa. Cinque cifre perche'
    si digitano su un telefono senza sbagliare -- e' corto, ed e' proprio per
    questo che c'e' il rate limit sopra e il TLS sotto."""
    os.makedirs(CONFIG_DIR, exist_ok=True)
    config = {}
    try:
        with open(CONFIG_PATH) as handle:
            config = json.load(handle)
    except FileNotFoundError:
        pass
    except (OSError, ValueError) as error:
        log("config illeggibile (%s): riparto dai default" % error)

    changed = False
    if not str(config.get("token", "")).isdigit() or len(str(config.get("token", ""))) != 5:
        config["token"] = "%05d" % secrets.randbelow(100000)
        changed = True
        log("token nuovo: %s  (sta in %s)" % (config["token"], CONFIG_PATH))
    if "port" not in config:
        config["port"] = DEFAULT_PORT
        changed = True
    if "require_tls" not in config:
        # Non si parte pretendendolo: openssl potrebbe mancare, e un telefono
        # che non si collega e' peggio di un telefono che si collega in
        # chiaro sulla rete di casa. Si accende dalle impostazioni una volta
        # verificato che il TLS funziona.
        config["require_tls"] = False
        changed = True

    if changed:
        save_config(config)
    return config


def save_config(config):
    tmp = CONFIG_PATH + ".tmp"
    with open(tmp, "w") as handle:
        json.dump(config, handle, indent=4, sort_keys=True)
    os.replace(tmp, CONFIG_PATH)
    os.chmod(CONFIG_PATH, 0o600)


# =============================================================================
# TLS
# =============================================================================

def generate_cert():
    """Certificato self-signed con openssl. False se non c'e' verso: il
    demone continua in chiaro invece di non partire."""
    try:
        subprocess.run(
            [
                "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                "-keyout", KEY_PATH, "-out", CERT_PATH,
                "-days", str(CERT_DAYS), "-subj", "/CN=quickshell-bridge",
            ],
            check=True,
            capture_output=True,
            timeout=60,
        )
    except (OSError, subprocess.SubprocessError) as error:
        log("openssl non ha generato il certificato (%s): si resta in chiaro" % error)
        return False
    if not (os.path.exists(CERT_PATH) and os.path.exists(KEY_PATH)):
        return False
    os.chmod(KEY_PATH, 0o600)
    return True


def cert_fingerprint():
    """Impronta SHA-1 nel formato "AA:BB:..", quella che l'app fissa.

    SHA-1 e non SHA-256 perche' e' l'unica che X509Certificate di Dart
    espone senza dipendenze: per spacciarsi per un certificato gia' noto
    serve una seconda preimmagine, non una collisione, quindi regge lo
    scopo."""
    import hashlib
    import ssl

    try:
        with open(CERT_PATH) as handle:
            der = ssl.PEM_cert_to_DER_cert(handle.read())
    except (OSError, ValueError):
        return None
    digest = hashlib.sha1(der).hexdigest().upper()
    return ":".join(digest[i:i + 2] for i in range(0, len(digest), 2))


def build_tls_context():
    """(contesto, impronta), oppure (None, None) se il TLS non e'
    disponibile."""
    if not (os.path.exists(CERT_PATH) and os.path.exists(KEY_PATH)):
        if not generate_cert():
            return None, None
    try:
        import ssl

        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(CERT_PATH, KEY_PATH)
    except (OSError, ImportError, ValueError) as error:
        log("certificato inutilizzabile (%s): si resta in chiaro" % error)
        return None, None
    return context, cert_fingerprint()


# =============================================================================
# LA DASHBOARD
# =============================================================================

class DashboardDown(Exception):
    """La dashboard non risponde. Merita un'eccezione invece di un dizionario
    vuoto perche' la risposta onesta e' "adesso non vedo la macchina": zeri
    al posto dei dati direbbero che non sta succedendo niente, che e' una
    risposta sbagliata invece che mancante."""


def ipc(function, request):
    """Una chiamata IPC alla dashboard, JSON dentro e JSON fuori."""
    try:
        done = subprocess.run(
            ["qs", "ipc"] + IPC_FLAGS + ["call", IPC_CONFIG, function, json.dumps(request)],
            capture_output=True,
            text=True,
            timeout=IPC_TIMEOUT,
        )
    except FileNotFoundError:
        raise DashboardDown("`qs` non e' nel PATH: quickshell non sembra installato")
    except subprocess.SubprocessError as error:
        raise DashboardDown("la dashboard non risponde: %s" % error)

    out = done.stdout.strip()
    if done.returncode != 0 or not out:
        detail = (done.stderr or "").strip().splitlines()
        raise DashboardDown(detail[-1] if detail else "nessuna risposta")

    try:
        return json.loads(out)
    except ValueError:
        raise DashboardDown("la dashboard ha risposto con qualcosa che non e' JSON")


def kdeconnect():
    """I telefoni via KDE Connect, letti direttamente dallo script."""
    try:
        done = subprocess.run(
            ["python3", KDECONNECT], capture_output=True, text=True, timeout=30
        )
        return json.loads(done.stdout)
    except (OSError, subprocess.SubprocessError, ValueError) as error:
        return {"ok": False, "error": "kdeconnect: %s" % error}


# =============================================================================
# RACCOLTA
# =============================================================================

class Collector:
    """Interroga la dashboard per conto dei telefoni collegati.

    Chiede solo quello che qualcuno sta guardando: l'unione dei moduli accesi
    su tutti i client. Quando l'ultimo telefono spegne un modulo, la sorgente
    smette di essere interrogata al giro dopo."""

    def __init__(self, bridge):
        self.bridge = bridge
        self.lock = threading.Lock()
        # sorgente -> istante (monotonic) dell'ultima interrogazione riuscita
        self.last = {}
        # sorgente -> ultima risposta, per lo snapshot a chi arriva dopo
        self.cache = {}
        self.down_since = None
        self.down_told = 0
        # L'ultimo motivo del guasto, per raccontarlo a chi si collega a
        # guasto gia' in corso invece di farlo aspettare il giro seguente.
        self.down_error = None
        self.scores = {}

    def wanted(self):
        """(sorgenti, metriche, entita') che servono ai client di adesso."""
        modules, metrics, asked = self.bridge.subscriptions()
        sources = set()
        series = set(metrics)
        entities = set(asked)
        for name in modules:
            if name == _ACTIVITY:
                sources.update(ACTIVITY_SOURCES)
                series.update(ACTIVITY_METRICS)
                entities.update(ACTIVITY_ENTITIES)
                continue
            found = MODULES.get(name)
            if found is None:
                continue
            sources.update(found[0])
            series.update(found[1])
        if series:
            sources.add("series")
        return sources, sorted(series), sorted(entities)

    def due(self, sources, now):
        """Le sorgenti scadute, fra quelle richieste."""
        out = []
        for name in sorted(sources):
            period = SOURCE_PERIODS.get(name, 10000) / 1000.0
            if now - self.last.get(name, 0) >= period:
                out.append(name)
        return out

    def tick(self):
        """Un giro. Ritorna i dati freschi da spingere, o None se non c'era
        niente da chiedere."""
        sources, metrics, entities = self.wanted()
        if not sources:
            return None

        now = time.monotonic()
        due = self.due(sources, now)
        if not due:
            return None

        fresh = {}

        # `phones` non passa dalla dashboard: kdeconnect.py risponde da solo,
        # ed e' l'unico caso in cui una risposta arriva anche a dashboard
        # spenta.
        if "phones" in due:
            due.remove("phones")
            fresh["phones"] = kdeconnect()
            self.last["phones"] = now

        if due:
            try:
                fresh.update(self.query(due, metrics, entities))
                for name in due:
                    if name in fresh:
                        self.last[name] = now
                if self.down_since is not None:
                    log("dashboard di nuovo raggiungibile")
                    self.bridge.broadcast({"type": "recovered"})
                self.down_since = None
                self.down_told = 0
                self.down_error = None
            except DashboardDown as error:
                first = self.down_since is None
                self.down_error = str(error)
                if first:
                    self.down_since = time.time()
                    log("dashboard muta: %s" % error)
                # Il guasto si annuncia una volta, poi si ricorda ogni mezzo
                # minuto: ripeterlo a ogni giro sarebbero trenta messaggi
                # identici al minuto verso un telefono che ha gia' capito, e
                # il ritorno (`recovered`) e' comunque immediato.
                if first or now - self.down_told >= 30:
                    self.down_told = now
                    self.bridge.broadcast(self.down_report())

        with self.lock:
            self.cache.update(fresh)
            snapshot = dict(self.cache)

        self.report_activity(snapshot)
        return fresh or None

    def down_report(self):
        """Il guasto in corso, o None se la dashboard risponde."""
        if self.down_since is None:
            return None
        return {
            "type": "error",
            "error": self.down_error or "dashboard non raggiungibile",
            "since": self.down_since,
            "hint": "avviala con `qs -c dashboard`",
        }

    def report_activity(self, cache):
        """Manda i punteggi a chi sorveglia, quando sono cambiati davvero.

        Un punto di differenza e' rumore di campionamento -- la CPU non sta
        ferma nemmeno da spenta -- e senza questo filtro sarebbe un messaggio
        ogni due secondi per dire la stessa cosa. Un modulo che compare o
        sparisce invece va detto sempre: e' esattamente il fatto che la vista
        dinamica aspetta."""
        if not self.bridge.watching_activity():
            return

        scores = activity_scores(cache)
        if scores.keys() == self.scores.keys() and all(
            abs(scores[name] - self.scores[name]) < 1.0 for name in scores
        ):
            return

        self.scores = scores
        self.bridge.broadcast(
            {"type": "activity", "scores": scores, "at": time.time()},
            activity_only=True,
        )

    def query(self, due, metrics, entities):
        """Le sorgenti scadute in una sola chiamata.

        Un `qs ipc call` e' un fork: sei pannelli aggiornati due volte al
        secondo, uno alla volta, sarebbero dodici processi al secondo per
        leggere dei numeri che la dashboard ha gia' in mano. Da cui il topic
        `bundle` (vedi Query.qml)."""
        topics = []
        for name in due:
            if name == "series":
                if not metrics:
                    continue
                topics.append({"topic": "series", "metrics": metrics})
            elif name == "top_gpu":
                topics.append({"topic": "top", "resource": "gpu"})
            elif name == "home_assistant":
                # Senza elenco il topic risponde con le prime quaranta entita'
                # in ordine alfabetico, che non e' quello che qualcuno sta
                # guardando. Con l'elenco risponde con quelle e basta, e
                # aggiunge comunque le entita' scelte nelle opzioni del
                # desktop.
                topics.append({"topic": "home_assistant", "entities": entities})
            else:
                topics.append({"topic": name})

        if not topics:
            return {}

        # Un topic solo non merita l'involucro del bundle.
        if len(topics) == 1:
            answer = ipc("query", topics[0])
            return {due[0]: answer}

        answer = ipc("query", {"topic": "bundle", "topics": topics})
        if not answer.get("ok"):
            raise DashboardDown(answer.get("error", "bundle rifiutato"))

        out = {}
        back = {"top": "top_gpu"}
        for one in answer.get("answers", []):
            name = back.get(one.get("topic"), one.get("topic"))
            out[name] = one
        for lost in answer.get("dropped", []):
            log("topic lasciato indietro: %s (%s)" % (lost.get("topic"), lost.get("why")))
        return out

    def snapshot(self):
        """Tutto quello che si sa adesso, per un telefono appena arrivato."""
        with self.lock:
            return dict(self.cache)

    def forget(self, sources):
        """Dimentica le sorgenti che non guarda piu' nessuno, cosi' un
        telefono che riaccende un modulo riceve un dato fresco invece di uno
        vecchio di mezz'ora."""
        with self.lock:
            for name in list(self.cache):
                if name not in sources:
                    self.cache.pop(name, None)
                    self.last.pop(name, None)


# =============================================================================
# IL SERVER
# =============================================================================

class Client:
    """Un telefono collegato."""

    def __init__(self, conn, address):
        self.conn = conn
        self.address = address
        self.authed = False
        self.modules = set()
        self.metrics = set()
        self.entities = set()
        self.activity = False


class Bridge:
    def __init__(self, config, port=None):
        self.token = str(config.get("token", ""))
        self.port = int(port or config.get("port", DEFAULT_PORT))
        self.require_tls = bool(config.get("require_tls", False))

        self.tls_context, self.fingerprint = build_tls_context()
        if self.require_tls and self.tls_context is None:
            log("`require_tls` e' acceso ma il certificato non c'e': nessun telefono potra' collegarsi")

        self.clients = set()
        self.clients_lock = threading.Lock()
        self.auth_failures = {}
        self.auth_lock = threading.Lock()
        self.collector = Collector(self)
        self.server = None
        self.running = True

    # --- sottoscrizioni ---------------------------------------------------

    def subscriptions(self):
        """Unione dei moduli, delle serie e delle entita' che i client stanno
        guardando."""
        modules = set()
        metrics = set()
        entities = set()
        with self.clients_lock:
            for client in self.clients:
                if client.authed:
                    modules |= client.modules
                    metrics |= client.metrics
                    entities |= client.entities
                    if client.activity:
                        # Chi sorveglia vuole sapere della CPU anche mentre
                        # guarda un'altra pagina: e' tutto il senso della
                        # vista dinamica.
                        modules.add(_ACTIVITY)
        # Chi chiede la serie storica di un'entita' ne vuole anche lo stato
        # di adesso: il grafico e' meta' della risposta.
        for metric in metrics:
            if metric.startswith("ha:"):
                entities.add(metric[3:])
        return modules, metrics, entities

    # --- invio ------------------------------------------------------------

    def send(self, conn, obj):
        try:
            conn.sendall((json.dumps(obj) + "\n").encode("utf-8"))
            return True
        except OSError:
            return False

    def watching_activity(self):
        with self.clients_lock:
            return any(c.authed and c.activity for c in self.clients)

    def broadcast(self, obj, only_authed=True, activity_only=False):
        data = (json.dumps(obj) + "\n").encode("utf-8")
        with self.clients_lock:
            clients = list(self.clients)
        for client in clients:
            if only_authed and not client.authed:
                continue
            if activity_only and not client.activity:
                continue
            try:
                client.conn.sendall(data)
            except OSError:
                self.drop(client)

    def push(self, fresh):
        """Spinge le sorgenti aggiornate, ma a ogni telefono solo quelle che
        quel telefono guarda: due telefoni su sezioni diverse non si scaricano
        a vicenda i dati dell'altro."""
        with self.clients_lock:
            clients = [c for c in self.clients if c.authed]
        for client in clients:
            mine = self.filter_for(client, fresh)
            if not mine:
                continue
            if not self.send(client.conn, {"type": "update", "sources": mine}):
                self.drop(client)

    def metrics_of(self, client):
        """Le serie che questo client disegna: quelle dei suoi moduli piu'
        quelle che ha chiesto per nome (un sensore, un disco, un'entita')."""
        mine = set(client.metrics)
        for name in client.modules:
            found = MODULES.get(name)
            if found is not None:
                mine.update(found[1])
        return mine

    def filter_for(self, client, sources):
        wanted = set()
        for name in client.modules:
            found = MODULES.get(name)
            if found is not None:
                wanted.update(found[0])

        mine = self.metrics_of(client)
        if mine:
            wanted.add("series")

        out = {k: v for k, v in sources.items() if k in wanted}

        # `series` porta l'unione delle metriche di tutti i telefoni
        # collegati, perche' si chiedono alla dashboard in una volta sola.
        # A ciascuno pero' vanno date le sue: un telefono che guarda la CPU
        # non deve ricevere il battito di un altro, e soprattutto non deve
        # ricevere -- appena si collega -- una copia in cache che contiene le
        # serie di qualcun altro e non le proprie. Misurato: uno snapshot con
        # dentro `memory` e non `cpu`, a un client che aveva appena chiesto
        # `cpu`, che disegnava un grafico vuoto per due secondi.
        series = out.get("series")
        if isinstance(series, dict) and isinstance(series.get("series"), dict):
            picked = {k: v for k, v in series["series"].items() if k in mine}
            if not picked:
                out.pop("series", None)
            else:
                out["series"] = dict(series, series=picked)

        return out

    def drop(self, client):
        with self.clients_lock:
            self.clients.discard(client)
        # `conn` e' gia' None quando a chiudere e' stato close(), cioe' dopo
        # un rifiuto dell'autenticazione: il ciclo di lettura passa comunque
        # di qui uscendo, e senza questa guardia il thread muore con una
        # traccia al posto di finire.
        conn = client.conn
        if conn is None:
            return
        try:
            conn.close()
        except OSError:
            pass

    # --- autenticazione ---------------------------------------------------

    def may_try(self, ip):
        now = time.monotonic()
        with self.auth_lock:
            attempts = [t for t in self.auth_failures.get(ip, []) if now - t < AUTH_WINDOW_SECONDS]
            if attempts:
                self.auth_failures[ip] = attempts
            else:
                self.auth_failures.pop(ip, None)
            return len(attempts) < AUTH_MAX_ATTEMPTS

    def record_failure(self, ip):
        with self.auth_lock:
            self.auth_failures.setdefault(ip, []).append(time.monotonic())

    # --- TLS o chiaro sulla stessa porta ----------------------------------

    def wrap_if_tls(self, conn):
        """Riconosce il protocollo dai primi due byte senza consumarli: un
        record TLS comincia con 0x16 0x03, il protocollo in chiaro con la
        graffa di un oggetto JSON. Cosi' la stessa porta serve un'app
        aggiornata e una vecchia durante il passaggio."""
        try:
            conn.settimeout(10)
            head = b""
            for _ in range(5):
                head = conn.recv(2, socket.MSG_PEEK)
                if len(head) >= 2 or not head:
                    break
                time.sleep(0.05)
        except OSError:
            return None

        is_tls = len(head) >= 2 and head[0] == 0x16 and head[1] == 0x03
        if not is_tls:
            if self.require_tls:
                # Non c'e' modo di rispondere cifrato a chi non parla TLS: si
                # avvisa in chiaro e si chiude, cosi' l'app mostra un motivo
                # invece di una connessione caduta senza spiegazioni.
                self.send(conn, {
                    "type": "auth",
                    "ok": False,
                    "reason": "tls_required",
                    "error": "questo ponte accetta solo connessioni cifrate",
                })
                return None
            conn.settimeout(None)
            return conn

        if self.tls_context is None:
            return None
        try:
            conn = self.tls_context.wrap_socket(conn, server_side=True)
        except OSError:
            return None
        conn.settimeout(None)
        return conn

    # --- una connessione --------------------------------------------------

    def serve_client(self, raw, address):
        ip = address[0]
        conn = self.wrap_if_tls(raw)
        if conn is None:
            try:
                raw.close()
            except OSError:
                pass
            return

        client = Client(conn, address)
        with self.clients_lock:
            self.clients.add(client)

        buffer = b""
        try:
            while self.running:
                try:
                    chunk = conn.recv(4096)
                except OSError:
                    break
                if not chunk:
                    break
                buffer += chunk
                while b"\n" in buffer:
                    line, buffer = buffer.split(b"\n", 1)
                    if line.strip():
                        self.handle(client, ip, line)
                        if client.conn is None:
                            return
        finally:
            self.drop(client)

    def handle(self, client, ip, line):
        try:
            message = json.loads(line.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            self.send(client.conn, {"type": "error", "error": "riga non JSON"})
            return

        command = message.get("cmd", "")

        if not client.authed:
            if command != "auth":
                self.send(client.conn, {"type": "auth", "ok": False, "error": "prima l'autenticazione"})
                return
            if not self.may_try(ip):
                self.send(client.conn, {
                    "type": "auth",
                    "ok": False,
                    "reason": "rate_limited",
                    "error": "troppi tentativi: aspetta un minuto",
                })
                self.close(client)
                return
            if not secrets.compare_digest(str(message.get("token", "")), self.token):
                self.record_failure(ip)
                self.send(client.conn, {
                    "type": "auth",
                    "ok": False,
                    "reason": "bad_token",
                    "error": "token sbagliato",
                })
                self.close(client)
                return

            client.authed = True
            log("telefono collegato da %s%s" % (ip, " (cifrato)" if self.tls_context and hasattr(client.conn, "cipher") and client.conn.cipher() else ""))
            self.send(client.conn, {
                "type": "auth",
                "ok": True,
                "modules": sorted(MODULES),
                "scorable": SCORABLE,
                "periods": SOURCE_PERIODS,
                "fingerprint": self.fingerprint,
                "host": socket.gethostname(),
            })
            return

        if command == "subscribe":
            self.subscribe(client, message)
            return

        if command == "ping":
            self.send(client.conn, {"type": "pong"})
            return

        self.send(client.conn, {"type": "error", "error": "comando sconosciuto: %s" % command})

    def subscribe(self, client, message):
        """Il telefono dice cosa sta guardando.

        Le `metrics` in piu' sono quelle che dipendono da una scelta
        dell'utente e che la tabella dei moduli non puo' conoscere: quale
        sensore, quale disco, quale entita' di Home Assistant."""
        modules = [m for m in message.get("modules", []) if m in MODULES]
        unknown = [m for m in message.get("modules", []) if m not in MODULES]
        client.modules = set(modules)
        client.metrics = set(str(m) for m in message.get("metrics", []))
        client.entities = set(str(e) for e in message.get("entities", []))
        client.activity = bool(message.get("activity", False))

        sources = self.collector.wanted()[0]
        self.collector.forget(sources)

        # Quello che si sa gia' parte subito: un grafico deve avere una linea
        # appena si apre, non fra due secondi.
        mine = self.filter_for(client, self.collector.snapshot())
        self.send(client.conn, {
            "type": "snapshot",
            "sources": mine,
            "modules": sorted(client.modules),
            "unknown_modules": unknown,
        })

        # Lo snapshot appena mandato viene dalla cache, e a dashboard spenta
        # e' vecchio di quanto dura il guasto: chi arriva adesso deve saperlo
        # subito, non al prossimo promemoria mezzo minuto piu' in la'.
        report = self.collector.down_report()
        if report is not None:
            self.send(client.conn, report)

        # Chi accende la sorveglianza riceve subito i punteggi che si sanno
        # gia', invece di guardare una vista vuota per due secondi.
        if client.activity:
            self.send(client.conn, {
                "type": "activity",
                "scores": activity_scores(self.collector.snapshot()),
                "at": time.time(),
            })

    def close(self, client):
        try:
            client.conn.close()
        except OSError:
            pass
        client.conn = None
        with self.clients_lock:
            self.clients.discard(client)

    # --- cicli ------------------------------------------------------------

    def collect_forever(self):
        # Il passo del ciclo e' la sorgente piu' frequente: dentro, ognuna
        # scatta quando e' scaduta.
        step = min(SOURCE_PERIODS.values()) / 1000.0
        while self.running:
            try:
                fresh = self.collector.tick()
                if fresh:
                    self.push(fresh)
            except Exception as error:          # noqa: BLE001
                # Un giro andato storto non porta giu' il demone: il telefono
                # si accorgerebbe solo dal silenzio.
                log("giro di raccolta fallito: %s" % error)
            time.sleep(step)

    def run(self):
        self.server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.server.bind((LISTEN_HOST, self.port))
        self.server.listen(8)

        log("in ascolto su %s:%d  token %s  %s" % (
            LISTEN_HOST, self.port, self.token,
            ("TLS %s" % self.fingerprint) if self.tls_context else "in chiaro (openssl mancante)"))

        threading.Thread(target=self.collect_forever, daemon=True).start()

        while self.running:
            try:
                conn, address = self.server.accept()
            except OSError:
                break
            threading.Thread(target=self.serve_client, args=(conn, address), daemon=True).start()

    def stop(self):
        self.running = False
        try:
            self.server.close()
        except (OSError, AttributeError):
            pass


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--port", type=int, default=None, help="porta di ascolto")
    parser.add_argument("--token", action="store_true", help="stampa il token e esce")
    args = parser.parse_args()

    config = load_config()

    if args.token:
        print(config["token"])
        return 0

    bridge = Bridge(config, port=args.port)
    try:
        bridge.run()
    except KeyboardInterrupt:
        bridge.stop()
    return 0


if __name__ == "__main__":
    sys.exit(main())
