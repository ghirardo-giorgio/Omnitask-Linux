#!/usr/bin/env python3
"""Il tasto pausa della dashboard: ferma quello che sta suonando e lo fa ripartire.

Si parla con i *player*, via MPRIS (`playerctl`), non con il mixer. Mutare il
canale o sospendere il sink toglie il suono ma non ferma niente: la traccia
scorre lo stesso, e un podcast ripreso dopo cinque minuti riparte cinque minuti
piu' avanti. Una pausa che non e' una pausa e' peggio di nessun pulsante.

Il prezzo di questa scelta e' che chi non espone MPRIS non si ferma — un gioco,
un `paplay`, la campanella di un programma. Non e' una dimenticanza: non esiste
un modo di dire «fermati» a uno stream che non ha un'interfaccia per sentirselo
dire, e l'unica alternativa (sospendere il sink) e' quella appena scartata.

Chi riparte non e' «tutti»: e' chi stava suonando quando si e' premuto pausa. La
differenza si vede la prima volta che in un'altra scheda del browser c'e' un
video fermo da ieri — «play» lo farebbe partire, e nessuno l'ha chiesto. Quindi
la lista di chi e' stato fermato si scrive in un file, che sta in
XDG_RUNTIME_DIR perche' e' vera fino al riavvio e non un attimo di piu'.

Uso:
    audiopause.py status
    audiopause.py pause
    audiopause.py resume
    audiopause.py toggle
    audiopause.py watch [--interval 2.0]

Stampa un oggetto JSON per riga:

    {"players": 2, "playing": 1, "paused": 1, "held": ["brave.instance123"],
     "state": "playing"}
    {"error": "playerctl non e' installato"}

`watch` stampa lo stato appena cambia (e la prima volta subito), cosi' il
pannello non interroga niente per conto suo. Esce con 0 anche in errore: chi
legge e' la dashboard, e deve poter mostrare il messaggio invece di un codice.
"""

import argparse
import json
import os
import subprocess
import sys
import time

# I percorsi scritti in ~/.config/quickshell/tools.json vincono sul PATH:
# vedi tools.py, che sta qui accanto.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tools


# Dove si ricorda chi e' stato messo in pausa da qui. In XDG_RUNTIME_DIR: la
# lista vale finche' la sessione e' quella, e al riavvio i player non ci sono
# piu' comunque.
STATE = os.path.join(
    os.environ.get("XDG_RUNTIME_DIR") or "/tmp",
    "quickshell-audiopause.json",
)

# Quanto si aspetta playerctl. E' D-Bus su bus di sessione: se non risponde in
# due secondi non risponde piu', e il pannello non puo' restare appeso.
TIMEOUT = 2.0


def _run(args):
    """playerctl con gli argomenti dati: (uscita, stdout)."""
    exe = tools.which("playerctl")

    if exe is None:
        raise LookupError("playerctl non e' installato")

    done = subprocess.run(
        [exe] + args,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        timeout=TIMEOUT,
    )

    return done.returncode, done.stdout


def players():
    """[(istanza, stato)] per ogni player MPRIS acceso, anche fermo.

    Una chiamata sola per tutti: `--all-players` con un formato che porta il
    nome accanto allo stato. Interrogarli uno per uno vorrebbe dire un processo
    a player a ogni giro di `watch`, che gira per tutto il tempo in cui il
    pannello si vede.
    """
    code, out = _run(["--all-players", "--format", "{{playerInstance}}={{status}}", "status"])

    # Nessun player acceso: playerctl esce con 1 e scrive "No players found".
    # E' lo stato normale di un PC in silenzio, non un guasto.
    if code != 0:
        return []

    found = []

    for line in out.splitlines():
        line = line.strip()

        if not line:
            continue

        # Il nome di un'istanza puo' contenere quasi tutto: si taglia sull'ultimo
        # '=', che e' quello che ha messo il formato.
        name, sep, status = line.rpartition("=")

        if sep:
            found.append((name, status))

    return found


def held_read():
    """I player fermati da qui l'ultima volta."""
    try:
        with open(STATE, "r") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return []

    names = data.get("held")

    return [str(n) for n in names] if isinstance(names, list) else []


def held_write(names):
    try:
        with open(STATE, "w") as fh:
            json.dump({"held": names, "ts": time.time()}, fh)
    except OSError:
        # Senza il file si perde solo la selettivita' del "play": si riparte da
        # quello che si trova in pausa. Non vale un errore in faccia all'utente.
        pass


def snapshot(held=None, settle=False):
    """L'oggetto che il pannello legge.

    Con `settle` si aspetta un attimo prima di guardare: MPRIS risponde al
    comando e cambia PlaybackStatus dopo, e uno stato letto nello stesso istante
    in cui si e' premuto pausa mostra ancora «sta suonando».
    """
    if settle:
        time.sleep(0.3)

    found = players()
    playing = [n for n, s in found if s == "Playing"]
    paused = [n for n, s in found if s == "Paused"]

    if held is None:
        held = [n for n in held_read() if any(n == m for m, _ in found)]

    return {
        "players": len(found),
        "playing": len(playing),
        "paused": len(paused),
        "held": held,
        "state": "playing" if playing else ("paused" if paused else "idle"),
    }


def do_pause():
    """Ferma chi sta suonando, e si segna chi era."""
    stopped = []

    for name, status in players():
        if status != "Playing":
            continue

        code, _ = _run(["--player", name, "pause"])

        # Un player che rifiuta la pausa (ce ne sono: i flussi live) non entra
        # nella lista, cosi' il "play" dopo non prova a farlo ripartire.
        if code == 0:
            stopped.append(name)

    held_write(stopped)

    return snapshot(held=stopped, settle=True)


def do_resume():
    """Fa ripartire chi era stato fermato da qui."""
    found = players()
    alive = {name for name, _ in found}
    wanted = [n for n in held_read() if n in alive]

    # Nessuna memoria — la dashboard e' stata riavviata, o si preme "play" senza
    # aver premuto "pausa": riparte quello che si trova in pausa. E' quello che
    # chiede chi guarda un pulsante play, e la memoria serviva a evitare il caso
    # opposto (far partire roba mai fermata) quando la memoria c'e'.
    if not wanted:
        wanted = [name for name, status in found if status == "Paused"]

    for name in wanted:
        _run(["--player", name, "play"])

    held_write([])

    return snapshot(held=[], settle=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("command", choices=["status", "pause", "resume", "toggle", "watch"])
    ap.add_argument(
        "--interval",
        type=float,
        default=2.0,
        help="secondi fra due letture in watch (default 2)",
    )
    args = ap.parse_args()

    try:
        if args.command == "status":
            print(json.dumps(snapshot()), flush=True)
            return 0

        if args.command == "pause":
            print(json.dumps(do_pause()), flush=True)
            return 0

        if args.command == "resume":
            print(json.dumps(do_resume()), flush=True)
            return 0

        if args.command == "toggle":
            now = snapshot()
            print(json.dumps(do_pause() if now["state"] == "playing" else do_resume()), flush=True)
            return 0
    except (LookupError, OSError, subprocess.SubprocessError) as err:
        print(json.dumps({"error": str(err) or err.__class__.__name__}), flush=True)
        return 0

    # watch: la prima riga subito, poi solo quando cambia qualcosa. Chi guarda
    # ha bisogno di sapere se il tasto e' premibile, non di trenta righe uguali
    # al minuto.
    interval = max(0.5, args.interval)
    last = None

    while True:
        try:
            now = snapshot()
        except (LookupError, OSError, subprocess.SubprocessError) as err:
            now = {"error": str(err) or err.__class__.__name__}

        line = json.dumps(now)

        if line != last:
            print(line, flush=True)
            last = line

        try:
            time.sleep(interval)
        except KeyboardInterrupt:
            return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(0)
