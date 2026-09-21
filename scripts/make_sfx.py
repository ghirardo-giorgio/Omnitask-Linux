#!/usr/bin/env python3
"""Genera gli effetti sonori del pet, invece di scaricarli.

Quattro suoni brevi, sintetizzati a onda quadra come li faceva una console a 8
bit: il preavviso di un bonus, quello di un malus, il tonfo a terra e la
raccolta. Sono generati e non presi da un pacchetto perche' cosi' non c'e' una
licenza da portare dietro, pesano insieme una manciata di kilobyte, e soprattutto
suonano come il pet e' disegnato — l'alternativa erano i suoni di sistema di
freedesktop, che sono suoni da scrivania e in una stanza a pixel stonano.

WAV PCM a 22050 Hz mono e non Ogg: SoundEffect di QtMultimedia legge WAV non
compressi e basta, ed e' l'unico formato che si puo' preparare in memoria e far
partire senza latenza.

Si rigenerano con:

    python3 scripts/make_sfx.py

Uscita: un oggetto JSON su stdout, come ogni script di questo progetto.
"""

import json
import math
import os
import struct
import sys
import wave

RATE = 22050
AMP = 20000  # su 32767: lascia margine, un suono d'interfaccia non deve pizzicare

HERE = os.path.dirname(os.path.abspath(__file__))
OUT_DIR = os.path.join(os.path.dirname(HERE), "sfx")


def square(freq, ms, volume=1.0, duty=0.5, decay=True):
    """Un'onda quadra, che e' il timbro della cosa: una sinusoide suonerebbe
    come un avviso di sistema, e il duty cycle e' quello che distingue il
    "blip" dal "pob" su un chip vero."""
    n = int(RATE * ms / 1000.0)
    out = []
    for i in range(n):
        phase = (i * freq / RATE) % 1.0
        v = 1.0 if phase < duty else -1.0
        # Coda che scende: un'onda tagliata di netto fa un clic, e il clic e'
        # esattamente cio' che rende "rotto" un suono altrimenti giusto.
        env = 1.0
        if decay:
            env = max(0.0, 1.0 - i / n) ** 0.6
        # Attacco di 2 ms, per la stessa ragione dall'altra parte.
        edge = min(1.0, i / max(1.0, RATE * 0.002))
        out.append(v * volume * env * edge)
    return out


def noise(ms, volume=1.0, seed=7):
    """Rumore pseudo-casuale deterministico: un LCG e non `random`, cosi' il
    file generato oggi e quello generato fra un anno sono lo stesso file."""
    n = int(RATE * ms / 1000.0)
    out = []
    state = seed
    for i in range(n):
        state = (1103515245 * state + 12345) & 0x7FFFFFFF
        v = (state / 0x3FFFFFFF) - 1.0
        env = max(0.0, 1.0 - i / n) ** 2.0
        out.append(v * volume * env)
    return out


def silence(ms):
    return [0.0] * int(RATE * ms / 1000.0)


def mix(*tracks):
    """Somma tracce di lunghezza diversa, allineate all'inizio."""
    length = max(len(t) for t in tracks)
    out = [0.0] * length
    for t in tracks:
        for i, v in enumerate(t):
            out[i] += v
    return out


def write(name, samples):
    peak = max((abs(v) for v in samples), default=0.0)
    scale = 1.0 if peak <= 1.0 else 1.0 / peak
    path = os.path.join(OUT_DIR, name)
    with wave.open(path, "wb") as f:
        f.setnchannels(1)
        f.setsampwidth(2)
        f.setframerate(RATE)
        f.writeframes(b"".join(
            struct.pack("<h", int(max(-1.0, min(1.0, v * scale)) * AMP))
            for v in samples
        ))
    return {"file": name, "bytes": os.path.getsize(path),
            "ms": round(len(samples) * 1000.0 / RATE)}


def main():
    try:
        os.makedirs(OUT_DIR, exist_ok=True)

        made = []

        # Preavviso di un bonus: due note che SALGONO. Sale = sta per arrivare
        # qualcosa di buono, ed e' la convenzione di tutti i giochi in cui una
        # cosa cade dall'alto.
        made.append(write("warn_bonus.wav",
                          square(784, 70, 0.55, 0.5) +   # sol
                          square(1046, 110, 0.55, 0.5)))  # do

        # Preavviso di un malus: le stesse due note al contrario e con il duty
        # storto, che e' il modo in cui un chip suona "sbagliato".
        made.append(write("warn_malus.wav",
                          square(392, 80, 0.55, 0.25) +
                          square(262, 130, 0.55, 0.25)))

        # Il tonfo: un tono basso e un pizzico di rumore insieme, corti. E'
        # l'unico che non deve essere una nota — una nota si legge come un
        # premio, e qui l'oggetto ha solo toccato terra.
        made.append(write("land.wav",
                          mix(square(120, 90, 0.5, 0.5),
                              noise(70, 0.35))))

        # La raccolta: la moneta. Due note veloci, la seconda piu' alta e piu'
        # lunga, senza rumore: e' il suono piu' importante dei quattro perche'
        # e' l'unico che segue una cosa che il giocatore ha ottenuto.
        made.append(write("catch.wav",
                          square(988, 60, 0.6, 0.5, decay=False) +
                          square(1319, 200, 0.6, 0.5)))

        print(json.dumps({"ok": True, "dir": OUT_DIR, "files": made}))
        return 0
    except Exception as exc:  # l'errore e' un campo, non una traccia Python
        print(json.dumps({"ok": False, "error": str(exc)}))
        return 1


if __name__ == "__main__":
    sys.exit(main())
