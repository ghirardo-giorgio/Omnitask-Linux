#!/usr/bin/env python3
"""Elenca i pannelli aggiunti dall'utente in panels/.

QML non sa elencare una cartella — non c'e' modo, dentro il linguaggio, di
chiedere "cosa c'e' qui dentro" — quindi lo fa un processo, come per i servizi
e per l'hardware.

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

        declared = DECLARED_TITLE.search(text)

        entry = {
            # Prefisso perche' un pannello dell'utente non possa mai scavalcare
            # uno di casa che si chiami allo stesso modo: gli id finiscono
            # nella configurazione, e una collisione la sposterebbe in silenzio.
            "id": "user:" + stem,
            "file": "panels/" + stem,
            "title": declared.group(1) if declared else readable(stem),
            "bytes": os.path.getsize(path),
        }

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
