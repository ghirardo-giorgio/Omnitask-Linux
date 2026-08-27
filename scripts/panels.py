#!/usr/bin/env python3
"""Elenca i pannelli in panels/: sono tutti li', di casa e aggiunti dall'utente.

QML non sa elencare una cartella — non c'e' modo, dentro il linguaggio, di
chiedere "cosa c'e' qui dentro" — quindi lo fa un processo, come per i servizi
e per l'hardware. Dall'elenco esce il catalogo per intero: la dashboard lo usa
per costruirsi e la finestra opzioni per farlo modificare, e non esiste piu'
nessun secondo elenco di pannelli scritto altrove.

Il posto e' obbligato, non una preferenza: Quickshell registra i singleton
(SystemStats, I18n, Settings) per cartella di configurazione, e un .qml che sta
altrove si carica benissimo ma li vede tutti `undefined`. Misurato: da fuori
cpu=undefined, da qui dentro cpu=17.9. Nessun import rimedia, nemmeno con lo
schema file:// per esteso.

Da cui anche l'unico requisito che si chiede a chi scrive un pannello: la riga
`import ".."` in cima. Senza quella, un file che sta nel posto giusto vede
comunque il nulla, ed e' un errore che non si indovina — quindi si controlla
qui e si dice, invece di lasciare una riga vuota nella dashboard.
"""
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
PANELS = os.path.join(ROOT, "panels")

# `import ".."`, con virgolette singole o doppie e spazi a piacere.
PARENT_IMPORT = re.compile(r'^\s*import\s+[\'"]\.\.[\'"]', re.M)

# Il titolo di default e' il nome del file reso leggibile: MioPannello.qml
# diventa "Mio Pannello". Chi vuole un titolo suo lo scrive nel file.
DECLARED_TITLE = re.compile(r'property\s+string\s+panelTitle\s*:\s*[\'"](.+?)[\'"]')

# L'id con cui il pannello finisce nella configurazione (le colonne di
# dashboard.json lo citano). Chi non lo dichiara riceve "user:" piu' il nome
# del file, che e' unico per costruzione; chi lo dichiara sceglie il suo, e
# deve scegliere un id che nessun altro file ha gia' preso.
DECLARED_ID = re.compile(r'property\s+string\s+panelId\s*:\s*[\'"]([A-Za-z0-9_:.-]+)[\'"]')


def readable(name):
    """MioPannello -> "Mio Pannello", meteo_locale -> "Meteo locale"."""
    spaced = re.sub(r"(?<=[a-z0-9])(?=[A-Z])", " ", name).replace("_", " ").replace("-", " ")
    spaced = " ".join(spaced.split())
    return spaced[:1].upper() + spaced[1:] if spaced else name


def collect():
    if not os.path.isdir(PANELS):
        # Non e' un guasto: e' il caso normale di chi non ne ha aggiunto
        # nessuno. La si crea cosi' chi va a cercarla la trova.
        try:
            os.makedirs(PANELS, exist_ok=True)
        except OSError as exc:
            return {"ok": False, "error": f"cartella dei pannelli non accessibile: {exc}",
                    "panels": [], "directory": PANELS}

    out = []

    try:
        names = sorted(os.listdir(PANELS))
    except OSError as exc:
        return {"ok": False, "error": f"cartella dei pannelli illeggibile: {exc}",
                "panels": [], "directory": PANELS}

    # Gli id gia' visti, per rifiutare i doppioni: due file con lo stesso id si
    # farebbero gare per la stessa riga della configurazione, e chi arriva
    # secondo non deve entrare nel catalogo in silenzio. Vince il primo in
    # ordine di nome, che e' lo stesso ordine con cui la lista si mostra.
    taken = {}

    for name in names:
        if not name.endswith(".qml"):
            continue

        path = os.path.join(PANELS, name)
        if not os.path.isfile(path):
            continue

        stem = name[:-4]

        # Un componente QML deve cominciare per maiuscola, altrimenti il file
        # non e' istanziabile e il Loader fallisce senza spiegare perche'.
        if not stem[:1].isupper():
            out.append({
                "id": "user:" + stem,
                "file": "panels/" + stem,
                "title": readable(stem),
                "error": "il nome del file deve cominciare per maiuscola",
            })
            continue

        try:
            with open(path, "r", errors="replace") as handle:
                text = handle.read()
        except OSError as exc:
            out.append({"id": "user:" + stem, "file": "panels/" + stem,
                        "title": readable(stem), "error": f"illeggibile: {exc}"})
            continue

        declared_title = DECLARED_TITLE.search(text)
        declared_id = DECLARED_ID.search(text)

        entry = {
            # Prefisso perche' un pannello dell'utente non possa mai scavalcare
            # uno che dichiara lo stesso id: gli id finiscono nella
            # configurazione, e una collisione la sposterebbe in silenzio.
            "id": declared_id.group(1) if declared_id else "user:" + stem,
            "file": "panels/" + stem,
            "title": declared_title.group(1) if declared_title else readable(stem),
            "bytes": os.path.getsize(path),
        }

        other = taken.get(entry["id"])
        if other:
            entry["error"] = f'id duplicato "{entry["id"]}": gia\' usato da {other}'
        else:
            taken[entry["id"]] = name

        if not PARENT_IMPORT.search(text):
            entry["warning"] = (
                'manca `import ".."` in cima: senza, il pannello si carica ma '
                "SystemStats, Settings e I18n restano indefiniti"
            )

        out.append(entry)

    return {"ok": True, "panels": out, "directory": PANELS}


if __name__ == "__main__":
    json.dump(collect(), sys.stdout, ensure_ascii=False)
    sys.stdout.write("\n")
