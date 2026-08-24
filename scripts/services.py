#!/usr/bin/env python3
"""Elenca i servizi systemd, utente e di sistema, in un unico JSON.

Servono due comandi per avere il quadro completo: `list-units` dice se un
servizio sta girando adesso, `list-unit-files` se parte da solo all'avvio.
Sono insiemi diversi (un servizio installato ma mai caricato compare solo nel
secondo), quindi si uniscono per nome.

Il sottocomando `diagnose` risponde all'altra meta' della domanda. L'elenco
dice *cosa* e' fallito; questo dice *perche'*, che e' quello che si vuole
sapere davvero quando il pannello mostra cinque righe rosse: il verdetto di
systemd sull'unita' (codice d'uscita, segnale che l'ha uccisa, tempo scaduto,
core dump, limite di riavvii, oppure una condizione non soddisfatta — che non
e' un guasto, e dirlo ferma la caccia prima che cominci), il comando che ha
eseguito, il file di unita' da cui viene, e le ultime righe che quell'unita' ha
scritto nel registro. Senza nome le guarda tutte quelle fallite adesso, nei due
systemd insieme:

    python3 services.py                       # l'elenco, per la dashboard
    python3 services.py diagnose              # perche' sono falliti
    python3 services.py diagnose sshd.service
"""
import argparse
import json
import re
import signal
import subprocess
import sys
from datetime import datetime
from concurrent.futures import ThreadPoolExecutor

TIMEOUT = 15


def run_json(args):
    try:
        out = subprocess.run(
            args, capture_output=True, text=True, timeout=TIMEOUT
        ).stdout.strip()
        return json.loads(out) if out else []
    except (OSError, subprocess.SubprocessError, ValueError):
        return []


def collect(user: bool, results):
    base = ["systemctl"] + (["--user"] if user else [])

    services = {}

    for u in results[0]:
        name = u.get("unit", "")
        if not name.endswith(".service"):
            continue
        services[name] = {
            "name": name,
            "description": u.get("description", ""),
            "active": u.get("active", "inactive"),
            "sub": u.get("sub", ""),
            "state": "",
        }

    for f in results[1]:
        name = f.get("unit_file", "")
        if not name.endswith(".service"):
            continue
        entry = services.setdefault(
            name,
            {
                "name": name,
                "description": "",
                "active": "inactive",
                "sub": "dead",
                "state": "",
            },
        )
        entry["state"] = f.get("state", "")

    # I template (foo@.service) non si avviano da soli: senza istanza non c'e'
    # nulla da accendere, quindi restano fuori dall'elenco.
    visible = [s for s in services.values() if "@." not in s["name"]]

    def rank(s):
        """Ordina per gestibilita', non solo per stato.

        In cima i guasti, poi i servizi con un vero file di unita' (gli unici
        che si possono abilitare o disabilitare), attivi prima di quelli fermi.
        In coda static, generated e transient: sono centinaia — unita' DBus
        attivate su richiesta, autostart XDG — e seppellirebbero i servizi veri.
        """
        running = s["active"] in ("active", "reloading", "activating")

        if s["active"] == "failed":
            return 0
        if s["state"] in ("enabled", "disabled"):
            return 1 if running else 2
        return 3 if running else 4

    return sorted(visible, key=lambda s: (rank(s), s["name"]))


# ------------------------------------------------------------------ diagnosi


# Le proprieta' che dicono *perche'* un'unita' sta come sta. Chiederle per nome
# invece di leggere tutto: `systemctl show` senza filtri ne stampa duecento, e
# di duecento righe se ne guardano nove.
PROPERTIES = (
    "Description", "LoadState", "ActiveState", "SubState", "UnitFileState",
    "Result", "ExecMainCode", "ExecMainStatus", "ExecMainStartTimestamp",
    "ExecMainExitTimestamp", "NRestarts", "ConditionResult", "AssertResult",
    "FragmentPath", "SourcePath", "ExecStart", "InvocationID", "TriggeredBy",
    "StatusText", "StatusErrno", "MainPID",
)

# Come sono finiti i processi, secondo si_code di waitid(2): systemd espone il
# numero, non la parola.
EXIT_HOW = {"1": "exited", "2": "killed", "3": "dumped"}


def show(unit, user):
    """Le proprieta' di un'unita', o {} se quel `systemctl` non la conosce."""
    args = ["systemctl"] + (["--user"] if user else []) + ["show", unit]
    args += [f"--property={p}" for p in PROPERTIES]

    try:
        done = subprocess.run(args, capture_output=True, text=True, timeout=TIMEOUT)
    except (OSError, subprocess.SubprocessError):
        return {}

    out = {}

    for line in done.stdout.splitlines():
        # Il valore puo' contenere altri "=" (ExecStart e' una struttura
        # intera), quindi si taglia solo al primo.
        key, sep, value = line.partition("=")

        if sep:
            out[key] = value

    return out


# Un messaggio solo puo' valere centinaia di righe — quello di systemd-coredump
# elenca ogni libreria caricata dal processo morto — e chi legge la diagnosi ha
# un budget, che sia una finestra di contesto o una schermata. Si tiene la testa
# del messaggio, che e' dove sta l'errore: la coda e' l'inventario.
MESSAGE_LINES = 3
MESSAGE_CHARS = 400


def clip(message):
    """Il messaggio ridotto a quello che si legge davvero."""
    rows = [r.rstrip() for r in message.splitlines()]
    kept = rows[:MESSAGE_LINES]
    text = " / ".join(r for r in kept if r)

    if len(rows) > MESSAGE_LINES:
        text += f" […{len(rows) - MESSAGE_LINES} righe]"

    return text[:MESSAGE_CHARS] + ("…" if len(text) > MESSAGE_CHARS else "")


def journal(unit, user, lines):
    """Le ultime voci di registro dell'unita', una riga per voce.

    In JSON e non nel formato consueto per due motivi. Il primo e' la data:
    quella del formato consueto e' scritta nella lingua della macchina — su
    questa esce in giapponese — e una data che cambia lingua non e' una data su
    cui si ragiona. Il secondo e' la lunghezza: `-n` conta le voci, non le
    righe, e una voce sola puo' essere lunga quanto tutte le altre insieme.
    """
    args = ["journalctl"] + (["--user"] if user else []) + [
        "-u", unit, "-n", str(lines), "--no-pager", "--output=json",
    ]

    try:
        done = subprocess.run(args, capture_output=True, text=True, timeout=TIMEOUT)
    except (OSError, subprocess.SubprocessError):
        return []

    if done.returncode != 0:
        return []

    out = []

    for row in done.stdout.splitlines():
        try:
            entry = json.loads(row)
        except ValueError:
            continue

        message = entry.get("MESSAGE", "")

        # Un messaggio non testuale arriva come lista di byte: succede con
        # l'output di un programma che scrive spazzatura, e non e' un motivo
        # per far fallire tutta la diagnosi.
        if isinstance(message, list):
            message = bytes(b for b in message if isinstance(b, int)).decode(
                "utf-8", "replace")
        elif not isinstance(message, str):
            message = str(message)

        stamp = entry.get("__REALTIME_TIMESTAMP", "")

        try:
            when = datetime.fromtimestamp(int(stamp) / 1e6).strftime("%Y-%m-%d %H:%M:%S")
        except (TypeError, ValueError):
            when = ""

        who = entry.get("SYSLOG_IDENTIFIER") or entry.get("_COMM") or ""

        out.append({
            "time": when,
            # 0..7 di syslog: sotto il 4 e' un guasto, e distinguerlo evita di
            # dare la stessa importanza a un avviso e a un errore fatale.
            "priority": int(entry.get("PRIORITY", 6) or 6),
            "from": who,
            "text": clip(message),
        })

    return out


def failed_units():
    """Le unita' fallite adesso, utente e sistema, come (scope, nome)."""
    out = []

    for user in (True, False):
        args = ["systemctl"] + (["--user"] if user else []) + [
            "list-units", "--type=service", "--state=failed", "--output=json",
        ]

        for unit in run_json(args):
            name = unit.get("unit", "")

            if name:
                out.append(("user" if user else "system", name))

    return out


def whose(unit, scope):
    """In quale dei due systemd vive quell'unita'.

    Un nome puo' esistere in tutti e due — `syncthing.service` e' l'esempio
    classico — e la risposta giusta e' quella che non e' `not-found`. A parita',
    quella che sta male: chi chiede una diagnosi non sta chiedendo dell'unita'
    che funziona.
    """
    if scope in ("user", "system"):
        return [(scope, show(unit, scope == "user"))]

    found = []

    for name in ("user", "system"):
        props = show(unit, name == "user")

        if props.get("LoadState", "not-found") != "not-found":
            found.append((name, props))

    if not found:
        return []

    broken = [f for f in found if f[1].get("ActiveState") == "failed"]

    return broken or found


def command_of(props):
    """La riga di comando dentro la struttura che stampa `systemctl show`.

    ExecStart esce come `{ path=… ; argv[]=… ; ignore_errors=no ; … }`: di
    tutto quello che c'e' li' dentro serve il comando, il resto e' contabilita'
    di systemd che chi legge una diagnosi non guardera' mai.
    """
    raw = props.get("ExecStart", "")
    found = re.search(r"argv\[\]=(.*?) ; ignore_errors=", raw)

    if found:
        return found.group(1).strip()

    found = re.search(r"path=(\S+)", raw)

    return found.group(1) if found else raw


def diagnose_one(unit, scope, props, lines):
    """Perche' quell'unita' sta come sta: i fatti, e il codice del motivo.

    Il motivo esce come codice e non come frase per la stessa ragione per cui
    lo fa kdeconnect.py: la stessa risposta serve il server MCP in inglese e
    chiunque altro nella sua lingua, e una frase scritta qui dentro sarebbe gia'
    tradotta nella lingua sbagliata per meta' dei suoi lettori.
    """
    result = props.get("Result", "")
    how = EXIT_HOW.get(props.get("ExecMainCode", ""), "")
    status = props.get("ExecMainStatus", "")

    exit_info = {}

    if how:
        exit_info = {"how": how, "status": int(status) if status.isdigit() else status}

        # Un processo ucciso porta il numero del segnale al posto del codice di
        # uscita, e il numero da solo non dice niente a nessuno.
        if how in ("killed", "dumped") and status.isdigit():
            try:
                exit_info["signal"] = signal.Signals(int(status)).name
            except ValueError:
                pass

    active = props.get("ActiveState", "")

    # Il motivo, in ordine di specificita': la condizione non soddisfatta viene
    # prima di tutto perche' in quel caso l'unita' non ha nemmeno provato a
    # partire, e cercare l'errore nel registro sarebbe cercarlo dove non c'e'.
    if props.get("LoadState", "") == "not-found":
        cause = "not-found"
    elif props.get("ConditionResult", "yes") == "no":
        cause = "condition"
    elif props.get("AssertResult", "yes") == "no":
        cause = "assert"
    elif active == "failed":
        cause = result or "unknown"
    elif active in ("active", "activating", "reloading"):
        cause = "running"
    else:
        cause = "stopped"

    return {
        "unit": unit,
        "scope": scope,
        "description": props.get("Description", ""),
        "load": props.get("LoadState", ""),
        "active": active,
        "sub": props.get("SubState", ""),
        "starts_at_boot": props.get("UnitFileState", ""),
        "cause": cause,
        "result": result,
        "exit": exit_info,
        "restarts": int(props.get("NRestarts", "0") or 0),
        "started": props.get("ExecMainStartTimestamp", ""),
        "ended": props.get("ExecMainExitTimestamp", ""),
        "status_text": props.get("StatusText", ""),
        "unit_file": props.get("FragmentPath", "") or props.get("SourcePath", ""),
        "command": command_of(props),
        "triggered_by": props.get("TriggeredBy", ""),
        "invocation": props.get("InvocationID", ""),
        "log": journal(unit, scope == "user", lines),
    }


def diagnose(unit="", scope="", lines=40):
    """La diagnosi di un'unita', o di tutte quelle che stanno male adesso.

    Senza nome guarda i falliti: e' la domanda che si fa davvero — "cosa non
    va" — e farla unita' per unita' vorrebbe dire sapere gia' la risposta a
    meta'. Con l'elenco le righe di registro sono meno, perche' cinque unita'
    a quaranta righe l'una sono duecento righe per una domanda sola.
    """
    if unit:
        found = whose(unit, scope)

        if not found:
            return {"ok": False, "error": f"nessuna unita' chiamata {unit}"}

        return {
            "ok": True,
            "units": [diagnose_one(unit, s, p, lines) for s, p in found],
        }

    wanted = failed_units()

    if scope in ("user", "system"):
        wanted = [w for w in wanted if w[0] == scope]

    if not wanted:
        return {"ok": True, "units": [], "note": "nessun servizio fallito"}

    short = max(8, lines // 3)

    return {
        "ok": True,
        "units": [
            diagnose_one(name, s, show(name, s == "user"), short)
            for s, name in wanted
        ],
    }


def list_all():
    """L'elenco completo, che e' quello che chiede la dashboard."""
    # I quattro systemctl sono indipendenti e passano il tempo ad aspettare
    # il bus: in parallelo l'attesa si dimezza abbondantemente.
    commands = [
        (user, kind)
        for user in (True, False)
        for kind in ("list-units", "list-unit-files")
    ]

    def fetch(job):
        user, kind = job
        args = ["systemctl"] + (["--user"] if user else []) + [kind, "--type=service"]
        if kind == "list-units":
            args.append("--all")
        return run_json(args + ["--output=json"])

    with ThreadPoolExecutor(max_workers=4) as pool:
        out = list(pool.map(fetch, commands))

    return {"user": collect(True, out[0:2]), "system": collect(False, out[2:4])}


if __name__ == "__main__":
    # Senza argomenti fa quello che ha sempre fatto: la dashboard lo chiama
    # cosi', e un elenco che si mette a chiedere un sottocomando sarebbe un
    # pannello vuoto.
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command")

    why = sub.add_parser("diagnose", help="perche' un'unita' sta come sta")
    why.add_argument("unit", nargs="?", default="",
                     help="il nome dell'unita'; vuoto = tutte quelle fallite")
    why.add_argument("--scope", default="", choices=["user", "system"],
                     help="in quale systemd cercarla; vuoto = in tutti e due")
    why.add_argument("--lines", type=int, default=40,
                     help="quante righe di registro (default 40)")

    args = parser.parse_args()

    if args.command == "diagnose":
        payload = diagnose(args.unit, args.scope, max(1, min(args.lines, 200)))
    else:
        payload = list_all()

    json.dump(payload, sys.stdout, ensure_ascii=False)
    sys.stdout.write("\n")

    # L'elenco non ha un `ok` da guardare e vale sempre zero; una diagnosi che
    # non ha trovato l'unita' esce con uno, come fa phone_adb.py.
    sys.exit(0 if payload.get("ok", True) else 1)
