#!/usr/bin/env python3
"""Parla con Hermes, l'agente che gira su questa macchina.

Il pannello "Comando IA" ha due pulsanti che partono dallo stesso microfono:
"Parla" passa per il demone Stenografa, che interpreta la frase come un
comando; "Parla con Hermes" prende la stessa trascrizione di Whisper e la
porta a Hermes, che non e' un modello di chat ma un agente — ha i suoi
strumenti, la sua memoria, le sue skill e i suoi MCP, fra cui il
dashboard_mcp.py di questa dashboard. Quindi a Hermes si possono chiedere
cose che un modello non saprebbe fare, tipo com'e' messa la CPU adesso.

Si passa dalla sua riga di comando, che ha un ingresso fatto apposta per chi
chiama da un programma:

    hermes chat -q "<testo>" -Q --continue "<sessione>" --create-if-missing \
                --source tool --in <cartella>

`-Q` toglie banner, rotella e anteprime dei tool: su stdout resta solo la
risposta finale, e `session_id: ...` va su stderr. `--continue <nome>
--create-if-missing` e' la forma pensata per «manda a questo filo, e crealo se
non c'e'»: cosi' la conversazione del pannello e' una sola, che continua fra
una domanda e l'altra. `hermes -z` sarebbe piu' corto ma non tiene memoria
(run_oneshot non accetta ne' --resume ne' --continue), e una chat senza
memoria non e' una chat.

Quello che si vede nella finestra della dashboard e' una copia locale della
conversazione, in ~/.cache/quickshell/hermes-chat.json: la memoria vera ce
l'ha Hermes nella sua sessione, questo file serve solo a disegnare. Da cui il
`reset`, che non si limita a svuotare la copia — cambia anche il nome della
sessione, altrimenti "nuova conversazione" pulirebbe lo schermo lasciando
Hermes a ricordare tutto.

Uso:
    hermes_chat.py ask "testo..." [--session S] [--cwd D] [--model M] [--timeout N]
    hermes_chat.py status
    hermes_chat.py reset

Stampa sempre un oggetto JSON per riga ed esce con codice 0, anche in errore:
chi legge (la dashboard) deve poter mostrare il messaggio invece di trovare
uno stream vuoto.
"""
import argparse
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time

CACHE = os.path.join(
    os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache"),
    "quickshell",
)

# La copia della conversazione, quella che la finestra guarda con FileView.
CHAT_FILE = os.path.join(CACHE, "hermes-chat.json")

# Qual e' il filo aperto: il nome con cui si riprende la sessione di Hermes e
# l'id che lui ci ha risposto (utile solo a `status`, per dire quale sia).
SESSION_FILE = os.path.join(CACHE, "hermes-session.json")

DEFAULT_SESSION = "Dashboard"

# Un turno d'agente non e' una completion: puo' cercare, leggere file, chiamare
# i suoi MCP. Cinque minuti sono lunghi per una risposta e corti per una piantata.
TIMEOUT_ASK = 300

# Il tetto vale solo per il file da disegnare: la memoria e' di Hermes, e qui
# si tiene abbastanza conversazione da poterla scorrere senza far crescere un
# file di cache all'infinito.
MAX_MESSAGES = 200

# `hermes chat -Q` scrive l'id della sessione su stderr, da solo su una riga.
SESSION_ID = re.compile(r"^session_id:\s*(\S+)\s*$", re.M)

# Anche in modalita' silenziosa la CLI si lascia scappare qualche avviso di
# configurazione su stdout, prima della risposta (p.es. "Warning: Unknown
# toolsets: messaging", che nasce dal file di Hermes e non da questa domanda).
# Non e' roba che ha detto Hermes: si stacca dalla risposta e viaggia a parte.
NOTICE = re.compile(r"^(?:Warning|Warn|Error|Note|Notice)\b\s*:", re.I)


def emit(obj):
    json.dump(obj, sys.stdout, ensure_ascii=False)
    sys.stdout.write("\n")
    sys.stdout.flush()


def find_hermes():
    """L'eseguibile di Hermes, o None.

    Quickshell avvia i processi con il PATH che aveva la sessione grafica, che
    non e' quello della shell di chi ha installato Hermes: il ripiego sul
    percorso noto non e' pignoleria, e' il caso normale.
    """
    found = shutil.which("hermes")

    if found:
        return found

    fallback = os.path.expanduser("~/.local/bin/hermes")

    return fallback if os.access(fallback, os.X_OK) else None


def load_chat():
    try:
        with open(CHAT_FILE, encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        return []

    return data if isinstance(data, list) else []


def write_json(path, data):
    tmp = path + ".tmp"

    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)

        with open(tmp, "w", encoding="utf-8") as handle:
            json.dump(data, handle, ensure_ascii=False)

        os.replace(tmp, path)
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass


def save_chat(messages):
    write_json(CHAT_FILE, messages[-MAX_MESSAGES:])


def load_session():
    """{"title": ..., "id": ...} — il filo aperto adesso."""
    try:
        with open(SESSION_FILE, encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        data = {}

    if not isinstance(data, dict):
        data = {}

    title = data.get("title")

    return {
        "title": title if isinstance(title, str) and title.strip() else DEFAULT_SESSION,
        "id": data.get("id") or "",
    }


def next_title(title):
    """"Dashboard" -> "Dashboard 2" -> "Dashboard 3".

    Il nome nuovo serve perche' `--continue` riprende per titolo: riusare lo
    stesso vorrebbe dire ritrovarsi dentro la conversazione appena chiusa.
    """
    match = re.match(r"^(.*?)(?:\s+(\d+))?$", title.strip())
    base = (match.group(1) if match else title).strip() or DEFAULT_SESSION
    count = int(match.group(2)) if match and match.group(2) else 1

    return f"{base} {count + 1}"


# Il figlio da uccidere se ci ammazzano mentre Hermes ragiona.
child = None


def kill_child():
    """Ammazza Hermes e tutto quello che ha avviato.

    Serve perche' e' un albero, non un processo: strumenti, MCP, magari un
    browser. Il figlio parte in una sessione sua (start_new_session), cosi'
    qui basta un colpo al gruppo per non lasciare in giro orfani che
    continuano a lavorare per una domanda che nessuno legge piu'.
    """
    if child is None or child.poll() is not None:
        return

    try:
        os.killpg(child.pid, signal.SIGTERM)
    except OSError:
        return

    # Misurato: Hermes il SIGTERM non lo raccoglie, resta a lavorare finche' non
    # arriva il colpo secco. I due secondi non sono un'attesa che serva a lui,
    # servono ai suoi MCP per chiudere le loro pipe senza lasciare rumore nei log.
    try:
        child.wait(timeout=2)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(child.pid, signal.SIGKILL)
        except OSError:
            pass


def on_signal(_signum, _frame):
    # Chi ci ha uccisi non sta leggendo: si porta via il figlio e si esce
    # senza scrivere niente. E' il pulsante "Ferma" del pannello.
    kill_child()
    os._exit(143)


def run_hermes(text, session, cwd, model, timeout):
    """Una domanda a Hermes. Torna (risposta, id sessione) o solleva RuntimeError."""
    global child

    exe = find_hermes()

    if exe is None:
        raise RuntimeError(
            "Hermes non trovato: manca `hermes` nel PATH e in ~/.local/bin")

    command = [
        exe, "chat",
        "-q", text,
        "-Q",
        "--continue", session,
        "--create-if-missing",
        # 'tool' tiene il filo del pannello fuori dall'elenco delle sessioni
        # che si vedono con `hermes sessions`: e' un canale, non una seduta.
        "--source", "tool",
        "--in", cwd,
    ]

    if model:
        command += ["-m", model]

    for handler in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(handler, on_signal)

    try:
        child = subprocess.Popen(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            cwd=cwd,
            start_new_session=True,
        )
    except OSError as exc:
        raise RuntimeError(f"non riesco ad avviare Hermes: {exc}")

    try:
        out, err = child.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        kill_child()
        raise RuntimeError(
            f"Hermes non ha finito entro {timeout:.0f}s: richiesta interrotta")

    session_id = ""
    match = SESSION_ID.search(err or "")

    if match:
        session_id = match.group(1)

    reply, notices = split_notices(out)

    if child.returncode != 0 or not reply:
        raise RuntimeError(explain(err, child.returncode))

    return reply, session_id, notices


def split_notices(out):
    """Separa gli avvisi in testa alla risposta vera. Torna (risposta, avvisi)."""
    lines = (out or "").splitlines()
    notices = []

    while lines and (not lines[0].strip() or NOTICE.match(lines[0].strip())):
        line = lines.pop(0).strip()

        if line:
            notices.append(line)

    return "\n".join(lines).strip(), notices


def explain(err, code):
    """Il messaggio da mostrare quando Hermes non risponde.

    Le cose che vanno storte davvero si leggono su stderr e sono due: il
    provider di inferenza spento, e lo slot di sessione gia' occupato da
    un'altra istanza. Vale la pena riportare le sue parole invece di
    riassumerle in un "errore": chi guarda il pannello deve capire se
    accendere qualcosa o chiudere un terminale.
    """
    lines = [
        line.strip()
        for line in (err or "").splitlines()
        if line.strip() and not SESSION_ID.match(line.strip())
    ]

    detail = " · ".join(lines[-4:])

    if not detail:
        return f"Hermes non ha risposto (uscita {code})"

    return detail[:600]


def ask(args):
    session = load_session()
    cwd = os.path.expanduser(args.cwd)

    if not os.path.isdir(cwd):
        cwd = os.path.expanduser("~")

    started = time.monotonic()

    try:
        reply, session_id, notices = run_hermes(
            args.text,
            args.session or session["title"],
            cwd,
            args.model,
            args.timeout,
        )
    except RuntimeError as exc:
        emit({"ok": False, "error": str(exc)})
        return

    messages = load_chat()
    messages.append({"role": "user", "content": args.text})
    messages.append({"role": "assistant", "content": reply})
    save_chat(messages)

    write_json(SESSION_FILE, {
        "title": args.session or session["title"],
        "id": session_id or session["id"],
    })

    payload = {"ok": True, "reply": reply,
               "sessione": args.session or session["title"],
               "ms": int((time.monotonic() - started) * 1000),
               "scambi": len(messages) // 2}

    if notices:
        payload["avvisi"] = notices

    emit(payload)


def gateway_state():
    """Se il gateway di Hermes gira: e' quello che lo tiene su Telegram."""
    try:
        done = subprocess.run(
            ["systemctl", "--user", "is-active", "hermes-gateway.service"],
            capture_output=True, text=True, timeout=3)
    except (OSError, subprocess.SubprocessError):
        return "sconosciuto"

    return done.stdout.strip() or "sconosciuto"


def status(_args):
    """Chi c'e' in ascolto, senza svegliare l'agente.

    Volutamente non chiede niente a Hermes: interrogarlo vorrebbe dire
    caricargli il modello per sapere se e' installato.
    """
    exe = find_hermes()

    if exe is None:
        emit({"ok": False,
              "error": "Hermes non trovato: manca `hermes` nel PATH e in ~/.local/bin"})
        return

    session = load_session()

    emit({"ok": True, "cli": exe, "gateway": gateway_state(),
          "sessione": session["title"], "id": session["id"],
          "scambi": len(load_chat()) // 2})


def reset(_args):
    # La copia si svuota riscrivendola invece di cancellarla: la finestra della
    # chat la tiene sotto FileView, e un file che sparisce vale buco mentre una
    # lista vuota vale "conversazione azzerata". Il filo di Hermes non si
    # cancella — si lascia dov'e' e se ne apre un altro: le sessioni vecchie
    # restano sue, e chi vuole rileggerle sa dove sono.
    session = load_session()
    title = next_title(session["title"])

    save_chat([])
    write_json(SESSION_FILE, {"title": title, "id": ""})

    emit({"ok": True, "sessione": title})


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="cmd", required=True)

    ask_parser = sub.add_parser("ask", help="chiede qualcosa, mantenendo la conversazione")
    ask_parser.add_argument("text")
    ask_parser.add_argument("--session", default="",
                            help="il filo da riprendere (default: quello aperto)")
    ask_parser.add_argument("--cwd", default="~",
                            help="cartella in cui far girare Hermes")
    ask_parser.add_argument("--model", default="",
                            help="modello da imporre (vuoto: quello configurato in Hermes)")
    ask_parser.add_argument("--timeout", type=float, default=TIMEOUT_ASK)
    ask_parser.set_defaults(func=ask)

    status_parser = sub.add_parser("status", help="chi c'e' in ascolto")
    status_parser.set_defaults(func=status)

    reset_parser = sub.add_parser("reset", help="apre una conversazione nuova")
    reset_parser.set_defaults(func=reset)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
