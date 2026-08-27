#!/usr/bin/env python3
"""Legge e ripristina la posizione delle finestre della dashboard.

QML non ha voce in capitolo su *dove* si apre una finestra: `WindowInterface`
espone dimensione e schermo, non le coordinate. Su GNOME Wayland l'unico che
puo' spostarla e' il compositor, raggiungibile tramite l'estensione "Window
Calls" — la stessa che Stenografa usa per sapere quale applicazione e' in primo
piano.

    winplace.py get <titolo>
    winplace.py set <titolo> <x> <y> [<larghezza> <altezza>]

Senza l'estensione non succede nulla e il comando lo dice: la finestra si
aprira' dove decide il window manager, che e' il comportamento di prima.

Con larghezza e altezza `set` rimette anche la misura, e non e' un di piu':
Qt non lascia scrivere `width`/`height` di una finestra e legge le implicite
una volta sola, quando la finestra viene mappata. Se in quel momento il
compositor la stringe — perche' la sta aprendo su uno schermo piu' piccolo di
quello dove andra' a finire — da QML non c'e' piu' modo di rimediare. Il
compositor invece puo': e' lo stesso che l'ha stretta. Le misure di `get` e di
`set` sono quelle del **bordo**, decorazione compresa, non dell'area cliente
che conosce Qt: la differenza fra le due si misura confrontandole, e cambia
col tema.

Stampa sempre un oggetto JSON su stdout.
"""
import json
import re
import subprocess
import sys

DEST = "org.gnome.Shell"
PATH = "/org/gnome/Shell/Extensions/Windows"
IFACE = "org.gnome.Shell.Extensions.Windows"


def call(method, *args):
    cmd = ["gdbus", "call", "--session", "--dest", DEST, "--object-path", PATH,
           "--method", f"{IFACE}.{method}"] + [str(a) for a in args]
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.SubprocessError) as exc:
        return None, f"estensione non raggiungibile: {exc}"
    if out.returncode != 0:
        return None, "estensione Window Calls non attiva"
    return out.stdout.strip(), None


def unwrap(raw):
    """gdbus incarta la risposta in ('...',), oppure in ("...",).

    Quale delle due lo decide il contenuto: GVariant stampa le stringhe fra
    apici, ma passa alle virgolette appena dentro c'e' un apice. Basta quindi
    che *una qualsiasi* finestra aperta abbia un apostrofo nel titolo perche'
    ogni risposta cambi forma — e cercando solo l'apice, questa funzione
    smetteva di leggere tutte le finestre, non quella. Sintomo: le finestre
    non si riaprivano piu' dove erano state lasciate, senza nessun errore.

    Cambia forma anche l'escape: il delimitatore usato viene preceduto da una
    barra, e con le virgolette tocca a ogni virgoletta del JSON. Si sfila solo
    quello, non gli escape del JSON: un \n dentro un titolo deve restare \n.
    """
    text = raw.strip()
    if text.startswith("(") and text.endswith(",)"):
        text = text[1:-2].strip()

    if len(text) < 2 or text[0] != text[-1] or text[0] not in "'\"":
        return None

    quote = text[0]
    inner = re.sub(r"\\([\\%s])" % re.escape(quote), r"\1", text[1:-1])

    try:
        return json.loads(inner)
    except json.JSONDecodeError:
        return None


def find(title):
    raw, error = call("List")
    if error:
        return None, error
    windows = unwrap(raw) or []
    for w in windows:
        # il titolo e' quello che l'utente vede sulla barra: piu' stabile
        # dell'id, che cambia a ogni riavvio della dashboard
        if (w.get("title") or "") == title and w.get("wm_class", "").startswith("org.quickshell"):
            return w.get("id"), None
    return None, f"nessuna finestra \"{title}\""


def main():
    args = sys.argv[1:]
    if len(args) >= 2 and args[0] == "get":
        wid, error = find(args[1])
        if error:
            result = {"ok": False, "error": error}
        else:
            raw, error = call("GetFrameRect", wid)
            rect = unwrap(raw) if raw else None
            result = {"ok": bool(rect), "error": error or "", **(rect or {})}
    elif len(args) >= 4 and args[0] == "set":
        wid, error = find(args[1])
        if error:
            result = {"ok": False, "error": error}
        elif len(args) >= 6:
            # Con la misura si sposta e si ridimensiona in un colpo solo: due
            # chiamate separate farebbero saltare la finestra due volte.
            _, error = call("MoveResize", wid, int(args[2]), int(args[3]),
                            int(args[4]), int(args[5]))
            result = {"ok": error is None, "error": error or "", "resized": True}
        else:
            _, error = call("Move", wid, int(args[2]), int(args[3]))
            result = {"ok": error is None, "error": error or "", "resized": False}
    else:
        result = {"ok": False,
                  "error": "uso: winplace.py get <titolo> | "
                           "set <titolo> <x> <y> [<larghezza> <altezza>]"}

    json.dump(result, sys.stdout, ensure_ascii=False)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
