#!/usr/bin/env python3
"""Legge quello che esce dalle casse e ne stampa la forma d'onda, un JSON per fotogramma.

L'oscilloscopio di ProTracker e quello di Winamp fanno la stessa cosa: prendono
una finestra di pochi millisecondi di audio e la disegnano. La differenza fra un
disegno che si legge e uno che trema sta tutta nel *trigger*: senza, la finestra
comincia in un punto a caso del periodo e la forma d'onda scorre di lato a ogni
fotogramma. Qui il trigger si cerca sul passaggio per lo zero in salita, come
facevano quelli veri, e si applica prima di ridurre i campioni a punti.

Il resto e' pipewire: `parec` sul monitor del sink di default. Il monitor non
porta il sink in RUNNING (misurato: resta IDLE con la cattura aperta), quindi
tenerlo aperto non impedisce alle casse di andare a dormire.

Il sink di default cambia sotto i piedi — cuffie che si accendono, HDMI che
prende il posto delle casse — e va riletto ogni tanto: e' la stessa cattura che
ricomincia, non un guasto, e chi guarda vede solo il nome cambiare.

Uscita, una riga per fotogramma:

    {"w": [-127..127], "peak": 0.42, "rms": 0.11, "sink": "...", "ms": 20}
    {"silent": true, "sink": "..."}          quando non suona niente
    {"error": "..."}                          quando manca parec o pactl
"""

import argparse
import array
import json
import os
import select
import subprocess
import sys
import threading
import time

# I percorsi scritti in ~/.config/quickshell/tools.json vincono sul PATH:
# vedi tools.py, che sta qui accanto.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tools


# =============================================================================
# CONFIGURAZIONE
# =============================================================================

# 48 kHz e' il ritmo con cui girano tutti i sink di questa macchina: chiedendo
# lo stesso, pipewire non deve ricampionare niente per noi.
RATE = 48000

# Quanto audio sta in un fotogramma. Venti millisecondi sono il compromesso di
# sempre: abbastanza per due o tre periodi di una nota bassa, abbastanza pochi
# perche' un colpo di batteria non diventi una macchia.
WINDOW_MS = 20.0

# Il tratto in cui si cerca il trigger, in finestre. Cercandolo in un tratto
# lungo quanto la finestra si copre almeno un periodo completo fino a 50 Hz.
TRIGGER_SPAN = 1.0

# Sotto questo picco non c'e' musica, c'e' il fruscio del silenzio digitale:
# -54 dBFS circa. Un valore piu' alto mangerebbe le code dei riverberi.
SILENCE_PEAK = 0.002

# Quanto silenzio prima di dirlo. Serve a non far lampeggiare la scritta fra
# una parola e l'altra di un podcast.
SILENCE_AFTER = 0.8

# Ogni quanto ripetere che c'e' silenzio, e a che ritmo si continua a guardare
# nel frattempo. La riga si ripete piano perche' e' anche il modo in cui il
# nome del sink arriva quando cambia a musica spenta; il ritmo non scende piu'
# in basso di dieci al secondo perche' e' quello il ritardo con cui la prima
# nota fa ripartire il disegno.
SILENCE_REPEAT = 2.0
SILENCE_FPS = 10.0

# Ogni quanto si ricontrolla qual e' il sink di default.
DEVICE_CHECK = 2.0

# Quanto si aspetta prima di riprovare quando parec muore o non parte: il caso
# tipico e' la scheda audio che sparisce per un istante durante un cambio.
RETRY_WAIT = 1.5

# Blocchi di lettura piccoli: il ring buffer deve contenere l'*ultimo* audio,
# non quello di mezzo fotogramma fa.
READ_MS = 5.0


def emit(obj):
    sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
    sys.stdout.flush()


# =============================================================================
# CATTURA
# =============================================================================

class Capture:
    """Il monitor del sink di default dentro un buffer circolare.

    Gira in un thread suo perche' le due cadenze non sono la stessa: l'audio
    arriva quando arriva, i fotogrammi escono a ritmo fisso. Tenerle insieme
    vorrebbe dire far dipendere il disegno dalla dimensione dei blocchi di
    pipewire, che cambia con il carico.
    """

    def __init__(self, keep_samples, device=None):
        self.keep = keep_samples
        self.forced = device
        self.lock = threading.Lock()
        self.ring = array.array("h")
        self.sink = None
        self.error = None
        self.stop = threading.Event()

    # --- il sink da guardare ------------------------------------------------

    def default_monitor(self):
        if self.forced:
            return self.forced

        pactl = tools.which("pactl")

        if not pactl:
            return None

        try:
            out = subprocess.run([pactl, "get-default-sink"], capture_output=True,
                                 text=True, timeout=5)
        except (OSError, subprocess.SubprocessError):
            return None

        name = out.stdout.strip()

        # Un sink di default puo' gia' essere un monitor (raro ma legittimo):
        # in quel caso aggiungere il suffisso lo renderebbe inesistente.
        if not name:
            return None

        return name if name.endswith(".monitor") else name + ".monitor"

    # --- il giro esterno: apri, leggi, riapri -------------------------------

    def run(self):
        parec = tools.which("parec")

        if not parec:
            self.error = "parec non trovato: serve pipewire-pulse o pulseaudio-utils"
            return

        while not self.stop.is_set():
            device = self.default_monitor()

            if not device:
                self.error = "nessun sink di default da ascoltare"
                self.stop.wait(RETRY_WAIT)
                continue

            self.error = None
            self.read_from(parec, device)

            if not self.stop.is_set():
                self.stop.wait(RETRY_WAIT)

    def read_from(self, parec, device):
        chunk = int(RATE * READ_MS / 1000) * 2

        try:
            proc = subprocess.Popen(
                [parec, "--device", device, "--format=s16le",
                 "--rate=%d" % RATE, "--channels=1",
                 "--latency-msec=%d" % int(READ_MS * 2),
                 "--client-name=Dashboard", "--stream-name=Oscilloscopio"],
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        except OSError as exc:
            self.error = "parec non si avvia: %s" % exc
            return

        with self.lock:
            self.sink = device
            self.ring = array.array("h")

        checked = time.monotonic()

        try:
            while not self.stop.is_set():
                # select e non una read secca: quando il sink va in sospensione
                # i dati smettono di arrivare, e una read bloccata non lascia
                # piu' controllare se nel frattempo il default e' cambiato.
                ready, _, _ = select.select([proc.stdout], [], [], 0.5)

                if ready:
                    data = proc.stdout.read(chunk)

                    if not data:
                        break

                    block = array.array("h")
                    block.frombytes(data[:len(data) - len(data) % 2])

                    with self.lock:
                        self.ring.extend(block)

                        if len(self.ring) > self.keep:
                            del self.ring[:len(self.ring) - self.keep]

                now = time.monotonic()

                if now - checked >= DEVICE_CHECK:
                    checked = now

                    if self.default_monitor() != device:
                        break
        finally:
            proc.terminate()

            try:
                proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                proc.kill()

    def window(self, count):
        """Gli ultimi `count` campioni, o meno se non ce ne sono ancora."""
        with self.lock:
            return self.ring[-count:], self.sink, self.error


# =============================================================================
# DISEGNO
# =============================================================================

def trigger(samples, window, level):
    """Da dove far cominciare la finestra: il passaggio per lo zero in salita.

    Si guarda solo il tratto che precede l'ultima finestra, cosi' qualunque
    punto si scelga il disegno resta fatto di audio gia' arrivato. `level` e'
    una soglia proporzionale al picco: senza, in un passaggio piano il trigger
    si aggancerebbe al rumore e la forma d'onda salterebbe comunque.
    """
    span = len(samples) - window

    if span <= 1:
        return max(0, len(samples) - window)

    # Prima si «arma» sotto la soglia negativa, poi si aspetta la risalita
    # attraverso lo zero: cosi' il disegno comincia sempre dallo stesso punto
    # del periodo, ed e' l'aggancio che tiene ferma la forma d'onda. Cercare
    # direttamente lo zero, senza armare, aggancerebbe la prima oscillazione
    # minuscola che passa di li'.
    armed = False

    for i in range(span - 1):
        if not armed:
            armed = samples[i] < -level
        elif samples[i] <= 0 < samples[i + 1]:
            return i

    # Nessun aggancio (un rumore senza periodo, o silenzio): si mostra la coda,
    # che e' comunque l'audio piu' recente.
    return span


def points(samples, start, window, count):
    """La finestra ridotta a `count` colonne, tenendo il campione piu' estremo.

    La media appiattirebbe proprio quello che si guarda in un oscilloscopio: il
    picco. Tenendo il valore assoluto maggiore di ogni gruppo la forma d'onda
    resta spigolosa come quella di ProTracker, e un transiente breve non
    scompare per colpa del ridimensionamento.
    """
    out = []
    end = min(start + window, len(samples))
    span = end - start

    if span <= 0:
        return [0] * count

    for i in range(count):
        a = start + span * i // count
        b = start + span * (i + 1) // count

        if b <= a:
            b = a + 1

        chunk = samples[a:min(b, end)]

        if not chunk:
            out.append(0)
            continue

        top = max(chunk)
        bottom = min(chunk)
        peak = top if top >= -bottom else bottom
        out.append(int(peak * 127 / 32768))

    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--fps", type=float, default=30.0, help="fotogrammi al secondo")
    ap.add_argument("--points", type=int, default=96, help="colonne della forma d'onda")
    ap.add_argument("--window", type=float, default=WINDOW_MS, help="millisecondi mostrati")
    ap.add_argument("--device", help="sorgente da ascoltare invece del monitor di default")
    args = ap.parse_args()

    fps = max(5.0, min(60.0, args.fps))
    count = max(8, min(512, args.points))
    window = int(RATE * max(4.0, min(200.0, args.window)) / 1000)
    look = int(window * (1 + TRIGGER_SPAN))

    cap = Capture(keep_samples=look * 2, device=args.device)
    worker = threading.Thread(target=cap.run, daemon=True)
    worker.start()

    period = 1.0 / fps
    quiet_period = max(period, 1.0 / SILENCE_FPS)
    quiet_since = time.monotonic()
    said_quiet = 0.0
    quiet = False
    said_error = None
    next_frame = time.monotonic()

    while True:
        # A musica spenta non serve guardare trenta volte al secondo: si
        # rallenta, e la prima nota rimette il ritmo pieno entro un decimo di
        # secondo — prima che chi guarda se ne accorga.
        next_frame += quiet_period if quiet else period
        wait = next_frame - time.monotonic()

        if wait > 0:
            time.sleep(wait)
        else:
            # Rimasti indietro (la macchina ha avuto da fare): si riparte da
            # adesso invece di rincorrere i fotogrammi persi.
            next_frame = time.monotonic()

        samples, sink, error = cap.window(look)

        if error:
            if error != said_error:
                said_error = error
                emit({"error": error})

            continue

        said_error = None

        if len(samples) < window:
            continue

        peak = max(max(samples), -min(samples)) / 32768.0
        now = time.monotonic()

        if peak >= SILENCE_PEAK:
            quiet_since = now
            quiet = False
        elif now - quiet_since >= SILENCE_AFTER:
            # Il silenzio si dice di rado: trenta righe al secondo di linea
            # piatta sono trenta ridisegni per niente. Ripeterlo ogni tanto
            # invece che una volta sola serve a far arrivare il nome del sink
            # anche quando cambia mentre non suona nulla.
            quiet = True

            if now - said_quiet >= SILENCE_REPEAT:
                said_quiet = now
                emit({"silent": True, "sink": sink})

            continue

        level = max(64, int(peak * 32768 * 0.15))
        start = trigger(samples, window, level)

        total = 0

        for s in samples[start:start + window]:
            total += s * s

        rms = (total / max(1, window)) ** 0.5 / 32768.0

        emit({
            "w": points(samples, start, window, count),
            "peak": round(peak, 4),
            "rms": round(rms, 4),
            "sink": sink,
            "ms": round(window * 1000.0 / RATE, 1),
        })


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
    except BrokenPipeError:
        # La dashboard ha chiuso il pannello: non e' un guasto da raccontare.
        pass
