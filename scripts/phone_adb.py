#!/usr/bin/env python3
"""ADB verso i telefoni gia' accoppiati con KDE Connect, senza porte a mano.

KDE Connect e ADB sono due canali indipendenti: essere accoppiati per la
clipboard e le notifiche non abilita il debug. Quello che i due condividono e'
l'indirizzo, ed e' il perno di questo file — kdeconnect.py sa che "moto g24" e'
192.168.50.134, e da li' si arriva al resto senza chiedere niente all'utente.

Il resto sarebbero le porte, che su Android 11+ sono il punto dolente: il
debug wireless annuncia due servizi mDNS e ogni volta su una porta diversa,
sorteggiata all'apertura del pannello.

  * `_adb-tls-pairing._tcp`  vive solo finche' resta aperta la finestra
    "Accoppia dispositivo con codice", ed e' quella che vuole il codice a sei
    cifre.

  * `_adb-tls-connect._tcp`  e' il debug wireless vero e proprio, presente
    finche' l'interruttore e' acceso.

`adb mdns services` le troverebbe da solo, ma l'adb dei pacchetti Fedora e'
compilato senza mDNS (risponde "unknown host service 'mdns:services'"), quindi
la scoperta la fa avahi-browse, che il sistema ha gia' acceso per conto suo.
Si legge la stessa rete che leggerebbe adb, solo con un altro programma.

Restano fuori i telefoni piu' vecchi, che di debug wireless non ne hanno: per
quelli la strada e' `adb tcpip 5555` da collegati col cavo, e da li' in poi la
porta e' fissa. `connect` prova comunque la 5555 quando l'annuncio mDNS manca,
cosi' i due casi si comportano allo stesso modo da fuori.

L'accoppiamento invece si fa una volta sola e basta: la chiave sta in
~/.android/adbkey e il telefono la ricorda finche' non gli si revocano le
autorizzazioni. Quello che cambia e' solo la porta, e infatti la porta che ha
funzionato si scrive in ~/.cache/quickshell/phone-adb.json: al riavvio della
dashboard `connect` la prova per prima e di solito entra senza ascoltare
niente. Se non entra si torna all'annuncio, e la cache si riscrive da se'.

Due annunci per lo stesso telefono non sono un errore: quello dell'accensione
precedente resta nella cache di mDNS mentre la sua porta e' gia' morta. Per
questo si provano tutte le porte note invece di sceglierne una — sceglierne
una voleva dire indovinare, e sbagliando si finiva per rifare un pairing che
era gia' a posto.

L'autorizzazione resta sempre e solo sul telefono: la chiave RSA la si conferma
li' la prima volta, e il codice di pairing lo legge l'utente dallo schermo.
Qui non c'e' niente che possa aggirare quel passaggio, ne' che lo voglia.

Guardare lo schermo si puo' in due modi, e sono diversi apposta. `screenshot`
scatta una foto e finisce li'. `live` resta aperto: fotografa a intervalli,
scrive i PNG a turno su due file in XDG_RUNTIME_DIR e legge da stdin i gesti da
fare, che esegue senza ricalcolare ogni volta di che telefono si parla — un
tocco costa cosi' cinque centesimi di secondo invece di un quarto. Il tetto e'
la cattura in se': mezzo secondo, speso sul telefono, che nessuna astuzia da
questa parte del cavo puo' abbreviare.

Quindi non e' un mirroring, e non lo diventera' passando di qui: `screenrecord`
in pipe su ffmpeg non emette un fotogramma finche' la pipe resta aperta, e i
gesti a due dita non esistono affatto — `input` ha un dito solo e scrivere su
/dev/input lo vieta SELinux anche allo shell di adb. Per quello c'e' `mirror`,
che apre scrcpy: un programma a parte, che sul telefono ci mette un pezzo suo.

Oltre a comandare, sa leggere: `screen` restituisce le scritte presenti sullo
schermo con il punto dove toccarle, e `tap-text` prende l'etichetta al posto
delle coordinate. Sono la coppia che serve a un modello per lavorare senza
indovinare pixel — guarda, tocca, riguarda.

`pointer` dice dov'e' il cursore del mouse, che e' l'unica posizione che
Android si ricordi: un dito appoggiato ha delle coordinate finche' sta giu' e
poi non le ha piu', un cursore invece resta dov'e'. Vuole pero' un mouse
collegato, e il mirroring ne monta uno finto apposta.

Sa anche scattare: `photo` comanda MacroCam, l'app headless che sceglie fra
ottica normale e macro, legge il testo con l'OCR e lascia la foto dove adb la
puo' prendere. `aim` apre il mirino sul telefono, che serve la prima volta su
un soggetto nuovo — un macro inquadra pochi centimetri quadrati e a mano si
punta alla cieca — e da li' in poi ogni scatto esce gia' ritagliato sull'area
scelta. `camera` invece guarda e basta: le lenti come le racconta la HAL,
anche senza l'app installata.

Le letture (`status`, `apps`, `screen`, `pointer`, `camera`) e le azioni (`connect`,
`pair`, `repair`, `forget`, `launch`, `input`, `tap-text`, `open`, `screenshot`,
`photo`, `aim`) stanno in sottocomandi separati per la stessa
ragione per cui kdeconnect.py tiene --send dietro un argomento esplicito: il
server MCP espone le due famiglie come due tool distinti, e una domanda non
deve poter toccare il telefono per sbaglio.
"""
import argparse
import json
import os
import re
import select
import shlex
import signal
import struct
import zlib
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

HERE = os.path.dirname(os.path.abspath(__file__))
KDECONNECT = os.path.join(HERE, "kdeconnect.py")

# I percorsi scritti in ~/.config/quickshell/tools.json vincono sul PATH: vedi
# tools.py. Serve soprattutto ad `adb`, che su Fedora e' compilato senza mDNS.
import tools  # noqa: E402  (dopo HERE, che e' cio' che lo rende importabile)

ADB = tools.which("adb")
AVAHI = tools.which("avahi-browse")
SCRCPY = tools.which("scrcpy")

TIMEOUT = 20

PAIRING = "_adb-tls-pairing._tcp"
CONNECT = "_adb-tls-connect._tcp"

# Porta del debug wireless "vecchio stile", quello aperto con `adb tcpip`.
# Fissa per definizione: e' il numero che si scrive a mano da sempre.
LEGACY_PORT = 5555

# Dove si ricorda la porta del debug wireless fra un avvio e l'altro. E'
# cache e non configurazione: se il file sparisce non si perde niente che mDNS
# non sappia ritrovare, ci si rimette solo l'attesa dell'ascolto.
CACHE = os.path.join(
    os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache"),
    "quickshell",
    "phone-adb.json",
)

# Dove la sessione `live` posa i frame: tmpfs, come XDG_RUNTIME_DIR e' fatto
# per essere. Due immagini al secondo su disco vero sarebbero scritture inutili
# di roba che non serve fra un secondo.
LIVE_DIR = os.path.join(
    os.environ.get("XDG_RUNTIME_DIR") or "/run/user/%d" % os.getuid(),
    "quickshell-phone",
)

NO_ADB = "adb non e' installato (pacchetto android-tools)"
NO_AVAHI = (
    "avahi-browse non e' installato: senza mDNS le porte del debug wireless "
    "vanno lette a mano dal telefono"
)

NO_SCRCPY = (
    "scrcpy non e' installato: `sudo dnf install scrcpy` (e' nei repo, versione "
    "4.0). E' l'unico modo di avere lo schermo in tempo reale e i gesti a due "
    "dita — via adb non esistono, e questo file non puo' inventarli"
)


def adb(*args, binary=False, timeout=TIMEOUT):
    """Una chiamata ad adb: (riuscita, output, errore).

    L'output torna in byte quando serve (screencap), altrimenti gia' decodificato.
    adb ha il vizio di uscire con 0 stampando "error:" su stdout, quindi il
    codice di uscita da solo non basta a chi chiama.
    """
    if not ADB:
        return False, b"" if binary else "", NO_ADB

    try:
        done = subprocess.run(
            [ADB] + [str(a) for a in args],
            capture_output=True,
            text=not binary,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        return False, b"" if binary else "", f"adb {args[0]} non ha risposto entro {timeout}s"
    except OSError as exc:
        return False, b"" if binary else "", str(exc)

    err = done.stderr if not binary else done.stderr.decode("utf-8", "replace")
    return done.returncode == 0, done.stdout, err.strip()


def browse(*services, seconds=2.5):
    """I servizi mDNS visti in una finestra di ascolto: {tipo: [{"ip", "port"}]}.

    Si ascolta per qualche secondo invece di usare `-t`, che chiude appena
    l'annuncio e' arrivato ma prima che la risoluzione sia tornata: con `-t` la
    porta del debug wireless compariva a giorni alterni, e un `connect` che
    ripiega sulla 5555 quando la porta buona c'era e' un fallimento inventato.

    avahi-browse -p da' righe a campi separati da ';', e quelle che iniziano
    con '=' sono le risolte: interfaccia, protocollo, nome, tipo, dominio,
    host, indirizzo, porta, TXT. Si tengono le IPv4 perche' ogni servizio
    compare due volte, una per protocollo, e adb l'IPv6 link-local non lo
    gradisce.

    I tipi si ascoltano insieme, non uno dopo l'altro: sono due processi che
    aspettano, e aspettare in parallelo costa quanto aspettarne uno.
    """
    found = {service: [] for service in services}

    if not AVAHI:
        return found

    running = {}

    for service in services:
        try:
            running[service] = subprocess.Popen(
                [AVAHI, "-pr", service],
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
            )
        except OSError:
            continue

    if not running:
        return found

    time.sleep(seconds)

    for service, proc in running.items():
        proc.terminate()

        try:
            data = proc.communicate(timeout=3)[0] or ""
        except subprocess.TimeoutExpired:
            proc.kill()
            data = proc.communicate()[0] or ""

        seen = set()

        for line in data.splitlines():
            parts = line.split(";")

            if len(parts) < 9 or parts[0] != "=" or parts[2] != "IPv4":
                continue

            entry = (parts[7], parts[8])

            if entry in seen:
                continue

            seen.add(entry)
            found[service].append({"ip": parts[7], "port": int(parts[8]), "host": parts[6]})

    return found


def load_cache():
    """Le porte gia' viste: {ip: {"name", "port", "paired", "seen"}}.

    Un file illeggibile vale come un file assente: chi legge questa cache ha
    sempre l'annuncio mDNS come alternativa, e far fallire un `connect` per un
    JSON troncato sarebbe peggio del guasto che si vuole evitare.
    """
    try:
        with open(CACHE, encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        return {}

    return data if isinstance(data, dict) else {}


def save_cache(data):
    """Scrive la cache, e se non ci riesce tace.

    Il file si sostituisce invece di riscriverlo sul posto: due finestre che si
    collegano insieme scrivono lo stesso file, e a meta' di una riscrittura
    diretta il secondo lettore troverebbe un JSON tagliato.
    """
    tmp = CACHE + ".tmp"

    try:
        os.makedirs(os.path.dirname(CACHE), exist_ok=True)

        with open(tmp, "w", encoding="utf-8") as handle:
            json.dump(data, handle, ensure_ascii=False)

        os.replace(tmp, CACHE)
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass


def remember(ip, name="", port=0, paired=None):
    """Segna che con questo indirizzo si e' entrati, e su che porta."""
    if not ip:
        return

    data = load_cache()
    entry = data.get(ip)
    entry = dict(entry) if isinstance(entry, dict) else {}

    if name:
        entry["name"] = name

    if port:
        entry["port"] = int(port)

    if paired is not None:
        entry["paired"] = bool(paired)

    entry["seen"] = int(time.time())
    data[ip] = entry
    save_cache(data)


def forget(target=""):
    """Toglie dalla cache un telefono, o tutti quando target e' vuoto."""
    data = load_cache()

    if not target:
        save_cache({})
        return sorted(data)

    needle = target.lower()
    flat = flatten(target)
    gone = [
        ip for ip, entry in data.items()
        if needle == ip.lower()
        or needle in ((entry or {}).get("name") or "").lower()
        or (flat and flat in flatten((entry or {}).get("name")))
    ]

    for ip in gone:
        data.pop(ip, None)

    if gone:
        save_cache(data)

    return gone


def order_ports(ports, first=0):
    """Le porte in ordine di probabilita', senza ripetizioni.

    In testa quella che ha funzionato l'ultima volta, quando c'e' ancora: se il
    telefono non ha riacceso il debug wireless e' ancora buona, e provarla per
    prima e' la differenza fra un tentativo e tre.
    """
    out = [int(first)] if first and int(first) in ports else []

    for port in ports:
        if port not in out:
            out.append(int(port))

    return out


def paired_phones():
    """I telefoni di KDE Connect, per dare un nome agli indirizzi."""
    try:
        done = subprocess.run(
            [sys.executable, KDECONNECT],
            capture_output=True,
            text=True,
            timeout=TIMEOUT,
        )
        data = json.loads(done.stdout)
    except (OSError, subprocess.SubprocessError, ValueError):
        return []

    if not data.get("ok"):
        return []

    return [d for d in data.get("devices", []) if d.get("paired")]


# Un solo tentativo di riconnessione per esecuzione: se il device resta
# offline il motivo e' altrove — cavo, porta, telefono — e ripetere il comando
# a ogni lettura di stato non lo cambia.
_reconnected = False


def read_devices():
    """Righe di `adb devices`, gia' spacchettate in {serial: stato}."""
    ok, out, _ = adb("devices")

    if not ok:
        return {}

    return {
        parts[0]: parts[1]
        for parts in (line.split() for line in (out or "").splitlines()[1:])
        if len(parts) >= 2
    }


def attached():
    """I device che adb ha adesso: {serial: stato}.

    Lo stato conta quanto il serial. `unauthorized` vuol dire che il telefono
    e' li' ma la finestra della chiave RSA non e' stata confermata. `offline`
    e' peggio e piu' insidioso: adb lo elenca, il telefono e' attaccato, ma la
    sessione e' morta — i comandi partono e le risposte tornano tronche, che e'
    il modo in cui uno screenshot arriva mezzo. `adb reconnect` la rifa', ed e'
    talmente il rimedio abituale che vale la pena darlo qui invece di
    aspettare che qualcuno legga un messaggio e lo scriva a mano.
    """
    global _reconnected

    devices = read_devices()

    if not _reconnected and any(state == "offline" for state in devices.values()):
        _reconnected = True
        adb("reconnect", "offline", timeout=15)
        time.sleep(1.5)
        devices = read_devices()

    return devices


def flatten(name):
    """Un nome ridotto all'osso, per confrontarne due che non si scrivono uguale.

    Lo stesso telefono si chiama "moto g(8) plus" per ADB e "moto g8 plus" per
    KDE Connect: due parentesi di differenza bastano a far sembrare scollegato
    un telefono che e' attaccato al cavo. Si confronta cio' che resta togliendo
    tutto quello su cui i due non sono d'accordo.
    """
    return re.sub(r"[^a-z0-9]", "", (name or "").lower())


def model_of(serial):
    """Il modello del telefono, per dare un nome a chi arriva dal cavo.

    Un device USB non ha indirizzo, quindi non si incrocia con KDE Connect
    sull'IP; il modello pero' e' la stessa stringa che KDE Connect mostra come
    nome ("moto g24"), e quando combacia le due voci sono lo stesso telefono.
    """
    ok, out, _ = adb("-s", serial, "shell", "getprop", "ro.product.model", timeout=10)

    return (out or "").strip() if ok else ""


def hw_serial(serial):
    """Il numero di fabbrica, che e' lo stesso sul cavo e sul wi-fi.

    Il serial adb non lo e': e' «ip:porta» quando si passa dalla rete e il
    numero vero quando si passa dal cavo, cosi' lo stesso apparecchio collegato
    in tutti e due i modi compare due volte e non si somiglia. Il modello non
    basta a riconciliarli — due telefoni uguali in casa lo hanno identico —
    mentre questo e' unico per apparecchio.
    """
    ok, out, _ = adb("-s", serial, "shell", "getprop", "ro.serialno", timeout=10)

    return (out or "").strip() if ok else ""


def fold_transports(out):
    """Lo stesso telefono visto da due strade torna a essere una voce sola.

    Senza questo, un apparecchio con il cavo attaccato e il debug wireless
    acceso conta per due, e `pick` si ferma a chiedere quale dei due si
    intendeva: una domanda a cui non c'e' risposta, perche' sono lo stesso.

    Si paga un getprop per apparecchio, e solo quando ce n'e' piu' d'uno
    collegato: con uno solo non c'e' niente da fondere e niente da chiedere.
    """
    live = [d for d in out if d["connected"]]

    if len(live) < 2:
        return out

    groups = {}

    for device in live:
        hw = hw_serial(device["serial"])

        if hw:
            groups.setdefault(hw, []).append(device)

    dropped = []

    for group in groups.values():
        if len(group) < 2:
            continue

        # Chi ha un'identita' KDE Connect porta con se' nome, indirizzo e
        # porte, e quindi e' la voce che resta; il cavo pero' e' il trasporto
        # migliore quando c'e'. Le due cose possono venire da voci diverse.
        keep = next((d for d in group if d["id"]), group[0])
        best = next((d for d in group if d["via"] == "usb"), keep)

        # Le due strade si annotano prima di toccare qualsiasi cosa: `keep` sta
        # dentro `group`, e riletto dopo racconterebbe due volte il trasporto
        # che ha appena adottato. L'altra non sparisce, smette solo di essere
        # un altro telefono — chi cercava per il serial wireless lo ritrova.
        keep["transports"] = [{"via": d["via"], "serial": d["serial"]} for d in group]

        keep["serial"] = best["serial"]
        keep["adb"] = best["adb"]
        keep["via"] = best["via"]
        keep["name"] = keep["name"] or next((d["name"] for d in group if d["name"]), "")

        dropped += [d for d in group if d is not keep]

    return [d for d in out if not any(d is gone for gone in dropped)]


def devices_view(discover=True):
    """Lo stato completo: telefoni noti, annunci mDNS e device adb, uniti.

    `discover` accende l'ascolto mDNS, che costa due secondi e mezzo di attesa
    e serve solo a chi deve ancora entrare: per toccare un pulsante su un
    telefono gia' collegato sono due secondi e mezzo buttati, e sono la
    differenza fra un comando che rientra nel timeout di chi lo ha chiesto e
    uno che se lo mangia tutto.

    L'unione avviene sull'indirizzo, che e' l'unica cosa che i tre elenchi
    hanno in comune. Un device adb collegato col cavo non ha indirizzo, quindi
    resta una voce a se': ha un serial vero e non serve incrociarlo con niente.
    """
    phones = paired_phones()
    seen = browse(CONNECT, PAIRING) if discover else {CONNECT: [], PAIRING: []}
    known = load_cache()

    # Tutte le porte annunciate per ogni indirizzo, non l'ultima vista. Un
    # telefono ne annuncia una sola per accensione, ma quella dell'accensione
    # precedente resta nella cache di mDNS finche' non scade: tenerne una e
    # buttare l'altra vuol dire tirare a sorte fra la porta viva e una morta.
    announced = {}
    pairing = {}

    for entry in seen[CONNECT]:
        announced.setdefault(entry["ip"], []).append(entry["port"])

    for entry in seen[PAIRING]:
        pairing.setdefault(entry["ip"], []).append(entry["port"])

    live = attached()

    # serial adb -> ip, per le connessioni wireless (il serial e' "ip:porta")
    by_ip = {}
    by_model = {}

    for serial, state in live.items():
        if ":" in serial:
            by_ip.setdefault(serial.rsplit(":", 1)[0], serial)
        elif state == "device":
            model = model_of(serial)

            if model:
                by_model.setdefault(flatten(model), serial)

    out = []
    claimed = set()

    for phone in phones:
        addresses = phone.get("addresses") or []
        ip = addresses[0] if addresses else ""
        serial = by_ip.get(ip, "") or by_model.get(flatten(phone.get("name", "")), "")
        remembered = known.get(ip) or {}
        ports = order_ports(announced.get(ip, []), remembered.get("port") or 0)

        if serial:
            claimed.add(serial)

        out.append({
            "name": phone.get("name", ""),
            "id": phone.get("id", ""),
            "ip": ip,
            "serial": serial,
            "adb": live.get(serial, "") if serial else "",
            "connected": bool(serial) and live.get(serial) == "device",
            "via": ("usb" if serial and ":" not in serial else "wireless") if serial else "",
            # Le porte annunciate adesso, piu' quella che ha funzionato
            # l'ultima volta: la prima cambia a ogni accensione del debug
            # wireless, la seconda e' un ricordo che vale finche' non si
            # riaccende, e insieme evitano di dover chiedere niente all'utente.
            "wireless_debugging": ip in announced,
            "wireless_ports": ports,
            "wireless_port": ports[0] if ports else 0,
            "known_port": int(remembered.get("port") or 0),
            "paired": bool(remembered.get("paired")),
            "pairing_open": ip in pairing,
        })

    # Quello che adb vede ma KDE Connect no: cavo USB, o un telefono non
    # accoppiato per la clipboard. Non e' un errore, e' solo un'altra strada.
    for serial, state in live.items():
        if serial in claimed:
            continue

        out.append({
            "name": model_of(serial) if state == "device" and ":" not in serial else "",
            "id": "",
            "ip": serial.rsplit(":", 1)[0] if ":" in serial else "",
            "serial": serial,
            "adb": state,
            "connected": state == "device",
            "wireless_debugging": False,
            "wireless_ports": [],
            "wireless_port": 0,
            "known_port": 0,
            "paired": False,
            "pairing_open": False,
            "via": "usb" if ":" not in serial else "wireless",
        })

    return fold_transports(out)


def matching(view, target):
    """I device che rispondono a quel nome, indirizzo o serial.

    Separata da `pick` perche' non tutti i comandi vogliono la stessa cosa:
    `pick` cerca un telefono su cui agire e quindi scarta chi non e' collegato,
    mentre `repair` cerca proprio quello — un telefono che c'e' ma non risponde
    piu' e' esattamente il caso da rimettere in piedi.
    """
    needle = target.lower()
    flat = flatten(target)

    return [
        d for d in view
        if needle in (d["name"] or "").lower()
        or (flat and flat in flatten(d["name"]))
        or needle == d["ip"]
        or needle == d["serial"].lower()
        or needle == d["id"].lower()
        or any(needle == t["serial"].lower() for t in d.get("transports", []))
    ]


def pick(view, target):
    """Il device su cui agire, scelto per nome, indirizzo o serial.

    Senza target va bene solo se ce n'e' uno connesso: agire "sul telefono"
    quando ce ne sono tre in casa e' il genere di ambiguita' che va risolta
    dicendolo, non tirando a indovinare.
    """
    connected = [d for d in view if d["connected"]]

    if not target:
        if len(connected) == 1:
            return connected[0], ""

        if not connected:
            return None, (
                "nessun telefono collegato ad adb: apri il debug wireless sul "
                "telefono e lancia `connect`, oppure collega il cavo"
            )

        names = ", ".join(d["name"] or d["serial"] for d in connected)
        return None, f"piu' di un telefono collegato ({names}): indica quale con --device"

    hits = matching(view, target)

    if not hits:
        return None, f"nessun telefono corrisponde a «{target}»"

    ready = [d for d in hits if d["connected"]]

    if not ready:
        state = hits[0]["adb"] or "non collegato ad adb"
        return None, f"«{target}» c'e' ma non e' utilizzabile: {state}"

    return ready[0], ""


# ------------------------------------------------------------------ azioni


def connect_reply(results, note=""):
    """La risposta di un `connect`, con quello che resta da fare sul telefono.

    La chiave RSA si conferma sul telefono, e finche' non lo si fa il device
    resta "unauthorized": dirlo qui evita di far cercare il guasto altrove.
    """
    unauthorized = [s for s, state in read_devices().items() if state == "unauthorized"]

    return {
        "ok": any(r["ok"] for r in results),
        "results": results,
        "unauthorized": unauthorized,
        "note": note or (
            "conferma la richiesta «Consentire il debug USB?» sullo schermo del "
            "telefono" if unauthorized else ""
        ),
    }


def connect_known(target=""):
    """Il tentativo con le porte gia' ricordate, senza mDNS ne' KDE Connect.

    E' la strada di chi riavvia la dashboard a telefono acceso: la porta e'
    ancora quella di prima, e provarla costa un `adb connect` invece dei due
    secondi e mezzo di ascolto piu' l'interrogazione di KDE Connect.

    Torna qualcosa solo se qualcuno e' entrato. Un fallimento qui non e' una
    risposta da dare a chi ha chiesto `connect` — e' solo il segnale che tocca
    cercare l'annuncio.
    """
    known = load_cache()

    if not known:
        return None

    needle = target.lower() if target else ""
    flat = flatten(target)
    live = read_devices()
    joined = []

    for ip, entry in known.items():
        entry = entry or {}
        port = int(entry.get("port") or 0)
        name = entry.get("name") or ""

        if not port:
            continue

        if needle and needle != ip.lower() and needle not in name.lower() \
                and not (flat and flat in flatten(name)):
            continue

        serial = f"{ip}:{port}"

        if live.get(serial) == "device":
            continue

        ok, out, _ = adb("connect", serial, timeout=8)
        text = (out or "").strip()

        if ok and "connected to" in text:
            remember(ip, name, port, paired=True)
            joined.append({
                "name": name,
                "ip": ip,
                "ok": True,
                "serial": serial,
                "note": text,
            })

    if not joined:
        return None

    return connect_reply(joined, "collegato sulla porta gia' nota, senza cercare l'annuncio")


def do_connect(target="", fast=True):
    """Collega ad adb i telefoni raggiungibili, senza scrivere porte.

    Due strade, in quest'ordine. La prima e' la porta ricordata dall'ultima
    volta, che non costa attesa; la seconda e' quella di sempre — guardare chi
    annuncia il debug wireless — e scatta solo se la prima non ha collegato
    niente.

    Le porte da provare sono tutte quelle note: la ricordata, quelle annunciate
    adesso (possono essere piu' d'una, perche' l'annuncio di un'accensione
    precedente resta in giro) e infine la 5555 di `adb tcpip`. Un telefono ne ha
    una sola buona, e quale sia non si sa prima di provarla.
    """
    if fast:
        quick = connect_known(target)

        if quick:
            return quick

    view = devices_view()

    wanted = []
    needle = target.lower() if target else ""

    for device in view:
        if not device["ip"] or device["connected"]:
            continue

        if needle and needle not in (device["name"] or "").lower() and needle != device["ip"]:
            continue

        wanted.append(device)

    if not wanted:
        already = [d["name"] or d["serial"] for d in view if d["connected"]]

        return {
            "ok": bool(already),
            "connected": already,
            "note": (
                "gia' collegati, niente da fare" if already else
                "nessun telefono da collegare: accendi il debug wireless "
                "(Opzioni sviluppatore) o collega il cavo USB"
            ),
        }

    results = []

    for device in wanted:
        ip = device["ip"]
        ports = order_ports(
            list(device["wireless_ports"]) + [LEGACY_PORT],
            device["known_port"],
        )

        outcome = {"name": device["name"], "ip": ip, "ok": False, "error": ""}
        # Ogni tentativo con la sua porta: la 5555 rifiutata dice solo che il
        # telefono e' moderno, ed e' l'errore sulla porta annunciata quello che
        # spiega davvero perche' non entra.
        attempts = []

        for port in ports:
            ok, out, err = adb("connect", f"{ip}:{port}", timeout=12)
            text = (out or "").strip()

            # adb esce con 0 anche quando fallisce, e la differenza sta nella
            # frase: "connected to" o "already connected to" contro "failed to
            # connect" e "Connection refused".
            if ok and ("connected to" in text):
                outcome.update({"ok": True, "serial": f"{ip}:{port}", "note": text})
                # Da qui in poi questa porta si prova per prima, e se e' ancora
                # buona al prossimo avvio non si ascolta piu' niente.
                remember(ip, device["name"], port, paired=True)
                break

            attempts.append({"port": port, "error": text or err})

        if not outcome["ok"]:
            outcome["attempts"] = attempts
            outcome["error"] = attempts[0]["error"] if attempts else ""

            refused = any("refused" in (a["error"] or "").lower() for a in attempts)

            # Porta chiusa e porta che rifiuta l'accoppiamento sono due guasti
            # diversi e vogliono due rimedi diversi. Un telefono che dorme
            # continua ad annunciare il servizio — l'annuncio resta nella cache
            # di mDNS mentre adbd ha gia' smesso di ascoltare — e dirgli di
            # rifare il pairing manderebbe a rifare una cosa gia' fatta.
            #
            # Lo stesso vale per chi ha gia' un accoppiamento riuscito alle
            # spalle: il pairing non scade da solo, e mandarlo a rifare e' il
            # consiglio che fa credere che vada rifatto a ogni avvio.
            outcome["hint"] = (
                "il telefono annuncia il debug wireless ma non risponde su "
                "quella porta: di solito sta dormendo, quindi accendigli lo "
                "schermo e riprova. Se insiste, spegni e riaccendi Debug "
                "wireless — la porta cambia a ogni riaccensione"
            ) if (device["wireless_debugging"] and refused) else (
                "il debug wireless e' acceso ma la connessione viene "
                "rifiutata: questo PC non e' accoppiato con quel telefono — "
                "apri «Accoppia dispositivo con codice» e lancia `pair <codice>`"
            ) if device["wireless_debugging"] else (
                "questo PC e' gia' accoppiato con quel telefono e il pairing "
                "non va rifatto: il telefono non sta annunciando il debug "
                "wireless, quindi accendigli lo schermo e controlla che Debug "
                "wireless sia ancora acceso. Se invece e' il telefono ad aver "
                "dimenticato questo PC (Debug wireless -> Dispositivi "
                "accoppiati), lancia `repair` e riaccoppia col codice"
            ) if device["paired"] else (
                "il telefono non annuncia il debug wireless: accendilo in "
                "Opzioni sviluppatore → Debug wireless, poi rifai `pair` se "
                "e' la prima volta"
            )

        results.append(outcome)

    return connect_reply(results)


def do_forget(target=""):
    """Dimentica le porte salvate, tutte o quelle di un telefono.

    Serve quando si cambia rete o telefono e la porta ricordata punta a
    qualcosa che non esiste piu': la cache si corregge anche da sola al primo
    tentativo fallito, ma poterla svuotare a mano evita di doverlo indovinare.
    """
    gone = forget(target)

    if target and not gone:
        return {"ok": False, "error": f"nessuna porta salvata per «{target}»"}

    return {
        "ok": True,
        "forgotten": gone,
        "note": (
            "il prossimo `connect` ripartira' dall'annuncio mDNS" if gone
            else "non c'era niente da dimenticare"
        ),
    }


def do_repair(target=""):
    """Rimette in gioco un telefono che ha tolto l'autorizzazione.

    L'autorizzazione la toglie il telefono, e lo fa in due modi che si
    somigliano solo nel risultato. Con «Revoca autorizzazioni debug USB» sparisce
    la chiave RSA: adb continua a elencarlo, ma come `unauthorized`, e il rimedio
    e' far ricomparire la richiesta sullo schermo — l'accoppiamento wireless non
    c'entra e rifarlo non servirebbe a niente. Con «Debug wireless → Dispositivi
    accoppiati → dimentica» sparisce invece l'accoppiamento, e li' l'unica strada
    e' il codice a sei cifre; ma la cache di qui continua a dire `paired`, e
    finche' lo dice ogni consiglio che ne discende — a partire da «il pairing non
    va rifatto» — manda a cercare il guasto dalla parte sbagliata.

    Quale dei due sia lo dice adb, quindi lo si guarda invece di chiederlo. La
    risposta porta con se' lo stato fresco del telefono: chi l'ha chiesta ha
    appena pagato l'ascolto mDNS, e fargli incatenare uno `status` vorrebbe dire
    farglielo pagare due volte.
    """
    view = devices_view()

    if target:
        hits = matching(view, target)

        if not hits:
            return {"ok": False, "error": f"nessun telefono corrisponde a «{target}»"}
    else:
        hits = view

        if not hits:
            return {"ok": False, "error": "nessun telefono da rimettere in piedi"}

        if len(hits) > 1:
            names = ", ".join(d["name"] or d["ip"] or d["serial"] for d in hits)
            return {
                "ok": False,
                "error": f"piu' di un telefono ({names}): indica quale con --device",
            }

    device = hits[0]
    state = {
        "name": device["name"],
        "ip": device["ip"],
        "serial": device["serial"],
        "adb": device["adb"],
        "paired": device["paired"],
        "pairing_open": device["pairing_open"],
    }

    # La chiave RSA: il telefono e' li' e adb lo vede, manca solo il consenso.
    # Staccare e riattaccare la sessione e' quello che fa ricomparire la
    # finestra, che altrimenti non torna da sola.
    if device["adb"] == "unauthorized":
        serial = device["serial"]

        if ":" in serial:
            adb("disconnect", serial, timeout=10)
            adb("connect", serial, timeout=12)
        else:
            adb("reconnect", serial, timeout=15)

        time.sleep(1.5)
        state["adb"] = read_devices().get(serial, "")

        return dict(state, ok=True, step="authorize", note=(
            "conferma la richiesta «Consentire il debug USB?» sullo schermo del "
            "telefono, e spunta «Consenti sempre da questo computer»"
        ))

    # L'indirizzo puo' mancare: KDE Connect lo pubblica solo mentre il telefono
    # risponde, e un telefono da riaccoppiare e' proprio un telefono che non
    # risponde. Quello con cui si e' entrati l'ultima volta e' nella cache, ed
    # e' il migliore che ci sia — l'unica alternativa sarebbe chiederlo.
    ip = device["ip"]

    if not ip:
        flat = flatten(device["name"])

        for known, entry in load_cache().items():
            if flat and flat == flatten((entry or {}).get("name")):
                ip = known
                break

        state["ip"] = ip

    # Senza indirizzo non c'e' niente da riaccoppiare: e' un telefono che vive
    # solo sul cavo, e sul cavo l'autorizzazione e' la chiave RSA di sopra.
    if not ip:
        return {
            "ok": False,
            "error": "questo telefono non ha un indirizzo: non c'e' nessun "
                     "accoppiamento wireless da rifare",
            "hint": "col cavo l'autorizzazione e' la richiesta della chiave RSA: "
                    "staccalo e riattaccalo per farla ricomparire",
        }

    # Il flag e basta: nome e porta restano. La porta ricordata e' ancora il
    # primo tentativo piu' probabile dopo il nuovo accoppiamento, e buttarla via
    # — cosa che farebbe `forget` — vorrebbe dire tornare a pagare l'ascolto
    # mDNS per un dato che non era sbagliato.
    remember(ip, device["name"], paired=False)
    state["paired"] = False

    return dict(state, ok=True, step="code", note=(
        "il telefono sta chiedendo il codice: digita le sei cifre che mostra"
        if device["pairing_open"] else
        "sul telefono: Opzioni sviluppatore → Debug wireless → «Accoppia "
        "dispositivo con codice di accoppiamento», poi digita qui le sei cifre"
    ), hint="" if AVAHI else NO_AVAHI)


def do_pair(code, target=""):
    """Accoppia col codice a sei cifre, trovando da solo host e porta.

    La porta di pairing e' sorteggiata quando si apre la finestra sul telefono
    e sparisce quando la si chiude, quindi non c'e' niente da ricordare fra una
    volta e l'altra: si guarda chi la sta annunciando adesso.
    """
    code = str(code).strip()

    if not code.isdigit() or len(code) != 6:
        return {"ok": False, "error": "il codice di pairing e' di sei cifre"}

    offers = browse(PAIRING)[PAIRING]

    if target:
        needle = target.lower()
        named = {
            (d["addresses"] or [""])[0]: d.get("name", "")
            for d in paired_phones()
        }
        offers = [
            o for o in offers
            if needle == o["ip"] or needle in named.get(o["ip"], "").lower()
        ]

    if not offers:
        return {
            "ok": False,
            "error": "nessun telefono sta chiedendo di essere accoppiato",
            "hint": (
                "sul telefono: Opzioni sviluppatore → Debug wireless → "
                "«Accoppia dispositivo con codice di accoppiamento», e tieni "
                "aperta quella schermata mentre lanci questo comando col "
                "codice che mostra"
            ) if AVAHI else NO_AVAHI,
        }

    if len(offers) > 1:
        return {
            "ok": False,
            "error": "piu' telefoni stanno chiedendo di essere accoppiati",
            "candidates": [f"{o['ip']}:{o['port']}" for o in offers],
            "hint": "indica quale con --device (nome o indirizzo)",
        }

    offer = offers[0]
    ok, out, err = adb("pair", f"{offer['ip']}:{offer['port']}", code, timeout=30)
    text = (out or "").strip()

    if not ok or "Successfully paired" not in text:
        return {
            "ok": False,
            "target": f"{offer['ip']}:{offer['port']}",
            "error": text or err or "pairing rifiutato",
            "hint": "il codice cambia a ogni apertura della finestra: rileggilo e riprova",
        }

    # Il pairing non scade: da qui in poi il telefono conosce questo PC, e
    # segnarlo evita che un connect fallito per altri motivi mandi a rifarlo.
    remember(offer["ip"], paired=True)

    # Chiuso il pairing, il telefono comincia ad annunciare il servizio di
    # connessione: ci mette un istante, quindi vale la pena riprovare invece di
    # far ripetere il comando a mano.
    connected = {}

    for _ in range(5):
        connected = do_connect(offer["ip"])

        if connected.get("ok"):
            break

        time.sleep(1.5)

    return {"ok": True, "paired": f"{offer['ip']}:{offer['port']}", "connect": connected}


def do_disconnect(target=""):
    """Stacca la connessione wireless, lasciando intatto l'accoppiamento."""
    view = devices_view(discover=False)

    if target:
        device, why = pick(view, target)

        if not device:
            return {"ok": False, "error": why}

        serials = [device["serial"]]
    else:
        serials = [d["serial"] for d in view if d["connected"] and ":" in d["serial"]]

    if not serials:
        return {"ok": True, "note": "nessuna connessione wireless da staccare"}

    done = []

    for serial in serials:
        ok, out, err = adb("disconnect", serial, timeout=10)
        done.append({"serial": serial, "ok": ok, "note": (out or err or "").strip()})

    return {"ok": True, "disconnected": done}


def shell(device, *args, binary=False, timeout=TIMEOUT):
    """Un comando sul telefono scelto, sempre con -s esplicito.

    Senza -s adb sceglie da solo quando c'e' un device unico e fallisce quando
    ce ne sono due, il che vuol dire che lo stesso comando si comporta in modo
    diverso a seconda di cosa c'e' attaccato in quel momento.
    """
    return adb("-s", device["serial"], *args, binary=binary, timeout=timeout)


def do_apps(target="", query="", system=False):
    """I pacchetti installati, di terze parti salvo richiesta contraria."""
    view = devices_view(discover=False)
    device, why = pick(view, target)

    if not device:
        return {"ok": False, "error": why}

    args = ["shell", "pm", "list", "packages"]

    if not system:
        args.append("-3")

    ok, out, err = shell(device, *args)

    if not ok:
        return {"ok": False, "error": err or "pm non ha risposto"}

    packages = sorted(
        line[len("package:"):].strip()
        for line in (out or "").splitlines()
        if line.startswith("package:")
    )

    if query:
        needle = query.lower()
        packages = [p for p in packages if needle in p.lower()]

    return {
        "ok": True,
        "device": device["name"] or device["serial"],
        "count": len(packages),
        "packages": packages,
    }


def do_launch(package, target="", activity=""):
    """Avvia un'app.

    Con la sola activity principale si userebbe `am start -n pkg/activity`, ma
    il nome dell'activity va saputo; `monkey` con la categoria LAUNCHER apre
    quella che aprirebbe un tocco sull'icona, che e' cio' che si intende per
    "fai partire l'app".
    """
    view = devices_view(discover=False)
    device, why = pick(view, target)

    if not device:
        return {"ok": False, "error": why}

    if activity:
        args = ["shell", "am", "start", "-n", f"{package}/{activity}"]
    else:
        args = [
            "shell", "monkey", "-p", package,
            "-c", "android.intent.category.LAUNCHER", "1",
        ]

    ok, out, err = shell(device, *args)
    text = (out or "").strip()

    # monkey riporta il fallimento nel testo ("No activities found"), am con
    # "Error:". Nessuno dei due si degna di uscire diverso da zero.
    failed = "No activities found" in text or "Error:" in text or "Exception" in text

    if failed:
        return {
            "ok": False,
            "device": device["name"] or device["serial"],
            "package": package,
            "error": (
                f"«{package}» non e' installata, o non ha un'icona da cui partire "
                "(cerca il nome esatto con `apps`)"
            ),
        }

    # Di monkey non si riporta l'eco degli argomenti e il conto dei pacchetti
    # di rete: chi chiede di aprire un'app vuole sapere se si e' aperta.
    return {
        "ok": ok,
        "device": device["name"] or device["serial"],
        "package": package,
        "error": "" if ok else (err or text or "avvio fallito"),
    }


def do_open(url, target=""):
    """Apre un indirizzo (o un intent VIEW) sul telefono."""
    view = devices_view(discover=False)
    device, why = pick(view, target)

    if not device:
        return {"ok": False, "error": why}

    ok, out, err = shell(
        device, "shell", "am", "start",
        "-a", "android.intent.action.VIEW", "-d", url,
    )
    text = (out or "").strip()

    return {
        "ok": ok and "Error:" not in text,
        "device": device["name"] or device["serial"],
        "url": url,
        "output": text or err,
    }


def input_args(action, values):
    """Gli argomenti di `input` per un gesto, o la ragione per cui non ce ne sono.

    Sta fuori da do_input perche' la sessione `live` manda gli stessi gesti
    senza rifare il giro di devices_view — che vuol dire interrogare KDE
    Connect, un quinto di secondo per un tocco che ne costa cinque centesimi.
    La traduzione e' la stessa, il contorno no.
    """
    values = [str(v) for v in values]

    if action == "text":
        text = " ".join(values)

        if not text:
            return None, "nessun testo da scrivere"

        # Due accorgimenti, per due guai diversi. `input text` prende un
        # argomento solo e degli spazi non sa che fare: la sequenza %s e' il
        # modo con cui Android li scrive.
        #
        # E soprattutto gli apici: `adb shell` non passa gli argomenti al
        # telefono uno per uno, li riattacca in una riga che di la' viene letta
        # da una shell. Senza quotare, un punto e virgola in mezzo a una frase
        # sarebbe un comando eseguito sul telefono — provato con `adb shell
        # echo "a;pwd"`, che stampa "a" e poi "/". Con una tastiera collegata
        # basterebbe digitare una & per finirci dentro senza volerlo.
        return ["shell", "input", "text", shlex.quote(text.replace(" ", "%s"))], ""

    if action == "key":
        key = values[0] if values else ""

        if not key:
            return None, "key vuole il nome di un tasto"

        if not key.isdigit() and not key.upper().startswith("KEYCODE_"):
            key = "KEYCODE_" + key.upper()

        return ["shell", "input", "keyevent", key], ""

    if action in ("tap", "swipe"):
        if not values or not all(v.lstrip("-").isdigit() for v in values):
            return None, f"{action} vuole coordinate in pixel"

        if action == "tap" and len(values) != 2:
            return None, "tap vuole due coordinate: X Y"

        if action == "swipe" and len(values) not in (4, 5):
            return None, "swipe vuole X1 Y1 X2 Y2 [durata_ms]"

        return ["shell", "input", action] + values, ""

    # Le tre fasi di un dito appoggiato, mosso e sollevato. `input swipe` fa un
    # gesto solo, dritto e a velocita' costante, che Android legge come un
    # lancio; queste tre lasciano che sia la mano a decidere il percorso, ed e'
    # l'unico modo di trascinare davvero qualcosa da qui.
    if action in ("down", "move", "up"):
        if len(values) != 2 or not all(v.lstrip("-").isdigit() for v in values):
            return None, f"{action} vuole due coordinate: X Y"

        return ["shell", "input", "motionevent", action.upper()] + values, ""

    return None, f"azione sconosciuta: {action}"


def do_input(action, values, target="", from_stdin=False):
    """Tocchi, scorrimenti, testo e tasti.

    Il testo puo' arrivare dallo standard input invece che dagli argomenti, e
    per un PIN e' l'unico modo accettabile: la riga di comando di un processo
    la legge chiunque passi di li' con un `ps` mentre gira, e resta scritta nel
    journal di systemd. Su stdin non la vede nessuno.
    """
    view = devices_view(discover=False)
    device, why = pick(view, target)

    if not device:
        return {"ok": False, "error": why}

    if action == "text" and from_stdin:
        values = [sys.stdin.read().rstrip("\n")]

    args, why = input_args(action, values)

    if not args:
        return {"ok": False, "error": why}

    ok, out, err = shell(device, *args)

    return {
        "ok": ok,
        "device": device["name"] or device["serial"],
        "action": action,
        "error": "" if ok else (err or (out or "").strip()),
    }


def locked(device):
    """Se c'e' la schermata di blocco davanti.

    `mIsShowing` del KeyguardStateMonitor e' il campo che lo dice davvero: il
    solo stato dello schermo non basta, perche' acceso e sbloccato sono due
    cose diverse e la sequenza di sblocco parte dalla prima per arrivare alla
    seconda.
    """
    ok, out, _ = shell(device, "shell", "dumpsys", "window", timeout=30)

    if not ok:
        return None

    found = re.search(r"KeyguardStateMonitor[\s\S]{0,200}?mIsShowing=(\w+)", out or "")

    return found.group(1) == "true" if found else None


def awake(device):
    """Se lo schermo e' acceso.

    `mWakefulness` distingue tre stati — Awake, Dozing, Asleep — e solo il
    primo e' uno schermo che mostra qualcosa. Il doze e' quello dell'orologio
    always-on: acceso in senso stretto, ma non c'e' niente da fotografare.
    """
    ok, out, _ = shell(device, "shell", "dumpsys", "power", timeout=30)

    if not ok:
        return None

    found = re.search(r"mWakefulness=(\w+)", out or "")

    return found.group(1) == "Awake" if found else None


def do_display(state="", target=""):
    """Accende o spegne lo schermo, e dice com'e' rimasto.

    Si chiama `display` e non `screen` perche' `screen` in questo file legge
    gia' cosa c'e' scritto sullo schermo: due significati sullo stesso nome, e
    il secondo avrebbe zitto zitto preso il posto del primo.

    Si usano SLEEP e WAKEUP invece di POWER perche' POWER e' un interruttore:
    premuto due volte torna al punto di partenza, e chi chiede "spegni" non
    vuole "cambia stato" — su uno schermo gia' spento lo riaccenderebbe.
    """
    view = devices_view(discover=False)
    device, why = pick(view, target)

    if not device:
        return {"ok": False, "error": why}

    if state in ("on", "off"):
        shell(device, "shell", "input", "keyevent",
              "KEYCODE_WAKEUP" if state == "on" else "KEYCODE_SLEEP", timeout=15)
        time.sleep(0.4)

    lit = awake(device)

    return {
        "ok": True,
        "device": device["name"] or device["serial"],
        "awake": lit,
        # Lo schermo acceso non vuol dire sbloccato, ed e' la domanda che viene
        # subito dopo: si risponde qui invece di far fare un secondo giro.
        "locked": locked(device) if lit else None,
    }


def do_unlock(target="", from_stdin=False):
    """Sveglia, scopre la tastiera e digita il PIN, se ne arriva uno.

    Le tre mosse stanno insieme qui e non nell'interfaccia perche' sono una
    sola intenzione — "sbloccalo" — e perche' il PIN deve attraversare un
    processo solo: farlo passare per tre comandi separati vorrebbe dire tre
    occasioni di lasciarlo in giro.

    Impronta e sequenza a gesti restano fuori portata: la prima e' hardware, la
    seconda si potrebbe disegnare con uno swipe ma basta un pixel storto per
    sbagliarla, e i tentativi falliti su un telefono si pagano cari.
    """
    view = devices_view(discover=False)
    device, why = pick(view, target)

    if not device:
        return {"ok": False, "error": why}

    return unlock_device(device, sys.stdin.read().strip() if from_stdin else "")


def unlock_device(device, pin=""):
    """Lo sblocco vero e proprio, su un telefono gia' scelto.

    Separato da do_unlock perche' anche la sessione `live` sblocca, e li' il
    PIN arriva da una riga di comandi invece che dallo standard input: il
    percorso del segreto cambia, il resto no.
    """
    before = locked(device)

    if before is False:
        return {"ok": True, "device": device["name"] or device["serial"],
                "note": "era gia' sbloccato", "locked": False}

    shell(device, "shell", "input", "keyevent", "KEYCODE_WAKEUP", timeout=15)

    # Lo swipe scopre il campo del PIN. Le coordinate vengono dalla dimensione
    # vera dello schermo: un telefono non e' alto quanto un altro, e un gesto
    # calcolato su misure altrui finisce nel posto sbagliato.
    ok, size, _ = shell(device, "shell", "wm", "size", timeout=15)
    found = re.search(r"(\d+)x(\d+)", size or "")
    width, height = (int(found.group(1)), int(found.group(2))) if found else (1080, 1920)

    shell(device, "shell", "input", "swipe",
          str(width // 2), str(int(height * 0.8)),
          str(width // 2), str(int(height * 0.2)), "300", timeout=15)

    if pin:
        shell(device, "shell", "input", "text", pin, timeout=15)
        shell(device, "shell", "input", "keyevent", "KEYCODE_ENTER", timeout=15)
        # Il keyguard non sparisce nell'istante in cui si preme invio.
        time.sleep(1.2)

    after = locked(device)

    return {
        "ok": after is not True,
        "device": device["name"] or device["serial"],
        "locked": after,
        # Chi non ha dato un PIN non ha sbagliato niente: gli serve, e basta.
        # Distinguere i due casi e' la differenza fra un'istruzione e
        # un'accusa.
        "error": "" if after is not True else (
            "PIN rifiutato, oppure serve l'impronta o la sequenza" if pin else
            "questo telefono ha un blocco: serve il PIN"
        ),
        "needs_pin": after is True and not pin,
    }


# --------------------------------------------------------------- sessione

# Quanto veloce si puo' andare e quanto lento ha senso andare. Il tetto non e'
# una scelta: una cattura costa quasi mezzo secondo sul telefono, e chiederne
# piu' di cinque al secondo vorrebbe dire accodare richieste che arrivano tardi
# comunque.
FPS_MIN = 0.2
FPS_MAX = 5.0

# Dopo tanti errori di fila la sessione si arrende invece di insistere: se il
# telefono si e' staccato, riprovare due volte al secondo non lo riattacca.
LIVE_GIVE_UP = 3

# I gesti che cambiano quello che c'e' sullo schermo, e dopo i quali vale la
# pena guardare subito invece di aspettare il turno. `move` no: durante un
# trascinamento le catture andrebbero a rilento proprio quando la mano si
# muove, ed e' l'unico momento in cui la lentezza si vede.
AFTER_SHOT = {"tap", "swipe", "key", "text", "up", "pin", "shot", "resume"}


def do_live(target="", fps=2.0, out="", paused=False):
    """La sessione interattiva: i frame su stdout, i comandi su stdin.

    Un processo che resta aperto finche' la finestra e' aperta, e che fa due
    cose insieme. Fotografa lo schermo a intervalli regolari, scrivendo il PNG
    a turno su due file e annunciandolo con una riga JSON; e legge da stdin i
    gesti da fare, che esegue con la scorciatoia di `input_args` — senza
    ricalcolare ogni volta di che telefono si parla.

    E' li' che sta il guadagno: lo stesso tocco passato da un processo nuovo
    costa un quarto di secondo di avvio, da qui cinque centesimi. Quello che
    non si puo' togliere e' il mezzo secondo della cattura, che avviene sul
    telefono e non da questa parte del cavo.

    Due nomi di file a turno, non uno nuovo per frame: il lettore ricarica
    l'immagine solo se il nome cambia, e un file nuovo ogni mezzo secondo
    riempirebbe la cartella di roba morta. Ognuno si scrive di fianco e poi si
    sposta al suo posto, cosi' chi guarda non trova mai mezzo PNG.
    """
    view = devices_view(discover=False)
    device, why = pick(view, target)

    if not device:
        return {"ok": False, "error": why}

    folder = os.path.expanduser(out) if out else LIVE_DIR

    try:
        os.makedirs(folder, exist_ok=True)
    except OSError as exc:
        return {"ok": False, "error": str(exc)}

    # Il numero del processo nel nome: due finestre aperte sullo stesso
    # telefono, o due dashboard, sono due sessioni che scrivono nella stessa
    # cartella, e senza questo si sovrascriverebbero i frame a vicenda —
    # peggio, chiudendone una si porterebbero via i file dell'altra.
    slots = [
        os.path.join(folder, "live-%d-%d.png" % (os.getpid(), n))
        for n in (0, 1)
    ]
    state = {
        "slot": 0,
        "frame": 0,
        "interval": 1.0 / min(max(fps, FPS_MIN), FPS_MAX),
        # Si nasce fermi o in movimento a seconda di com'e' l'interruttore
        # dall'altra parte. E' un argomento e non un comando su stdin perche'
        # il primo giro parte prima che chiunque abbia avuto modo di scrivere.
        "paused": paused,
        "misses": 0,
        # La strada veloce (pixel nudi, PNG rifatto qui) finche' funziona: su un
        # telefono che manda i pixel in un formato che non si sa richiudere si
        # torna al PNG del telefono, ma una volta sola, non a ogni frame.
        "raw": True,
    }

    def say(payload):
        print(json.dumps(payload, ensure_ascii=False), flush=True)

    def capture():
        """Uno scatto: sul file di turno, annunciato, o l'errore per cui non c'e'."""
        start = time.monotonic()
        data, error, used_raw = grab(device, timeout=30, raw=state["raw"])

        if state["raw"] and data and not used_raw:
            state["raw"] = False
            say({"event": "state", "raw": False})

        if not data:
            state["misses"] += 1
            say({"event": "miss", "error": error, "misses": state["misses"]})
            return state["misses"] < LIVE_GIVE_UP

        state["misses"] = 0
        state["slot"] ^= 1
        state["frame"] += 1
        target_path = slots[state["slot"]]
        tmp = target_path + ".tmp"

        try:
            with open(tmp, "wb") as handle:
                handle.write(data)

            os.replace(tmp, target_path)
        except OSError as exc:
            say({"event": "miss", "error": str(exc)})
            return True

        width, height = png_size(data)
        say({
            "event": "frame",
            "raw": used_raw,
            "frame": state["frame"],
            "path": target_path,
            "ms": int((time.monotonic() - start) * 1000),
            "width": width,
            "height": height,
            "bytes": len(data),
        })

        return True

    def act(verb, rest, raw):
        """Un comando dalla riga: torna True se dopo vale la pena guardare."""
        if verb == "pause":
            state["paused"] = True
            say({"event": "state", "paused": True})
            return False

        if verb == "resume":
            state["paused"] = False
            say({"event": "state", "paused": False})
            return True

        if verb == "fps":
            try:
                value = float(rest[0])
            except (IndexError, ValueError):
                say({"event": "error", "cmd": verb, "error": "fps vuole un numero"})
                return False

            state["interval"] = 1.0 / min(max(value, FPS_MIN), FPS_MAX)
            say({"event": "state", "fps": round(1.0 / state["interval"], 2)})
            return False

        if verb == "shot":
            return True

        if verb == "pin":
            # Il PIN arriva qui dentro una riga di stdin e non fra gli
            # argomenti del processo, che e' l'unica differenza che conta: la
            # riga di comando la legge chiunque, questo canale no.
            done = unlock_device(device, " ".join(rest))
            say({"event": "unlock", **done})
            return True

        if verb == "text":
            # Il testo si prende dalla riga cruda: fare split e rijoin
            # mangerebbe gli spazi doppi, e chi scrive un messaggio li mette
            # dove vuole lui.
            rest = [raw.split(" ", 1)[1]] if " " in raw else []

        args, why = input_args(verb, rest)

        if not args:
            say({"event": "error", "cmd": verb, "error": why})
            return False

        ok, out_text, err = shell(device, *args, timeout=15)

        if not ok:
            say({"event": "error", "cmd": verb, "error": err or (out_text or "").strip()})

        return verb in AFTER_SHOT

    say({
        "event": "ready",
        "device": device["name"] or device["serial"],
        "serial": device["serial"],
        "fps": round(1.0 / state["interval"], 2),
        "folder": folder,
    })

    # Una prima fotografia comunque, anche da fermi: chi apre la finestra vuole
    # vedere lo schermo, e «Segui» spento vuol dire "non continuare", non
    # "non cominciare".
    alive = capture()
    due = time.monotonic() + state["interval"]

    # Chi chiude la finestra chiude il processo, e senza questo il segnale
    # arriverebbe senza passare dal `finally`: i due PNG resterebbero li' e
    # alla riapertura si vedrebbe per un istante lo schermo di prima.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))

    try:
        while alive:
            now = time.monotonic()

            # In pausa non c'e' nessun turno da aspettare: si dorme sullo stdin
            # finche' non arriva qualcosa da fare. E' lo stato in cui la
            # finestra sta con «Segui» spento, e deve costare zero.
            wait = None if state["paused"] else max(0.0, due - now)
            ready = select.select([sys.stdin], [], [], wait)[0]

            if ready:
                line = sys.stdin.readline()

                if not line:
                    # stdin chiuso: dall'altra parte non c'e' piu' nessuno.
                    break

                parts = line.strip().split()

                if parts:
                    verb = parts[0].lower()

                    if verb == "quit":
                        break

                    if act(verb, parts[1:], line.strip()):
                        alive = capture()
                        due = time.monotonic() + state["interval"]

                continue

            if not state["paused"]:
                alive = capture()
                due = time.monotonic() + state["interval"]
    except (KeyboardInterrupt, SystemExit):
        pass
    finally:
        # I due file non servono a nessuno appena la finestra si chiude, e
        # lasciarli vorrebbe dire che alla prossima apertura si vede per un
        # istante lo schermo di ieri.
        for leftover in slots + [s + ".tmp" for s in slots]:
            try:
                os.unlink(leftover)
            except OSError:
                pass

    return {
        "ok": state["misses"] < LIVE_GIVE_UP,
        "frames": state["frame"],
        "error": "" if state["misses"] < LIVE_GIVE_UP else (
            "il telefono ha smesso di rispondere agli scatti"
        ),
    }


def do_mirror(target="", mouse="uhid"):
    """Apre scrcpy sul telefono scelto e torna subito.

    Qui non si duplica quello che scrcpy fa gia': si sceglie il telefono con le
    stesse regole di tutti gli altri comandi e gli si passa il serial. Il
    processo parte in una sessione sua perche' deve sopravvivere a chi lo ha
    lanciato — la dashboard si chiude, il mirroring no.

    E' l'unica strada per i gesti a due dita: `input` ha un dito solo, e
    scrivere su /dev/input lo vieta SELinux anche allo shell di adb. scrcpy ha
    un pezzo suo sul telefono che inietta gli eventi dall'interno, ed e' quello
    che qui non si puo' rifare.

    Il mouse parte in modalita' uhid, che non e' un dettaglio: con --mouse=sdk
    scrcpy inietta i click via API e il telefono non si accorge di avere un
    mouse, mentre uhid gli monta un mouse HID vero col modulo UHID del kernel.
    Da quel momento esiste un cursore, che resta dov'e' quando il click e'
    finito, ed e' quello che `pointer` sa leggere. Il prezzo e' che la finestra
    di scrcpy si prende il mouse del PC e lo muove in relativo: LAlt o Super lo
    restituiscono. Chi preferisce il vecchio comportamento passa --mouse=sdk.
    """
    view = devices_view(discover=False)
    device, why = pick(view, target)

    if not device:
        return {"ok": False, "error": why}

    if not SCRCPY:
        return {"ok": False, "error": NO_SCRCPY}

    name = device["name"] or device["serial"]

    try:
        subprocess.Popen(
            [SCRCPY, "-s", device["serial"], "--window-title", name,
             "--mouse=" + mouse],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
    except OSError as exc:
        return {"ok": False, "error": str(exc)}

    return {
        "ok": True,
        "device": name,
        "mouse": mouse,
        "note": (
            "scrcpy aperto in una finestra a parte"
            if mouse != "uhid" else
            "scrcpy aperto in una finestra a parte, con un mouse HID: muovilo "
            "una volta e `pointer` sa dire dov'e' il cursore"
        ),
    }


BOUNDS = re.compile(r"\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]")


def hierarchy(device):
    """L'albero della schermata attuale, come lo vede l'accessibilita'.

    `uiautomator dump` e' lo stesso servizio che alimenta TalkBack: restituisce
    ogni nodo con il suo testo, la sua descrizione e il rettangolo che occupa.
    Vuole scrivere su un file, ma /dev/tty gli fa stampare tutto su stdout —
    e ci va `exec-out`, non `shell`, perche' lo pty di quest'ultimo traduce i
    ritorni a capo e spezza l'XML. Se l'apparecchio non gradisce /dev/tty si
    ripiega sul file su disco, che funziona sempre ed e' solo piu' lento.

    Quello che non c'e' qui non c'e' nemmeno per un non vedente: i giochi, i
    canvas e le app disegnate a mano espongono un rettangolo vuoto, e nessun
    trucco lato PC puo' inventarne il contenuto.
    """
    ok, out, err = shell(device, "exec-out", "uiautomator", "dump", "/dev/tty", timeout=60)
    raw = out or ""

    if "<hierarchy" not in raw:
        remote = "/sdcard/window_dump.xml"
        ok, out, err = shell(device, "shell", "uiautomator", "dump", remote, timeout=60)

        if ok:
            ok, raw, err = shell(device, "exec-out", "cat", remote, timeout=30)
            raw = raw or ""
            shell(device, "shell", "rm", "-f", remote, timeout=15)

    if "<hierarchy" not in raw:
        # Su uno schermo spento uiautomator risponde «could not get idle
        # state», che dice cosa non ha funzionato e non cosa fare. La domanda
        # vera e' se ci fosse qualcosa da leggere, e la si paga solo qui.
        if awake(device) is False:
            return None, (
                "lo schermo e' spento: accendilo con `display on`, o con "
                "`unlock` se c'e' il PIN, e richiedi la schermata"
            )

        return None, (err or "").strip() or "la schermata non e' leggibile"

    # uiautomator premette la sua riga di conferma e a volte lascia code dopo
    # la chiusura: si ritaglia l'XML invece di fidarsi degli estremi.
    start = raw.index("<?xml") if "<?xml" in raw else raw.index("<hierarchy")
    end = raw.rindex("</hierarchy>") + len("</hierarchy>")

    try:
        return ET.fromstring(raw[start:end]), ""
    except ET.ParseError as exc:
        return None, f"la schermata e' arrivata illeggibile: {exc}"


def foreground(device):
    """Pacchetto e activity in primo piano, per sapere cosa si sta guardando."""
    ok, out, _ = shell(device, "shell", "dumpsys", "window", timeout=30)

    if not ok:
        return {}

    found = re.search(r"mCurrentFocus=Window\{[^ ]+ [^ ]+ ([^/]+)/([^}]+)\}", out or "")

    if not found:
        return {}

    return {"package": found.group(1), "activity": found.group(2)}


def elements(root):
    """I nodi che hanno qualcosa da dire, con il centro gia' calcolato.

    Si tiene anche il rettangolo del genitore cliccabile: l'etichetta di un
    pulsante quasi mai e' il pulsante — in Fitbit "Salute" e' un TextView
    dentro una tab, e toccare il testo funziona solo perche' cade dentro
    l'area di chi lo contiene. Chi tocca vuole il bersaglio vero.
    """
    parents = {child: parent for parent in root.iter() for child in parent}
    out = []

    for node in root.iter("node"):
        text = (node.get("text") or "").strip()
        desc = (node.get("content-desc") or "").strip()

        if not text and not desc:
            continue

        box = BOUNDS.match(node.get("bounds") or "")

        if not box:
            continue

        x1, y1, x2, y2 = (int(v) for v in box.groups())

        if x2 <= x1 or y2 <= y1:
            continue

        # Il bersaglio: questo nodo se e' cliccabile, altrimenti il primo
        # antenato che lo e'.
        target = node
        walk = node

        while walk is not None:
            if walk.get("clickable") == "true":
                target = walk
                break

            walk = parents.get(walk)

        hit = BOUNDS.match(target.get("bounds") or "")
        hx1, hy1, hx2, hy2 = (int(v) for v in hit.groups()) if hit else (x1, y1, x2, y2)

        out.append({
            "text": text,
            "desc": desc,
            "class": (node.get("class") or "").rsplit(".", 1)[-1],
            "clickable": target is not node or node.get("clickable") == "true",
            "bounds": [x1, y1, x2, y2],
            "center": [(hx1 + hx2) // 2, (hy1 + hy2) // 2],
        })

    return out


def do_screen(target="", query=""):
    """Il testo che c'e' adesso sullo schermo, con dove toccarlo."""
    view = devices_view(discover=False)
    device, why = pick(view, target)

    if not device:
        return {"ok": False, "error": why}

    root, err = hierarchy(device)

    if root is None:
        return {"ok": False, "error": err}

    items = elements(root)

    if query:
        needle = query.lower()
        items = [
            i for i in items
            if needle in i["text"].lower() or needle in i["desc"].lower()
        ]

    return {
        "ok": True,
        "device": device["name"] or device["serial"],
        "foreground": foreground(device),
        "count": len(items),
        # Una schermata fitta arriva a qualche centinaio di nodi, e oltre un
        # certo punto sono decorazioni: chi cerca qualcosa di preciso usa query.
        "elements": items[:150],
        "truncated": len(items) > 150,
    }


def find_label(items, label):
    """I nodi che corrispondono a un'etichetta, dal piu' preciso al piu' largo.

    Prima l'uguaglianza sul testo, poi sulla descrizione, poi il contenimento:
    cercando "Salute" con dentro anche "Salute e benessere" vince quello che
    porta esattamente quel nome, che e' quello che intendeva chi l'ha chiesto.
    """
    needle = label.strip().lower()

    exact = [i for i in items if i["text"].lower() == needle]
    exact += [i for i in items if i["desc"].lower() == needle and i not in exact]

    if exact:
        return exact

    return [
        i for i in items
        if needle in i["text"].lower() or needle in i["desc"].lower()
    ]


def do_tap_text(label, target="", index=None):
    """Tocca l'elemento che porta quell'etichetta."""
    view = devices_view(discover=False)
    device, why = pick(view, target)

    if not device:
        return {"ok": False, "error": why}

    root, err = hierarchy(device)

    if root is None:
        return {"ok": False, "error": err}

    items = elements(root)
    hits = find_label(items, label)

    if not hits:
        # Serve sapere cosa c'era davvero: un'etichetta assente perche' la
        # schermata e' un'altra si distingue da una scritta in modo diverso
        # solo guardando l'elenco.
        return {
            "ok": False,
            "error": f"«{label}» non e' sullo schermo",
            "visible": [i["text"] or i["desc"] for i in items if i["clickable"]][:30],
        }

    if len(hits) > 1 and index is None:
        return {
            "ok": False,
            "error": f"«{label}» compare {len(hits)} volte",
            "candidates": [
                {"text": h["text"], "desc": h["desc"], "center": h["center"]}
                for h in hits[:10]
            ],
            "hint": "scegli con --index (0 e' il primo)",
        }

    hit = hits[index or 0] if len(hits) > 1 else hits[0]
    x, y = hit["center"]

    ok, out, err = shell(device, "shell", "input", "tap", str(x), str(y))

    return {
        "ok": ok,
        "device": device["name"] or device["serial"],
        "tapped": hit["text"] or hit["desc"],
        "at": [x, y],
        # Un'etichetta dentro un contenitore non cliccabile si tocca lo stesso,
        # ma vale la pena dirlo: se non succede niente, e' il primo sospetto.
        "clickable": hit["clickable"],
        "error": "" if ok else (err or (out or "").strip()),
    }


# Il cursore del mouse non e' una finestra e non sta nell'albero di
# accessibilita': e' uno sprite che SurfaceFlinger disegna sopra tutto, e la
# sua posizione la si legge solo di li'. Il nome del layer e' sempre «Sprite»,
# il numero cambia a ogni sessione.
#
# La riga completa e' lunga un centinaio di campi, e il dump intero passa i
# cinquemila righe: il grep sta sul telefono apposta, e quello che attraversa
# la rete e' una manciata di righe. Sono 130 ms contro qualche secondo.
SPRITE_DUMP = "dumpsys SurfaceFlinger | grep -A4 'Layer (Sprite'"

SPRITE_AT = re.compile(
    r"layerStack=\s*(\d+),.*?pos=\(\s*([-\d.]+)\s*,\s*([-\d.]+)\s*\)"
)


def sprites(dump):
    """I cursori disegnati adesso, uno per blocco «+ Layer (Sprite…)».

    Ce n'e' piu' d'uno quando lo schermo e' clonato su un display virtuale, e
    quando «Mostra tocchi» e' acceso: anche i cerchietti sotto le dita sono
    sprite. Il chiamante sceglie, qui si legge e basta.
    """
    found = []

    for block in dump.split("+ Layer (Sprite")[1:]:
        where = SPRITE_AT.search(block)

        if not where:
            continue

        found.append({
            "display": int(where.group(1)),
            # Interi: servono a essere ripassati a `tap`, che vuole pixel.
            "x": round(float(where.group(2))),
            "y": round(float(where.group(3))),
        })

    return found


def mouse_attached(device):
    """Se il telefono vede un mouse, e se il suo cursore e' gia' comparso.

    Due domande in una lettura sola perche' servono insieme: senza mouse non
    c'e' niente da cercare, e con il mouse appena collegato il cursore esiste
    ma non e' ancora stato disegnato da nessuna parte.
    """
    ok, out, _ = shell(device, "shell", "dumpsys", "input")

    if not ok:
        return False, False

    dump = out or ""

    # Ogni device dichiara le sue sorgenti; un mouse dice MOUSE. Il puntatore
    # passa a POINTER da SPOT la prima volta che il mouse si muove davvero.
    return (
        bool(re.search(r"Sources:.*MOUSE", dump)),
        "Presentation: POINTER" in dump,
    )


def do_pointer(target=""):
    """Dove sta adesso il cursore del mouse, in pixel dello schermo.

    Un dito non lascia coordinate: Android tiene la posizione del tocco finche'
    il dito e' appoggiato e poi la butta — `dumpsys input` risponde «no
    displays touched» un istante dopo. Un cursore invece resta dov'e', ma
    esiste solo se al telefono e' collegato un mouse: uno vero via USB o
    Bluetooth, oppure quello finto che scrcpy crea con --mouse=uhid, che e' il
    modo in cui `mirror` apre il mirroring.

    Quello che torna di qui va passato di peso a `tap`.
    """
    view = devices_view(discover=False)
    device, why = pick(view, target)

    if not device:
        return {"ok": False, "error": why}

    ok, out, err = shell(device, "shell", SPRITE_DUMP)

    if not ok:
        return {"ok": False, "error": err or "SurfaceFlinger non ha risposto"}

    found = sprites(out or "")

    if found:
        # Il display 0 e' quello fisico; gli altri sono cloni, e un clone
        # ripete il cursore del display che sta specchiando.
        found.sort(key=lambda s: s["display"])
        here = found[0]

        return {
            "ok": True,
            "device": device["name"] or device["serial"],
            "x": here["x"],
            "y": here["y"],
            "display": here["display"],
            "source": "mouse",
            "note": "cursore del mouse: il dito e i tap di adb non lo spostano",
        }

    # Da qui in giu' si paga un secondo dumpsys, ma solo quando c'e' da
    # spiegare un'assenza — ed e' li' che una risposta vuota fa perdere tempo.
    seen, moved = mouse_attached(device)

    if not seen:
        return {
            "ok": False,
            "device": device["name"] or device["serial"],
            "error": "nessun mouse collegato al telefono, quindi nessun cursore",
            "hint": (
                "apri il mirroring con `mirror` e muovi il mouse dentro quella "
                "finestra: il mouse finto nasce quando scrcpy lo cattura, non "
                "quando parte. Oppure attacca un mouse USB o Bluetooth"
            ),
        }

    return {
        "ok": False,
        "device": device["name"] or device["serial"],
        "error": "c'e' un mouse ma il suo cursore non e' sullo schermo",
        "hint": (
            "muovilo una volta e il cursore compare"
            if not moved else
            "il cursore si nasconde da solo dopo un po': muovilo di nuovo"
        ),
    }


# Il formato dei pixel che screencap dichiara nell'intestazione: 1 e'
# RGBA_8888, l'unico che si sa reimpacchettare qui. Gli altri esistono (RGB_565
# sui telefoni vecchi) e per quelli si torna al PNG fatto dal telefono, che li
# conosce tutti.
RGBA_8888 = 1


def raw_to_png(raw, level=1):
    """Il buffer di `screencap` senza opzioni, richiuso in un PNG qui.

    Vale la pena perche' e' piu' svelto. Comprimere in PNG lo fa il telefono
    con la sua CPU, e su uno sfondo fotografico ci mette un secondo e mezzo;
    mandare i pixel come sono, con un gzip di passaggio, costa 0,8 s in tutto —
    35 ms dei quali sono questa funzione, che gira su una CPU che ha altro da
    dare. Sotto, la mezza dozzina di righe che un PNG richiede: intestazione,
    un byte di filtro davanti a ogni riga, e zlib.

    L'intestazione di screencap e' larghezza, altezza e formato in little
    endian, seguiti su Android recenti dallo spazio colore: invece di
    indovinare quanto e' lunga la si deduce da quanto avanza dopo i pixel.
    """
    if len(raw) < 16:
        return b"", "il buffer dello schermo e' arrivato troppo corto"

    width, height, fmt = struct.unpack("<III", raw[:12])
    offset = len(raw) - width * height * 4

    if fmt != RGBA_8888 or width <= 0 or height <= 0 or offset not in (12, 16):
        return b"", f"schermo in un formato che non so richiudere ({width}x{height}, tipo {fmt})"

    pixels = raw[offset:]
    stride = width * 4
    rows = bytearray()

    for y in range(height):
        rows.append(0)
        rows += pixels[y * stride:(y + 1) * stride]

    def chunk(tag, payload):
        body = tag + payload
        return struct.pack(">I", len(payload)) + body + struct.pack(">I", zlib.crc32(body))

    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(bytes(rows), level))
        + chunk(b"IEND", b"")
    ), ""


def grab_raw(device, timeout=60):
    """I pixel nudi, compressi dal telefono con gzip e ricuciti qui.

    Il gzip di mezzo non e' una finezza: i pixel nudi sono 4,6 MB a frame, e
    farli passare per la rete due volte al secondo occuperebbe il Wi-Fi per
    intero. Compressi sono 1,7 MB e il tempo e' lo stesso.
    """
    ok, data, err = shell(
        device, "exec-out", "screencap | toybox gzip -1", binary=True, timeout=timeout,
    )

    if not ok or not data:
        return b"", err or "screencap non ha prodotto niente"

    try:
        raw = zlib.decompress(data, 31)
    except zlib.error as exc:
        return b"", str(exc)

    return raw_to_png(raw)


def grab(device, timeout=60, raw=True):
    """I byte PNG dello schermo, o la ragione per cui non ci sono.

    `exec-out` e non `shell`: quest'ultimo passa da uno pty che sostituisce i
    ritorni a capo e consegna un PNG corrotto, un classico di adb.

    Sta per conto suo perche' la usano in due: lo scatto singolo, che la salva
    dove gli e' stato chiesto, e la sessione `live`, che la ripete due volte al
    secondo. Il controllo dell'immagine troncata deve restare uno solo.

    Torna anche da quale delle due strade e' passata: chi ripete la cattura ha
    bisogno di sapere se la piu' veloce ha funzionato, per non ritentarla a
    ogni frame su un telefono che non la sa fare.
    """
    if raw:
        data, why = grab_raw(device, timeout=timeout)

        if data:
            return data, "", True

    ok, data, err = shell(device, "exec-out", "screencap", "-p", binary=True, timeout=timeout)

    if not ok or not data:
        return b"", err or "screencap non ha prodotto niente", False

    # Un PNG finisce con il chunk IEND: quattro byte di lunghezza a zero, il
    # nome, e il CRC. Guardare solo l'intestazione non basta — una sessione che
    # muore a meta' trasferimento lascia un file che comincia benissimo e non
    # finisce, e chi lo apre dopo si trova un errore di decodifica al posto di
    # una spiegazione.
    if not data.startswith(b"\x89PNG") or not data.endswith(b"\x00\x00\x00\x00IEND\xaeB`\x82"):
        return b"", (
            "l'immagine e' arrivata incompleta: il collegamento si e' "
            "interrotto a meta' — riprova, e se insiste stacca e riattacca "
            "il cavo"
        ), False

    return data, "", False


def png_size(data):
    """Larghezza e altezza lette dall'intestazione del PNG.

    Sono nei byte 16..24, subito dopo la firma e il nome del chunk IHDR. Si
    leggono qui invece di chiedere `wm size` al telefono perche' l'immagine sa
    gia' quanto e' grande, e perche' un telefono ruotato la cambia senza
    avvisare nessuno.
    """
    if len(data) < 24:
        return 0, 0

    return struct.unpack(">II", data[16:24])


def do_screenshot(path="", target=""):
    """Salva uno screenshot PNG e restituisce il percorso."""
    view = devices_view(discover=False)
    device, why = pick(view, target)

    if not device:
        return {"ok": False, "error": why}

    data, why, _ = grab(device)

    if not data:
        return {"ok": False, "error": why}

    if not path:
        name = (device["name"] or "phone").replace(" ", "-")
        path = f"/tmp/{name}-{time.strftime('%Y%m%d-%H%M%S')}.png"

    try:
        with open(os.path.expanduser(path), "wb") as handle:
            handle.write(data)
    except OSError as exc:
        return {"ok": False, "error": str(exc)}

    return {
        "ok": True,
        "device": device["name"] or device["serial"],
        "path": os.path.expanduser(path),
        "bytes": len(data),
    }


# ----------------------------------------------------------------- macrocam

# L'app che scatta: sta in un progetto a parte, qui se ne conoscono solo il
# nome e i due punti d'ingresso. Non e' una dipendenza — se non c'e', gli altri
# comandi continuano a funzionare e questo lo dice.
MACROCAM = "com.oberon.macrocam"
MACROCAM_FILES = "/sdcard/Android/data/%s/files" % MACROCAM

MACROCAM_MISSING = (
    "MacroCam non e' installata su questo telefono. Dal progetto "
    "~/Documents/Development/Flutter/macrocamera: `./gradlew assembleDebug`, "
    "poi `adb -s SERIAL install -r app/build/outputs/apk/debug/app-debug.apk` e "
    "`adb -s SERIAL shell pm grant %s android.permission.CAMERA`" % MACROCAM
)

# Le tre voci che bastano a capire cos'e' una lente: da che parte guarda,
# quanto e' corta e a che distanza mette a fuoco.
CAMERA_KEYS = {
    "android.lens.facing": "facing",
    "android.lens.info.availableFocalLengths": "focal_mm",
    "android.lens.info.minimumFocusDistance": "min_focus_diopters",
}

CAMERA_HEADER = re.compile(r"/(\d+) \(v[\d.]+\) static information")


def camera_blocks(dump):
    """Le caratteristiche di ogni lente, cosi' come le racconta la HAL.

    Il formato mette il nome della voce su una riga e il valore fra parentesi
    quadre su quella dopo, quindi si legge a coppie: si segna cosa si sta
    aspettando e lo si raccoglie al giro successivo.
    """
    blocks = {}
    current = None
    pending = None

    for line in dump.splitlines():
        header = CAMERA_HEADER.search(line)

        if header:
            current = header.group(1)
            blocks.setdefault(current, {})
            pending = None
            continue

        if current is None:
            continue

        if pending:
            blocks[current][pending] = line.strip().strip("[]").strip()
            pending = None
            continue

        stripped = line.strip()

        for key, name in CAMERA_KEYS.items():
            if stripped.startswith(key + " "):
                pending = name
                break

    return blocks


def do_camera(target=""):
    """Le lenti del telefono, lette e basta.

    Passa da `dumpsys` e non dall'app perche' e' una domanda, non un'azione:
    risponde anche a telefono con MacroCam non installata, e non accende
    niente. Le lenti che compaiono qui non sono per forza tutte apribili da
    un'app di terze parti — quello lo dice solo il probe dell'app.
    """
    view = devices_view(discover=False)
    device, why = pick(view, target)

    if not device:
        return {"ok": False, "error": why}

    ok, dump, err = shell(device, "shell", "dumpsys", "media.camera", timeout=40)

    if not ok or not dump:
        return {"ok": False, "error": err or "dumpsys media.camera non ha detto niente"}

    cameras = []

    for camera_id, values in sorted(camera_blocks(dump).items(), key=lambda kv: int(kv[0])):
        try:
            focal = round(float(values.get("focal_mm", "0")), 2)
            diopters = float(values.get("min_focus_diopters", "0"))
        except ValueError:
            continue

        cameras.append({
            "id": camera_id,
            "facing": values.get("facing", "?").lower(),
            "focal_mm": focal,
            # Zero diottrie non vuol dire infinito: vuol dire che la lente non
            # mette a fuoco niente, ed e' la firma dei moduli macro.
            "fixed_focus": diopters <= 0,
            "min_focus_cm": None if diopters <= 0 else round(100.0 / diopters, 1),
        })

    back = [c for c in cameras if c["facing"] == "back"]
    macro = [c["id"] for c in back[1:] if c["fixed_focus"]]

    return {
        "ok": True,
        "device": device["name"] or device["serial"],
        "cameras": cameras,
        "macro_candidates": macro,
        "macrocam": macrocam_installed(device),
        "note": (
            "candidate macro: posteriori a fuoco fisso che non sono la principale. "
            "Quale sia apribile davvero lo dice solo l'app."
        ),
    }


def macrocam_installed(device):
    ok, out, _ = shell(device, "shell", "pm", "list", "packages", MACROCAM)
    return bool(ok and MACROCAM in (out or ""))


def macrocam_status(device):
    ok, out, _ = shell(device, "shell", "cat", MACROCAM_FILES + "/status.json")

    if not ok or not out:
        return None

    try:
        return json.loads(out)
    except ValueError:
        return None


def do_photo(mode="normal", target="", out="", camera="", torch=False,
             roi="", ocr=True, name="", full=False, zoom=""):
    """Uno scatto, e i file che ne escono, sul PC.

    `am start` non aspetta la fine di niente e non restituisce niente: l'app
    scrive il risultato in un file con un contatore che sale, e qui si guarda
    quel numero finche' non cambia. E' l'unico modo di rendere sincrona una
    chiamata che non lo e', ed e' anche il motivo per cui un timeout qui non e'
    un dettaglio ma la differenza fra una risposta e un blocco.
    """
    view = devices_view(discover=False)
    device, why = pick(view, target)

    if not device:
        return {"ok": False, "error": why}

    if not macrocam_installed(device):
        return {"ok": False, "error": MACROCAM_MISSING}

    before = (macrocam_status(device) or {}).get("seq", 0)

    # Per scattare l'app deve accendere lo schermo, e un'app non ha il potere
    # di rispegnerlo. Chi lo sa com'era prima e' qui: se il telefono dormiva,
    # lo si rimanda a dormire alla fine.
    _, power, _ = shell(device, "shell", "dumpsys", "power")
    slept = "mWakefulness=Asleep" in (power or "")

    args = [
        "shell", "am", "start", "-n", MACROCAM + "/.CaptureActivity",
        "--es", "action", "capture", "--es", "mode", mode,
    ]

    if camera:
        args += ["--es", "camera", str(camera)]
    if torch:
        args += ["--es", "torch", "on"]
    if roi:
        args += ["--es", "roi", roi]
    if zoom:
        args += ["--es", "zoom", str(zoom)]
    if not ocr:
        args += ["--es", "ocr", "off"]
    if name:
        args += ["--es", "name", name]

    started, _, err = shell(device, *args, timeout=30)

    if not started:
        return {"ok": False, "error": err or "l'app non si e' avviata"}

    status = None
    deadline = time.time() + 40

    while time.time() < deadline:
        fresh = macrocam_status(device)

        if fresh and fresh.get("seq", 0) > before and fresh.get("state") != "busy":
            status = fresh
            break

        time.sleep(0.4)

    if not status:
        return {"ok": False, "error": "lo scatto non ha risposto entro quaranta secondi"}

    if status.get("state") != "ok":
        return {"ok": False, "error": status.get("error") or "scatto fallito"}

    stem = os.path.splitext(os.path.expanduser(out))[0] if out else "/tmp/%s-%s" % (
        (device["name"] or "phone").replace(" ", "-"), time.strftime("%Y%m%d-%H%M%S")
    )

    # La copia ridotta e' quella che serve a un modello; l'originale e il
    # ritaglio a piena risoluzione si scaricano solo se qualcuno li chiede,
    # perche' sono megabyte che passano dalla rete.
    wanted = [("path", status.get("fileSmall"), ".jpg")]

    if full:
        wanted.append(("path_full", status.get("file"), "-full.jpg"))
        wanted.append(("path_crop", status.get("fileCrop"), "-crop.jpg"))

    grabbed = {}

    for key, remote, suffix in wanted:
        if not remote:
            continue

        local = os.path.expanduser(out) if (out and key == "path") else stem + suffix
        got, _, _ = shell(device, "pull", remote, local, timeout=120)

        if got:
            grabbed[key] = local

    result = {
        "ok": True,
        "device": device["name"] or device["serial"],
        "mode": status.get("mode"),
        "camera": status.get("cameraId"),
        "focus": status.get("focusStrategy"),
        "roi": status.get("roi"),
        "zoom": status.get("zoom"),
        "text": status.get("text", ""),
        "size": "%sx%s" % (status.get("width"), status.get("height")),
        "took_ms": status.get("tookMs"),
    }

    if status.get("notes"):
        result["notes"] = status["notes"]

    if slept:
        shell(device, "shell", "input", "keyevent", "KEYCODE_SLEEP")
        result["note"] = "il telefono dormiva ed e' stato rimesso a dormire"

    result.update(grabbed)
    return result


def do_aim(mode="macro", target=""):
    """Apre il mirino sul telefono: l'unico comando che chiede una mano.

    Serve la prima volta su un soggetto nuovo, perche' un macro inquadra pochi
    centimetri quadrati e chi appoggia il telefono sta puntando alla cieca.
    Il pulsante a sinistra alterna due modi per lo stesso dito: `Zoom` fa
    comparire un cursore per ingrandire l'inquadratura, `Inquadra` lo fa
    tornare a disegnare il rettangolo dell'area. Il rettangolo si salva da
    solo appena si alza il dito, e da li' in poi ogni scatto esce gia'
    ritagliato su quella zona.
    """
    view = devices_view(discover=False)
    device, why = pick(view, target)

    if not device:
        return {"ok": False, "error": why}

    if not macrocam_installed(device):
        return {"ok": False, "error": MACROCAM_MISSING}

    # Il mirino va guardato, quindi lo schermo si accende e la schermata di
    # blocco si toglie di mezzo. Con un PIN impostato restera' il PIN: quello
    # e' di chi possiede il telefono, non di chi lo comanda.
    shell(device, "shell", "input", "keyevent", "KEYCODE_WAKEUP")
    shell(device, "shell", "wm", "dismiss-keyguard")

    ok, _, err = shell(
        device, "shell", "am", "start", "-n", MACROCAM + "/.AimActivity",
        "--es", "mode", mode, timeout=30,
    )

    if not ok:
        return {"ok": False, "error": err or "il mirino non si e' aperto"}

    return {
        "ok": True,
        "device": device["name"] or device["serial"],
        "mode": mode,
        "note": (
            "mirino aperto sul telefono: `Zoom` per ingrandire e vedere cosa "
            "c'e' sotto la lente, `Inquadra` per trascinare il rettangolo "
            "sull'area che interessa, che si salva da sola. `Scatta` fa una "
            "prova con la stessa pipeline dei comandi da qui. Per leggere del "
            "testo conviene tornare a zoom 1x prima dello scatto buono: "
            "ingrandire non aggiunge dettaglio e sfoca i caratteri piccoli."
        ),
    }


# -------------------------------------------------------------- healthbridge

# L'app che legge Health Connect: sta in un progetto a parte, qui se ne
# conoscono solo il nome e il punto d'ingresso. Come MacroCam non e' una
# dipendenza — se non c'e', tutto il resto continua a funzionare e questo lo
# dice.
HEALTH = "com.oberon.healthbridge"
HEALTH_FILES = "/sdcard/Android/data/%s/files" % HEALTH

HEALTH_READS = [
    "READ_HEART_RATE", "READ_STEPS", "READ_SLEEP", "READ_DISTANCE",
    "READ_TOTAL_CALORIES_BURNED", "READ_ACTIVE_CALORIES_BURNED",
    "READ_SKIN_TEMPERATURE", "READ_OXYGEN_SATURATION", "READ_WEIGHT",
    "READ_HEALTH_DATA_IN_BACKGROUND",
]

HEALTH_MISSING = (
    "HealthBridge non e' installata su questo telefono. Dal progetto "
    "~/Documents/Development/Android/healthbridge: `./gradlew assembleDebug`, "
    "poi `adb -s SERIAL install -r app/build/outputs/apk/debug/app-debug.apk` e "
    "`phone_adb.py health-grant`"
)


# Un telefono che adb elenca non e' un telefono che risponde: una sessione
# wireless stantia resta scritta in `adb devices` come "device" e fallisce a
# ogni comando con "error: closed". La differenza conta proprio qui, perche' un
# `pm list packages` che non arriva torna vuoto esattamente come quello di un
# telefono senza l'app — e mandare a ricompilare un APK per un debug wireless
# spento e' il genere di consiglio che fa perdere un pomeriggio.
HEALTH_UNREACHABLE = (
    "«%s» non risponde ad adb: la sessione e' caduta. Riaccendi il debug "
    "wireless sul telefono (Opzioni sviluppatore → Debug wireless), poi apri la "
    "sua finestra e premi Collega"
)


def health_probe(device):
    """(l'app c'e', perche' non si sa). Le due cose non si deducono l'una dall'altra."""
    ok, out, err = shell(device, "shell", "pm", "list", "packages", HEALTH)

    if not ok:
        return False, HEALTH_UNREACHABLE % (device["name"] or device["serial"])

    return HEALTH in (out or ""), ""


def health_status(device):
    ok, out, _ = shell(device, "shell", "cat", HEALTH_FILES + "/status.json")

    if not ok or not out:
        return None

    try:
        return json.loads(out)
    except ValueError:
        return None


# `am broadcast` stampa il risultato del receiver su una riga sua, fra
# virgolette che non protegge: il JSON dentro ha le proprie e nessuno le
# raddoppia, quindi non si puo' cercare la prima virgoletta di chiusura — si
# prende tutto fino all'ultima.
BROADCAST_DATA = 'data="'


def broadcast_payload(out):
    """Il JSON dentro la risposta di `am broadcast`, se c'e'."""
    where = (out or "").find(BROADCAST_DATA)

    if where < 0:
        return None

    raw = out[where + len(BROADCAST_DATA):].strip()

    if raw.endswith('"'):
        raw = raw[:-1]

    try:
        return json.loads(raw)
    except ValueError:
        return None


def health_ask(device, action, extras=(), timeout=45):
    """Una domanda all'app e la sua risposta.

    Passa da un broadcast e non da `am start` perche' un receiver non e'
    un'activity: non entra nella pila delle applicazioni, non prende il fuoco e
    non ha niente a che vedere con cio' che c'e' a schermo — l'app che si sta
    usando resta dov'e', e il telefono addormentato resta addormentato. In piu'
    `am broadcast` riporta il risultato al chiamante, mentre `am start` non
    riporta niente: e' quello che fa sparire la danza del contatore e del file
    riletto finche' il numero non cambia.

    L'activity resta come ripiego, per le due volte in cui serve: una lettura
    piu' lunga di quanto un receiver possa vivere — oltre la decina di secondi
    Android lo chiude — e il sospetto che sia il receiver stesso a non
    rispondere. Li' si torna a guardare `status.json`, che l'app scrive
    comunque.

    Una lettura costa cinque o sei secondi, quasi tutti spesi a collegarsi a
    Health Connect: non dipende da quanti minuti si chiedono.
    """
    args = [
        "shell", "am", "broadcast",
        "-a", HEALTH + ".READ", "-n", HEALTH + "/.ReadReceiver",
        "--es", "action", action,
    ]

    for key, value in extras:
        args += ["--es", key, str(value)]

    ok, out, err = shell(device, *args, timeout=timeout)
    status = broadcast_payload(out) if ok else None

    if status is None:
        return health_ask_slowly(device, action, extras, timeout, err or "")

    if status.get("state") != "ok":
        return None, status.get("error") or "la lettura e' fallita"

    return status, ""


def health_ask_slowly(device, action, extras, timeout, why):
    """La stessa domanda per la via lunga: l'activity, e il file riletto.

    `am start` non aspetta la fine di niente e non restituisce niente, quindi
    si legge il contatore prima, si lancia, e si guarda il file finche' il
    numero non e' cambiato — la stessa danza di `do_photo`.
    """
    before = (health_status(device) or {}).get("seq", 0)

    args = ["shell", "am", "start", "-n", HEALTH + "/.ReadActivity", "--es", "action", action]

    for key, value in extras:
        args += ["--es", key, str(value)]

    started, _, err = shell(device, *args, timeout=30)

    if not started:
        return None, (why or err or "l'app non ha risposto")

    deadline = time.time() + timeout

    while time.time() < deadline:
        fresh = health_status(device)

        if fresh and fresh.get("seq", 0) > before and fresh.get("state") != "busy":
            if fresh.get("state") != "ok":
                return None, fresh.get("error") or "la lettura e' fallita"

            return fresh, ""

        time.sleep(0.4)

    return None, "la lettura non ha risposto entro %d secondi" % timeout


def health_open(target):
    """Il telefono scelto, gia' controllato che abbia l'app: lo fanno in cinque.

    Il secondo valore e' la risposta d'errore gia' pronta, non il solo motivo:
    quando i telefoni collegati sono piu' d'uno serve portarsi dietro anche i
    loro nomi, perche' chi chiede possa farne dei pulsanti invece di stampare
    una parentesi in fondo a una frase che dice di usare `--device`.
    """
    view = devices_view(discover=False)
    device, why = pick(view, target)

    if not device:
        problem = {"ok": False, "error": why}
        names = [d["name"] or d["serial"] for d in view if d["connected"]]

        if not target and len(names) > 1:
            problem["choices"] = names

        return None, problem

    installed, why = health_probe(device)

    if not installed:
        return None, {"ok": False, "error": why or HEALTH_MISSING}

    return device, {}


def do_heart(target="", minutes=60, bucket=60, raw=False):
    """Il battito degli ultimi minuti, un punto per intervallo.

    I buchi si aprono qui e non sull'app: Health Connect restituisce solo gli
    intervalli che hanno campioni, il che e' giusto — ma chi disegna vuole una
    griglia regolare in cui un minuto senza dati sia `None` e non un punto che
    non c'e'. Senza, la linea salterebbe il buco unendo i due estremi, e mezz'ora
    col braccialetto sul comodino sembrerebbe mezz'ora di battito.
    """
    device, problem = health_open(target)

    if not device:
        return problem

    extras = [("minutes", minutes), ("bucket", bucket)]

    if raw:
        extras.append(("raw", "on"))

    status, err = health_ask(device, "heart", extras)

    if not status:
        return {"ok": False, "error": err}

    out = {
        "ok": True,
        "device": device["name"] or device["serial"],
        "minutes": minutes,
        "now": status.get("now"),
        "latest": status.get("latest"),
        "lag_seconds": status.get("lagSeconds"),
    }

    if raw:
        out["samples"] = status.get("samples") or []
        out["count"] = status.get("count", 0)
        return out

    have = {int(b[0]): b for b in (status.get("buckets") or [])}
    now = status.get("now") or int(time.time())
    step = bucket
    first = now - minutes * 60

    # La griglia si allinea al passo, se no due letture di fila cadrebbero su
    # istanti diversi e gli stessi minuti non si sovrapporrebbero mai.
    first -= first % step
    points = []

    for at in range(first, now + 1, step):
        found = have.get(at)
        points.append(
            {"t": at, "avg": found[1], "min": found[2], "max": found[3]}
            if found else {"t": at, "avg": None, "min": None, "max": None}
        )

    out["bucket_seconds"] = bucket
    out["count"] = len(have)
    out["gaps"] = len(points) - len(have)
    out["points"] = points

    return out


def do_today(target=""):
    """Passi, calorie, sonno e il resto della giornata, come li ha Health Connect."""
    device, problem = health_open(target)

    if not device:
        return problem

    status, err = health_ask(device, "today")

    if not status:
        return {"ok": False, "error": err}

    out = {"ok": True, "device": device["name"] or device["serial"]}

    for key in (
        "now", "since", "steps", "distanceMeters", "calories", "activeCalories",
        "bpmAvg", "bpmMin", "bpmMax", "sleep", "skinTemperature", "oxygen", "weight",
    ):
        out[key] = status.get(key)

    return out


def do_vitals(target=""):
    """Cosa c'e' dentro Health Connect e quanto e' fresco, tipo per tipo.

    Serve a rispondere alla sola domanda che conta quando qualcosa non torna:
    il dato non c'e' perche' l'app ponte non lo sa leggere, o perche' Fitbit non
    lo ha mai scritto? La riga `origins` dice chi lo ha messo li'.
    """
    device, problem = health_open(target)

    if not device:
        return problem

    status, err = health_ask(device, "probe")

    if not status:
        return {"ok": False, "error": err}

    return {
        "ok": True,
        "device": device["name"] or device["serial"],
        "sdk": status.get("sdk"),
        "now": status.get("now"),
        "granted": status.get("granted"),
        "missing": status.get("missing"),
        "types": status.get("types"),
    }


def do_health_grant(target=""):
    """I permessi di lettura all'app ponte, uno per uno.

    Su questo telefono `pm grant` basta: i permessi health sono `dangerous` ma
    non ristretti. Dove non bastasse, la strada e' quella di MacroCam — aprire
    l'app e toccare il dialogo con `tap-text` — e il suggerimento lo dice.
    """
    device, problem = health_open(target)

    if not device:
        return problem

    done, failed = [], {}

    for name in HEALTH_READS:
        ok, out, err = shell(
            device, "shell", "pm", "grant", HEALTH, "android.permission.health." + name,
        )
        trouble = (err or out or "").strip()

        if ok and not trouble:
            done.append(name)
        else:
            failed[name] = trouble or "rifiutato"

    return {
        "ok": not failed,
        "device": device["name"] or device["serial"],
        "granted": done,
        "failed": failed,
        "hint": "" if not failed else (
            "questi vanno concessi a mano: `launch %s`, poi `screen` per "
            "leggere le etichette e `tap-text` per toccarle" % HEALTH
        ),
    }


def do_status(quick=False):
    """Chi c'e', come e cosa manca perche' sia utilizzabile.

    Con `quick` non si ascolta la rete: si guarda solo cosa ha adb adesso e chi
    conosce KDE Connect. Trecento millisecondi invece di tre secondi, e serve a
    chi vuole sapere se il telefono risponde — non a chi deve ancora entrarci.
    E' la domanda del pannello, che la rifa' ogni trenta secondi: pagare li'
    l'ascolto mDNS vorrebbe dire tenere occupato un processo un decimo del
    tempo per un pallino colorato.

    Quello che si perde e' il debug wireless annunciato e la finestra del
    codice: senza ascolto non si sa se ci sono, e "non annunciato" e "non lo
    so" sono due cose diverse. Per questo la risposta porta `discovered`, e i
    suggerimenti che dipendono dall'annuncio restano fuori invece di essere
    dati per falsi.
    """
    if not ADB:
        return {"ok": False, "error": NO_ADB}

    view = devices_view(discover=not quick)

    hints = []

    for device in view:
        if device["connected"]:
            continue

        who = device["name"] or device["ip"] or device["serial"]

        if device["adb"] == "unauthorized":
            hints.append(
                f"{who}: conferma la chiave RSA sullo schermo del telefono "
                "(se la finestra non c'e' piu', `repair` la fa ricomparire)"
            )
        elif device["adb"] == "offline":
            # Il telefono e' attaccato ma la sessione e' morta. Qui si e' gia'
            # provato `adb reconnect` una volta: se e' ancora offline serve una
            # mano fisica. Compare col serial invece che col nome perche' senza
            # sessione non si puo' chiedere il modello a cui associarlo.
            hints.append(
                f"{who}: collegamento offline — stacca e riattacca il cavo, "
                "oppure prova un'altra porta USB"
            )
        elif quick:
            # Da qui in giu' ogni ramo parla di cosa il telefono sta
            # annunciando, e con `quick` nessuno ha ascoltato.
            continue
        elif device["pairing_open"]:
            hints.append(f"{who}: sta chiedendo il codice — lancia `pair <codice>`")
        elif device["wireless_debugging"]:
            hints.append(f"{who}: debug wireless acceso, basta `connect`")
        elif device["paired"]:
            hints.append(
                f"{who}: gia' accoppiato — il pairing non va rifatto, ma adesso "
                "non annuncia il debug wireless: accendigli lo schermo, e se "
                "serve riaccendi Opzioni sviluppatore → Debug wireless. Se e' "
                "il telefono ad aver dimenticato questo PC, `repair`"
            )
        elif device["ip"]:
            hints.append(
                f"{who}: debug wireless spento (Opzioni sviluppatore → Debug wireless)"
            )

    # Un percorso scritto a mano in tools.json e sbagliato si e' gia' fatto
    # sostituire dal PATH, senza rompere niente: qui e' il primo posto in cui
    # c'e' qualcuno che legge, ed e' l'unico modo di scoprirlo prima di
    # chiedersi per mezz'ora perche' il binario scelto non viene usato.
    hints += tools.trouble()

    return {
        "ok": True,
        "devices": view,
        "connected": [d["name"] or d["serial"] for d in view if d["connected"]],
        # Se qualcuno ha ascoltato la rete in questo giro. Quando e' falso,
        # `wireless_debugging` e `pairing_open` valgono "non lo so", non "no".
        "discovered": not quick,
        "mdns": bool(AVAHI),
        # Non e' una capacita' del telefono ma di questa macchina: il pannello
        # ci disegna sopra un pulsante, e senza saperlo lo disegnerebbe acceso
        # per poi fallire al clic.
        "mirror": bool(SCRCPY),
        "hints": hints,
        "note": "" if AVAHI else NO_AVAHI,
    }


# -------------------------------------------------------------------- cli


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--device", default="", help="nome, indirizzo o serial del telefono")
    sub = parser.add_subparsers(dest="command")

    status = sub.add_parser("status", help="telefoni, stato adb e cosa manca")
    status.add_argument("--quick", action="store_true",
                        help="senza ascolto mDNS: solo cosa ha adb adesso")
    sub.add_parser("connect", help="collega ad adb chi e' raggiungibile")
    sub.add_parser("disconnect", help="stacca la connessione wireless")
    sub.add_parser("forget", help="dimentica le porte salvate")
    sub.add_parser("repair", help="rimette in gioco un telefono che ha tolto l'autorizzazione")
    mirror = sub.add_parser("mirror", help="apre scrcpy sul telefono")
    mirror.add_argument("--mouse", default="uhid", choices=["uhid", "sdk", "aoa"],
                        help="come mandare il mouse: uhid monta un mouse HID "
                             "vero (e da' un cursore leggibile con pointer)")

    live = sub.add_parser("live", help="sessione: frame su stdout, comandi su stdin")
    live.add_argument("--fps", type=float, default=2.0, help="scatti al secondo")
    live.add_argument("--out", default="", help="dove posare i frame")
    live.add_argument("--paused", action="store_true",
                      help="parte fermo: uno scatto e poi si aspettano i comandi")

    pair = sub.add_parser("pair", help="accoppia col codice a sei cifre")
    pair.add_argument("code")

    apps = sub.add_parser("apps", help="pacchetti installati")
    apps.add_argument("--query", default="")
    apps.add_argument("--system", action="store_true", help="anche quelli di sistema")

    launch = sub.add_parser("launch", help="avvia un'app")
    launch.add_argument("package")
    launch.add_argument("--activity", default="")

    opener = sub.add_parser("open", help="apre un indirizzo sul telefono")
    opener.add_argument("url")

    tap = sub.add_parser("tap", help="tocca un punto: X Y")
    tap.add_argument("values", nargs="+")

    swipe = sub.add_parser("swipe", help="scorre: X1 Y1 X2 Y2 [durata_ms]")
    swipe.add_argument("values", nargs="+")

    text = sub.add_parser("text", help="scrive del testo")
    text.add_argument("values", nargs="*")
    text.add_argument("--stdin", action="store_true",
                      help="legge il testo da standard input (per PIN e password)")

    key = sub.add_parser("key", help="preme un tasto: HOME, BACK, POWER…")
    key.add_argument("values", nargs=1)

    sub.add_parser("pointer", help="dov'e' adesso il cursore del mouse")

    screen = sub.add_parser("screen", help="il testo sullo schermo, con dove toccarlo")
    screen.add_argument("--query", default="", help="solo gli elementi che contengono questo")

    tap_text = sub.add_parser("tap-text", help="tocca l'elemento con quell'etichetta")
    tap_text.add_argument("label")
    tap_text.add_argument("--index", type=int, default=None, help="quale, se compare piu' volte")

    display = sub.add_parser("display", help="accende o spegne lo schermo")
    display.add_argument("state", nargs="?", default="", choices=["on", "off", ""],
                         help="on, off, oppure niente per sapere com'e'")

    unlock = sub.add_parser("unlock", help="sveglia e sblocca (PIN da --stdin)")
    unlock.add_argument("--stdin", action="store_true",
                        help="legge il PIN da standard input")

    shot = sub.add_parser("screenshot", help="salva uno screenshot PNG")
    shot.add_argument("--out", default="")

    sub.add_parser("camera", help="le lenti del telefono, lette da dumpsys")

    photo = sub.add_parser("photo", help="scatta con MacroCam e scarica la foto")
    photo.add_argument("--mode", default="normal", choices=["normal", "macro"])
    photo.add_argument("--out", default="", help="dove salvare la copia ridotta")
    photo.add_argument("--camera", default="", help="forza una lente per id")
    photo.add_argument("--torch", action="store_true", help="torcia accesa durante lo scatto")
    photo.add_argument("--roi", default="", help="area: sinistra,alto,destra,basso in 0..1, oppure off")
    photo.add_argument("--zoom", default="", help="ingrandimento, es. 2.0, oppure off")
    photo.add_argument("--no-ocr", action="store_true", help="salta la lettura del testo")
    photo.add_argument("--name", default="", help="nome del file sul telefono")
    photo.add_argument("--full", action="store_true", help="scarica anche originale e ritaglio")

    aim = sub.add_parser("aim", help="apre il mirino sul telefono per scegliere l'area")
    aim.add_argument("--mode", default="macro", choices=["normal", "macro"])

    heart = sub.add_parser("heart", help="il battito degli ultimi minuti, da Health Connect")
    heart.add_argument("--minutes", type=int, default=60)
    heart.add_argument("--bucket", type=int, default=60, help="secondi per punto")
    heart.add_argument("--raw", action="store_true", help="i campioni singoli, non le medie")

    sub.add_parser("today", help="passi, calorie, sonno e il resto di oggi")
    # `vitals` e non `health`: in questo progetto `health` e' gia' lo stato del
    # sistema, e due nomi uguali per cose diverse sono un errore di lettura in
    # attesa di succedere.
    sub.add_parser("vitals", help="cosa c'e' in Health Connect e quanto e' fresco")
    sub.add_parser("health-grant", help="concede i permessi di lettura all'app ponte")

    args = parser.parse_args()
    command = args.command or "status"

    if command == "status":
        payload = do_status(getattr(args, "quick", False))
    elif command == "connect":
        payload = do_connect(args.device)
    elif command == "disconnect":
        payload = do_disconnect(args.device)
    elif command == "forget":
        payload = do_forget(args.device)
    elif command == "repair":
        payload = do_repair(args.device)
    elif command == "mirror":
        payload = do_mirror(args.device, args.mouse)
    elif command == "live":
        payload = do_live(args.device, args.fps, args.out, args.paused)
    elif command == "pair":
        payload = do_pair(args.code, args.device)
    elif command == "apps":
        payload = do_apps(args.device, args.query, args.system)
    elif command == "launch":
        payload = do_launch(args.package, args.device, args.activity)
    elif command == "open":
        payload = do_open(args.url, args.device)
    elif command == "screen":
        payload = do_screen(args.device, args.query)
    elif command == "pointer":
        payload = do_pointer(args.device)
    elif command == "tap-text":
        payload = do_tap_text(args.label, args.device, args.index)
    elif command in ("tap", "swipe", "text", "key"):
        payload = do_input(command, args.values, args.device,
                           getattr(args, "stdin", False))
    elif command == "display":
        payload = do_display(args.state, args.device)
    elif command == "unlock":
        payload = do_unlock(args.device, args.stdin)
    elif command == "screenshot":
        payload = do_screenshot(args.out, args.device)
    elif command == "camera":
        payload = do_camera(args.device)
    elif command == "photo":
        payload = do_photo(
            mode=args.mode,
            target=args.device,
            out=args.out,
            camera=args.camera,
            torch=args.torch,
            roi=args.roi,
            ocr=not args.no_ocr,
            name=args.name,
            full=args.full,
            zoom=args.zoom,
        )
    elif command == "aim":
        payload = do_aim(args.mode, args.device)
    elif command == "heart":
        payload = do_heart(args.device, args.minutes, args.bucket, args.raw)
    elif command == "today":
        payload = do_today(args.device)
    elif command == "vitals":
        payload = do_vitals(args.device)
    elif command == "health-grant":
        payload = do_health_grant(args.device)
    else:
        payload = {"ok": False, "error": f"comando sconosciuto: {command}"}

    # Indentato solo verso un terminale: il server MCP legge questo stdout e
    # gli spazi in piu' sono soldi buttati in token.
    print(json.dumps(payload, ensure_ascii=False, indent=2 if sys.stdout.isatty() else None))

    return 0 if payload.get("ok") else 1


if __name__ == "__main__":
    sys.exit(main())
