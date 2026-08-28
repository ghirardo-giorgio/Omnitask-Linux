#!/usr/bin/env python3
"""Cancella dallo storico di Home Assistant una lettura sbagliata.

Serve al menu del tasto destro dei grafici: un igrometro che per una volta
legge 90% mentre l'aria sta al 47 lascia nel grafico una montagna che non e'
mai esistita, e finche' quella lettura sta nel recorder torna a ogni
ricaricamento — cancellarla dalla dashboard e basta durerebbe cinque minuti.

Le API di Home Assistant non sanno cancellare un singolo stato: `recorder.purge`
e `recorder.purge_entities` ragionano in giorni e in entita' intere, e non
esiste una DELETE fra le REST. Quindi si scende nel database del recorder, che
e' lo stesso posto da cui l'API storico rilegge — la cancellazione si vede al
primo aggiornamento del grafico.

Il database appartiene a root perche' Home Assistant gira in un container:
quando non e' scrivibile da qui, questo stesso file viene spedito dentro il
container su stdin e rieseguito li' con --db. Un solo pezzo di codice, in due
posti, senza copie da tenere allineate.

Cosa tocca, per l'intervallo indicato e per quella sola entita':

- `states`: le righe registrate li' dentro. Prima si azzera `old_state_id` di
  chi puntava a una riga che sta per sparire, come fa la purga di Home
  Assistant: una catena rotta la ritrova il recorder mesi dopo, e non si
  capirebbe piu' da dove viene.
- `statistics_short_term`: i cinque minuti aggregati, se no il picco resta
  nella scheda statistiche del sensore anche dopo che il grafico e' pulito.
  Non solo quelli dell'intervallo: uno stato di Home Assistant vale finche' non
  ne arriva un altro, quindi la lettura sbagliata compare anche negli aggregati
  che la seguono fino alla lettura dopo, e si cancellano anche quelli.
- `statistics`: l'ora che conteneva quei cinque minuti si ricalcola da quelli
  rimasti, invece di cancellarla intera — un'ora sono dodici bucket, e undici
  sono buoni. `sum` e `state` dei contatori non si toccano: sono valori
  progressivi, e ricalcolarli da qui vorrebbe dire riscrivere l'energia di
  tutti i giorni successivi.

Solo libreria standard: dentro il container c'e' il Python di Home Assistant e
nient'altro di garantito.
"""
import argparse
import json
import os
import sqlite3
import subprocess
import sys
import time

# Dove sta il database dentro il container: e' il percorso di casa di Home
# Assistant, /config e' il volume che chiunque monta.
DB_IN_CONTAINER = "/config/home-assistant_v2.db"

# Un secondo non basta: il recorder scrive di continuo, e con WAL una
# transazione in corso tiene il lock per il tempo del proprio commit. Trenta
# secondi sono l'attesa oltre la quale conviene dire che non si e' riusciti.
LOCK_TIMEOUT = 30


def fail(message):
    """L'errore e' un campo, non una traccia Python: chi legge e' un grafico."""
    print(json.dumps({"ok": False, "error": message}))
    sys.exit(1)


# --------------------------------------------------------------- il container


def container():
    """Il nome del container di Home Assistant, o None se non ce n'e' uno."""
    try:
        listing = subprocess.run(
            ["docker", "ps", "--format", "{{.Names}}\t{{.Image}}"],
            capture_output=True, text=True, timeout=15,
        )
    except (OSError, subprocess.SubprocessError):
        return None

    if listing.returncode != 0:
        return None

    for line in listing.stdout.splitlines():
        name, _, image = line.partition("\t")
        if "home-assistant" in image or "homeassistant" in name or "hass" in name:
            return name

    return None


def host_db(name):
    """Il database visto da qui: il volume montato su /config piu' il nome.

    Se e' scrivibile si lavora direttamente, senza passare da docker — un
    processo in meno e un errore in meno da spiegare. Su un'installazione dove
    il container gira come root non lo e', ed e' il caso normale.
    """
    try:
        found = subprocess.run(
            ["docker", "inspect", name, "--format",
             "{{range .Mounts}}{{.Source}}\t{{.Destination}}\n{{end}}"],
            capture_output=True, text=True, timeout=15,
        )
    except (OSError, subprocess.SubprocessError):
        return None

    if found.returncode != 0:
        return None

    for line in found.stdout.splitlines():
        source, _, destination = line.partition("\t")
        if destination.strip() == "/config" and source:
            return os.path.join(source, os.path.basename(DB_IN_CONTAINER))

    return None


def delegate(name, argv):
    """Rispedisce questo file dentro il container e ne riporta la risposta."""
    with open(os.path.abspath(__file__), "rb") as myself:
        source = myself.read()

    try:
        run = subprocess.run(
            ["docker", "exec", "-i", name, "python3", "-", "--db", DB_IN_CONTAINER] + argv,
            input=source, capture_output=True, timeout=120,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        fail(f"docker exec su {name} non riuscito: {exc}")

    answer = run.stdout.decode(errors="replace").strip()

    if not answer:
        error = run.stderr.decode(errors="replace").strip().splitlines()
        fail(error[-1] if error else f"nessuna risposta da {name}")

    # La risposta e' gia' la riga JSON che ci hanno chiesto: si ripete tale e
    # quale, compreso il codice d'uscita.
    print(answer)
    sys.exit(run.returncode)


# ---------------------------------------------------------------- il database


def columns(db, table):
    return {row[1] for row in db.execute(f"pragma table_info({table})")}


def states_meta(db, entity):
    """L'entita' negli stati. Le tabelle la citano per numero, non per nome."""
    row = db.execute("select metadata_id from states_meta where entity_id = ?", (entity,)).fetchone()
    return row[0] if row else None


def statistics_meta(db, entity):
    """La stessa entita' fra le statistiche, dove il numero e' un altro."""
    row = db.execute("select id from statistics_meta where statistic_id = ?", (entity,)).fetchone()
    return row[0] if row else None


def purge_states(db, entity, start, end):
    """Le righe di stato dell'intervallo. Torna quante ne sono sparite."""
    meta = states_meta(db, entity)

    if meta is None:
        return 0

    ids = [row[0] for row in db.execute(
        "select state_id from states"
        " where metadata_id = ? and last_updated_ts >= ? and last_updated_ts < ?",
        (meta, start, end),
    )]

    if not ids:
        return 0

    # A blocchi: un bucket di cinque minuti ne contiene una manciata, ma la
    # stessa funzione deve reggere anche un intervallo lungo senza sfondare il
    # limite di variabili di sqlite.
    for chunk in (ids[i:i + 400] for i in range(0, len(ids), 400)):
        marks = ",".join("?" * len(chunk))
        db.execute(f"update states set old_state_id = NULL where old_state_id in ({marks})", chunk)
        db.execute(f"delete from states where state_id in ({marks})", chunk)

    return len(ids)


def next_state_ts(db, entity, end):
    """Quando e' arrivata la lettura successiva, o None se non e' arrivata.

    Fino a li' valeva quella che si sta cancellando: e' la coda in cui gli
    aggregati la ripetono, e senza toglierla il picco resterebbe nelle
    statistiche del sensore anche dopo essere sparito dal grafico.
    """
    meta = states_meta(db, entity)

    if meta is None:
        return None

    row = db.execute(
        "select min(last_updated_ts) from states"
        " where metadata_id = ? and last_updated_ts >= ?",
        (meta, end),
    ).fetchone()

    return row[0] if row and row[0] else None


def purge_statistics(db, entity, start, end):
    """I cinque minuti aggregati, e l'ora che li conteneva. Torna quanti."""
    meta = statistics_meta(db, entity)

    if meta is None:
        return 0

    gone = db.execute(
        "delete from statistics_short_term"
        " where metadata_id = ? and start_ts >= ? and start_ts < ?",
        (meta, start, end),
    ).rowcount

    if gone <= 0:
        return 0

    weighted = "mean_weight" in columns(db, "statistics_short_term")

    # Le ore toccate: una cancellazione a cavallo di due ore ne rifa' due.
    first = int(start // 3600) * 3600
    for hour in range(first, int(end) + 1, 3600):
        row = db.execute(
            "select id, mean, sum from statistics where metadata_id = ? and start_ts = ?",
            (meta, hour),
        ).fetchone()

        if row is None:
            continue

        rows = db.execute(
            "select mean, min, max" + (", mean_weight" if weighted else "") +
            " from statistics_short_term"
            " where metadata_id = ? and start_ts >= ? and start_ts < ?",
            (meta, hour, hour + 3600),
        ).fetchall()

        means = [r for r in rows if r[0] is not None]

        if not means:
            # Un'ora rimasta senza nemmeno un bucket non ha piu' niente da
            # dire. Quella di un contatore invece si tiene: `sum` e' il totale
            # progressivo, e toglierlo farebbe crollare tutti i giorni dopo.
            if row[2] is None:
                db.execute("delete from statistics where id = ?", (row[0],))
            continue

        if weighted and all(r[3] for r in means):
            total = sum(r[3] for r in means)
            mean = sum(r[0] * r[3] for r in means) / total
        else:
            mean = sum(r[0] for r in means) / len(means)

        lows = [r[1] for r in rows if r[1] is not None]
        highs = [r[2] for r in rows if r[2] is not None]

        db.execute(
            "update statistics set mean = ?, min = ?, max = ? where id = ?",
            (mean, min(lows) if lows else None, max(highs) if highs else None, row[0]),
        )

    return gone


def delete(path, entity, start, end):
    if not os.path.exists(path):
        fail(f"database del recorder non trovato: {path}")

    try:
        db = sqlite3.connect(path, timeout=LOCK_TIMEOUT)
    except sqlite3.Error as exc:
        fail(f"database non apribile ({path}): {exc}")

    try:
        with db:
            states = purge_states(db, entity, start, end)
            # Senza niente da cancellare non c'e' nemmeno una coda da
            # rincorrere: gli aggregati di quell'intervallo raccontano una
            # lettura che sta altrove, e non sono affare di questa chiamata.
            tail = end
            if states:
                tail = next_state_ts(db, entity, end) or time.time()
            statistics = purge_statistics(db, entity, start, tail)
    except sqlite3.OperationalError as exc:
        # "database is locked" dopo trenta secondi vuol dire che il recorder
        # sta scrivendo molto: riprovare fra poco e' un consiglio, non un
        # guasto da segnalare come tale.
        fail(f"database occupato ({exc}): riprova fra qualche secondo")
    except sqlite3.Error as exc:
        fail(f"cancellazione non riuscita: {exc}")
    finally:
        db.close()

    print(json.dumps({
        "ok": True,
        "entity": entity,
        "deleted": states,
        "statistics": statistics,
    }))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", help="database del recorder, se non e' quello del container")
    sub = parser.add_subparsers(dest="command", required=True)

    cut = sub.add_parser("delete", help="cancella le letture di un intervallo")
    cut.add_argument("--entity", required=True)
    # In millisecondi perche' li' arrivano da QML, dove il tempo e' Date.now().
    cut.add_argument("--from", dest="start", type=int, required=True)
    cut.add_argument("--to", dest="end", type=int, required=True)

    args = parser.parse_args()

    if args.end <= args.start:
        fail("intervallo vuoto: --to deve venire dopo --from")

    if args.db:
        delete(args.db, args.entity, args.start / 1000, args.end / 1000)
        return

    name = container()

    if name is None:
        fail("nessun container di Home Assistant in esecuzione: indica il database con --db")

    local = host_db(name)

    if local and os.access(local, os.W_OK):
        delete(local, args.entity, args.start / 1000, args.end / 1000)
        return

    delegate(name, sys.argv[1:])


if __name__ == "__main__":
    main()
