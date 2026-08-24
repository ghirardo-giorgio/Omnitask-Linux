#!/usr/bin/env python3
"""Stato dei telefoni accoppiati: batteria e connessione, in un unico JSON.

Due implementazioni dello stesso protocollo possono rispondere, e non danno le
stesse cose:

  * `kdeconnectd` (org.kde.kdeconnect) espone un oggetto per plugin, batteria
    compresa: /modules/kdeconnect/devices/<id>/battery con `charge` e
    `isCharging`. E' la fonte buona.

  * GSConnect (org.gnome.Shell.Extensions.GSConnect) nelle versioni recenti
    pubblica su D-Bus solo l'interfaccia Device — nome, tipo, connesso,
    accoppiato — e tiene i plugin dentro il menu della shell, dove non sono
    dati ma voci di GMenu. Da li' la batteria non si legge.

Si interrogano tutti e due e si uniscono gli elenchi, invece di usare il
secondo solo quando manca il primo. Sulla stessa macchina possono girare
entrambi, e un telefono accoppiato con uno solo dei due esiste soltanto per
quello: col ripiego semplice un dispositivo aggiunto a GSConnect non sarebbe
mai comparso, perche' kdeconnectd rispondeva e nessuno andava a chiedere
all'altro. I due usano lo stesso identificativo per lo stesso telefono, quindi
unire e' solo questione di preferire la voce che porta anche la batteria.

Oltre a leggere, questo file sa fare due cose: mandare la clipboard al telefono
e farsela mandare. Sono le uniche, stanno dietro argomenti espliciti
(--send/--receive) e non passano mai dal percorso di lettura, per la stessa
ragione per cui Query.qml tiene `answer` separato da `act`: una domanda non
deve poter cambiare niente per sbaglio. Il server MCP infatti chiama solo la
lettura — la clipboard e' roba che si spinge premendo un pulsante, non
rispondendo a una domanda.

Si parla con `busctl --json=short`, non con gdbus: gdbus stampa GVariant, che
va fra apici o fra virgolette a seconda di cosa c'e' dentro la stringa, e
questo progetto ha gia' pagato quella lezione una volta (vedi unwrap in
winplace.py, dove bastava un apostrofo nel titolo di una finestra qualsiasi per
far fallire in silenzio ogni lettura). busctl il JSON lo produce lui.
"""
import json
import subprocess
import sys

# I percorsi scritti in ~/.config/quickshell/tools.json vincono sul PATH:
# vedi tools.py, che sta qui accanto.
import tools

TIMEOUT = 5

BUSCTL = tools.which("busctl")

KDE = "org.kde.kdeconnect"
KDE_DAEMON = "/modules/kdeconnect"
KDE_DEVICE = "org.kde.kdeconnect.device"
KDE_BATTERY = "org.kde.kdeconnect.device.battery"

GS = "org.gnome.Shell.Extensions.GSConnect"
GS_ROOT = "/org/gnome/Shell/Extensions/GSConnect"
GS_DEVICE = "org.gnome.Shell.Extensions.GSConnect.Device"
GS_ACTIONS = "org.gtk.Actions"

GS_NOTE = (
    "Letto da GSConnect, che su D-Bus pubblica solo nome, tipo e stato della "
    "connessione: la batteria sta nel menu della shell, non fra le proprieta', "
    "e da li' non si legge. Per averla serve kdeconnectd in esecuzione "
    "(pacchetto kdeconnect)."
)

# Perche' manca la percentuale. Codici e non frasi: la stessa risposta la legge
# il pannello, che la vuole tradotta nella lingua scelta, e il server MCP, che
# la vuole in inglese e distesa. Chi la mostra sceglie le parole; qui si dice
# solo quale dei quattro casi e'.
UNPAIRED = "unpaired"
UNREACHABLE = "unreachable"
NOT_REPORTED = "not_reported"
GSCONNECT_BLIND = "gsconnect_cannot_report"


def bus(*args):
    """Una chiamata a busctl, gia' spacchettata dal suo involucro JSON.

    busctl incarta ogni valore in {"type": ..., "data": ...}; qui interessa
    solo il dato. Restituisce None quando la chiamata non riesce — servizio
    assente, oggetto inesistente, timeout — perche' i tre casi si distinguono
    da chi chiama, che sa cosa stava cercando.
    """
    if not BUSCTL:
        return None

    try:
        done = subprocess.run(
            [BUSCTL, "--user", "--json=short"] + list(args),
            capture_output=True,
            text=True,
            timeout=TIMEOUT,
        )
    except (OSError, subprocess.SubprocessError):
        return None

    if done.returncode != 0 or not done.stdout.strip():
        return None

    try:
        return json.loads(done.stdout)["data"]
    except (ValueError, KeyError, TypeError):
        return None


def invoke(*args):
    """Una chiamata che non restituisce niente: conta solo se e' andata.

    Non si puo' usare `bus`, che giudica dall'output: qui l'output vuoto e'
    il successo. Restituisce il messaggio d'errore, o stringa vuota.
    """
    if not BUSCTL:
        return "busctl non e' installato"

    try:
        done = subprocess.run(
            [BUSCTL, "--user"] + list(args),
            capture_output=True,
            text=True,
            timeout=TIMEOUT,
        )
    except subprocess.TimeoutExpired:
        return "il demone non ha risposto in tempo"
    except (OSError, subprocess.SubprocessError) as exc:
        return f"chiamata fallita: {exc}"

    if done.returncode != 0:
        detail = (done.stderr or "").strip().splitlines()
        return detail[-1] if detail else "chiamata rifiutata dal demone"

    return ""


def properties(service, path, interface):
    """Tutte le proprieta' di un'interfaccia in una chiamata sola."""
    data = bus("call", service, path, "org.freedesktop.DBus.Properties",
               "GetAll", "s", interface)
    if not data:
        return {}
    return {
        key: value.get("data")
        for key, value in data[0].items()
        if isinstance(value, dict)
    }


def rescan():
    """Chiede al demone di riannunciarsi sulla rete e ricontare chi risponde.

    Un telefono acceso adesso, o passato ora sul Wi-Fi di casa, il demone non
    lo conosce finche' non ci ripassa sopra da solo. Questo e' l'unico punto
    del file che *fa* qualcosa invece di leggere, e per questo non sta nel
    giro periodico: lo chiama il pannello quando viene acceso e quando gli si
    chiede esplicitamente di rileggere, non ogni trenta secondi.
    """
    bus("call", KDE, KDE_DAEMON, "org.kde.kdeconnect.daemon",
        "forceOnNetworkChange")


# ------------------------------------------------------------- kdeconnectd


def from_kdeconnect():
    listed = bus("call", KDE, KDE_DAEMON, "org.kde.kdeconnect.daemon",
                 "deviceNames")
    if not listed:
        return None

    out = []

    for device_id, fallback_name in sorted(
            listed[0].items(), key=lambda pair: pair[1].lower()):
        path = f"{KDE_DAEMON}/devices/{device_id}"
        info = properties(KDE, path, KDE_DEVICE)

        reachable = bool(info.get("isReachable"))
        paired = bool(info.get("isPaired"))

        entry = {
            "id": device_id,
            "name": info.get("name") or fallback_name,
            "type": info.get("type", ""),
            "reachable": reachable,
            "paired": paired,
            # L'indirizzo da cui risponde adesso: dice su quale rete e' il
            # telefono, che e' meta' della risposta a "perche' non si collega".
            "addresses": info.get("reachableAddresses") or [],
            "battery": None,
        }

        # Gli oggetti dei plugin esistono solo mentre il dispositivo e'
        # collegato: per un telefono spento non c'e' nessun .../battery da
        # interrogare. Distinguere i due casi conta — una percentuale assente
        # non e' una batteria a zero, e mostrare 0% per un telefono che sta
        # benissimo sarebbe una risposta sbagliata invece che mancante.
        if not paired:
            entry["battery_unknown"] = UNPAIRED
        elif not reachable:
            entry["battery_unknown"] = UNREACHABLE
        else:
            battery = properties(KDE, f"{path}/battery", KDE_BATTERY)
            charge = battery.get("charge")
            if isinstance(charge, int) and charge >= 0:
                entry["battery"] = {
                    "percent": charge,
                    "charging": bool(battery.get("isCharging")),
                }
            else:
                entry["battery_unknown"] = NOT_REPORTED

        out.append(entry)

    return {"ok": True, "source": "kdeconnectd", "devices": out}


# --------------------------------------------------------------- GSConnect


def from_gsconnect():
    managed = bus("call", GS, GS_ROOT, "org.freedesktop.DBus.ObjectManager",
                  "GetManagedObjects")
    if not managed:
        return None

    out = []

    for path, interfaces in managed[0].items():
        info = interfaces.get(GS_DEVICE)
        if not info:
            continue

        fields = {
            key: value.get("data")
            for key, value in info.items()
            if isinstance(value, dict)
        }

        out.append({
            "id": fields.get("Id", path.rsplit("/", 1)[-1]),
            "name": fields.get("Name", ""),
            "type": fields.get("Type", ""),
            "reachable": bool(fields.get("Connected")),
            "paired": bool(fields.get("Paired")),
            "addresses": [],
            "battery": None,
            "battery_unknown": GSCONNECT_BLIND,
        })

    out.sort(key=lambda d: d["name"].lower())
    return {"ok": True, "source": "gsconnect", "devices": out, "note": GS_NOTE}


# --------------------------------------------------------------- clipboard


def clipboard_capabilities(entry):
    """Se questo dispositivo sa mandare e ricevere la clipboard, chiesto a lui.

    Non si deduce da quale demone lo conosce, che era la scorciatoia
    sbagliata: le azioni di GSConnect sono per dispositivo, e un telefono
    accoppiato con kdeconnectd ma non con GSConnect compare comunque
    nell'elenco di quest'ultimo — con sei sole azioni, giusto per accoppiarlo.
    Misurato: due telefoni con 33 azioni e clipboardPull, un terzo con 6 e
    nessuna delle due. Dedurlo avrebbe messo a video una freccia che al clic
    rispondeva "Unknown action".

    Solo per i dispositivi vivi: uno spento non fa niente comunque, e
    risparmia due chiamate a testa.
    """
    entry["can_send"] = False
    entry["can_receive"] = False

    if not (entry["paired"] and entry["reachable"]):
        return

    if "kdeconnectd" in entry["known_to"]:
        # L'oggetto del plugin esiste solo se il plugin e' caricato: se manca,
        # `properties` torna vuoto e non c'e' niente a cui parlare.
        loaded = properties(
            KDE, f"{KDE_DAEMON}/devices/{entry['id']}/clipboard",
            "org.kde.kdeconnect.device.clipboard")
        entry["can_send"] = bool(loaded)

    if "gsconnect" in entry["known_to"]:
        listed = bus("call", GS, f"{GS_ROOT}/Device/{entry['id']}",
                     GS_ACTIONS, "List")
        actions = listed[0] if listed else []
        entry["can_send"] = entry["can_send"] or "clipboardPush" in actions
        # kdeconnectd non ha proprio un modo di chiedere la clipboard al
        # telefono: espone il solo sendClipboard, e la direzione opposta la
        # apre il telefono. Quindi ricevere passa per forza da GSConnect.
        entry["can_receive"] = "clipboardPull" in actions


def find_device(device_id):
    """Chi conosce questo dispositivo, fra i due demoni."""
    report = collect()
    for entry in report.get("devices", []):
        if entry["id"] == device_id:
            return entry
    return None


def send_clipboard(device_id):
    """La clipboard di questo PC finisce su quella del telefono."""
    device = find_device(device_id)
    if device is None:
        return {"ok": False, "error": f"dispositivo sconosciuto: {device_id}"}
    if not device["can_send"]:
        return {"ok": False, "error": "dispositivo non accoppiato o non raggiungibile"}

    # kdeconnectd per primo quando lo conosce: e' il demone che tiene anche la
    # batteria, quindi e' quello che sicuramente sta parlando col telefono.
    if "kdeconnectd" in device["known_to"]:
        error = invoke(
            "call", KDE, f"{KDE_DAEMON}/devices/{device_id}/clipboard",
            "org.kde.kdeconnect.device.clipboard", "sendClipboard")
        if not error:
            return {"ok": True, "action": "send", "device": device["name"],
                    "via": "kdeconnectd"}

    if "gsconnect" in device["known_to"]:
        error = invoke(
            "call", GS, f"{GS_ROOT}/Device/{device_id}", GS_ACTIONS,
            "Activate", "sava{sv}", "clipboardPush", "0", "0")
        if not error:
            return {"ok": True, "action": "send", "device": device["name"],
                    "via": "gsconnect"}

    return {"ok": False, "error": error or "nessun demone ha accettato l'invio"}


def receive_clipboard(device_id):
    """La clipboard del telefono finisce su quella di questo PC.

    Solo via GSConnect: kdeconnectd non ha un metodo per chiedere, la sua
    direzione entrante la apre il telefono.
    """
    device = find_device(device_id)
    if device is None:
        return {"ok": False, "error": f"dispositivo sconosciuto: {device_id}"}
    if not device["can_receive"]:
        return {
            "ok": False,
            "error": (
                "kdeconnectd non sa chiedere la clipboard al telefono: ha il "
                "solo sendClipboard. Serve GSConnect, che ha clipboardPull — "
                "oppure si manda dal telefono."
            ),
        }

    error = invoke(
        "call", GS, f"{GS_ROOT}/Device/{device_id}", GS_ACTIONS,
        "Activate", "sava{sv}", "clipboardPull", "0", "0")

    if error:
        return {"ok": False, "error": error}

    return {"ok": True, "action": "receive", "device": device["name"],
            "via": "gsconnect"}


# ------------------------------------------------------------------ report


def collect(scan=False):
    if not BUSCTL:
        return {
            "ok": False,
            "error": "busctl non e' installato: senza non si legge il bus di sessione.",
            "devices": [],
        }

    if scan:
        rescan()

    kde = from_kdeconnect()
    gs = from_gsconnect()

    if kde is None and gs is None:
        return {
            "ok": False,
            "error": (
                "nessun demone KDE Connect in ascolto sul bus di sessione. "
                "Avvia kdeconnectd, oppure abilita l'estensione GSConnect."
            ),
            "devices": [],
        }

    # Uniti per identificativo: lo stesso telefono ha lo stesso id dai due
    # lati. Vince la voce di kdeconnectd perche' e' l'unica che porta la
    # batteria; da GSConnect si prendono i dispositivi che lui solo conosce.
    merged = {}

    for entry in (kde or {}).get("devices", []):
        entry["known_to"] = ["kdeconnectd"]
        merged[entry["id"]] = entry

    for entry in (gs or {}).get("devices", []):
        seen = merged.get(entry["id"])
        if seen:
            seen["known_to"].append("gsconnect")
            continue
        entry["known_to"] = ["gsconnect"]
        merged[entry["id"]] = entry

    for entry in merged.values():
        clipboard_capabilities(entry)

    devices = sorted(merged.values(), key=lambda d: d["name"].lower())

    sources = [name for name, report in
               (("kdeconnectd", kde), ("gsconnect", gs)) if report is not None]

    out = {
        "ok": True,
        "source": "+".join(sources),
        "devices": devices,
    }

    # La nota di GSConnect serve solo se c'e' qualcosa che dipende da lui: con
    # kdeconnectd che risponde per tutti, spiegare cosa non sa fare l'altro e'
    # rumore.
    if any(d["known_to"] == ["gsconnect"] for d in devices):
        out["note"] = GS_NOTE

    return out


if __name__ == "__main__":
    args = sys.argv[1:]

    def value_after(flag):
        return args[args.index(flag) + 1] if flag in args and len(args) > args.index(flag) + 1 else ""

    if "--send" in args:
        result = send_clipboard(value_after("--send"))
    elif "--receive" in args:
        result = receive_clipboard(value_after("--receive"))
    else:
        # --rescan fa prima una scoperta attiva sulla rete: costa un annuncio
        # broadcast e un attimo di attesa, quindi lo chiede chi ha motivo di
        # aspettarsi un dispositivo nuovo, non il giro periodico.
        result = collect("--rescan" in args)

    json.dump(result, sys.stdout, ensure_ascii=False)
    sys.stdout.write("\n")
    raise SystemExit(0 if result.get("ok") else 1)
