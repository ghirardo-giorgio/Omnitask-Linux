#!/usr/bin/env python3
"""Elenca i servizi systemd, utente e di sistema, in un unico JSON.

Servono due comandi per avere il quadro completo: `list-units` dice se un
servizio sta girando adesso, `list-unit-files` se parte da solo all'avvio.
Sono insiemi diversi (un servizio installato ma mai caricato compare solo nel
secondo), quindi si uniscono per nome.
"""
import json
import subprocess
import sys
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


if __name__ == "__main__":
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

    json.dump(
        {"user": collect(True, out[0:2]), "system": collect(False, out[2:4])},
        sys.stdout,
    )
    sys.stdout.write("\n")
