#!/usr/bin/env python3
"""Ponte fra la dashboard e il comando IA del demone Stenografa.

Quickshell non sa aprire socket TCP, quindi il pannello "Comando IA" passa
di qui: si parla con lo stesso socket di controllo locale (127.0.0.1:8767)
usato dal server MCP di Stenografa, che accetta un JSON per riga e risponde
allo stesso modo.

Il comando avviene in due tempi, ed e' voluto: il demone detta, trascrive e
interpreta, ma si ferma prima di eseguire; `choose` fa partire l'azione
scelta. In mezzo ci sta il momento in cui la dashboard si nasconde e
restituisce il fuoco della tastiera all'applicazione da comandare — senza
quella pausa i tasti simulati finirebbero nella finestra della dashboard.

Uso:
    stenografa_ai.py record [dashboard_id]   avvia o ferma la dettatura
    stenografa_ai.py watch [secondi] [seq]   segue la sessione fino all'esito
    stenografa_ai.py status
    stenografa_ai.py cancel
    stenografa_ai.py choose <request_id> <indice> [delay_ms] [confirm]
    stenografa_ai.py send "chiudi la scheda"  (comando gia' scritto)

`confirm` serve per i candidati che eseguono comandi da terminale: senza,
il demone li rifiuta. E' la conferma che l'utente li ha letti.

Stampa sempre un oggetto JSON per riga su stdout ed esce con codice 0, anche
in caso di errore: chi legge (Dashboard) deve poter mostrare il messaggio
invece di trovarsi uno stream vuoto.
"""
import json
import socket
import sys
import time

HOST = "127.0.0.1"
PORT = 8767
# generoso: il tempo di risposta e' quello dell'LLM configurato nel demone,
# che con un backend cloud o col CLI Claude Code non e' immediato
TIMEOUT = 120
# ogni quanto `watch` richiede lo stato al demone. Il socket e' locale e la
# risposta minuscola: la frequenza si sceglie per la reattivita' del
# pannello, non per il costo
WATCH_INTERVAL = 0.25
# tetto di durata di `watch`: una dettatura piu' l'interpretazione stanno
# ampiamente dentro, e senza un limite un pannello dimenticato aperto
# lascerebbe il processo a girare per sempre
WATCH_TIMEOUT = 300
# fasi oltre le quali non c'e' piu' niente da seguire: o c'e' un esito, o
# tocca all'utente scegliere
WATCH_FINAL_PHASES = ("choice", "error", "done")


def request(payload):
    try:
        with socket.create_connection((HOST, PORT), timeout=TIMEOUT) as s:
            s.settimeout(TIMEOUT)
            s.sendall((json.dumps(payload) + "\n").encode("utf-8"))
            # il demone chiude la connessione dopo aver risposto: si legge
            # fino a EOF invece di fidarsi di una singola recv, perche' la
            # lista di opzioni puo' arrivare spezzata in piu' pacchetti
            chunks = []
            while True:
                chunk = s.recv(65536)
                if not chunk:
                    break
                chunks.append(chunk)
    except ConnectionRefusedError:
        return {"ok": False, "error": f"demone Stenografa non in ascolto su {HOST}:{PORT}"}
    except socket.timeout:
        return {"ok": False, "error": f"nessuna risposta dal demone entro {TIMEOUT}s"}
    except OSError as exc:
        return {"ok": False, "error": f"errore di connessione al demone: {exc}"}

    raw = b"".join(chunks)
    if not raw.strip():
        return {"ok": False, "error": "risposta vuota dal demone"}
    try:
        return json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        return {"ok": False, "error": f"risposta illeggibile dal demone: {exc}"}


def emit(obj):
    json.dump(obj, sys.stdout, ensure_ascii=False)
    sys.stdout.write("\n")
    sys.stdout.flush()


def watch(timeout, min_seq=0):
    """Segue la sessione del comando IA e stampa una riga ogni volta che
    cambia qualcosa, finche' non c'e' un esito (o tocca scegliere
    all'utente). Il pannello legge queste righe come se fossero eventi: il
    demone non ha modo di spingergliele, ma il polling di un socket locale
    costa quanto nulla.

    `min_seq` e' il numero di sequenza restituito da `record`: senza, la
    prima lettura potrebbe pescare l'esito della sessione precedente —
    ancora in una fase finale — e chiudere la sorveglianza prima ancora che
    questa cominci."""
    deadline = time.monotonic() + timeout
    last_seq = None
    while time.monotonic() < deadline:
        reply = request({"cmd": "ai_status"})
        if not reply.get("ok"):
            emit(reply)
            return
        session = reply.get("session") or {}
        seq = session.get("seq")
        if not isinstance(seq, int) or seq < min_seq:
            time.sleep(WATCH_INTERVAL)
            continue
        if seq != last_seq:
            last_seq = seq
            emit(reply)
            if session.get("phase") in WATCH_FINAL_PHASES:
                return
        time.sleep(WATCH_INTERVAL)
    emit({"ok": False, "error": f"nessun esito entro {timeout}s"})


def main():
    args = sys.argv[1:]
    if not args:
        result = {
            "ok": False,
            "error": (
                "uso: stenografa_ai.py record|watch|status|cancel|choose|send "
                "(vedi l'intestazione del file)"
            ),
        }
    elif args[0] == "record":
        result = request({"cmd": "ai_record", "dashboard_id": args[1] if len(args) > 1 else None})
    elif args[0] == "status":
        result = request({"cmd": "ai_status"})
    elif args[0] == "cancel":
        result = request({"cmd": "ai_cancel"})
    elif args[0] == "watch":
        try:
            timeout = int(args[1]) if len(args) > 1 else WATCH_TIMEOUT
            min_seq = int(args[2]) if len(args) > 2 else 0
        except ValueError:
            emit({"ok": False, "error": "timeout e seq devono essere numeri"})
            return
        watch(timeout, min_seq)
        return
    elif args[0] == "send" and len(args) >= 2:
        result = request({"cmd": "ai_command", "text": args[1], })
    elif args[0] == "choose" and len(args) >= 3:
        try:
            index = int(args[2])
            delay_ms = int(args[3]) if len(args) > 3 else 0
        except ValueError:
            result = {"ok": False, "error": "indice e delay_ms devono essere numeri"}
        else:
            result = request({
                "cmd": "ai_choose",
                "request_id": args[1],
                "index": index,
                "delay_ms": delay_ms,
                # l'ultimo argomento e' la conferma dei comandi da terminale:
                # senza, il demone li rifiuta (vedi _handle_control_ai_choose)
                "confirm_shell": "confirm" in args[4:],
            })
    else:
        result = {"ok": False, "error": f"argomenti non validi: {' '.join(args)}"}

    emit(result)


if __name__ == "__main__":
    main()
