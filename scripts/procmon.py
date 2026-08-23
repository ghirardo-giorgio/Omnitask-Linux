#!/usr/bin/env python3
"""Campiona TUTTI i processi e stampa una riga JSON per ciclo su stdout.

Stesso schema di sysmon.py: processo persistente letto riga per riga dalla
dashboard, invece di forkare qualcosa a ogni aggiornamento. Qui serve anche
per un altro motivo — CPU, disco e rete sono grandezze differenziali: hanno
senso solo fra due campioni, e uno script che parte e muore non ha un "prima".

Per ogni processo: percentuale di CPU, memoria residente, byte al secondo
letti e scritti su disco, byte al secondo di rete, carico sulla GPU e VRAM
occupata.

    procmon.py [--interval MS]

Il traffico di rete e' l'unico dato che il kernel non espone per processo:
arriva da nethogs, che deve poter mettere le interfacce in ascolto. Senza i
permessi giusti resta semplicemente assente (campo null) e tutto il resto
continua a funzionare — vedi NET_HELP.
"""
import json
import os
import pwd
import re
import shutil
import socket
import subprocess
import sys
import threading
import time

PROC = "/proc"
PAGE_SIZE = os.sysconf("SC_PAGE_SIZE")
CLOCK_TICKS = os.sysconf("SC_CLK_TCK")
INTERVAL = 2.0
# la riga di comando serve a distinguere due processi omonimi, non a leggere
# l'intera invocazione
CMDLINE_PREVIEW = 200

NET_HELP = (
    "traffico di rete non disponibile: nethogs non ha i permessi per "
    "ascoltare le interfacce. Una volta sola: "
    "sudo setcap cap_net_raw,cap_net_admin+ep $(which nethogs)"
)

# `ss` sa sempre quali connessioni esistono — le chiede al kernel — ma per dire
# di *chi* sono deve rovistare in /proc/PID/fd, e quelli degli altri utenti gli
# sono chiusi due volte: dai permessi della cartella e dal controllo ptrace sui
# collegamenti dentro. Servono entrambe le capacita', o le connessioni di root
# restano nell'elenco del kernel senza un processo a cui appartenere.
CONN_HELP = (
    "ss non ha i permessi per leggere i descrittori dei processi altrui, "
    "quindi non sa a chi appartengono queste connessioni. Basta darglieli una "
    "volta sola:"
)
# tenuto separato dalla spiegazione perche' e' quello che finisce negli
# appunti: chi lo incolla nel terminale non vuole anche la prosa
CONN_FIX = "sudo setcap cap_dac_read_search,cap_sys_ptrace+ep $(which ss)"

# pid -> [byte inviati/s, byte ricevuti/s], riempita dal thread di nethogs
_net = {}
_net_error = NET_HELP if shutil.which("nethogs") else "nethogs non installato"
_net_lock = threading.Lock()

# --- carico sulla GPU, per processo ------------------------------------------
# Due backend, come in sysmon.py e per la stessa ragione: pynvml da' tutto in
# processo, ma c'e' solo nel python in cui e' stato installato, e questo script
# parte col python3 del PATH — che cambia a seconda che Quickshell sia avviato
# da terminale o dalla sessione grafica. Il ripiego e' `nvidia-smi pmon`, che
# a differenza della tabella di `nvidia-smi` riporta anche l'utilizzo per pid.
GPU = None
GPU_BACKEND = None

try:
    import pynvml

    pynvml.nvmlInit()
    GPU = pynvml.nvmlDeviceGetHandleByIndex(0)
    GPU_BACKEND = "nvml"
except Exception:
    if shutil.which("nvidia-smi"):
        GPU_BACKEND = "pmon"

_gpu_error = "" if GPU_BACKEND else (
    "carico per processo sulla GPU non disponibile: serve una GPU NVIDIA con "
    "nvidia-smi, o il modulo pynvml nel python che avvia la dashboard"
)

# pid -> {"sm": percentuale, "vram": byte}, riempita dal thread della GPU
_gpu = {}
_gpu_lock = threading.Lock()

# --- con chi sta parlando un processo ----------------------------------------
# Le connessioni aperte si leggono da `ss`, che fa gia' il lavoro di risalire
# dal socket al processo. Vale la stessa regola del resto: dei processi altrui
# non si vedono i descrittori, quindi non si vedono le loro connessioni.

# quanti interlocutori riportare per processo: oltre una manciata l'elenco
# smette di dire qualcosa (un browser ne apre a decine)
MAX_PEERS = 8
# indirizzo -> nome, riempita in sottofondo: il DNS inverso costa una query di
# rete e non deve mai far aspettare un campione
_names = {}
_names_lock = threading.Lock()
_to_resolve = []

# --- dove si trova un indirizzo ----------------------------------------------
# Database locale di MaxMind, interrogato con mmdblookup: nessun indirizzo esce
# dalla macchina. E' la ragione per cui non si usa un servizio web ne' whois —
# quest'ultimo per giunta direbbe dove l'organizzazione ha *registrato* il
# blocco, non dove stanno le macchine: sugli indirizzi di una VPN sono due
# risposte diverse, e quella registrata e' quasi sempre la sede legale.
#
# Il file pero' invecchia, e invecchia male: il pacchetto delle distribuzioni e'
# fermo a dicembre 2019, da quando MaxMind ha messo la licenza e nessuno puo'
# piu' ridistribuirlo aggiornato. Gli indirizzi delle VPN cambiano mano di
# continuo, e sei anni di ritardo vogliono dire il paese sbagliato — non un
# errore di qualche chilometro. Quindi non si punta a un percorso fisso: si
# prende il piu' recente fra quelli che ci sono, e chi installa geoipupdate se
# lo ritrova adoperato da solo al giro dopo.
GEO_PATHS = [
    # geoipupdate, cioe' la strada giusta
    "/var/lib/GeoIP/GeoLite2-City.mmdb",
    os.path.expanduser("~/.local/share/GeoIP/GeoLite2-City.mmdb"),
    # altri programmi che se lo scaricano per conto loro
    os.path.expanduser("~/.cache/camoufox/GeoLite2-City.mmdb"),
    # il pacchetto della distribuzione: l'ultima scelta, e' il piu' vecchio
    "/usr/share/GeoIP/GeoLite2-City.mmdb",
]
# oltre questa eta' il database va segnalato: vedi GEO_HELP
GEO_STALE_DAYS = 400
GEO_HELP = (
    "il database di geolocalizzazione ha piu' di un anno: su indirizzi di VPN e "
    "di hosting, che cambiano mano di continuo, il paese mostrato puo' essere "
    "sbagliato. Il pacchetto della distribuzione e' fermo al 2019; per averlo "
    "aggiornato serve una licenza gratuita su maxmind.com e poi:"
)
GEO_FIX = "sudo dnf install geoipupdate && sudo geoipupdate"


def mmdb_built(path):
    """Quando e' stato costruito un database, dai suoi metadati.

    La data del file non basta: un .mmdb copiato o scompattato porta la data
    della copia, non quella dei dati che contiene. I metadati stanno in fondo,
    dopo un marcatore, e `build_epoch` e' un intero preceduto da un byte che ne
    dichiara la lunghezza."""
    try:
        with open(path, "rb") as f:
            raw = f.read()
    except OSError:
        return 0
    start = raw.rfind(b"\xab\xcd\xefMaxMind.com")
    if start < 0:
        return 0
    at = raw.find(b"build_epoch", start)
    if at < 0:
        return 0
    tail = raw[at + len("build_epoch"):]
    if not tail:
        return 0
    # I tre bit alti del byte di controllo sono il tipo, i cinque bassi la
    # lunghezza. Il tipo 0 vuol dire "esteso": il tipo vero sta nel byte dopo,
    # piu' sette. build_epoch e' un uint64, cioe' il tipo 9, e passa sempre di
    # qui — leggere il valore senza saltare quel byte da' una data del 1971.
    control = tail[0]
    size = control & 0x1F
    offset = 2 if (control >> 5) == 0 else 1
    try:
        return int.from_bytes(tail[offset:offset + size], "big")
    except (IndexError, ValueError):
        return 0


def pick_geo_db():
    """(percorso, data di costruzione) del database piu' recente disponibile."""
    best = ("", 0)
    for path in GEO_PATHS:
        if not os.path.exists(path):
            continue
        built = mmdb_built(path) or int(os.path.getmtime(path))
        if built > best[1]:
            best = (path, built)
    return best


GEO_DB, GEO_BUILT = pick_geo_db()
# `accuracy_radius` dice quanto il database e' sicuro, in km: 10 e' un
# quartiere, 1000 e' "da qualche parte in quel paese" — cioe' il centroide
# nazionale, dove finiscono a decine indirizzi diversi. Oltre questa soglia la
# posizione va dichiarata approssimativa invece di disegnata come un fatto.
GEO_APPROX_KM = 500
# Da dove arriva un indirizzo, per i filtri della finestra Rete e per sapere a
# chi non ha senso chiedere una posizione:
#   loopback = la macchina con se stessa
#   lan      = altre macchine di casa, container compresi (Docker sta in 172.16/12)
#   public   = tutto il resto, cioe' l'unico traffico che esce davvero
LOOPBACK_IP = re.compile(r"^(127\.|::1$)")
LAN_IP = re.compile(
    r"^(10\.|192\.168\.|169\.254\.|172\.(1[6-9]|2\d|3[01])\.|fe80:|f[cd])"
)


def scope_of(ip):
    if LOOPBACK_IP.match(ip):
        return "loopback"
    if LAN_IP.match(ip):
        return "lan"
    return "public"


_geo = {}
_geo_lock = threading.Lock()
_to_locate = []
GEO_NUM = re.compile(r'"(latitude|longitude|accuracy_radius)":\s*\n?\s*([-0-9.]+)')
GEO_STR = re.compile(r'"([^"]+)"\s+<utf8_string>')
SS_LINE = re.compile(r"\s(?P<peer>\S+):(?P<port>\d+)\s+users:\(\((?P<users>.+)\)\)")
SS_PID = re.compile(r"pid=(\d+)")
# il campo locale sta sempre in terza posizione su "ss -tnp" per le connessioni
# stabilite (RecvQ SendQ Locale:porta Remoto:porta processo): non serve un
# parser piu' furbo di cosi'
SS_LOCAL = re.compile(r"^\S+\s+\S+\s+(?P<local>\S+):(?P<lport>\d+)\s")
# "IFACE    inet 1.2.3.4/24 ..." oppure "IFACE    inet6 ::1/128 ...", una riga
# per indirizzo grazie a `-o`
IFACE_ADDR = re.compile(r"^\d+:\s+(?P<iface>\S+)\s+inet6?\s+(?P<addr>[0-9a-fA-F.:]+)/")


def normalize_ip(ip):
    """"::ffff:192.168.1.5" e' un IPv4 vestito da IPv6: senza spogliarlo non
    combacia con nessun elenco di reti private, e finirebbe a interrogare il
    database di geolocalizzazione per niente."""
    ip = ip.strip("[]")
    if ip.lower().startswith("::ffff:") and "." in ip:
        ip = ip.split(":")[-1]
    return ip


def iface_map():
    """indirizzo -> interfaccia che lo possiede, per dire da dove passa ogni
    connessione (vedi connections()). Una chiamata a `ip`, non una per
    connessione: gli indirizzi di questa macchina cambiano una volta ogni
    tanto, non a ogni riga di `ss`."""
    try:
        out = subprocess.run(
            ["ip", "-o", "addr", "show"],
            capture_output=True,
            text=True,
            timeout=5,
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return {}

    out_map = {}
    for line in out.splitlines():
        m = IFACE_ADDR.match(line)
        if m:
            out_map[normalize_ip(m.group("addr"))] = m.group("iface")
    return out_map


def connections():
    """(pid -> lista di interlocutori, quante connessioni sono restate orfane).

    Le orfane sono le connessioni TCP che il kernel elenca ma che `ss` non e'
    riuscito ad attribuire a nessun processo: quasi sempre sono di root o di un
    altro utente. Il conto serve a dirlo invece di far sparire il traffico —
    vedi CONN_HELP."""
    try:
        out = subprocess.run(
            ["ss", "-tnpH", "state", "established"],
            capture_output=True,
            text=True,
            timeout=5,
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return {}, 0

    ifaces = iface_map()

    peers = {}
    orphans = 0
    for line in out.splitlines():
        if not line.strip():
            continue
        m = SS_LINE.search(line)
        if not m:
            orphans += 1
            continue
        ip = normalize_ip(m.group("peer"))
        port = int(m.group("port"))
        # a quale interfaccia appartiene l'indirizzo locale di questa
        # connessione: e' quello che permette di isolare "solo cio' che passa
        # dalla VPN" nella finestra Rete
        local = SS_LOCAL.match(line)
        iface = ifaces.get(normalize_ip(local.group("local")), "") if local else ""
        for pid in {int(p) for p in SS_PID.findall(m.group("users"))}:
            entry = peers.setdefault(pid, {})
            # stesso indirizzo su piu' porte: una riga sola con un contatore,
            # altrimenti un browser riempirebbe l'elenco di se stesso
            key = ip
            if key in entry:
                entry[key]["count"] += 1
            else:
                entry[key] = {
                    "ip": ip,
                    "port": port,
                    "count": 1,
                    "scope": scope_of(ip),
                    "iface": iface,
                }
    return peers, orphans


def resolve_worker():
    """Nome di dominio degli indirizzi visti, uno per volta e senza fretta."""
    while True:
        time.sleep(0.4)
        with _names_lock:
            pending = _to_resolve[:8]
            del _to_resolve[:8]
        for ip in pending:
            try:
                name = socket.gethostbyaddr(ip)[0]
            except (OSError, socket.herror, socket.gaierror):
                name = ""
            with _names_lock:
                _names[ip] = name


def name_for(ip):
    """Nome se gia' noto; la prima volta mette l'indirizzo in coda e ritorna
    vuoto, cosi' il campione parte subito con l'IP."""
    with _names_lock:
        if ip in _names:
            return _names[ip]
        _names[ip] = ""
        _to_resolve.append(ip)
    return ""


def mmdb(ip, *path):
    """Interroga il database locale. Ritorna l'output grezzo di mmdblookup, che
    non e' JSON (i valori portano il tipo accanto: `51.4964 <double>`)."""
    try:
        return subprocess.run(
            ["mmdblookup", "--file", GEO_DB, "--ip", ip, *path],
            capture_output=True,
            text=True,
            timeout=5,
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return ""


def locate(ip):
    """Posizione di un indirizzo, o None se il database non lo conosce."""
    numbers = {k: float(v) for k, v in GEO_NUM.findall(mmdb(ip, "location"))}
    if "latitude" not in numbers or "longitude" not in numbers:
        return None
    country = GEO_STR.search(mmdb(ip, "country", "names", "en"))
    # il codice a due lettere serve alla bandiera: le due lettere diventano i
    # due "regional indicator" che il font compone in un'unica emoji
    iso = GEO_STR.search(mmdb(ip, "country", "iso_code"))
    radius = numbers.get("accuracy_radius", 0)
    return {
        "lat": numbers["latitude"],
        "lon": numbers["longitude"],
        "country": country.group(1) if country else "",
        "iso": iso.group(1) if iso else "",
        "radius": int(radius),
        "approx": radius >= GEO_APPROX_KM,
    }


def geo_worker():
    """Posizioni in sottofondo, con la stessa regola dei nomi: il campione non
    aspetta mai un lookup. Tenuto separato dal DNS inverso di proposito — un
    nome che non risolve ci mette secondi, e ritarderebbe tutte le posizioni in
    coda dietro di lui."""
    while True:
        time.sleep(0.3)
        with _geo_lock:
            pending = _to_locate[:8]
            del _to_locate[:8]
        for ip in pending:
            found = locate(ip)
            with _geo_lock:
                _geo[ip] = found


def geo_for(ip):
    """Posizione se gia' nota, altrimenti la mette in coda e ritorna None.
    Loopback e rete locale non si interrogano: non hanno una posizione da
    trovare, e resterebbero in cache come buchi."""
    if scope_of(ip) != "public":
        return None
    with _geo_lock:
        if ip in _geo:
            return _geo[ip]
        _geo[ip] = None
        _to_locate.append(ip)
    return None


def read_text(path):
    try:
        with open(path, "r", errors="replace") as f:
            return f.read()
    except (OSError, PermissionError):
        return ""


# --- dove il mondo crede che siamo -------------------------------------------
_cities = {}


def city_for(ip):
    """Il nome della citta': l'unica cosa che locate() non prende, perche' per i
    trecento interlocutori di un campione non serve. Per l'uscita della VPN si',
    ed e' un indirizzo solo."""
    if ip not in _cities:
        found = GEO_STR.search(mmdb(ip, "city", "names", "en"))
        _cities[ip] = found.group(1) if found else ""
    return _cities[ip]


def hex_ip(value):
    """Un indirizzo come lo scrive /proc/net/route: quattro byte in esadecimale,
    nell'ordine della macchina — il meno significativo per primo."""
    try:
        raw = int(value, 16)
    except ValueError:
        return ""
    return ".".join(str((raw >> shift) & 0xFF) for shift in (0, 8, 16, 24))


def tunnels():
    """Le interfacce tunnel attive. tun e tap si riconoscono da tun_flags,
    WireGuard si dichiara nel DEVTYPE: in entrambi i casi il file esiste solo
    finche' il tunnel esiste."""
    found = []
    try:
        names = os.listdir("/sys/class/net")
    except OSError:
        return found
    for name in sorted(names):
        base = f"/sys/class/net/{name}"
        is_tunnel = os.path.exists(f"{base}/tun_flags") or "DEVTYPE=wireguard" in read_text(f"{base}/uevent")
        if is_tunnel and read_text(f"{base}/operstate").strip() != "down":
            found.append(name)
    return found


def vpn_exit():
    """Posizione apparente della macchina quando c'e' un tunnel attivo.

    Nessuno chiede a un servizio esterno qual e' il nostro indirizzo pubblico —
    lo scopo del database locale e' proprio che nessun indirizzo esca da qui.
    Non serve: sia OpenVPN sia WireGuard lasciano una rotta verso il proprio
    server *fuori* dal tunnel (dentro ci si passa, non ci si arriva), e quella
    sta gia' in /proc/net/route. La posizione del server e' quella da cui il
    traffico riemerge, che e' la domanda a cui la mappa deve rispondere."""
    active = tunnels()
    if not active:
        return None

    endpoint = ""
    for line in read_text(f"{PROC}/net/route").splitlines()[1:]:
        parts = line.split()
        # maschera piena = rotta verso un singolo host; e la si cerca su un
        # dispositivo che non sia il tunnel stesso
        if len(parts) < 8 or parts[7] != "FFFFFFFF" or parts[0] in active:
            continue
        ip = hex_ip(parts[1])
        # le /32 private sono altro (il DNS del tunnel, per esempio)
        if ip and scope_of(ip) == "public":
            endpoint = ip
            break

    if not endpoint:
        return None

    # come per ogni altro indirizzo: la prima volta mette in coda e ritorna
    # None, il campione dopo ha la posizione
    where = geo_for(endpoint)
    if not where:
        return None

    out = {"ip": endpoint, "iface": active[0], "city": city_for(endpoint)}
    out.update(where)
    return out


def proc_stat(pid):
    """(nome, jiffies di CPU usati, stato, nice) da /proc/PID/stat.

    Il nome sta fra parentesi e puo' contenere spazi e parentesi a sua volta
    ("(Web Content)"): si taglia sull'ULTIMA graffa chiusa, non sulla prima,
    altrimenti i campi successivi scalano di posizione."""
    data = read_text(f"{PROC}/{pid}/stat")
    end = data.rfind(")")
    if end < 0:
        return "", 0, "", 0
    name = data[data.find("(") + 1:end]
    fields = data[end + 2:].split()
    try:
        # utime e stime: campi 14 e 15 di stat, qui 11 e 12 perche' i primi
        # tre (pid, comm, state) sono gia' fuori. Lo stato serve a far vedere
        # nell'elenco chi e' stato sospeso, il nice a dire con che priorita'
        # sta girando.
        return name, int(fields[11]) + int(fields[12]), fields[0], int(fields[16])
    except (IndexError, ValueError):
        return name, 0, fields[0] if fields else "", 0


def proc_rss(pid):
    data = read_text(f"{PROC}/{pid}/statm").split()
    if len(data) < 2:
        return 0
    try:
        return int(data[1]) * PAGE_SIZE
    except ValueError:
        return 0


def proc_io(pid):
    """(byte letti, byte scritti) da disco. Sono i byte davvero passati dal
    dispositivo, non le read()/write() servite dalla cache."""
    read = write = 0
    for line in read_text(f"{PROC}/{pid}/io").splitlines():
        if line.startswith("read_bytes:"):
            read = int(line.split()[1])
        elif line.startswith("write_bytes:"):
            write = int(line.split()[1])
    return read, write


# uid -> nome: /etc/passwd non cambia mentre la dashboard gira, e la stessa
# manciata di uid torna per ognuno dei trecento processi a ogni campione.
_users = {}


def user_of(uid):
    if uid not in _users:
        try:
            _users[uid] = pwd.getpwuid(uid).pw_name
        except KeyError:
            # un uid senza voce in passwd esiste eccome: succede con i processi
            # dei container, che mappano numeri che qui dentro non vogliono dire
            # niente. Meglio il numero che il vuoto.
            _users[uid] = str(uid)
    return _users[uid]


def proc_owner(pid):
    """(nome dell'utente che possiede il processo, e' mio?)."""
    try:
        uid = os.stat(f"{PROC}/{pid}").st_uid
    except OSError:
        return "", False
    return user_of(uid), uid == os.getuid()


def proc_cmdline(pid):
    raw = read_text(f"{PROC}/{pid}/cmdline")
    return " ".join(part for part in raw.split("\0") if part).strip()[:CMDLINE_PREVIEW]


def snapshot():
    """Stato istantaneo di tutti i processi leggibili: pid -> misure grezze."""
    out = {}
    for entry in os.listdir(PROC):
        if not entry.isdigit():
            continue
        pid = int(entry)
        name, ticks, state, nice = proc_stat(pid)
        if not name:
            continue
        cmdline = proc_cmdline(pid)
        if not cmdline:
            # senza riga di comando e' un thread del kernel: non si termina e
            # non ha nulla da mostrare
            continue
        read, write = proc_io(pid)
        user, owned = proc_owner(pid)
        out[pid] = {
            "pid": pid,
            "name": name,
            "cmdline": cmdline,
            "ticks": ticks,
            "state": state,
            "nice": nice,
            "rss": proc_rss(pid),
            "read": read,
            "write": write,
            "user": user,
            "owned": owned,
        }
    return out


def nethogs_worker():
    """Legge l'output di nethogs in tracemode e tiene aggiornato _net.

    Formato di una riga: "percorso/pid/uid\tinviati\tricevuti", con i valori
    in kB/s. Le righe "unknown TCP" raccolgono il traffico che non e' stato
    possibile attribuire: si scartano, attribuirle a caso sarebbe peggio che
    non mostrarle."""
    global _net_error

    binary = shutil.which("nethogs")
    if not binary:
        return
    try:
        proc = subprocess.Popen(
            [binary, "-t", "-d", str(int(INTERVAL))],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
    except OSError as exc:
        with _net_lock:
            _net_error = f"nethogs non avviabile: {exc}"
        return

    current = {}
    for line in proc.stdout:
        line = line.strip()
        if not line:
            continue
        if line.startswith("Refreshing:"):
            # fine di un blocco: quello raccolto diventa la fotografia buona
            with _net_lock:
                _net.clear()
                _net.update(current)
                _net_error = ""
            current = {}
            continue
        parts = line.split("\t")
        if len(parts) < 3:
            continue
        path = parts[0]
        if path.startswith("unknown"):
            continue
        # la riga comincia con l'intera riga di comando, argomenti compresi:
        # gli ultimi due segmenti sono pid e uid, e si prendono da destra
        # proprio perche' in mezzo ci sono slash a volonta'
        bits = path.rsplit("/", 2)
        if len(bits) < 3 or not bits[1].isdigit():
            continue
        # pid 0: traffico che nethogs non ha saputo attribuire (connessioni
        # gia' chiuse, o di container), non un processo di questa macchina
        if bits[1] == "0":
            continue
        try:
            sent = float(parts[1]) * 1024
            received = float(parts[2]) * 1024
        except ValueError:
            continue
        pid = int(bits[1])
        entry = current.setdefault(pid, [0.0, 0.0])
        entry[0] += sent
        entry[1] += received

    # nethogs e' uscito: senza permessi succede subito
    with _net_lock:
        _net_error = NET_HELP


def nvml_gpu_sample(since):
    """pid -> {"sm": percentuale, "vram": byte} via pynvml."""
    out = {}
    try:
        running = pynvml.nvmlDeviceGetComputeRunningProcesses(GPU)
        running += pynvml.nvmlDeviceGetGraphicsRunningProcesses(GPU)
    except Exception:
        return {}

    for p in running:
        # lo stesso pid compare in entrambe le liste con la stessa VRAM (chi
        # disegna e calcola, tipicamente un browser): sommarla la raddoppierebbe
        out.setdefault(p.pid, {"sm": 0, "vram": p.usedGpuMemory or 0})

    try:
        for s in pynvml.nvmlDeviceGetProcessUtilization(GPU, since):
            entry = out.setdefault(s.pid, {"sm": 0, "vram": 0})
            # nella finestra possono cadere piu' campioni dello stesso pid: si
            # tiene il piu' alto, sommarli porterebbe oltre il 100% un processo
            # che ha soltanto prodotto piu' campioni degli altri
            entry["sm"] = max(entry["sm"], min(100, s.smUtil))
    except Exception:
        # NVML solleva NOT_FOUND quando nella finestra non c'e' alcun campione,
        # cioe' a GPU ferma: resta la VRAM, che e' l'unica cosa da dire
        pass
    return out


def pmon_gpu_sample():
    """Come sopra, dal ripiego `nvidia-smi pmon`.

    Tabella a colonne fisse, una riga per processo:
        gpu pid type sm mem enc dec jpg ofa fb ccpm command
    Le colonne assenti valgono "-" (a GPU ferma sono quasi tutte). `fb` e' la
    VRAM in MB.
    """
    try:
        out = subprocess.run(
            ["nvidia-smi", "pmon", "-c", "1", "-s", "um"],
            capture_output=True,
            text=True,
            timeout=10,
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return {}

    procs = {}
    for line in out.splitlines():
        # le due righe di intestazione
        if line.startswith("#"):
            continue
        fields = line.split()
        if len(fields) < 11 or not fields[1].isdigit():
            continue
        try:
            sm = 0 if fields[3] == "-" else int(fields[3])
            vram = 0 if fields[9] == "-" else int(fields[9]) * 1024 * 1024
        except ValueError:
            continue
        procs[int(fields[1])] = {"sm": min(100, sm), "vram": vram}
    return procs


def gpu_worker():
    """Tiene aggiornata _gpu, fuori dal ciclo dei campioni.

    Il ripiego `nvidia-smi pmon` costa ~46 ms a invocazione, che sul ciclo si
    vedrebbero; pynvml costa un paio di millisecondi, ma tenere un solo percorso
    evita due politiche diverse per la stessa misura.
    """
    interval = max(INTERVAL, 1.0)
    while True:
        if GPU_BACKEND == "nvml":
            # la finestra di campionamento e' quella appena trascorsa, non
            # l'intera storia: NVML tiene i campioni per qualche secondo
            since = int((time.time() - interval) * 1e6)
            sample = nvml_gpu_sample(since)
        else:
            sample = pmon_gpu_sample()

        with _gpu_lock:
            _gpu.clear()
            _gpu.update(sample)
        time.sleep(interval)


# --- priorita' ricordate ------------------------------------------------------
# Le regole dicono "questo programma, ogni volta che parte, in secondo piano".
# Si applicano qui e non in un processo a parte perche' snapshot() gia' passa in
# rassegna tutti i processi due volte al secondo con nome, nice e proprietario:
# aggiungere il confronto costa un accesso a un dizionario.
#
# La funzione che agisce e' quella di procs.py, che tocca *tutti* i thread e
# anche la priorita' di I/O: averne due che fanno la stessa cosa in modo diverso
# sarebbe il modo migliore per farle divergere.
from procs import set_priority  # noqa: E402  (dopo le costanti, per leggibilita')

RULES = {}
# I monitor della dashboard non si toccano mai. Una regola sul nome "python3"
# li prenderebbe tutti e tre — sono processi python come gli altri — e la
# dashboard finirebbe per rallentare se stessa senza che si capisca perche'.
NEVER = ("scripts/sysmon.py", "scripts/procmon.py", "scripts/procs.py")


def apply_rules(processes):
    """Riporta al valore ricordato i processi che se ne sono allontanati.

    Si agisce solo verso il basso: alzare la priorita' vuole privilegi che la
    dashboard non ha e non deve avere, e un tentativo per processo a ogni giro
    sarebbe solo un errore ripetuto. Per questo una regola "normale" (zero) di
    solito non fa nulla: e' li' per dire che il programma *non* va abbassato,
    e il lavoro che risparmia e' quello che facevano le regole di prima.
    """
    if not RULES:
        return
    for entry in processes.values():
        target = RULES.get(entry["name"])
        if target is None or not entry["owned"] or entry["nice"] >= target:
            continue
        if any(mark in entry["cmdline"] for mark in NEVER):
            continue
        set_priority(entry["pid"], nice=target, idle_io=target > 0)


def parse_rules(text):
    """"nome:nice,nome:nice" -> dizionario. Le voci storte si saltano."""
    rules = {}
    for item in text.split(","):
        name, _, value = item.rpartition(":")
        if not name:
            continue
        try:
            nice = int(value)
        except ValueError:
            continue
        # da zero in su: zero vuol dire "questo programma resta a priorita'
        # normale", cioe' nessun abbassamento da fare. Sotto zero no: alzare
        # una priorita' vuole i privilegi, e la regola resterebbe a fallire
        if nice >= 0:
            rules[name] = max(0, min(19, nice))
    return rules


def parse_args():
    global INTERVAL, RULES

    args = sys.argv[1:]
    for i, arg in enumerate(args):
        if arg == "--interval" and i + 1 < len(args):
            try:
                INTERVAL = max(1.0, min(30.0, float(args[i + 1]) / 1000.0))
            except ValueError:
                pass
        elif arg == "--rules" and i + 1 < len(args):
            RULES = parse_rules(args[i + 1])


def main():
    parse_args()
    threading.Thread(target=nethogs_worker, daemon=True).start()
    threading.Thread(target=resolve_worker, daemon=True).start()
    threading.Thread(target=geo_worker, daemon=True).start()
    if GPU_BACKEND:
        threading.Thread(target=gpu_worker, daemon=True).start()

    prev = snapshot()
    prev_t = time.monotonic()

    while True:
        time.sleep(INTERVAL)
        now = time.monotonic()
        dt = now - prev_t or INTERVAL
        prev_t = now

        cur = snapshot()
        apply_rules(cur)
        peers, orphans = connections()
        with _net_lock:
            net = dict(_net)
            net_error = _net_error
        with _gpu_lock:
            gpu = dict(_gpu)

        processes = []
        for pid, entry in cur.items():
            before = prev.get(pid)
            # un processo appena nato non ha un "prima": le grandezze
            # differenziali partono da zero invece di essere inventate
            cpu = 0.0
            read = write = 0
            if before:
                cpu = (entry["ticks"] - before["ticks"]) / CLOCK_TICKS / dt * 100
                read = max(0, int((entry["read"] - before["read"]) / dt))
                write = max(0, int((entry["write"] - before["write"]) / dt))
            sent, received = net.get(pid, (None, None))
            # niente backend: la colonna resta vuota per tutti (null). Con un
            # backend, chi non ha contesto sulla GPU sta a zero — e' un fatto,
            # non un dato mancante.
            on_gpu = gpu.get(pid)
            # i piu' "chiacchierati" per primi: con un browser aperto la coda
            # e' fatta di connessioni singole che non dicono nulla
            talking = sorted(peers.get(pid, {}).values(),
                             key=lambda p: -p["count"])[:MAX_PEERS]
            for peer in talking:
                peer["name"] = name_for(peer["ip"])
                where = geo_for(peer["ip"])
                if where:
                    peer.update(where)
            processes.append({
                "pid": pid,
                "name": entry["name"],
                "cmdline": entry["cmdline"],
                "user": entry["user"],
                "owned": entry["owned"],
                "state": entry["state"],
                "nice": entry["nice"],
                "cpu": round(max(0.0, cpu), 1),
                "rss": entry["rss"],
                "read": read,
                "write": write,
                "io": read + write,
                "gpu": None if GPU_BACKEND is None else (on_gpu["sm"] if on_gpu else 0),
                "vram": None if GPU_BACKEND is None else (on_gpu["vram"] if on_gpu else 0),
                "net": None if sent is None else int(sent + received),
                "netSent": None if sent is None else int(sent),
                "netReceived": None if received is None else int(received),
                "peers": talking,
                "conns": sum(p["count"] for p in peers.get(pid, {}).values()),
            })

        prev = cur
        geo_stale = not GEO_BUILT or (time.time() - GEO_BUILT) > GEO_STALE_DAYS * 86400
        sys.stdout.write(json.dumps({
            "processes": processes,
            "netError": net_error,
            "gpuError": _gpu_error,
            # quante connessioni sono rimaste senza proprietario, e cosa fare
            # perche' non lo siano piu'
            "orphanConns": orphans,
            "connError": CONN_HELP if orphans else "",
            "connFix": CONN_FIX if orphans else "",
            # da dove vengono le posizioni sul globo, e da quanto: un database
            # vecchio non sbaglia di qualche chilometro, sbaglia paese
            "geoDb": GEO_DB,
            "geoBuilt": GEO_BUILT,
            "geoError": GEO_HELP if geo_stale else "",
            "geoFix": GEO_FIX if geo_stale else "",
            # dove riemerge il traffico quando c'e' un tunnel attivo, per la
            # posizione dell'osservatore sul globo
            "exit": vpn_exit(),
        }) + "\n")
        sys.stdout.flush()


if __name__ == "__main__":
    try:
        main()
    except (KeyboardInterrupt, BrokenPipeError):
        os._exit(0)
