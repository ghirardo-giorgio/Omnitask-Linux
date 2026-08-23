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

L'autorizzazione resta sempre e solo sul telefono: la chiave RSA la si conferma
li' la prima volta, e il codice di pairing lo legge l'utente dallo schermo.
Qui non c'e' niente che possa aggirare quel passaggio, ne' che lo voglia.

Oltre a comandare, sa leggere: `screen` restituisce le scritte presenti sullo
schermo con il punto dove toccarle, e `tap-text` prende l'etichetta al posto
delle coordinate. Sono la coppia che serve a un modello per lavorare senza
indovinare pixel — guarda, tocca, riguarda.

Sa anche scattare: `photo` comanda MacroCam, l'app headless che sceglie fra
ottica normale e macro, legge il testo con l'OCR e lascia la foto dove adb la
puo' prendere. `aim` apre il mirino sul telefono, che serve la prima volta su
un soggetto nuovo — un macro inquadra pochi centimetri quadrati e a mano si
punta alla cieca — e da li' in poi ogni scatto esce gia' ritagliato sull'area
scelta. `camera` invece guarda e basta: le lenti come le racconta la HAL,
anche senza l'app installata.

Le letture (`status`, `apps`, `screen`, `camera`) e le azioni (`connect`, `pair`,
`launch`, `input`, `tap-text`, `open`, `screenshot`, `photo`, `aim`) stanno in sottocomandi separati per la stessa
ragione per cui kdeconnect.py tiene --send dietro un argomento esplicito: il
server MCP espone le due famiglie come due tool distinti, e una domanda non
deve poter toccare il telefono per sbaglio.
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

HERE = os.path.dirname(os.path.abspath(__file__))
KDECONNECT = os.path.join(HERE, "kdeconnect.py")

ADB = shutil.which("adb")
AVAHI = shutil.which("avahi-browse")

TIMEOUT = 20

PAIRING = "_adb-tls-pairing._tcp"
CONNECT = "_adb-tls-connect._tcp"

# Porta del debug wireless "vecchio stile", quello aperto con `adb tcpip`.
# Fissa per definizione: e' il numero che si scrive a mano da sempre.
LEGACY_PORT = 5555

NO_ADB = "adb non e' installato (pacchetto android-tools)"
NO_AVAHI = (
    "avahi-browse non e' installato: senza mDNS le porte del debug wireless "
    "vanno lette a mano dal telefono"
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
    announced = {entry["ip"]: entry["port"] for entry in seen[CONNECT]}
    pairing = {entry["ip"]: entry["port"] for entry in seen[PAIRING]}
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
            # La porta annunciata cambia a ogni accensione del debug wireless:
            # e' un dato di adesso, non una configurazione da ricordare.
            "wireless_debugging": ip in announced,
            "wireless_port": announced.get(ip, 0),
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
            "wireless_port": 0,
            "pairing_open": False,
            "via": "usb" if ":" not in serial else "wireless",
        })

    return out


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

    needle = target.lower()
    flat = flatten(target)
    hits = [
        d for d in view
        if needle in (d["name"] or "").lower()
        or (flat and flat in flatten(d["name"]))
        or needle == d["ip"]
        or needle == d["serial"].lower()
        or needle == d["id"].lower()
    ]

    if not hits:
        return None, f"nessun telefono corrisponde a «{target}»"

    ready = [d for d in hits if d["connected"]]

    if not ready:
        state = hits[0]["adb"] or "non collegato ad adb"
        return None, f"«{target}» c'e' ma non e' utilizzabile: {state}"

    return ready[0], ""


# ------------------------------------------------------------------ azioni


def do_connect(target=""):
    """Collega ad adb i telefoni raggiungibili, senza scrivere porte.

    Si prova prima la porta annunciata via mDNS, che e' quella del debug
    wireless di Android 11+, e poi la 5555 di `adb tcpip`: un telefono ha una
    delle due, mai tutte e due, e provarle entrambe evita di dover sapere in
    anticipo di che generazione e'.
    """
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
        ports = [device["wireless_port"]] if device["wireless_port"] else []
        ports.append(LEGACY_PORT)

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
                "il telefono non annuncia il debug wireless: accendilo in "
                "Opzioni sviluppatore → Debug wireless, poi rifai `pair` se "
                "e' la prima volta"
            )

        results.append(outcome)

    # La chiave RSA si conferma sul telefono, e finche' non lo si fa il device
    # resta "unauthorized": dirlo qui evita di far cercare il guasto altrove.
    live = attached()
    unauthorized = [s for s, state in live.items() if state == "unauthorized"]

    return {
        "ok": any(r["ok"] for r in results),
        "results": results,
        "unauthorized": unauthorized,
        "note": (
            "conferma la richiesta «Consentire il debug USB?» sullo schermo del "
            "telefono" if unauthorized else ""
        ),
    }


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

    if action == "text":
        text = sys.stdin.read().rstrip("\n") if from_stdin else " ".join(values)

        if not text:
            return {"ok": False, "error": "nessun testo da scrivere"}

        # `input text` prende un argomento solo e degli spazi non sa che fare:
        # la sequenza %s e' il modo con cui Android li scrive.
        args = ["shell", "input", "text", text.replace(" ", "%s")]
    elif action == "key":
        key = values[0] if values else ""

        if not key.isdigit() and not key.upper().startswith("KEYCODE_"):
            key = "KEYCODE_" + key.upper()

        args = ["shell", "input", "keyevent", key]
    elif action in ("tap", "swipe"):
        if not all(v.lstrip("-").isdigit() for v in values):
            return {"ok": False, "error": f"{action} vuole coordinate in pixel"}

        if action == "tap" and len(values) != 2:
            return {"ok": False, "error": "tap vuole due coordinate: X Y"}

        if action == "swipe" and len(values) not in (4, 5):
            return {"ok": False, "error": "swipe vuole X1 Y1 X2 Y2 [durata_ms]"}

        args = ["shell", "input", action] + list(values)
    else:
        return {"ok": False, "error": f"azione sconosciuta: {action}"}

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

    pin = sys.stdin.read().strip() if from_stdin else ""

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


def do_screenshot(path="", target=""):
    """Salva uno screenshot PNG e restituisce il percorso.

    `exec-out` e non `shell`: quest'ultimo passa da uno pty che sostituisce i
    ritorni a capo e consegna un PNG corrotto, un classico di adb.
    """
    view = devices_view(discover=False)
    device, why = pick(view, target)

    if not device:
        return {"ok": False, "error": why}

    ok, data, err = shell(device, "exec-out", "screencap", "-p", binary=True, timeout=60)

    if not ok or not data:
        return {"ok": False, "error": err or "screencap non ha prodotto niente"}

    # Un PNG finisce con il chunk IEND: quattro byte di lunghezza a zero, il
    # nome, e il CRC. Guardare solo l'intestazione non basta — una sessione che
    # muore a meta' trasferimento lascia un file che comincia benissimo e non
    # finisce, e chi lo apre dopo si trova un errore di decodifica al posto di
    # una spiegazione.
    if not data.startswith(b"\x89PNG") or not data.endswith(b"\x00\x00\x00\x00IEND\xaeB`\x82"):
        return {
            "ok": False,
            "error": "l'immagine e' arrivata incompleta: il collegamento si e' "
                     "interrotto a meta' — riprova, e se insiste stacca e "
                     "riattacca il cavo",
            "bytes": len(data),
        }

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


def do_status():
    """Chi c'e', come e cosa manca perche' sia utilizzabile."""
    if not ADB:
        return {"ok": False, "error": NO_ADB}

    view = devices_view()

    hints = []

    for device in view:
        if device["connected"]:
            continue

        who = device["name"] or device["ip"] or device["serial"]

        if device["adb"] == "unauthorized":
            hints.append(f"{who}: conferma la chiave RSA sullo schermo del telefono")
        elif device["adb"] == "offline":
            # Il telefono e' attaccato ma la sessione e' morta. Qui si e' gia'
            # provato `adb reconnect` una volta: se e' ancora offline serve una
            # mano fisica. Compare col serial invece che col nome perche' senza
            # sessione non si puo' chiedere il modello a cui associarlo.
            hints.append(
                f"{who}: collegamento offline — stacca e riattacca il cavo, "
                "oppure prova un'altra porta USB"
            )
        elif device["pairing_open"]:
            hints.append(f"{who}: sta chiedendo il codice — lancia `pair <codice>`")
        elif device["wireless_debugging"]:
            hints.append(f"{who}: debug wireless acceso, basta `connect`")
        elif device["ip"]:
            hints.append(
                f"{who}: debug wireless spento (Opzioni sviluppatore → Debug wireless)"
            )

    return {
        "ok": True,
        "devices": view,
        "connected": [d["name"] or d["serial"] for d in view if d["connected"]],
        "mdns": bool(AVAHI),
        "hints": hints,
        "note": "" if AVAHI else NO_AVAHI,
    }


# -------------------------------------------------------------------- cli


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--device", default="", help="nome, indirizzo o serial del telefono")
    sub = parser.add_subparsers(dest="command")

    sub.add_parser("status", help="telefoni, stato adb e cosa manca")
    sub.add_parser("connect", help="collega ad adb chi e' raggiungibile")
    sub.add_parser("disconnect", help="stacca la connessione wireless")

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

    args = parser.parse_args()
    command = args.command or "status"

    if command == "status":
        payload = do_status()
    elif command == "connect":
        payload = do_connect(args.device)
    elif command == "disconnect":
        payload = do_disconnect(args.device)
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
    else:
        payload = {"ok": False, "error": f"comando sconosciuto: {command}"}

    # Indentato solo verso un terminale: il server MCP legge questo stdout e
    # gli spazi in piu' sono soldi buttati in token.
    print(json.dumps(payload, ensure_ascii=False, indent=2 if sys.stdout.isatty() else None))

    return 0 if payload.get("ok") else 1


if __name__ == "__main__":
    sys.exit(main())
