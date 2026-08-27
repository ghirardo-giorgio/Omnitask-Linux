#!/usr/bin/env python3
"""MacroCam senza cavo: gli stessi scatti, chiesti in HTTP invece che con adb.

E' il gemello di `phone_adb.do_photo` per la versione web dell'app
(~/Documents/Development/macrocam-web). Il vocabolario e' identico — modo,
area, ingrandimento, torcia — e anche la forma di quello che torna, cosi' chi
scattava con l'uno puo' scattare con l'altro cambiando una riga.

Cosa cambia davvero, e non e' il trasporto:

  * **Non serve lo schermo.** `am start` doveva accendere il telefono, togliere
    di mezzo la schermata di blocco e poi rimandarlo a dormire; qui la porta la
    tiene aperta un servizio in primo piano, e il telefono puo' restare uno
    schermo nero appoggiato sul banco.
  * **La risposta torna a chi ha chiesto.** Niente contatore `seq` da guardare
    finche' non cambia: la POST resta aperta finche' lo scatto non e' finito, e
    il JSON e' il suo corpo.
  * **Non serve il debug USB.** Che e' l'unica ragione per cui esisteva la meta'
    complicata di phone_adb: porte mDNS sorteggiate a ogni accensione,
    accoppiamenti, chiavi RSA. Qui c'e' un indirizzo e una chiave.

L'indirizzo non si scrive da nessuna parte, per lo stesso motivo per cui non lo
scrive phone_adb: lo sa gia' KDE Connect. Il telefono si chiama `OPG02_jp_kdi`
sia per adb sia per questa parte, e il DHCP puo' spostarlo quanto vuole. Quello
che va scritto e' solo la chiave, che nessuno puo' dedurre: sta in
~/.config/quickshell/macrocam.json, insieme al nome del telefono a cui
appartiene.

    {
      "phones": {
        "OPG02_jp_kdi": {"token": "q7ab4xg3y"}
      }
    }

La chiave la mostra l'app col QR. Su una build di debug si puo' anche farsela
leggere da qui: `macrocam_web.py token --device OPG02_jp_kdi`, che e' un giro da
adb e serve una volta sola.

**Un telefono che accetta la connessione e non risponde non e' rotto: e'
congelato.** Il risparmio energetico di ColorOS mette in freezer i processi a
schermo spento — servizio in primo piano compreso — e da fuori la differenza
con un guasto di rete non si vede, perche' la porta continua ad accettare: ad
accettare e' il kernel. Si sistema una volta sola, esentando l'app:

    adb shell dumpsys deviceidle whitelist +com.oberon.macrocamweb

Misurato sull'OPG02: senza esenzione, ogni richiesta a schermo spento moriva di
timeout; con l'esenzione, `/api/state` risponde in cinquanta millisecondi a
telefono addormentato.
"""
import argparse
import json
import os
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
KDECONNECT = os.path.join(HERE, "kdeconnect.py")

CONFIG = os.path.expanduser("~/.config/quickshell/macrocam.json")

# L'ultimo indirizzo che ha risposto. E' un appunto, non una configurazione:
# la verita' e' KDE Connect, e questo serve solo quando KDE Connect e' fermo o
# non ha ancora rivisto il telefono dopo un cambio di rete.
CACHE = os.path.join(
    os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache"),
    "quickshell",
    "macrocam-web.json",
)

PACKAGE = "com.oberon.macrocamweb"
DEFAULT_PORT = 8420

# Tre timeout per tre domande diverse. Chiedere "ci sei?" a un indirizzo che
# non c'e' deve costare poco, perche' lo si chiede anche all'indirizzo
# sbagliato; una risposta breve arriva in millisecondi ma un'immagine da due
# megabyte no; uno scatto costa quanto ci mette la camera.
#
# Nessuno dei tre e' generoso, ed e' voluto: la cosa piu' probabile quando
# questo server non risponde non e' che sia lento, e' che sia congelato (vedi
# FROZEN). Aspettare un minuto non lo sveglia, ritarda solo il momento in cui
# qualcuno lo scopre.
REACH_TIMEOUT = 2.0
TIMEOUT = 15
SHOT_TIMEOUT = 45

# Cosa dire quando la porta accetta ma nessuno risponde.
#
# E' successo davvero, e per mezz'ora e' sembrato un guasto della rete: su
# ColorOS il gestore di risparmio energetico (OplusHansManager, "HANS") congela
# i processi quando si spegne lo schermo, servizio in primo piano compreso. Il
# socket resta in ascolto perche' ad accettare le connessioni e' il kernel, ma
# nessun thread dell'app gira piu' e ogni richiesta muore di timeout. A
# scongelarlo basterebbe una chiamata binder, e una connessione TCP non lo e'.
#
# Non e' una cosa che si possa riparare da questa parte: si puo' solo
# riconoscerla e dire dove si ripara.
FROZEN = (
    "il telefono accetta la connessione ma non risponde entro %ds. Di solito "
    "vuol dire che il risparmio energetico ha congelato l'app a schermo spento: "
    "mettila fra le esenzioni con `adb shell dumpsys deviceidle whitelist "
    "+" + PACKAGE + "`, oppure dalle impostazioni della batteria del telefono "
    "(su ColorOS: Batteria -> Consumo in background -> Consenti)"
)

NO_CONFIG = (
    "nessuna chiave per MacroCam Web: scrivila in %s. La mostra l'app col QR "
    "(oppure, su una build di debug, `macrocam_web.py token --device NOME`)"
    % CONFIG
)


# ------------------------------------------------------------ configurazione


def flatten(name):
    """Un nome ridotto all'osso, per confrontarne due che non si scrivono uguale.

    Stessa regola di phone_adb: lo stesso telefono e' "moto g(8) plus" per adb e
    "moto g8 plus" per KDE Connect, e due parentesi non devono bastare a farlo
    sembrare un altro.
    """
    return "".join(c for c in (name or "").lower() if c.isalnum())


def config():
    """La configurazione, o un dizionario vuoto se non c'e'.

    Non e' un errore fatale che manchi: chi chiama puo' avere una strada
    alternativa — solar_meter.py ha ancora quella con adb — e farlo morire qui
    vorrebbe dire togliergliela.
    """
    try:
        with open(CONFIG, encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        return {}

    return data if isinstance(data, dict) else {}


def phones(data=None):
    """Nome del telefono -> quello che sappiamo di lui."""
    data = config() if data is None else data
    known = data.get("phones")

    if not isinstance(known, dict):
        return {}

    return {k: v for k, v in known.items() if isinstance(v, dict)}


def entry(target="", data=None):
    """La voce di configurazione per questo telefono, e il suo nome vero.

    `target` si puo' scrivere come viene: vuoto vuol dire "l'unico che c'e'"
    (o quello indicato da `default`), e un nome parziale basta se non e'
    ambiguo — chi scrive a mano `OPG02` non deve ricordarsi la coda `_jp_kdi`.
    """
    data = config() if data is None else data
    known = phones(data)

    if not known:
        return "", {}, NO_CONFIG

    if not target:
        target = data.get("default") or ""

    if not target:
        if len(known) == 1:
            name = next(iter(known))
            return name, known[name], ""

        return "", {}, "quale telefono? Ne conosco %s" % ", ".join(sorted(known))

    wanted = flatten(target)
    hits = [n for n in known if flatten(n) == wanted]

    if not hits:
        hits = [n for n in known if wanted and wanted in flatten(n)]

    if not hits:
        return "", {}, "%s non e' fra i telefoni configurati (%s)" % (
            target, ", ".join(sorted(known)))

    if len(hits) > 1:
        return "", {}, "%s corrisponde a piu' telefoni: %s" % (target, ", ".join(sorted(hits)))

    return hits[0], known[hits[0]], ""


def cache_load():
    try:
        with open(CACHE, encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        return {}

    return data if isinstance(data, dict) else {}


def cache_save(name, host):
    """Ricorda l'indirizzo che ha risposto, senza fare storie se non ci riesce.

    Perdere questo file costa una scoperta in piu' alla prossima chiamata, non
    una lettura: non vale un'eccezione che risalga fino a chi voleva una foto.
    """
    known = cache_load()

    if known.get(name, {}).get("host") == host:
        return

    known[name] = {"host": host, "seen": time.strftime("%Y-%m-%d %H:%M:%S")}
    tmp = CACHE + ".tmp"

    try:
        os.makedirs(os.path.dirname(CACHE), exist_ok=True)

        with open(tmp, "w", encoding="utf-8") as handle:
            json.dump(known, handle, ensure_ascii=False, indent=2)

        os.replace(tmp, CACHE)
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass


# ------------------------------------------------------------- l'indirizzo


def kde_address(name):
    """L'indirizzo che KDE Connect vede adesso per questo telefono.

    E' la stessa fonte che usa phone_adb per dare un nome agli indirizzi, letta
    dallo stesso script: due copie della stessa domanda avrebbero due risposte
    diverse il giorno in cui una delle due sbaglia.
    """
    try:
        done = subprocess.run(
            [sys.executable, KDECONNECT],
            capture_output=True, text=True, timeout=15,
        )
        data = json.loads(done.stdout)
    except (OSError, subprocess.SubprocessError, ValueError):
        return ""

    if not data.get("ok"):
        return ""

    wanted = flatten(name)

    for device in data.get("devices", []):
        if flatten(device.get("name", "")) != wanted:
            continue

        for address in device.get("addresses") or []:
            if address:
                return address

    return ""


def answers(host, port):
    """Vero se dietro quell'indirizzo c'e' qualcosa in ascolto.

    Una connessione TCP e non una richiesta HTTP: quello che serve sapere e' se
    l'indirizzo e' ancora quello del telefono, e per rispondere basta il
    saluto. La chiave e le rotte si sbagliano dopo, con calma.
    """
    try:
        with socket.create_connection((host, port), REACH_TIMEOUT):
            return True
    except OSError:
        return False


def base(target="", data=None):
    """L'indirizzo a cui parlare, e il nome del telefono a cui appartiene.

    Prima quello che dice KDE Connect, poi quello scritto a mano nella
    configurazione, poi l'ultimo che aveva risposto. Non si sceglie il primo
    della lista: si sceglie il primo che risponde, perche' un telefono appena
    spostato di rete ha ancora un indirizzo vecchio in giro da qualche parte e
    provarlo costa due secondi mentre crederci costa la lettura.
    """
    name, phone, why = entry(target, data)

    if not name:
        return "", "", why

    if not phone.get("token"):
        return "", name, "manca la chiave di %s in %s" % (name, CONFIG)

    port = int(phone.get("port") or (data or config()).get("port") or DEFAULT_PORT)

    candidates = []

    for host in (kde_address(name), phone.get("host", ""), cache_load().get(name, {}).get("host", "")):
        if host and host not in candidates:
            candidates.append(host)

    if not candidates:
        return "", name, ("nessun indirizzo per %s: KDE Connect non lo vede e non "
                          "ne ho uno in memoria" % name)

    for host in candidates:
        if answers(host, port):
            cache_save(name, host)
            return "http://%s:%d" % (host, port), name, ""

    return "", name, "%s non risponde sulla porta %d (provati: %s). Il server e' " \
                     "acceso nell'app?" % (name, port, ", ".join(candidates))


# ------------------------------------------------------------- le richieste


def call(url, token, path, payload=None, timeout=TIMEOUT, binary=False):
    """Una chiamata all'app, GET o POST secondo il payload.

    La chiave viaggia nell'intestazione e non nell'indirizzo: nell'indirizzo ci
    sta per il QR, che deve entrare in un'inquadratura, e non e' un buon motivo
    per farla finire anche nei log di chiunque.
    """
    body = json.dumps(payload).encode() if payload is not None else None

    request = urllib.request.Request(
        url + path,
        data=body,
        headers={"X-Macrocam-Token": token, "Content-Type": "application/json"},
        method="POST" if payload is not None else "GET",
    )

    with urllib.request.urlopen(request, timeout=timeout) as answer:
        return answer.read() if binary else json.load(answer)


def fetch(url, token, remote, local, timeout=TIMEOUT):
    """Scarica un file degli scatti sul PC. Il nome basta, il percorso no.

    L'app espone la sua cartella e nient'altro, quindi di un percorso lungo come
    /storage/emulated/0/Android/data/.../foto.jpg quello che serve e' la coda.
    """
    try:
        data = call(url, token, "/shot/" + os.path.basename(remote), timeout=timeout, binary=True)
    except (urllib.error.URLError, OSError, ValueError):
        return False

    try:
        with open(local, "wb") as handle:
            handle.write(data)
    except OSError:
        return False

    return True


# Com'era la camera prima che questo processo la toccasse: None finche' non
# lo si e' guardato, poi True se qualcuno la stava gia' usando.
#
# Si guarda una volta sola e non a ogni scatto, ed e' la differenza fra una
# cortesia e un errore. Dal secondo scatto in poi la camera e' aperta perche'
# l'abbiamo aperta noi: chiederlo di nuovo darebbe "aperta, quindi non e'
# nostra, quindi non la chiudo", e un timer che scatta due volte per lettura la
# lascerebbe accesa per sempre — cioe' proprio la cosa che questa cortesia
# doveva evitare. La memoria vale per la durata del processo, che per uno
# script a colpo singolo e' esattamente la durata della faccenda.
_found_open = None

# La camera che abbiamo aperto noi e che tocca a noi richiudere, con le
# credenziali per farlo: (indirizzo, chiave).
_ours = None


def fail(error, name=""):
    out = {"ok": False, "error": error}

    if name:
        out["device"] = name

    return out


def do_state(target=""):
    """Cosa sta facendo il telefono: lente aperta, area, ingrandimento, ultimo scatto."""
    url, name, why = base(target)

    if not url:
        return fail(why, name)

    _, phone, _ = entry(target)

    try:
        state = call(url, phone["token"], "/api/state")
    except urllib.error.HTTPError as exc:
        return fail(http_reason(exc), name)
    except (urllib.error.URLError, OSError, ValueError) as exc:
        return fail(reason(exc, TIMEOUT), name)

    state["ok"] = state.get("state") == "ok"
    state["device"] = name
    state["url"] = url

    return state


def do_probe(target=""):
    """Cosa c'e' dietro al vetro: le lenti, comprese quelle non elencate."""
    url, name, why = base(target)

    if not url:
        return fail(why, name)

    _, phone, _ = entry(target)

    try:
        found = call(url, phone["token"], "/api/probe")
    except urllib.error.HTTPError as exc:
        return fail(http_reason(exc), name)
    except (urllib.error.URLError, OSError, ValueError) as exc:
        return fail(reason(exc, TIMEOUT), name)

    found["ok"] = found.get("state") == "ok"
    found["device"] = name

    return found


def timed_out(exc):
    """Vero se questa eccezione e' un'attesa scaduta e non un rifiuto."""
    if isinstance(exc, TimeoutError):
        return True

    return isinstance(exc, urllib.error.URLError) and isinstance(exc.reason, TimeoutError)


def reason(exc, timeout):
    """Il motivo, detto in modo che si sappia dove andare a guardare."""
    if timed_out(exc):
        return FROZEN % timeout

    return str(exc)


def http_reason(exc):
    """Il motivo che l'app ha scritto nel corpo, non il numero del protocollo.

    Un 401 e' "chiave sbagliata" e un 503 e' "la camera non e' aperta": sono
    due cose da riparare in due posti diversi, e il numero da solo non lo dice.
    """
    try:
        body = json.loads(exc.read().decode("utf-8", "replace"))
        told = body.get("error")
    except (ValueError, OSError):
        told = ""

    if told:
        return told

    if exc.code == 401:
        return "chiave rifiutata: quella in %s non e' quella dell'app" % CONFIG

    return "l'app ha risposto %s" % exc.code


def do_photo(mode="normal", target="", out="", camera="", torch=False,
             roi="", ocr=True, name="", full=False, zoom="", script="",
             release="auto"):
    """Uno scatto, e i file che ne escono, sul PC.

    Restituisce le stesse chiavi di `phone_adb.do_photo` — ok, text, path,
    roi, took_ms — perche' chi le legge non deve sapere da quale delle due
    strade sono arrivate.

    `roi` vuoto vuol dire "quella che ha il telefono", come nell'altra: l'area
    la riquadra chi guarda l'anteprima, e imporla a ogni scatto vorrebbe dire
    cancellare quel lavoro dieci minuti dopo senza dire niente.

    `release` e' la cortesia che nell'altra strada era rimandare a dormire il
    telefono. Un timer che scatta ogni dieci minuti non ha nessun motivo di
    tenere una camera accesa nei nove e mezzo in cui non serve, ne' di
    spegnerla in faccia a chi sta inquadrando dal browser: `auto` segna la
    camera come nostra se l'abbiamo trovata chiusa, e la richiude `tidy()`
    quando chi scattava ha finito. `always` la chiude subito, `never` la
    lascia dov'e'.
    """
    data = config()
    url, phone_name, why = base(target, data)

    if not url:
        return fail(why, phone_name)

    _, phone, _ = entry(target, data)
    token = phone["token"]

    # Com'era prima di toccare niente: e' l'unica cosa che dice se la camera
    # aperta e' nostra o di qualcun altro, e dopo lo scatto non si sa piu'.
    global _found_open

    if release == "auto" and _found_open is None:
        try:
            _found_open = bool(call(url, token, "/api/state").get("running"))
        except (urllib.error.URLError, OSError, ValueError):
            # Non sapere com'era prima non e' un motivo per non scattare: al
            # massimo si lascia la camera aperta, che e' l'esito piu' innocuo
            # dei due.
            _found_open = True

    payload = {"mode": mode, "ocr": bool(ocr)}

    if camera:
        payload["camera"] = str(camera)
    if torch:
        payload["torch"] = True
    if roi:
        payload["roi"] = roi
    if zoom:
        payload["zoom"] = float(zoom)
    if name:
        payload["name"] = name
    if script:
        payload["script"] = script

    try:
        status = call(url, token, "/api/capture", payload, timeout=SHOT_TIMEOUT)
    except urllib.error.HTTPError as exc:
        return fail(http_reason(exc), phone_name)
    except (urllib.error.URLError, OSError, ValueError) as exc:
        return fail(reason(exc, SHOT_TIMEOUT), phone_name)

    if status.get("state") != "ok":
        return fail(status.get("error") or "scatto fallito", phone_name)

    stem = os.path.splitext(os.path.expanduser(out))[0] if out else "/tmp/%s-%s" % (
        (phone_name or "phone").replace(" ", "-"), time.strftime("%Y%m%d-%H%M%S")
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

        if fetch(url, token, remote, local):
            grabbed[key] = local

    result = {
        "ok": True,
        "device": phone_name,
        "mode": status.get("mode"),
        "camera": status.get("cameraId"),
        "focus": status.get("focusStrategy"),
        "roi": status.get("roi"),
        "zoom": status.get("zoom"),
        "text": status.get("text", ""),
        "size": "%sx%s" % (status.get("width"), status.get("height")),
        "took_ms": status.get("tookMs"),
        # Con quale alfabeto ha letto e quali ha dovuto provare: non ce l'ha
        # l'altra strada, ed e' la differenza fra "l'OCR ha sbagliato" e "ha
        # letto con il modello sbagliato", che si riparano diversamente.
        "script": status.get("script"),
        "script_tried": status.get("scriptTried"),
        "transport": "web",
    }

    if status.get("notes"):
        result["notes"] = status["notes"]

    if release == "always":
        result["note"] = ("la camera e' stata richiusa" if release_now(url, token)
                          else "la camera e' rimasta aperta")
    elif release == "auto" and _found_open is False:
        # Non adesso: alla fine. Una lettura sono due o tre scatti, e chiudere
        # fra l'uno e l'altro vuol dire pagare due volte i due secondi di
        # apertura per riaprire subito la stessa camera. Chi ha finito lo dice
        # chiamando `tidy()`.
        global _ours
        _ours = (url, token)

    result.update(grabbed)

    return result


def release_now(url, token):
    """Chiude la camera, e dice se ci e' riuscito.

    Non riuscirci non e' il fallimento di niente: lo scatto e' gia' andato, e
    quello che resta e' un telefono che scalda un po' piu' del necessario.
    """
    try:
        call(url, token, "/api/release", {})
        return True
    except (urllib.error.URLError, OSError, ValueError):
        return False


def tidy():
    """Richiude la camera se l'abbiamo aperta noi. Da chiamare quando si e' finito.

    Sta qui e non in fondo a `do_photo` perche' "finito" lo sa solo chi ha
    chiesto le foto: una lettura del tester ne vuole due quando la prima non
    convince, e in mezzo la camera deve restare su. Chiamarla quando non c'e'
    niente da chiudere non fa niente, ed e' il motivo per cui la si puo' mettere
    in un `finally` senza chiedersi se serviva.
    """
    global _ours, _found_open

    if _ours is None:
        return False

    url, token = _ours
    _ours = None
    _found_open = None

    return release_now(url, token)


def do_release(target=""):
    """Chiude la camera senza spegnere il server: il telefono smette di scaldare."""
    url, name, why = base(target)

    if not url:
        return fail(why, name)

    _, phone, _ = entry(target)

    try:
        call(url, phone["token"], "/api/release", {})
    except urllib.error.HTTPError as exc:
        return fail(http_reason(exc), name)
    except (urllib.error.URLError, OSError, ValueError) as exc:
        return fail(reason(exc, TIMEOUT), name)

    return {"ok": True, "device": name, "camera": "chiusa"}


# ------------------------------------------------------ la chiave, una volta


def do_token(target=""):
    """Legge la chiave dalle preferenze dell'app, col cavo o col debug wireless.

    E' l'unico comando qui dentro che passa da adb, e serve una volta sola:
    dopo, la chiave sta nella configurazione e il debug puo' anche spegnersi.
    Funziona solo su una build di debug — `run-as` su una build firmata per il
    rilascio non entra, ed e' giusto cosi'.
    """
    prefs = "/data/data/%s/shared_prefs/macrocam.xml" % PACKAGE
    serial = adb_serial(target)

    if not serial:
        return fail("nessun telefono raggiungibile via adb"
                    " (serve solo per leggere la chiave la prima volta)")

    try:
        done = subprocess.run(
            ["adb", "-s", serial, "shell", "run-as", PACKAGE, "cat", prefs],
            capture_output=True, text=True, timeout=30,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        return fail(str(exc))

    text = done.stdout or ""

    # Le preferenze sono un XML minuscolo e prevedibile: tirarci dentro un
    # parser per una riga sola sarebbe piu' codice di quello che legge.
    marker = '<string name="token">'
    cut = text.find(marker)

    if cut < 0:
        return fail("chiave non trovata: l'app non e' mai stata avviata su "
                    "questo telefono, oppure non e' una build di debug")

    end = text.find("</string>", cut)
    token = text[cut + len(marker):end]

    return {"ok": True, "serial": serial, "token": token,
            "config": "scrivila in %s: {\"phones\": {\"NOME\": {\"token\": \"%s\"}}}"
                      % (CONFIG, token)}


def adb_serial(target=""):
    """Il primo device adb utile, o quello che contiene `target` nel serial."""
    try:
        done = subprocess.run(["adb", "devices"], capture_output=True, text=True, timeout=15)
    except (OSError, subprocess.SubprocessError):
        return ""

    found = []

    for line in (done.stdout or "").splitlines()[1:]:
        parts = line.split()

        if len(parts) >= 2 and parts[1] == "device":
            found.append(parts[0])

    if not found:
        return ""

    if target:
        hits = [s for s in found if target in s]

        if hits:
            return hits[0]

    return found[0]


# --------------------------------------------------------------------- main


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--device", default="", help="quale telefono (nome KDE Connect)")
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("state", help="lente aperta, area, ingrandimento, ultimo scatto")
    sub.add_parser("probe", help="le lenti, comprese quelle non elencate")
    sub.add_parser("release", help="chiude la camera senza spegnere il server")
    sub.add_parser("token", help="legge la chiave dall'app via adb (build di debug)")

    photo = sub.add_parser("photo", help="scatta, legge il testo e scarica la foto")
    photo.add_argument("--mode", default="macro", choices=["normal", "macro"])
    photo.add_argument("--out", default="", help="dove scrivere la foto sul PC")
    photo.add_argument("--camera", default="", help="forza l'id della lente")
    photo.add_argument("--torch", action="store_true")
    photo.add_argument("--roi", default="", help="vuoto = quella che ha il telefono")
    photo.add_argument("--zoom", default="")
    photo.add_argument("--name", default="", help="come chiamare lo scatto sul telefono")
    photo.add_argument("--script", default="",
                       help="alfabeto: latin, japanese, chinese, korean, devanagari")
    photo.add_argument("--full", action="store_true", help="scarica anche originale e ritaglio")
    photo.add_argument("--no-ocr", action="store_true")
    photo.add_argument("--keep-open", action="store_true",
                       help="non richiudere la camera dopo lo scatto")

    args = parser.parse_args()

    if args.command == "photo":
        payload = do_photo(
            mode=args.mode, target=args.device, out=args.out, camera=args.camera,
            torch=args.torch, roi=args.roi, ocr=not args.no_ocr, name=args.name,
            full=args.full, zoom=args.zoom, script=args.script,
            release="never" if args.keep_open else "auto",
        )
    elif args.command == "state":
        payload = do_state(args.device)
    elif args.command == "probe":
        payload = do_probe(args.device)
    elif args.command == "release":
        payload = do_release(args.device)
    else:
        payload = do_token(args.device)

    tidy()

    print(json.dumps(payload, ensure_ascii=False, indent=2 if sys.stdout.isatty() else None))

    return 0 if payload.get("ok") else 1


if __name__ == "__main__":
    sys.exit(main())
