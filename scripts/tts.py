#!/usr/bin/env python3
"""Fa parlare la dashboard: la risposta di Hermes letta ad alta voce.

Il motore e' Audio8 TTS Preview 0.1B in ONNX INT8
(https://huggingface.co/Audio8/audio8-TTS-0.1B-ONNX-INT8): gira sulla CPU,
non vuole PyTorch e sta sotto il mezzo giga di modello. Non lo si pilota
importandolo: il runtime ufficiale (Audio8_TTS/onnx_runtime_0_1b_int8) vuole
onnxruntime<1.24 e tokenizers, che qui non ci sono e che non e' il caso di
imporre al Python di sistema — quindi vive in un venv suo, e questo script
gli parla via HTTP.

Il servizio si accende da solo alla prima frase e resta su: caricare le tre
sessioni ONNX costa una decina di secondi e ~0.6 GB, e pagarli a ogni
risposta vorrebbe dire aspettare mezzo minuto prima di sentire una parola.
Da cui anche lo streaming: `/api/tts/stream` manda PCM a blocchi da mezzo
secondo mentre il modello genera, e i blocchi vanno dritti nella pipe del
riproduttore — si comincia a sentire la frase prima che sia finita di
sintetizzare.

Il testo non ci arriva pulito: Hermes scrive in Markdown, con blocchi di
codice, link e tabelle. Roba che letta ad alta voce e' rumore, e che il
modello dovrebbe comunque sillabare a 21 fotogrammi al secondo — quindi si
toglie prima (vedi `clean`), e il resto si taglia a `--max-chars`.

Uso:
    tts.py speak "testo..." [--voice V] [--port N] [--volume 0..100]
    tts.py stop
    tts.py status
    tts.py install [--with-registration]

Stampa un oggetto JSON per riga: `speak` ne emette piu' d'uno (avvio,
sintesi, fine) cosi' il pannello puo' dire a che punto e', e chiude sempre
con un oggetto che ha `ok`. Esce con 0 anche in errore — chi legge e' la
dashboard, e deve poter mostrare il messaggio.
"""
import argparse
import array
import base64
import json
import math
import os
import re
import shutil
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.request

DATA = os.path.join(
    os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share"),
    "quickshell",
)

CACHE = os.path.join(
    os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache"),
    "quickshell",
)

# Il runtime ufficiale, clonato dov'e' installato il motore. La cartella e'
# quella che i suoi script si aspettano (model/, voices/, .venv/): tenerla
# identica al monte vuol dire poter usare start_server.sh e run_infer.sh a
# mano quando qualcosa non torna.
BASE = os.path.join(DATA, "audio8-tts")
ROOT = os.path.join(BASE, "Audio8_TTS", "onnx_runtime_0_1b_int8")
VENV = os.path.join(ROOT, ".venv")
PYTHON = os.path.join(VENV, "bin", "python")
MODEL = os.path.join(ROOT, "model")
VOICES = os.path.join(ROOT, "voices")
SERVICE_PID = os.path.join(ROOT, ".service.pid")
SERVICE_LOG = os.path.join(ROOT, "service.log")

REPO = "https://github.com/Audio8-AI/Audio8_TTS.git"
SUBDIR = "onnx_runtime_0_1b_int8"
MODEL_ID = "Audio8/audio8-TTS-0.1B-ONNX-INT8"

PORT = 8024

# Il pid del `speak` in corso: serve al `stop` chiamato da un altro processo
# (il pulsante del pannello passa di li' quando non ha in mano il Process).
SPEAK_PID = os.path.join(CACHE, "tts-speak.pid")

# Caricare le tre sessioni ONNX e' l'attesa piu' lunga di tutto il giro: si
# misura in decine di secondi su una macchina carica, e va aspettata una
# volta sola per accensione.
START_TIMEOUT = 120

# Oltre questa lunghezza non e' piu' una risposta parlata, e' un monologo: il
# modello ci mette ~0.6 s di CPU per ogni secondo d'audio, e mezza pagina di
# Markdown letta ad alta voce sono minuti.
MAX_CHARS = 700

# L'API si ferma a 1000 caratteri per richiesta, ma il motivo per spezzare non
# e' quello: un pezzo corto comincia a suonare prima, e una pausa dopo il
# punto e' quello che farebbe chiunque legga.
CHUNK_CHARS = 260

SAMPLE_RATE = 44100

# Il modello non dice mai "ho finito". Il token di fine non arriva: 384
# fotogrammi generati su 384 disponibili, con l'italiano, l'inglese e il
# cinese della sua voce di riferimento, e a qualunque temperatura — misurato,
# non dedotto. Quindi dopo la frase continua a produrre audio, e la fine va
# sentita invece che aspettata: quando il silenzio dura abbastanza, la frase
# e' detta e la generazione si annulla. Senza questo, ogni frase costerebbe il
# tetto intero: quasi un minuto di CPU per dire "ciao".
#
# Un secondo di silenzio e' piu' lungo di qualunque pausa dentro una frase e
# piu' corto di un'attesa che si noti.
SILENCE_STOP = 1.0

# Ampiezza efficace sotto la quale non c'e' voce, su una scala 0..1. Il
# parlato di questo modello sta fra 0.03 e 0.45; la coda muta e' due ordini di
# grandezza sotto.
SILENCE_FLOOR = 0.012

# Prima di dar retta al silenzio va sentita un po' di voce: l'attacco di una
# frase puo' cominciare con mezzo secondo di niente.
SPEECH_MIN = 0.5

# La finestra su cui si misura: abbastanza corta da trovare la fine al
# quarto di secondo, abbastanza lunga da non scambiare un'occlusiva per
# silenzio.
WINDOW = 0.05

# Fotogrammi per carattere (il codec ne fa ~21.5 al secondo, la lettura sta
# sui 14 caratteri al secondo): e' il secondo freno, quello che vale quando
# dopo la frase il modello non tace ma continua a borbottare, e il silenzio
# non arriva mai.
FRAMES_PER_CHAR = 2.2


def emit(obj):
    json.dump(obj, sys.stdout, ensure_ascii=False)
    sys.stdout.write("\n")
    sys.stdout.flush()


def installed():
    """Vero se c'e' tutto il necessario per parlare."""
    return (
        os.access(PYTHON, os.X_OK)
        and os.path.isfile(os.path.join(MODEL, "runtime_manifest.json"))
        and os.path.isfile(os.path.join(MODEL, "slow_ar_int8.onnx"))
        and os.path.isfile(os.path.join(VOICES, "default", "codes.npy"))
    )


def api(port, path, payload=None, timeout=10):
    """Una chiamata al servizio locale. Torna l'oggetto JSON o solleva OSError."""
    url = f"http://127.0.0.1:{port}{path}"
    data = None
    headers = {}

    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"

    request = urllib.request.Request(url, data=data, headers=headers)

    # Il servizio e' su 127.0.0.1: un proxy configurato nell'ambiente lo
    # manderebbe fuori a cercare una macchina che non esiste.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    with opener.open(request, timeout=timeout) as response:
        return json.loads(response.read().decode("utf-8"))


def alive(port):
    try:
        return bool(api(port, "/api/health", timeout=3).get("ok"))
    except (OSError, ValueError):
        return False


def start_service(port):
    """Accende il servizio e aspetta che risponda. Solleva RuntimeError."""
    if alive(port):
        return False

    environment = dict(os.environ)
    environment.update({
        "ARKTTS_MODEL_DIR": MODEL,
        "ARKTTS_VOICES_DIR": VOICES,
        "ARKTTS_PRECISION": "int8",
        "ARKTTS_CODEC_PRECISION": "fp16",
        # Cinque thread sono il default del monte; qui la dashboard sta gia'
        # misurando la macchina, e prendersi tutti i core per leggere una
        # frase si vedrebbe nei suoi stessi grafici.
        "ARKTTS_THREADS": environment.get("ARKTTS_THREADS", "4"),
    })

    try:
        log = open(SERVICE_LOG, "ab")
    except OSError:
        log = subprocess.DEVNULL

    try:
        child = subprocess.Popen(
            [os.path.join(VENV, "bin", "uvicorn"), "arktts_runtime.service:app",
             "--app-dir", ROOT, "--host", "127.0.0.1", "--port", str(port)],
            cwd=ROOT,
            env=environment,
            stdin=subprocess.DEVNULL,
            stdout=log,
            stderr=subprocess.STDOUT,
            # Il servizio deve sopravvivere a chi lo accende: e' un demone, non
            # un figlio di questa frase.
            start_new_session=True,
        )
    except OSError as exc:
        raise RuntimeError(f"non riesco ad avviare il motore vocale: {exc}")
    finally:
        if log is not subprocess.DEVNULL:
            log.close()

    try:
        with open(SERVICE_PID, "w", encoding="utf-8") as handle:
            handle.write(str(child.pid))
    except OSError:
        pass

    deadline = time.monotonic() + START_TIMEOUT

    while time.monotonic() < deadline:
        if alive(port):
            return True

        if child.poll() is not None:
            raise RuntimeError(
                f"il motore vocale si e' spento all'avvio (vedi {SERVICE_LOG})")

        time.sleep(0.5)

    raise RuntimeError(f"il motore vocale non risponde entro {START_TIMEOUT}s")


# --- il testo -----------------------------------------------------------

FENCE = re.compile(r"```.*?```", re.S)
INLINE_CODE = re.compile(r"`([^`]*)`")
LINK = re.compile(r"\[([^\]]*)\]\([^)]*\)")
IMAGE = re.compile(r"!\[[^\]]*\]\([^)]*\)")
URL = re.compile(r"https?://\S+")
HEADING = re.compile(r"^\s{0,3}#{1,6}\s*", re.M)
BULLET = re.compile(r"^\s*([-*+]|\d+[.)])\s+", re.M)
EMPHASIS = re.compile(r"(\*\*|__|\*|_|~~)")
TABLE = re.compile(r"^\s*\|.*\|\s*$", re.M)
# Gli emoji e i simboli decorativi il modello li sillaberebbe o li salterebbe
# a seconda del tokenizer: non sono parlato, si tolgono.
PICTOGRAM = re.compile(
    "[\U0001F300-\U0001FAFF\u2190-\u21FF\u2300-\u27BF"
    "\u2B00-\u2BFF\u2600-\u26FF\uFE0F\u200D]")


def clean(text, limit=MAX_CHARS):
    """Da Markdown a qualcosa che ha senso ascoltare."""
    value = FENCE.sub(" ", text or "")
    value = IMAGE.sub(" ", value)
    value = LINK.sub(r"\1", value)
    value = TABLE.sub(" ", value)
    value = HEADING.sub("", value)
    value = BULLET.sub("", value)
    value = INLINE_CODE.sub(r"\1", value)
    value = EMPHASIS.sub("", value)
    value = URL.sub(" ", value)
    value = PICTOGRAM.sub(" ", value)
    value = re.sub(r"[ \t]+", " ", value)
    # togliendo link e codice restano spazi appesi davanti alla punteggiatura,
    # e il modello ci mette una pausa dove non ce n'e' una
    value = re.sub(r"\s+([.,;:!?…])", r"\1", value)
    value = re.sub(r"\n{2,}", "\n", value).strip()

    if len(value) <= limit:
        return value

    # Si tronca alla fine di una frase, non a meta' parola: una lettura che si
    # interrompe su un punto sembra finita, una che si interrompe su una
    # sillaba sembra un guasto.
    cut = value[:limit]
    stop = max(cut.rfind("."), cut.rfind("!"), cut.rfind("?"), cut.rfind("\n"))

    return (cut[:stop + 1] if stop > limit // 3 else cut).strip()


def chunks(text, limit=CHUNK_CHARS):
    """Spezza in pezzi da sintetizzare uno dopo l'altro."""
    pieces = []
    current = ""

    for sentence in re.split(r"(?<=[.!?;:])\s+|\n+", text):
        sentence = sentence.strip()

        if not sentence:
            continue

        # Una frase piu' lunga del pezzo intero (elenchi senza punteggiatura,
        # p.es.) si taglia sulle virgole, e se non ce ne sono sugli spazi.
        while len(sentence) > limit:
            window = sentence[:limit]
            split = max(window.rfind(", "), window.rfind(" "))
            split = split if split > limit // 3 else limit
            pieces.append(sentence[:split].strip())
            sentence = sentence[split:].strip()

        if not sentence:
            continue

        if len(current) + len(sentence) + 1 <= limit:
            current = f"{current} {sentence}".strip()
        else:
            if current:
                pieces.append(current)
            current = sentence

    if current:
        pieces.append(current)

    return [piece for piece in pieces if piece]


# --- la voce ------------------------------------------------------------

def player_command(volume):
    """Il riproduttore che accetta PCM grezzo sullo standard input."""
    if shutil.which("paplay"):
        command = ["paplay", "--raw", "--format=s16le",
                   f"--rate={SAMPLE_RATE}", "--channels=1",
                   "--client-name=Quickshell", "--stream-name=Hermes"]

        if volume is not None:
            # paplay conta il volume su 65536, non su cento.
            command.append(f"--volume={int(max(0, min(100, volume)) * 655.36)}")

        return command

    if shutil.which("pw-play"):
        return ["pw-play", "--format=s16", f"--rate={SAMPLE_RATE}",
                "--channels=1", "-"]

    if shutil.which("aplay"):
        return ["aplay", "-q", "-f", "S16_LE", "-r", str(SAMPLE_RATE), "-c", "1", "-"]

    raise RuntimeError("nessun riproduttore audio: mancano paplay, pw-play e aplay")


class Ear:
    """Ascolta il PCM che passa e dice quando la frase e' finita.

    Tiene il conto di quanta voce ha sentito e da quanto non ne sente piu'.
    Lavora su finestre di `WINDOW` secondi, e i byte che avanzano da una
    chiamata restano in pancia per la successiva: i blocchi che arrivano dal
    servizio non cadono sui confini delle finestre.
    """

    def __init__(self):
        self.rest = b""
        self.speech = 0.0
        self.silence = 0.0

    def feed(self, pcm):
        """Torna (byte da suonare, frase finita)."""
        data = self.rest + pcm
        width = int(SAMPLE_RATE * WINDOW) * 2
        keep = len(data)
        done = False
        offset = 0

        while offset + width <= len(data):
            window = array.array("h")
            window.frombytes(data[offset:offset + width])

            # media quadratica, riportata su 0..1
            energy = math.sqrt(sum(value * value for value in window) / len(window)) / 32768

            if energy >= SILENCE_FLOOR:
                self.speech += WINDOW
                self.silence = 0.0
            elif self.speech >= SPEECH_MIN:
                self.silence += WINDOW

                if self.silence >= SILENCE_STOP:
                    # Si taglia dove il silenzio comincia, non dove finisce:
                    # la coda muta non aggiunge niente da sentire. Un pelo di
                    # margine perche' l'ultima sillaba non venga mozzata.
                    keep = max(0, offset + width - int(
                        (self.silence - 0.15) * SAMPLE_RATE) * 2)
                    done = True
                    break

            offset += width

        if done:
            self.rest = b""
            return data[:keep], True

        self.rest = data[offset:]

        return data[:offset], False


# Chi sta suonando adesso, per il colpo di grazia dei segnali.
player = None
speaking_port = PORT


def hush():
    """Zittisce subito: taglia la sintesi in corso e chiude il riproduttore.

    L'ordine conta. Prima si annulla la generazione — altrimenti il servizio
    resterebbe a produrre un audio che nessuno prende, con il suo lock tenuto,
    e la frase dopo aspetterebbe la fine di quella zittita. Poi si uccide il
    riproduttore: il buffer che ha gia' in pancia va buttato, non suonato.
    """
    try:
        api(speaking_port, "/api/tts/cancel", payload={}, timeout=2)
    except (OSError, ValueError):
        pass

    global player

    if player is not None and player.poll() is None:
        try:
            player.stdin.close()
        except (OSError, ValueError):
            pass

        player.kill()

    player = None


def on_signal(_signum, _frame):
    # Chi ci ha uccisi non sta ascoltando: si zittisce e si esce senza
    # scrivere altro. E' il pulsante "Zitto" del pannello.
    hush()
    os._exit(143)


def stream_chunk(port, text, voice, params, sink):
    """Sintetizza un pezzo e versa il PCM nel riproduttore. Torna i campioni."""
    payload = {"text": text, "voice_name": voice}
    payload.update(params)

    # Il tetto vero e' il piu' stretto fra quello chiesto e quello che questa
    # frase puo' ragionevolmente durare: vedi FRAMES_PER_CHAR.
    payload["max_new_tokens"] = max(32, min(
        int(payload.get("max_new_tokens", 320)),
        int(len(text) * FRAMES_PER_CHAR) + 24))

    request = urllib.request.Request(
        f"http://127.0.0.1:{port}/api/tts/stream",
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
    )
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    ear = Ear()
    samples = 0

    with opener.open(request, timeout=600) as response:
        for line in response:
            line = line.strip()

            if not line:
                continue

            try:
                event = json.loads(line)
            except ValueError:
                continue

            if event.get("event") != "audio_chunk":
                continue

            pcm = base64.b64decode(event.get("pcm_b64", ""))

            if not pcm:
                continue

            audio, finita = ear.feed(pcm)

            if audio:
                try:
                    sink.write(audio)
                    sink.flush()
                except (BrokenPipeError, ValueError):
                    # Il riproduttore e' morto (uscita audio staccata, o uno
                    # stop): inutile continuare a generare per una pipe chiusa.
                    raise RuntimeError("riproduzione interrotta")

                samples += len(audio) // 2

            if finita:
                # La frase e' detta: quello che il modello avrebbe continuato a
                # produrre non lo vuole nessuno, e costa CPU come il resto.
                try:
                    api(port, "/api/tts/cancel", payload={}, timeout=2)
                except (OSError, ValueError):
                    pass

                break

    # Quel che resta in pancia all'orecchio e' meno di una finestra: si suona,
    # altrimenti l'ultima frase finirebbe con un troncone di sillaba.
    if not ear.rest:
        return samples

    try:
        sink.write(ear.rest)
        sink.flush()
    except (BrokenPipeError, ValueError):
        return samples

    return samples + len(ear.rest) // 2


def speak(args):
    global player, speaking_port

    speaking_port = args.port
    text = clean(args.text, args.max_chars)

    if not text:
        emit({"ok": True, "detto": False, "motivo": "niente da leggere"})
        return

    if not installed():
        emit({"ok": False,
              "error": "motore vocale non installato: scripts/tts.py install"})
        return

    for handler in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(handler, on_signal)

    try:
        os.makedirs(CACHE, exist_ok=True)

        with open(SPEAK_PID, "w", encoding="utf-8") as handle:
            handle.write(str(os.getpid()))
    except OSError:
        pass

    started = time.monotonic()

    try:
        if start_service(args.port):
            emit({"ok": True, "stato": "avvio", "messaggio": "motore vocale acceso"})
    except RuntimeError as exc:
        emit({"ok": False, "error": str(exc)})
        return

    pieces = chunks(text)
    emit({"ok": True, "stato": "sintesi", "pezzi": len(pieces),
          "caratteri": len(text)})

    try:
        command = player_command(args.volume)
    except RuntimeError as exc:
        emit({"ok": False, "error": str(exc)})
        return

    try:
        player = subprocess.Popen(command, stdin=subprocess.PIPE)
    except OSError as exc:
        emit({"ok": False, "error": f"non riesco a riprodurre l'audio: {exc}"})
        return

    params = {"max_new_tokens": args.max_new_tokens, "temperature": args.temperature,
              "top_p": args.top_p, "top_k": args.top_k, "seed": args.seed}
    samples = 0

    try:
        for index, piece in enumerate(pieces):
            samples += stream_chunk(args.port, piece, args.voice, params, player.stdin)

            if index == 0:
                emit({"ok": True, "stato": "parla",
                      "ms": int((time.monotonic() - started) * 1000)})
    except urllib.error.HTTPError as exc:
        hush()
        emit({"ok": False, "error": f"il motore vocale ha rifiutato la frase ({exc.code})"})
        return
    except (OSError, RuntimeError, ValueError) as exc:
        hush()
        emit({"ok": False, "error": f"sintesi non riuscita: {exc}"})
        return

    # Il PCM e' gia' tutto nella pipe: chiudere l'ingresso e aspettare vuol
    # dire aspettare che finisca di suonare, che e' quando la frase e' detta.
    try:
        player.stdin.close()
        player.wait()
    except (OSError, ValueError):
        pass

    try:
        os.unlink(SPEAK_PID)
    except OSError:
        pass

    emit({"ok": True, "detto": True, "pezzi": len(pieces),
          "secondi": round(samples / SAMPLE_RATE, 1),
          "ms": int((time.monotonic() - started) * 1000)})


def stop(args):
    """Zittisce il parlato in corso, chiunque l'abbia avviato."""
    fermato = False

    try:
        with open(SPEAK_PID, encoding="utf-8") as handle:
            pid = int(handle.read().strip())
    except (OSError, ValueError):
        pid = 0

    if pid > 0:
        try:
            os.kill(pid, signal.SIGTERM)
            fermato = True
        except OSError:
            pass

        try:
            os.unlink(SPEAK_PID)
        except OSError:
            pass

    # Anche senza pid vale la pena bussare al servizio: il parlato puo' essere
    # partito da un altro processo (la finestra della chat) e la generazione
    # va fermata comunque.
    try:
        api(args.port, "/api/tts/cancel", payload={}, timeout=2)
        fermato = True
    except (OSError, ValueError):
        pass

    emit({"ok": True, "fermato": fermato})


def status(args):
    if not installed():
        emit({"ok": False, "installato": False,
              "error": "motore vocale non installato: scripts/tts.py install"})
        return

    voci = []

    try:
        voci = [voce.get("name", "") for voce in
                api(args.port, "/api/voices", timeout=3).get("voices", [])]
        acceso = True
    except (OSError, ValueError):
        acceso = False
        voci = sorted(
            name for name in os.listdir(VOICES)
            if os.path.isfile(os.path.join(VOICES, name, "meta.json"))
        ) if os.path.isdir(VOICES) else []

    emit({"ok": True, "installato": True, "acceso": acceso,
          "porta": args.port, "voci": voci, "radice": ROOT})


# --- installazione ------------------------------------------------------

def run(command, cwd=None, passo=""):
    """Un passo dell'installazione, con l'esito su una riga JSON."""
    emit({"ok": True, "passo": passo, "stato": "in corso"})

    done = subprocess.run(command, cwd=cwd, capture_output=True, text=True)

    if done.returncode != 0:
        coda = (done.stderr or done.stdout or "").strip().splitlines()[-3:]
        raise RuntimeError(f"{passo}: " + " · ".join(coda)[:400])

    emit({"ok": True, "passo": passo, "stato": "fatto"})


def install(args):
    """Scarica runtime e modello. Ci mette minuti: e' roba da riga di comando."""
    if shutil.which("git") is None:
        emit({"ok": False, "error": "manca git"})
        return

    try:
        os.makedirs(BASE, exist_ok=True)

        if not os.path.isdir(os.path.join(BASE, "Audio8_TTS", ".git")):
            # Del monte serve una cartella sola: il resto del repository ha
            # dentro il runtime della 0.6B, che con questi grafi non c'entra.
            run(["git", "clone", "--depth", "1", "--filter=blob:none",
                 "--sparse", REPO, "Audio8_TTS"], cwd=BASE, passo="runtime")
            run(["git", "sparse-checkout", "set", SUBDIR],
                cwd=os.path.join(BASE, "Audio8_TTS"), passo="runtime/sparse")

        if not os.access(PYTHON, os.X_OK):
            run([sys.executable, "-m", "venv", VENV], passo="venv")

        run([PYTHON, "-m", "pip", "install", "--upgrade", "pip", "--quiet"],
            passo="pip")
        run([PYTHON, "-m", "pip", "install", "--quiet", "-r",
             os.path.join(ROOT, "requirements.txt"), "huggingface_hub[cli]"],
            passo="dipendenze")

        # La cartella registration/ (415 MB) serve solo a clonare una voce
        # nuova da una registrazione: senza, la voce di serie funziona lo
        # stesso e il modello dimezza.
        download = [os.path.join(VENV, "bin", "hf"), "download", MODEL_ID,
                    "--local-dir", MODEL]

        if not args.with_registration:
            # `--exclude` vuole un motivo per volta: due su una riga sola e il
            # secondo diventa un file da scaricare, che nel repository non c'e'.
            download += ["--exclude", "registration/*", "--exclude", "*.jpeg"]

        run(download, passo="modello")
        run([PYTHON, os.path.join(ROOT, "scripts", "register_default_voice.py"),
             "--model-dir", MODEL, "--voices-dir", VOICES, "--overwrite"],
            passo="voce")
    except RuntimeError as exc:
        emit({"ok": False, "error": str(exc)})
        return
    except OSError as exc:
        emit({"ok": False, "error": f"installazione non riuscita: {exc}"})
        return

    emit({"ok": True, "installato": installed(), "radice": ROOT})


def shutdown(args):
    """Spegne il servizio: 0.6 GB che tornano alla macchina."""
    try:
        with open(SERVICE_PID, encoding="utf-8") as handle:
            pid = int(handle.read().strip())
    except (OSError, ValueError):
        emit({"ok": True, "spento": False, "motivo": "non risulta acceso"})
        return

    try:
        os.kill(pid, signal.SIGTERM)
    except OSError:
        emit({"ok": True, "spento": False, "motivo": "non risulta acceso"})
        return
    finally:
        try:
            os.unlink(SERVICE_PID)
        except OSError:
            pass

    emit({"ok": True, "spento": True})


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--port", type=int, default=PORT)
    sub = parser.add_subparsers(dest="cmd", required=True)

    speak_parser = sub.add_parser("speak", help="legge un testo ad alta voce")
    speak_parser.add_argument("text")
    speak_parser.add_argument("--voice", default="default")
    speak_parser.add_argument("--volume", type=int, default=None,
                              help="0..100 (vuoto: volume del canale)")
    speak_parser.add_argument("--max-chars", type=int, default=MAX_CHARS)
    speak_parser.add_argument("--max-new-tokens", type=int, default=320,
                              help="tetto di fotogrammi per pezzo (~21.5 al secondo)")
    speak_parser.add_argument("--temperature", type=float, default=0.7)
    speak_parser.add_argument("--top-p", type=float, default=0.9)
    speak_parser.add_argument("--top-k", type=int, default=50)
    speak_parser.add_argument("--seed", type=int, default=42)
    speak_parser.set_defaults(func=speak)

    stop_parser = sub.add_parser("stop", help="zittisce il parlato in corso")
    stop_parser.set_defaults(func=stop)

    status_parser = sub.add_parser("status", help="motore installato e acceso?")
    status_parser.set_defaults(func=status)

    install_parser = sub.add_parser("install", help="scarica runtime e modello")
    install_parser.add_argument("--with-registration", action="store_true",
                                help="anche il codificatore per clonare voci nuove (+415 MB)")
    install_parser.set_defaults(func=install)

    shutdown_parser = sub.add_parser("shutdown", help="spegne il servizio")
    shutdown_parser.set_defaults(func=shutdown)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
