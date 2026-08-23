#!/usr/bin/env python3
"""Azioni su un singolo processo, per la finestra dei processi.

L'elenco vive altrove (procmon.py, che campiona di continuo perche' CPU,
disco e rete sono grandezze differenziali): qui stanno le operazioni mirate
su un pid, che hanno senso solo quando l'utente le chiede.

Legge /proc direttamente: niente dipendenze esterne.

Uso:
    procs.py detail <pid>
    procs.py search <testo> [limite]
    procs.py kill <pid> <nome atteso> [force]

Il nome atteso in `kill` non e' burocrazia: fra il momento in cui la lista e'
stata mostrata e il click possono passare minuti, e i pid vengono riciclati.
Se il processo dietro quel pid non e' piu' quello che l'utente ha visto, il
comando si rifiuta invece di uccidere un estraneo.

Stampa sempre un oggetto JSON su stdout ed esce con codice 0, anche in caso
di errore: chi legge (Dashboard) deve poter mostrare il messaggio.
"""
import ctypes
import json
import os
import signal
import sys

PROC = "/proc"

# --- priorita' ----------------------------------------------------------------
# Su Linux il valore `nice` e' un attributo *per thread*, non per processo:
# setpriority(PRIO_PROCESS, pid) cambia solo il thread il cui id e' `pid`, cioe'
# quello principale. Su un programma a molti thread — un browser, un editor —
# abbassare la priorita' cosi' non fa quasi niente, e la si crede fatta. Per
# questo si passa sempre da /proc/PID/task/, che li elenca tutti. I thread creati
# dopo ereditano il valore da chi li crea, quindi una passata copre anche quelli
# che verranno.
#
# La priorita' di I/O non ha un corrispettivo in os: si chiama la syscall.
# Il numero e' quello di x86_64 e aarch64; altrove la funzione si limita a non
# fare nulla, che e' meglio di chiamare la syscall sbagliata.
IOPRIO_SET = 251
IOPRIO_WHO_PROCESS = 1
IOPRIO_CLASS_IDLE = 3
IOPRIO_CLASS_BEST_EFFORT = 2
IOPRIO_CLASS_SHIFT = 13

try:
    _libc = ctypes.CDLL("libc.so.6", use_errno=True)
except OSError:
    _libc = None


def tasks_of(pid):
    """I thread di un processo. Almeno il processo stesso, se /proc non aiuta."""
    try:
        return [int(t) for t in os.listdir(f"{PROC}/{pid}/task") if t.isdigit()]
    except OSError:
        return [pid]


def set_io_idle(tid, idle):
    """Classe di I/O di un thread: idle = usa il disco quando non serve a nessuno.

    Scendere di classe e' sempre permesso, quindi non servono privilegi. La
    classe "best effort" senza livello e' quella predefinita, ed e' il modo di
    tornare indietro.
    """
    if _libc is None:
        return False
    value = (IOPRIO_CLASS_IDLE << IOPRIO_CLASS_SHIFT) if idle else (
        (IOPRIO_CLASS_BEST_EFFORT << IOPRIO_CLASS_SHIFT) | 4
    )
    return _libc.syscall(IOPRIO_SET, IOPRIO_WHO_PROCESS, tid, value) == 0


def set_priority(pid, nice=None, idle_io=None):
    """Priorita' di CPU e di I/O di *tutti* i thread di un processo.

    Restituisce quanti thread sono stati toccati. Un thread che sparisce a
    meta' non e' un errore: i processi finiscono anche mentre li si guarda.
    """
    touched = 0
    for tid in tasks_of(pid):
        # I due permessi sono distinti: tornare alla priorita' normale di CPU
        # richiede privilegi, rimettere il disco in "best effort" no. Se il
        # primo fallisce il secondo si prova lo stesso — altrimenti un
        # programma rimesso a priorita' normale continuerebbe a usare il disco
        # come se fosse ancora in secondo piano. Il conteggio pero' guarda solo
        # il nice: e' quello che l'utente ha chiesto di cambiare.
        ok = nice is None
        if nice is not None:
            try:
                os.setpriority(os.PRIO_PROCESS, tid, nice)
                ok = True
            except (ProcessLookupError, PermissionError, OSError):
                ok = False
        if idle_io is not None:
            try:
                set_io_idle(tid, idle_io)
            except OSError:
                pass
        if ok:
            touched += 1
    return touched
# tetto di default dei risultati: la barra sta in una dashboard stretta, e
# una ricerca che restituisce mezzo sistema non aiuta a scegliere
DEFAULT_LIMIT = 6
# la riga di comando serve a distinguere due processi con lo stesso nome
# (tre "python3", quattro "chrome"), non a leggere l'intera invocazione
CMDLINE_PREVIEW = 120


def read_text(path):
    try:
        with open(path, "r", errors="replace") as f:
            return f.read()
    except (OSError, PermissionError):
        return ""


def proc_name(pid):
    return read_text(f"{PROC}/{pid}/comm").strip()


def proc_cmdline(pid):
    # gli argomenti sono separati da NUL; l'ultimo lascia un separatore in coda
    raw = read_text(f"{PROC}/{pid}/cmdline")
    return " ".join(part for part in raw.split("\0") if part).strip()


def proc_rss(pid):
    """Memoria residente in byte, dal campo 2 di statm (in pagine)."""
    data = read_text(f"{PROC}/{pid}/statm").split()
    if len(data) < 2:
        return 0
    try:
        return int(data[1]) * os.sysconf("SC_PAGE_SIZE")
    except (ValueError, OSError):
        return 0


def proc_state(pid):
    """Lettera di stato da /proc/PID/stat: S dorme, R gira, T sospeso, Z zombie.

    Il nome fra parentesi puo' contenere spazi e parentesi, quindi si taglia
    sull'ULTIMA graffa chiusa."""
    data = read_text(f"{PROC}/{pid}/stat")
    end = data.rfind(")")
    if end < 0:
        return ""
    fields = data[end + 2:].split()
    return fields[0] if fields else ""


def proc_owned(pid):
    """True se il processo e' dell'utente corrente: gli altri non si possono
    terminare senza privilegi, e mostrarli come se si potesse sarebbe una
    promessa che il pulsante non mantiene."""
    try:
        return os.stat(f"{PROC}/{pid}").st_uid == os.getuid()
    except OSError:
        return False


def search(query, limit):
    query = query.strip().lower()
    if not query:
        return {"ok": True, "query": "", "processes": []}

    self_pid = os.getpid()
    parent_pid = os.getppid()
    found = []
    for entry in os.listdir(PROC):
        if not entry.isdigit():
            continue
        pid = int(entry)
        # il processo di ricerca e la shell che l'ha lanciato comparirebbero
        # in ogni risultato (contengono il testo cercato negli argomenti)
        if pid in (self_pid, parent_pid):
            continue
        name = proc_name(pid)
        if not name:
            continue
        cmdline = proc_cmdline(pid)
        if not cmdline:
            # senza riga di comando e' un thread del kernel: non si termina
            # e non e' quello che l'utente sta cercando
            continue
        if query not in name.lower() and query not in cmdline.lower():
            continue
        found.append({
            "pid": pid,
            "name": name,
            "cmdline": cmdline[:CMDLINE_PREVIEW],
            "rss": proc_rss(pid),
            "owned": proc_owned(pid),
        })

    # i piu' pesanti per primi: chi cerca un processo per chiuderlo di solito
    # cerca proprio quello che sta occupando la macchina
    found.sort(key=lambda p: p["rss"], reverse=True)
    return {"ok": True, "query": query, "total": len(found), "processes": found[:limit]}


def read_status(pid):
    """Campi di /proc/PID/status come dizionario."""
    out = {}
    for line in read_text(f"{PROC}/{pid}/status").splitlines():
        if ":" in line:
            key, value = line.split(":", 1)
            out[key] = value.strip()
    return out


def user_name(uid):
    """Nome dell'utente, senza il modulo pwd se il file basta."""
    try:
        import pwd

        return pwd.getpwuid(uid).pw_name
    except (ImportError, KeyError):
        return str(uid)


def started_at(pid):
    """Ora di avvio del processo, ricavata dal mtime della sua directory in
    /proc: piu' semplice che convertire starttime in jiffies dal boot, e per
    un'informazione da leggere a colpo d'occhio e' abbastanza."""
    try:
        return os.stat(f"{PROC}/{pid}").st_mtime
    except OSError:
        return 0


def detail(pid):
    """Tutto quello che serve al riquadro di dettaglio: si legge solo per il
    processo sotto il puntatore, non per tutti a ogni campione."""
    try:
        pid = int(pid)
    except (TypeError, ValueError):
        return {"ok": False, "error": "pid non valido"}

    name = proc_name(pid)
    if not name:
        return {"ok": False, "error": f"il processo {pid} non esiste piu'"}

    status = read_status(pid)
    uid = 0
    if status.get("Uid"):
        try:
            uid = int(status["Uid"].split()[0])
        except (IndexError, ValueError):
            uid = 0

    try:
        open_files = len(os.listdir(f"{PROC}/{pid}/fd"))
    except OSError:
        # senza permessi non si contano: meglio dirlo che mostrare zero
        open_files = -1

    return {
        "ok": True,
        "pid": pid,
        "name": name,
        "cmdline": proc_cmdline(pid),
        "exe": os.path.realpath(f"{PROC}/{pid}/exe") if os.path.exists(f"{PROC}/{pid}/exe") else "",
        "cwd": os.path.realpath(f"{PROC}/{pid}/cwd") if os.path.exists(f"{PROC}/{pid}/cwd") else "",
        "user": user_name(uid),
        "ppid": status.get("PPid", ""),
        "state": status.get("State", ""),
        "threads": status.get("Threads", ""),
        "openFiles": open_files,
        "startedAt": started_at(pid),
        "rss": proc_rss(pid),
        "owned": proc_owned(pid),
        # su quali thread logici puo' girare: il pannello dell'affinita' parte
        # da qui, invece di far ricominciare da zero ogni volta
        "affinity": sorted(os.sched_getaffinity(pid)) if os.path.exists(f"{PROC}/{pid}") else [],
        "nice": os.getpriority(os.PRIO_PROCESS, pid) if os.path.exists(f"{PROC}/{pid}") else 0,
        "cores": len(os.sched_getaffinity(0)),
    }


def identify(pid, expected_name):
    """Controlla che dietro quel pid ci sia ancora il processo che l'utente ha
    visto. Ritorna (pid, nome, None) oppure (None, None, errore).

    Non e' burocrazia: fra il momento in cui l'elenco e' stato disegnato e il
    clic possono passare minuti, e i pid vengono riciclati. Vale per ogni
    azione, non solo per la terminazione — sospendere il processo sbagliato e'
    fastidioso quanto ucciderlo."""
    try:
        pid = int(pid)
    except (TypeError, ValueError):
        return None, None, "pid non valido"
    if pid <= 1:
        return None, None, "pid di sistema: non si tocca"

    name = proc_name(pid)
    if not name:
        return None, None, f"il processo {pid} non esiste piu'"
    if expected_name and name != expected_name:
        return None, None, (
            f"il pid {pid} ora e' \"{name}\", non \"{expected_name}\": "
            "aggiorna l'elenco"
        )
    return pid, name, None


# Le voci del menu, e il segnale che ciascuna manda. Sospendere e riprendere non
# sono distruttivi (il processo resta in memoria, congelato); terminare chiede al
# processo di chiudersi e gli lascia il tempo di salvare; forzare non chiede.
SIGNALS = {
    "stop": (signal.SIGSTOP, "SIGSTOP"),
    "resume": (signal.SIGCONT, "SIGCONT"),
    "terminate": (signal.SIGTERM, "SIGTERM"),
    "force": (signal.SIGKILL, "SIGKILL"),
}


def send(pid, expected_name, action):
    """Manda uno dei segnali di SIGNALS."""
    if action not in SIGNALS:
        return {"ok": False, "error": f"azione sconosciuta: {action}"}
    pid, name, error = identify(pid, expected_name)
    if error:
        return {"ok": False, "error": error}

    sig, label = SIGNALS[action]
    try:
        os.kill(pid, sig)
        # Un processo sospeso non gira, quindi non puo' accorgersi di SIGTERM:
        # il segnale gli resta appeso e l'utente vede una richiesta di chiusura
        # che non produce niente. Lo si sveglia subito dopo, cosi' il segnale
        # viene gestito. Non serve per SIGKILL, che non passa dal processo.
        if action == "terminate" and proc_state(pid) == "T":
            os.kill(pid, signal.SIGCONT)
    except PermissionError:
        return {"ok": False, "error": f"permesso negato su {name} ({pid})"}
    except ProcessLookupError:
        return {"ok": False, "error": f"il processo {pid} non esiste piu'"}
    except OSError as exc:
        return {"ok": False, "error": f"errore su {pid}: {exc}"}
    return {"ok": True, "pid": pid, "name": name, "signal": label, "action": action}


def send_many(action, pairs):
    """La stessa azione su piu' processi, in un solo avvio.

    `pairs` alterna pid e nome atteso. Un fallimento non ferma gli altri: se un
    processo e' morto nel frattempo, gli altri vanno comunque serviti, e chi
    chiama riceve il conto di quelli riusciti e la lista degli errori."""
    if action not in SIGNALS:
        return {"ok": False, "error": f"azione sconosciuta: {action}"}

    done = []
    errors = []
    for i in range(0, len(pairs) - 1, 2):
        result = send(pairs[i], pairs[i + 1], action)
        if result.get("ok"):
            done.append(result["name"])
        else:
            errors.append(result.get("error", "errore"))
    return {
        "ok": len(errors) == 0,
        "action": action,
        "done": done,
        "errors": errors,
        "signal": SIGNALS[action][1],
    }


def renice(pid, expected_name, value):
    """Cambia la priorita' (valore nice: -20 la piu' alta, 19 la piu' bassa).

    Abbassare la priorita' e' sempre permesso; alzarla richiede privilegi, e il
    kernel risponde con "permesso negato" — che qui si riscrive in una frase che
    dice cosa fare. Si tenta lo stesso invece di rifiutare a priori: su una
    macchina configurata con RLIMIT_NICE alzarla si puo' eccome, e quel limite
    non e' affare di questo script.

    Sotto lo zero si abbassa anche la priorita' di I/O: un processo messo in
    secondo piano che continua a martellare il disco rallenta tutto il resto
    lo stesso, ed e' la meta' del problema che non si vede.
    """
    pid, name, error = identify(pid, expected_name)
    if error:
        return {"ok": False, "error": error}
    try:
        value = int(value)
    except (TypeError, ValueError):
        return {"ok": False, "error": "priorita' non valida"}
    value = max(-20, min(19, value))

    try:
        current = os.getpriority(os.PRIO_PROCESS, pid)
    except OSError:
        current = 0

    touched = set_priority(pid, nice=value, idle_io=value > 0)
    if not touched:
        if not os.path.exists(f"{PROC}/{pid}"):
            return {"ok": False, "error": f"il processo {pid} non esiste piu'"}
        if value < current:
            return {
                "ok": False,
                "error": (
                    f"per alzare la priorita' di {name} servono privilegi di "
                    "amministratore (abbassarla e' sempre possibile)"
                ),
            }
        return {"ok": False, "error": f"non si e' potuta cambiare la priorita' di {name}"}

    return {
        "ok": True,
        "pid": pid,
        "name": name,
        "nice": value,
        "threads": touched,
    }


def affinity(pid, expected_name, cores):
    """Limita il processo ai thread logici indicati (elenco separato da virgole).

    Un elenco vuoto o non valido non viene interpretato come "nessun core", che
    il kernel rifiuterebbe: si risponde con un errore."""
    pid, name, error = identify(pid, expected_name)
    if error:
        return {"ok": False, "error": error}

    available = os.sched_getaffinity(0)
    try:
        wanted = {int(x) for x in str(cores).split(",") if x.strip() != ""}
    except ValueError:
        return {"ok": False, "error": "elenco di core non valido"}
    wanted &= available
    if not wanted:
        return {"ok": False, "error": "serve almeno un thread valido"}

    try:
        os.sched_setaffinity(pid, wanted)
    except PermissionError:
        return {"ok": False, "error": f"permesso negato su {name} ({pid})"}
    except ProcessLookupError:
        return {"ok": False, "error": f"il processo {pid} non esiste piu'"}
    except OSError as exc:
        return {"ok": False, "error": f"errore su {pid}: {exc}"}
    return {
        "ok": True,
        "pid": pid,
        "name": name,
        "cores": sorted(wanted),
        "total": len(available),
    }


def kill(pid, expected_name, force):
    """Compatibilita': la vecchia forma `kill <pid> <nome> [force]`."""
    return send(pid, expected_name, "force" if force else "terminate")


def main():
    args = sys.argv[1:]
    if args and args[0] == "detail" and len(args) >= 2:
        result = detail(args[1])
    elif args and args[0] == "search" and len(args) >= 2:
        try:
            limit = int(args[2]) if len(args) > 2 else DEFAULT_LIMIT
        except ValueError:
            limit = DEFAULT_LIMIT
        result = search(args[1], limit)
    elif args and args[0] == "kill" and len(args) >= 2:
        result = kill(args[1], args[2] if len(args) > 2 else "", "force" in args[3:])
    elif args and args[0] == "signal" and len(args) >= 4:
        result = send(args[1], args[2], args[3])
    elif args and args[0] == "signal-many" and len(args) >= 4:
        result = send_many(args[1], args[2:])
    elif args and args[0] == "nice" and len(args) >= 4:
        result = renice(args[1], args[2], args[3])
    elif args and args[0] == "affinity" and len(args) >= 4:
        result = affinity(args[1], args[2], args[3])
    else:
        result = {
            "ok": False,
            "error": (
                "uso: procs.py detail <pid> | kill <pid> <nome> [force] | "
                "signal <pid> <nome> stop|resume|terminate|force | "
                "nice <pid> <nome> <-20..19> | affinity <pid> <nome> <0,1,2…>"
            ),
        }

    json.dump(result, sys.stdout, ensure_ascii=False)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
