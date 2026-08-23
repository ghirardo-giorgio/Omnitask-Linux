#!/usr/bin/env python3
"""Genera world.json: i profili delle terre emerse per il globo della dashboard.

Da lanciare a mano, una volta sola — il risultato sta nel progetto e a runtime
non serve nessuna rete. Se un giorno il file va rigenerato, il come e' qui.

    python3 scripts/make_world.py

La fonte e' Natural Earth 110m "land" (dominio pubblico), la risoluzione piu'
grossa delle tre: su un globo da qualche centinaio di pixel le altre due
aggiungerebbero soltanto byte. Il GeoJSON originale viene ridotto a un elenco di
anelli di coordinate, arrotondate a un decimale (~11 km, piu' fine di quanto un
pixel possa mostrare) e senza i punti che dopo l'arrotondamento coincidono col
precedente.
"""
import json
import math
import sys
import urllib.request
from pathlib import Path

SOURCE = (
    "https://raw.githubusercontent.com/martynafford/natural-earth-geojson/"
    "master/110m/physical/ne_110m_land.json"
)
OUTPUT = Path(__file__).resolve().parent.parent / "world.json"
# gradi quadrati: sotto questa soglia l'anello e' un'isola che a questa scala
# occuperebbe meno di un pixel
MIN_AREA = 1.5
DECIMALS = 1


def ring_area(ring):
    """Area del poligono in gradi quadrati (formula del laccio di scarpe).

    Non e' un'area vera — i gradi di longitudine si stringono verso i poli — ma
    serve solo a distinguere un continente da uno scoglio."""
    total = 0.0
    for i in range(len(ring)):
        x1, y1 = ring[i]
        x2, y2 = ring[(i + 1) % len(ring)]
        total += x1 * y2 - x2 * y1
    return abs(total) / 2.0


def simplify(ring):
    """Arrotonda e togli i punti diventati uguali al precedente."""
    out = []
    for lon, lat in ring:
        point = [round(lon, DECIMALS), round(lat, DECIMALS)]
        if not out or point != out[-1]:
            out.append(point)
    # l'anello si chiude da se' in fase di disegno: l'ultimo punto uguale al
    # primo e' un doppione
    if len(out) > 1 and out[0] == out[-1]:
        out.pop()
    return out


def rings_of(geometry):
    """Solo gli anelli esterni: i successivi sono laghi e buchi, che a questa
    scala non si vedono e raddoppierebbero il file."""
    kind = geometry.get("type")
    coords = geometry.get("coordinates") or []
    if kind == "Polygon":
        return [coords[0]] if coords else []
    if kind == "MultiPolygon":
        return [polygon[0] for polygon in coords if polygon]
    return []


def main():
    print(f"scarico {SOURCE}")
    try:
        with urllib.request.urlopen(SOURCE, timeout=30) as response:
            data = json.load(response)
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
        print(f"non riuscito: {exc}", file=sys.stderr)
        return 1

    rings = []
    for feature in data.get("features", []):
        for ring in rings_of(feature.get("geometry") or {}):
            simple = simplify(ring)
            if len(simple) >= 4 and ring_area(simple) >= MIN_AREA:
                rings.append(simple)

    rings.sort(key=ring_area, reverse=True)
    OUTPUT.write_text(json.dumps({"rings": rings}, separators=(",", ":")) + "\n")

    points = sum(len(r) for r in rings)
    size = OUTPUT.stat().st_size
    print(f"scritto {OUTPUT.name}: {len(rings)} contorni, {points} punti, "
          f"{size / 1024:.1f} KB")
    return 0


if __name__ == "__main__":
    sys.exit(main())
