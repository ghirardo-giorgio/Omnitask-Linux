#!/usr/bin/env python3
"""Campiona le risorse di sistema e stampa una riga JSON al secondo su stdout.

Girando come processo persistente evita di forkare nvidia-smi o altri tool a
ogni aggiornamento: Quickshell legge lo stream riga per riga con SplitParser.

Il rilevamento della CPU cerca di essere indipendente dal produttore e
dall'architettura: Intel, AMD, ARM e altri sistemi Linux possono esporre
nomi, frequenze, sensori e informazioni energetiche differenti.
"""

import json
import os
import shutil
import subprocess
import sys
import threading
import time


# =============================================================================
# CONFIGURAZIONE
# =============================================================================

# Ogni quanto campionare e quante voci per classifica: valori di partenza,
# sovrascritti dagli argomenti passati dalla dashboard.
INTERVAL = 1.0
TOP_COUNT = 3

# La classifica RAM vive in un thread separato.
RAM_INTERVAL = 10.0

# SMART cambia lentamente.
SMART_INTERVAL = 300.0

# Stato generale del sistema.
HEALTH_INTERVAL = 60.0

# Aggiornamenti disponibili.
UPDATE_INTERVAL = 3600.0

# Per quanto un'interfaccia resta nell'elenco di quelle attive dopo l'ultimo
# byte passato. Senza memoria l'elenco lampeggia: un bridge o un veth stanno
# fermi per un ciclo e spariscono, poi tornano — e i pulsanti che ci si
# costruiscono sopra ballano sotto il puntatore.
IFACE_MEMORY = 30.0

PAGE_SIZE = os.sysconf("SC_PAGE_SIZE")


# =============================================================================
# GPU
# =============================================================================

GPU = None
BACKEND = None

try:
    import pynvml

    pynvml.nvmlInit()
    GPU = pynvml.nvmlDeviceGetHandleByIndex(0)
    BACKEND = "nvml"

except Exception:
    if shutil.which("nvidia-smi"):
        BACKEND = "smi"


SMI_FIELDS = (
    "utilization.gpu,"
    "utilization.memory,"
    "memory.used,"
    "memory.total,"
    "temperature.gpu,"
    "power.draw,"
    "power.limit"
)


# =============================================================================
# MODELLI CPU E GPU
# =============================================================================

CPU_NAME_NOISE = (
    "(R)",
    "(TM)",
    "(r)",
    "(tm)",
    "CPU",
    "Processor",
    "processor",
)

CPU_NAME = ""
GPU_NAME = ""


def read_file(path):
    """Legge un file di testo restituendo None se non disponibile."""
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    except (OSError, PermissionError):
        return None


def read_int(path):
    """Legge un intero da un file.

    Restituisce None se il file non esiste o non contiene un intero valido.
    """
    try:
        data = read_file(path)

        if data is None:
            return None

        return int(data.strip())

    except (TypeError, ValueError):
        return None


def cpu_model():
    """Restituisce il nome più descrittivo disponibile della CPU.

    /proc/cpuinfo cambia formato fra architetture. Intel e AMD usano
    normalmente "model name", mentre sistemi ARM o altre piattaforme possono
    usare "Hardware", "Model", "cpu model" o "Processor".
    """

    candidates = (
        "model name",
        "cpu model",
        "hardware",
        "model",
        "processor",
    )

    try:
        values = {}

        with open(
            "/proc/cpuinfo",
            encoding="utf-8",
            errors="replace",
        ) as f:
            for line in f:
                if ":" not in line:
                    continue

                key, value = line.split(":", 1)

                key = key.strip().lower()
                value = value.strip()

                if key and value and key not in values:
                    values[key] = value

        name = ""

        for key in candidates:
            if key in values:
                name = values[key]
                break

        if not name:
            return os.uname().machine

        for noise in CPU_NAME_NOISE:
            name = name.replace(noise, " ")

        if "@" in name:
            name = name.split("@", 1)[0]

        # Elimina suffissi tipo "8-Core" o "16-Core".
        words = [
            word
            for word in name.split()
            if not word.lower().endswith("-core")
        ]

        name = " ".join(words).strip()

        return name or os.uname().machine

    except OSError:
        return os.uname().machine


def gpu_model():
    """Nome della scheda video, senza il prefisso NVIDIA."""
    name = ""

    if BACKEND == "nvml":
        try:
            raw = pynvml.nvmlDeviceGetName(GPU)
            name = raw.decode() if isinstance(raw, bytes) else raw
        except Exception:
            name = ""

    elif BACKEND == "smi":
        try:
            result = subprocess.run(
                [
                    "nvidia-smi",
                    "--query-gpu=name",
                    "--format=csv,noheader",
                ],
                capture_output=True,
                text=True,
                timeout=5,
            )

            lines = result.stdout.strip().splitlines()

            if lines:
                name = lines[0]

        except (OSError, subprocess.SubprocessError):
            name = ""

    return name.replace("NVIDIA ", "").strip()


# =============================================================================
# NVIDIA-SMI
# =============================================================================

def smi_query():
    """Dati aggregati della GPU via nvidia-smi."""

    try:
        result = subprocess.run(
            [
                "nvidia-smi",
                f"--query-gpu={SMI_FIELDS}",
                "--format=csv,noheader,nounits",
            ],
            capture_output=True,
            text=True,
            timeout=5,
        )

        out = result.stdout.strip().splitlines()

    except (OSError, subprocess.SubprocessError):
        return None

    if not out:
        return None

    try:
        fields = [x.strip() for x in out[0].split(",")]

        return {
            "util": int(float(fields[0])),
            "memUtil": int(float(fields[1])),
            "memUsed": int(float(fields[2])) * 1024 * 1024,
            "memTotal": int(float(fields[3])) * 1024 * 1024,
            "temp": int(float(fields[4])),
            "power": float(fields[5]),
            "powerLimit": float(fields[6]),
        }

    except (IndexError, ValueError):
        return None


def smi_procs():
    """Restituisce (pid, byte VRAM) dalla tabella di nvidia-smi."""

    try:
        result = subprocess.run(
            ["nvidia-smi"],
            capture_output=True,
            text=True,
            timeout=5,
        )

        out = result.stdout

    except (OSError, subprocess.SubprocessError):
        return []

    procs = []
    in_table = False

    for line in out.splitlines():
        if "Processes:" in line:
            in_table = True
            continue

        if not in_table or not line.startswith("|"):
            continue

        fields = line.strip("| \n").split()

        if len(fields) < 6 or not fields[3].isdigit():
            continue

        mib = fields[-1].replace("MiB", "")

        try:
            procs.append(
                (
                    int(fields[3]),
                    int(mib) * 1024 * 1024,
                )
            )
        except ValueError:
            continue

    return procs


# =============================================================================
# RAPL / POTENZA CPU
# =============================================================================

def find_rapl():
    """Trova un dominio RAPL del package CPU.

    RAPL non è disponibile su tutte le architetture. Se non esiste una
    sorgente leggibile, restituisce None.
    """

    try:
        entries = sorted(
            os.scandir("/sys/class/powercap"),
            key=lambda e: e.name,
        )
    except OSError:
        return None

    for entry in entries:
        name_file = os.path.join(entry.path, "name")

        try:
            with open(name_file, encoding="utf-8") as f:
                name = f.read().strip()

            if not name.startswith("package-"):
                continue

            energy_path = os.path.join(
                entry.path,
                "energy_uj",
            )

            with open(energy_path, encoding="utf-8") as f:
                int(f.read())

        except (
            OSError,
            PermissionError,
            ValueError,
        ):
            continue

        max_range = 0

        try:
            with open(
                os.path.join(
                    entry.path,
                    "max_energy_range_uj",
                ),
                encoding="utf-8",
            ) as f:
                max_range = int(f.read())

        except (OSError, ValueError):
            pass

        return {
            "path": energy_path,
            "max": max_range,
        }

    return None


def rapl_energy(rapl):
    """Legge il contatore energetico RAPL."""

    if not rapl:
        return None

    try:
        with open(
            rapl["path"],
            encoding="utf-8",
        ) as f:
            return int(f.read())

    except (OSError, ValueError):
        return None


# =============================================================================
# RETE
# =============================================================================

def default_iface():
    """Interfaccia della default route con la metrica piu' bassa.

    Con una VPN attiva possono comparire due righe di default route insieme
    — quella fisica e quella del tunnel — e l'ordine nel file non e' per
    metrica: e' quello in cui le rotte sono state aggiunte. Prendere la prima
    e basta vorrebbe dire restare su eno1 anche quando il traffico vero passa
    dal tunnel."""

    best_iface = None
    best_metric = None

    try:
        with open(
            "/proc/net/route",
            encoding="utf-8",
        ) as f:
            for line in f.readlines()[1:]:
                parts = line.split()

                if len(parts) <= 6 or parts[1] != "00000000":
                    continue

                try:
                    metric = int(parts[6])
                except ValueError:
                    continue

                if best_metric is None or metric < best_metric:
                    best_iface = parts[0]
                    best_metric = metric

    except OSError:
        pass

    return best_iface


def net_bytes(iface):
    """Byte ricevuti e trasmessi."""

    if not iface:
        return (0, 0)

    try:
        with open(
            f"/sys/class/net/{iface}/statistics/rx_bytes",
            encoding="utf-8",
        ) as f:
            rx = int(f.read())

        with open(
            f"/sys/class/net/{iface}/statistics/tx_bytes",
            encoding="utf-8",
        ) as f:
            tx = int(f.read())

        return (rx, tx)

    except OSError:
        return (0, 0)


def list_ifaces():
    """Tutte le interfacce di rete tranne loopback, per sommare il traffico
    di quante ce ne sono in questo momento — fisica, VPN, container — invece
    di seguirne una sola."""

    try:
        return [
            name
            for name in os.listdir("/sys/class/net")
            if name != "lo"
        ]

    except OSError:
        return []


# =============================================================================
# CPU UTILIZATION
# =============================================================================

def cpu_times():
    """Restituisce (busy, total) per ogni CPU logica.

    Usa /proc/stat, un'interfaccia Linux indipendente dall'architettura.
    """

    out = []

    try:
        with open(
            "/proc/stat",
            encoding="utf-8",
            errors="replace",
        ) as f:

            for line in f:
                parts = line.split()

                if not parts:
                    continue

                name = parts[0]

                if not name.startswith("cpu"):
                    continue

                # Salta la riga aggregata "cpu".
                if name == "cpu":
                    continue

                try:
                    values = [
                        int(x)
                        for x in parts[1:]
                    ]
                except ValueError:
                    continue

                if len(values) < 4:
                    continue

                idle = values[3]

                # iowait.
                if len(values) > 4:
                    idle += values[4]

                total = sum(values)
                busy = total - idle

                out.append((busy, total))

    except OSError:
        pass

    return out


# =============================================================================
# PROCESSI
# =============================================================================

GENERIC_COMM = {
    "python3",
    "python",
    "node",
    "sh",
    "bash",
    "zsh",
    "perl",
    "ruby",
    "java",
}


def proc_name(pid):
    """Nome leggibile del processo."""

    try:
        with open(
            f"/proc/{pid}/comm",
            encoding="utf-8",
            errors="replace",
        ) as f:
            comm = f.read().strip()

    except OSError:
        return None

    if comm not in GENERIC_COMM:
        return comm

    try:
        with open(
            f"/proc/{pid}/cmdline",
            encoding="utf-8",
            errors="replace",
        ) as f:
            args = [
                arg
                for arg in f.read().split("\0")
                if arg
            ]

    except OSError:
        return comm

    for arg in args[1:]:
        if not arg.startswith("-"):
            return os.path.basename(arg) or comm

    return comm


def proc_cpu_times():
    """pid -> jiffies CPU utilizzati."""

    out = {}

    try:
        entries = os.scandir("/proc")
    except OSError:
        return out

    for entry in entries:
        if not entry.name.isdigit():
            continue

        try:
            with open(
                f"/proc/{entry.name}/stat",
                encoding="utf-8",
                errors="replace",
            ) as f:
                fields = f.read().rpartition(")")[2].split()

            out[entry.name] = (
                int(fields[11])
                + int(fields[12])
            )

        except (
            OSError,
            IndexError,
            ValueError,
        ):
            continue

    return out


def top_cpu(prev, cur, total_delta, limit=3):
    """Processi che hanno consumato più CPU."""

    if total_delta <= 0:
        return []

    by_name = {}

    for pid, ticks in cur.items():
        delta = ticks - prev.get(pid, ticks)

        if delta <= 0:
            continue

        name = proc_name(pid)

        if name:
            by_name[name] = (
                by_name.get(name, 0)
                + delta
            )

    top = sorted(
        by_name.items(),
        key=lambda kv: kv[1],
        reverse=True,
    )[:limit]

    return [
        {
            "name": name,
            "pct": round(
                ticks / total_delta * 100,
                1,
            ),
        }
        for name, ticks in top
        if ticks / total_delta * 100 >= 0.1
    ]


# =============================================================================
# RAM
# =============================================================================

def proc_rss(pid):
    """RSS di un processo."""

    data = read_file(
        f"/proc/{pid}/statm"
    )

    try:
        return (
            int(data.split()[1])
            * PAGE_SIZE
        )

    except (
        AttributeError,
        IndexError,
        ValueError,
    ):
        return 0


def proc_pss(pid):
    """Memoria proporzionale di un processo."""

    data = read_file(
        f"/proc/{pid}/smaps_rollup"
    )

    if not data:
        return None

    for line in data.splitlines():
        if line.startswith("Pss:"):
            try:
                return (
                    int(line.split()[1])
                    * 1024
                )
            except (
                IndexError,
                ValueError,
            ):
                return None

    return None


def compute_top_ram(limit=3, candidates=6):
    """Applicazioni che occupano più RAM."""

    groups = {}

    try:
        entries = os.scandir("/proc")
    except OSError:
        return []

    for entry in entries:
        if not entry.name.isdigit():
            continue

        name = proc_name(entry.name)

        if not name:
            continue

        group = groups.setdefault(
            name,
            {
                "rss": 0,
                "pids": [],
            },
        )

        group["rss"] += proc_rss(entry.name)
        group["pids"].append(entry.name)

    top = sorted(
        groups.items(),
        key=lambda kv: kv[1]["rss"],
        reverse=True,
    )[:candidates]

    out = []

    for name, group in top:
        total = 0

        for pid in group["pids"]:
            pss = proc_pss(pid)

            total += (
                pss
                if pss is not None
                else proc_rss(pid)
            )

        out.append(
            {
                "name": name,
                "bytes": total,
            }
        )

    out.sort(
        key=lambda p: p["bytes"],
        reverse=True,
    )

    return out[:limit]


_top_ram = []


def ram_worker():
    """Aggiorna periodicamente la classifica RAM."""

    global _top_ram

    while True:
        try:
            _top_ram = compute_top_ram(
                TOP_COUNT,
                TOP_COUNT * 2,
            )
        except Exception:
            pass

        time.sleep(RAM_INTERVAL)


# =============================================================================
# GPU PROCESSI
# =============================================================================

def gpu_procs():
    """Processi con contesto sulla GPU."""

    if BACKEND == "smi":
        procs = {}

        for pid, mem in smi_procs():
            name = proc_name(pid)

            if not name:
                continue

            entry = procs.setdefault(
                name,
                {
                    "name": name,
                    "sm": 0,
                    "mem": 0,
                },
            )

            entry["mem"] += mem

        return list(procs.values())

    if GPU is None:
        return []

    procs = {}

    try:
        running = (
            pynvml.nvmlDeviceGetComputeRunningProcesses(GPU)
        )

        running += (
            pynvml.nvmlDeviceGetGraphicsRunningProcesses(GPU)
        )

    except Exception:
        return []

    for proc in running:
        name = proc_name(proc.pid)

        if not name:
            continue

        entry = procs.setdefault(
            name,
            {
                "name": name,
                "sm": 0,
                "mem": 0,
                "pids": set(),
            },
        )

        if proc.pid not in entry["pids"]:
            entry["pids"].add(proc.pid)

            entry["mem"] += (
                proc.usedGpuMemory or 0
            )

    try:
        since = (
            int(time.time() * 1e6)
            - int(2 * 1e6)
        )

        for sample in (
            pynvml.nvmlDeviceGetProcessUtilization(
                GPU,
                since,
            )
        ):
            name = proc_name(sample.pid)

            if name in procs:
                procs[name]["sm"] += sample.smUtil

    except Exception:
        pass

    return [
        {
            "name": proc["name"],
            "sm": min(
                100,
                proc["sm"],
            ),
            "mem": proc["mem"],
        }
        for proc in procs.values()
    ]


def top_gpu(procs, limit=3):
    """Top processi GPU per carico SM."""

    return sorted(
        procs,
        key=lambda p: (
            p["sm"],
            p["mem"],
        ),
        reverse=True,
    )[:limit]


def top_vram(procs, limit=3):
    """Top processi per VRAM."""

    return sorted(
        procs,
        key=lambda p: p["mem"],
        reverse=True,
    )[:limit]


# =============================================================================
# VM / MEMORIA
# =============================================================================

VMSTAT_KEYS = (
    "pswpin",
    "pswpout",
    "pgmajfault",
    "oom_kill",
)


def vmstat():
    """Legge contatori VM."""

    out = {}

    data = read_file(
        "/proc/vmstat"
    )

    if not data:
        return out

    for line in data.splitlines():
        key, _, value = line.partition(" ")

        if key not in VMSTAT_KEYS:
            continue

        try:
            out[key] = int(value)
        except ValueError:
            continue

    return out


def zram_stats():
    """Statistiche ZRAM."""

    original = 0
    compressed = 0
    found = False

    try:
        names = [
            name
            for name in os.listdir("/sys/block")
            if name.startswith("zram")
        ]
    except OSError:
        return None

    for name in names:
        fields = (
            read_file(
                f"/sys/block/{name}/mm_stat"
            )
            or ""
        ).split()

        try:
            original += int(fields[0])
            compressed += int(fields[1])
        except (
            IndexError,
            ValueError,
        ):
            continue

        found = True

    if not found:
        return None

    return {
        "orig": original,
        "compressed": compressed,
        "ratio": (
            round(
                original / compressed,
                1,
            )
            if compressed
            else 0.0
        ),
    }


def mem():
    """Statistiche RAM e swap."""

    info = {}

    try:
        with open(
            "/proc/meminfo",
            encoding="utf-8",
        ) as f:
            for line in f:
                key, _, value = line.partition(":")

                try:
                    info[key] = (
                        int(value.split()[0])
                        * 1024
                    )
                except (
                    IndexError,
                    ValueError,
                ):
                    continue

    except OSError:
        return {
            "used": 0,
            "total": 0,
            "pct": 0.0,
            "swapUsed": 0,
            "swapTotal": 0,
            "swapPct": 0.0,
            "zram": zram_stats(),
        }

    total = info.get("MemTotal", 0)
    available = info.get("MemAvailable", 0)
    used = max(0, total - available)

    swap_total = info.get("SwapTotal", 0)
    swap_free = info.get("SwapFree", 0)

    return {
        "used": used,
        "total": total,
        "pct": (
            round(
                used / total * 100,
                1,
            )
            if total
            else 0.0
        ),
        "swapUsed": max(
            0,
            swap_total - swap_free,
        ),
        "swapTotal": swap_total,
        "swapPct": (
            round(
                (
                    swap_total
                    - swap_free
                )
                / swap_total
                * 100,
                1,
            )
            if swap_total
            else 0.0
        ),
        "zram": zram_stats(),
    }


# =============================================================================
# GPU
# =============================================================================

def gpu_power(smi=None):
    """Potenza GPU."""

    if BACKEND == "smi":
        if smi:
            return (
                smi["power"],
                smi["powerLimit"],
            )

        return (None, None)

    if GPU is None:
        return (None, None)

    try:
        watts = (
            pynvml.nvmlDeviceGetPowerUsage(GPU)
            / 1000.0
        )
    except Exception:
        return (None, None)

    try:
        limit = (
            pynvml.nvmlDeviceGetEnforcedPowerLimit(GPU)
            / 1000.0
        )
    except Exception:
        limit = None

    return (
        watts,
        limit,
    )


def gpu(smi=None):
    """Statistiche GPU."""

    if BACKEND == "smi":
        if not smi:
            return None

        return {
            "util": smi["util"],
            "memUtil": smi["memUtil"],
            "memUsed": smi["memUsed"],
            "memTotal": smi["memTotal"],
            "memPct": (
                round(
                    smi["memUsed"]
                    / smi["memTotal"]
                    * 100,
                    1,
                )
                if smi["memTotal"]
                else 0
            ),
            "temp": smi["temp"],
        }

    if GPU is None:
        return None

    try:
        util = (
            pynvml.nvmlDeviceGetUtilizationRates(
                GPU
            )
        )

        memory_info = (
            pynvml.nvmlDeviceGetMemoryInfo(
                GPU
            )
        )

        return {
            "util": util.gpu,
            "memUtil": util.memory,
            "memUsed": memory_info.used,
            "memTotal": memory_info.total,
            "memPct": round(
                memory_info.used
                / memory_info.total
                * 100,
                1,
            ),
            "temp": (
                pynvml.nvmlDeviceGetTemperature(
                    GPU,
                    pynvml.NVML_TEMPERATURE_GPU,
                )
            ),
        }

    except Exception:
        return None


# =============================================================================
# ARGOMENTI
# =============================================================================

def parse_args():
    """Argomenti passati dalla dashboard."""

    global INTERVAL
    global TOP_COUNT

    args = sys.argv[1:]

    for i, arg in enumerate(args):
        if arg == "--top" and i + 1 < len(args):
            try:
                TOP_COUNT = max(
                    1,
                    min(
                        10,
                        int(args[i + 1]),
                    ),
                )
            except ValueError:
                pass

        elif (
            arg == "--interval"
            and i + 1 < len(args)
        ):
            try:
                INTERVAL = max(
                    0.5,
                    min(
                        10.0,
                        float(args[i + 1])
                        / 1000.0,
                    ),
                )
            except ValueError:
                pass


# =============================================================================
# DISCHI
# =============================================================================

SECTOR = 512

FAKE_FS = {
    "proc",
    "sysfs",
    "devtmpfs",
    "tmpfs",
    "cgroup",
    "cgroup2",
    "devpts",
    "securityfs",
    "pstore",
    "efivarfs",
    "bpf",
    "debugfs",
    "tracefs",
    "fusectl",
    "configfs",
    "autofs",
    "mqueue",
    "hugetlbfs",
    "binfmt_misc",
    "nsfs",
    "ramfs",
    "overlay",
    "squashfs",
    "rpc_pipefs",
}

NOT_A_DISK = (
    "loop",
    "ram",
    "zram",
    "sr",
    "dm-",
    "md",
)

_disk_space = {}
_disk_models = {}
# Partizioni dei dischi, per il pulsante "Monta" delle opzioni. E' separato da
# _disk_space perche' quello si occupa solo dei filesystem gia' montati; qui
# servono anche le partizioni libere di un disco non montato.
_partitions = {}


def is_disk(name):
    """True se il dispositivo sembra un disco fisico."""

    return not name.startswith(NOT_A_DISK)


def disk_model(name):
    """Restituisce il modello commerciale del disco."""

    if _disk_models:
        return _disk_models.get(
            name,
            "",
        )

    try:
        result = subprocess.run(
            [
                "lsblk",
                "-dno",
                "NAME,MODEL",
            ],
            capture_output=True,
            text=True,
            timeout=5,
        )

        for line in result.stdout.splitlines():
            parts = line.split(
                None,
                1,
            )

            if parts:
                _disk_models[parts[0]] = (
                    parts[1].strip()
                    if len(parts) > 1
                    else ""
                )

    except (
        OSError,
        subprocess.SubprocessError,
    ):
        pass

    _disk_models.setdefault(
        name,
        "",
    )

    return _disk_models.get(
        name,
        "",
    )


def physical_disks():
    """Restituisce i dischi fisici rilevati."""

    out = {}

    try:
        names = sorted(
            os.listdir("/sys/block")
        )
    except OSError:
        return out

    for name in names:
        if not is_disk(name):
            continue

        base = f"/sys/block/{name}"

        size_data = read_file(
            f"{base}/size"
        )

        try:
            sectors = (
                int(size_data.strip())
                if size_data
                else 0
            )
        except ValueError:
            continue

        if sectors <= 0:
            continue

        model = disk_model(name)

        if not model:
            model = (
                read_file(
                    f"{base}/device/model"
                )
                or ""
            ).strip()

        rotational_data = read_file(
            f"{base}/queue/rotational"
        )

        rotational = (
            rotational_data is not None
            and rotational_data.strip() == "1"
        )

        out[name] = {
            "name": name,
            "model": model,
            "total": sectors * SECTOR,
            "rotational": rotational,
        }

    return out


def partition_owner(device, depth=0):
    """Trova il disco fisico dietro una partizione o device mapper."""

    if depth > 8:
        return ""

    name = os.path.basename(
        os.path.realpath(device)
    )

    parent = ""

    try:
        parent = os.path.basename(
            os.path.dirname(
                os.path.realpath(
                    f"/sys/class/block/{name}"
                )
            )
        )
    except OSError:
        parent = ""

    if (
        parent
        and is_disk(parent)
        and os.path.isdir(
            f"/sys/block/{parent}"
        )
    ):
        return parent

    slaves_dir = (
        f"/sys/block/{name}/slaves"
    )

    try:
        slaves = sorted(
            os.listdir(slaves_dir)
        )
    except OSError:
        slaves = []

    if slaves:
        return partition_owner(
            "/dev/" + slaves[0],
            depth + 1,
        )

    if (
        is_disk(name)
        and os.path.isdir(
            f"/sys/block/{name}"
        )
    ):
        return name

    return ""


def mount_list():
    """Filesystem reali montati."""

    out = []

    data = read_file(
        "/proc/mounts"
    )

    if not data:
        return out

    for line in data.splitlines():
        parts = line.split()

        if len(parts) < 3:
            continue

        source = parts[0]
        mount = parts[1]
        fstype = parts[2]

        if fstype in FAKE_FS:
            continue

        if not source.startswith("/dev/"):
            continue

        out.append(
            (
                source,
                mount.replace("\\040", " "),
                fstype,
            )
        )

    return out


def block_partitions():
    """Partizioni di ogni disco fisico, per il pulsante "Monta".

    Restituisce {disco: [{"path", "label", "fstype", "mountpoint"}], ...}. Il
    monitor dei filesystem (_disk_space) vede solo quello che e' gia' montato:
    per montare un disco che non lo e' servono anche le partizioni libere, che
    qui si leggono con lsblk.
    """

    out = {}

    try:
        result = subprocess.run(
            [
                "lsblk",
                "-J",
                "-o",
                "NAME,PATH,TYPE,FSTYPE,LABEL,MOUNTPOINT",
            ],
            capture_output=True,
            text=True,
            timeout=5,
        )
        data = json.loads(result.stdout)
    except (
        OSError,
        subprocess.SubprocessError,
        ValueError,
    ):
        return out

    def collect(node, owner):
        typ = node.get("type")
        name = node.get("name")

        if typ == "disk":
            owner = name

        if owner and typ == "part":
            out.setdefault(owner, []).append(
                {
                    "path": node.get("path") or "",
                    "label": node.get("label") or "",
                    "fstype": node.get("fstype") or "",
                    "mountpoint": node.get("mountpoint") or "",
                }
            )

        for child in node.get("children") or []:
            collect(child, owner)

    for child in data.get("blockdevices") or []:
        collect(child, "")

    return out


def disk_space_worker():
    """Aggiorna lo spazio usato e le partizioni di ogni disco fisico."""

    global _disk_space, _partitions

    seen = None
    seen_parts = None

    while True:
        mounts = mount_list()

        signature = tuple(
            sorted(
                (
                    mount[0],
                    mount[1],
                )
                for mount in mounts
            )
        )

        # Le partizioni si aggiornano quando cambiano (disco collegato o
        # montato), non a ogni giro: lsblk e' un processo in piu' ogni cinque
        # secondi e non serve rifare il lavoro quando tutto e' uguale.
        parts = block_partitions()
        parts_signature = tuple(
            sorted(
                (
                    name,
                    tuple(
                        sorted(
                            tuple(sorted(part.items()))
                            for part in (value or [])
                        )
                    ),
                )
                for name, value in parts.items()
            )
        )

        if (
            signature == seen
            and parts_signature == seen_parts
        ):
            time.sleep(5.0)
            continue

        seen = signature
        seen_parts = parts_signature
        _partitions = parts
        space = {}

        for source, mount, fstype in mounts:
            owner = partition_owner(source)

            if not owner:
                continue

            try:
                stat = os.statvfs(mount)
            except OSError:
                continue

            total = (
                stat.f_blocks
                * stat.f_frsize
            )

            free = (
                stat.f_bavail
                * stat.f_frsize
            )

            if total <= 0:
                continue

            entry = space.setdefault(
                owner,
                {
                    "used": 0,
                    "size": 0,
                    "mounts": [],
                    "sources": set(),
                },
            )

            if source not in entry["sources"]:
                entry["sources"].add(source)

                entry["used"] += (
                    total - free
                )

                entry["size"] += total

            entry["mounts"].append(
                {
                    "mount": mount,
                    "source": source,
                    "fstype": fstype,
                }
            )

        # Non esporre il set interno.
        _disk_space = {
            name: {
                "used": value["used"],
                "size": value["size"],
                "mounts": value["mounts"],
            }
            for name, value in space.items()
        }

        time.sleep(5.0)


def disk_counters():
    """Byte letti e scritti per device."""

    out = {}

    data = read_file(
        "/proc/diskstats"
    )

    if not data:
        return out

    for line in data.splitlines():
        fields = line.split()

        if len(fields) < 10:
            continue

        try:
            out[fields[2]] = (
                int(fields[5])
                * SECTOR,
                int(fields[9])
                * SECTOR,
            )
        except ValueError:
            continue

    return out


def disks(prev, cur, dt):
    """Statistiche dei dischi."""

    out = []

    for name, info in sorted(
        physical_disks().items()
    ):
        entry = dict(info)

        space = _disk_space.get(name)

        if (
            space
            and space["size"] > 0
        ):
            entry["used"] = space["used"]
            entry["free"] = (
                space["size"]
                - space["used"]
            )
            entry["formatted"] = space["size"]

            entry["pct"] = round(
                space["used"]
                / space["size"]
                * 100,
                1,
            )

            entry["mounts"] = [
                mount["mount"]
                for mount in space["mounts"]
            ]

        else:
            entry["used"] = 0
            entry["free"] = 0
            entry["formatted"] = 0
            entry["pct"] = -1
            entry["mounts"] = []

        # Per il pulsante "Monta" delle opzioni: le partizioni del disco con
        # filesystem, montate o no, cosi' la dashboard sa cosa montare.
        entry["partitions"] = _partitions.get(
            name,
            [],
        )

        before = prev.get(name)
        after = cur.get(name)

        if before and after and dt > 0:
            entry["read"] = max(
                0,
                int(
                    (
                        after[0]
                        - before[0]
                    )
                    / dt
                ),
            )

            entry["write"] = max(
                0,
                int(
                    (
                        after[1]
                        - before[1]
                    )
                    / dt
                ),
            )

        else:
            entry["read"] = 0
            entry["write"] = 0

        entry["smart"] = _smart.get(
            name,
            {},
        )

        out.append(entry)

    return out


# =============================================================================
# SMART
# =============================================================================

SMARTCTL = shutil.which("smartctl")

NVME_UNIT = 512 * 1000

ATA_ATTRS = {
    5: "realloc",
    9: "hours",
    # 187 e 198 sono i due che Backblaze ha trovato piu' correlati alla morte
    # di un disco, ed erano gli unici guasti che questa raccolta non vedeva:
    # un disco con settori illeggibili puo' benissimo avere ancora
    # smart_status.passed a true, perche' quella soglia la decide il
    # produttore ed e' quasi sempre lontanissima.
    187: "uncorrect",
    197: "pending",
    198: "offline",
    199: "crc",
    241: "written",
}

_smart = {}


def smart_query(name):
    """Interroga SMART per un disco."""

    if not SMARTCTL:
        return {
            "error": "missing",
        }

    try:
        result = subprocess.run(
            [
                "sudo",
                "-n",
                SMARTCTL,
                "-j",
                "-A",
                "-H",
                f"/dev/{name}",
            ],
            capture_output=True,
            text=True,
            timeout=20,
        )

        out = result.stdout

    except (
        OSError,
        subprocess.SubprocessError,
    ):
        return {
            "error": "failed",
        }

    try:
        data = json.loads(out)
    except ValueError:
        return {
            "error": "denied",
        }

    smart = {}

    status = data.get(
        "smart_status"
    )

    if isinstance(status, dict):
        smart["passed"] = bool(
            status.get("passed")
        )

        # Perche' e' fallito. NVMe non ha attributi con soglie come ATA: ha un
        # registro di bandierine, che smartctl decodifica gia' per nome. Senza
        # queste resta un "passed: false" che non dice cosa sia rotto.
        nvme = status.get("nvme")

        if isinstance(nvme, dict):
            smart["flags"] = sorted(
                name
                for name, on in nvme.items()
                if name != "value"
                and on is True
            )

    log = data.get(
        "nvme_smart_health_information_log"
    )

    if isinstance(log, dict):
        smart["used"] = log.get(
            "percentage_used"
        )

        smart["spare"] = log.get(
            "available_spare"
        )

        smart["hours"] = log.get(
            "power_on_hours"
        )

        smart["written"] = (
            log.get("data_units_written")
            or 0
        ) * NVME_UNIT

        smart["errors"] = log.get(
            "media_errors"
        )

        smart["warning"] = log.get(
            "critical_warning"
        )

    table = (
        data.get(
            "ata_smart_attributes"
        )
        or {}
    ).get("table")

    if isinstance(table, list):
        for attr in table:
            field = ATA_ATTRS.get(
                attr.get("id")
            )

            value = (
                attr.get("raw")
                or {}
            ).get("value")

            if (
                not field
                or value is None
            ):
                continue

            smart[field] = (
                value * SECTOR
                if field == "written"
                else value
            )

    return smart or {
        "error": "empty",
    }


def smart_worker():
    """Aggiorna periodicamente i dati SMART."""

    global _smart

    while True:
        try:
            _smart = {
                name: smart_query(name)
                for name in physical_disks()
            }
        except Exception:
            pass

        time.sleep(SMART_INTERVAL)


# =============================================================================
# TEMPERATURE
# =============================================================================

# Driver noti che normalmente rappresentano la temperatura CPU.
CPU_CHIPS = {
    # AMD
    "k10temp",
    "zenpower",
    "zenpower3",

    # Intel
    "coretemp",

    # ARM / embedded
    "cpu_thermal",
    "soc_thermal",

    # Generici
    "acpi_thermal",
}

MAIN_LABELS = (
    "Tctl",
    "Tdie",
    "Composite",
    "Package id 0",
)

TEMP_RANGE = (
    20,
    150,
)

SLOW_SENSOR_MS = 2.0
TEMP_INTERVAL = 3.0

_sensors = []
_slow_temps = {}
_sensor_speed = {}


def is_cpu_sensor(chip, label, path):
    """Determina se un sensore appartiene probabilmente alla CPU."""

    chip = (
        chip
        or ""
    ).lower()

    label = (
        label
        or ""
    ).lower()

    path = (
        path
        or ""
    ).lower()

    if chip in CPU_CHIPS:
        return True

    cpu_words = (
        "cpu",
        "package",
        "tctl",
        "tdie",
    )

    if any(
        word in label
        for word in cpu_words
    ):
        return True

    if "/cpu" in path:
        return True

    return False


def hwmon_disks():
    """Mappa percorso hwmon -> disco."""

    out = {}

    try:
        names = os.listdir("/sys/block")
    except OSError:
        return out

    for name in names:
        if not is_disk(name):
            continue

        device = (
            f"/sys/block/{name}/device"
        )

        try:
            entries = os.listdir(device)
        except OSError:
            continue

        for entry in entries:
            if entry.startswith("hwmon"):
                out[
                    os.path.realpath(
                        f"{device}/{entry}"
                    )
                ] = name

    return out


def sensor_limit(base):
    """Temperatura critica o massima plausibile."""

    for field in (
        "_crit",
        "_max",
    ):
        value = read_int(
            base + field
        )

        if value is None:
            continue

        celsius = value / 1000

        if (
            TEMP_RANGE[0]
            <= celsius
            <= TEMP_RANGE[1]
        ):
            return round(celsius)

    return None


def scan_sensors():
    """Enumera i sensori di temperatura."""

    by_hwmon = hwmon_disks()
    out = []

    try:
        entries = sorted(
            os.scandir(
                "/sys/class/hwmon"
            ),
            key=lambda e: e.name,
        )
    except OSError:
        return out

    for entry in entries:
        chip = (
            read_file(
                f"{entry.path}/name"
            )
            or ""
        ).strip()

        if not chip:
            continue

        disk = by_hwmon.get(
            os.path.realpath(entry.path),
            "",
        )

        try:
            files = sorted(
                os.listdir(entry.path)
            )
        except OSError:
            continue

        chip_sensors = []

        for filename in files:
            if (
                not filename.startswith("temp")
                or not filename.endswith("_input")
            ):
                continue

            base = (
                f"{entry.path}/"
                f"{filename[:-len('_input')]}"
            )

            label = (
                read_file(
                    f"{base}_label"
                )
                or ""
            ).strip()

            if not label:
                label = filename[
                    :-len("_input")
                ]

            path = f"{base}_input"

            if path not in _sensor_speed:
                started = time.perf_counter()

                read_file(path)

                _sensor_speed[path] = (
                    (
                        time.perf_counter()
                        - started
                    )
                    * 1000
                )

            chip_sensors.append(
                {
                    "key": (
                        f"{disk or chip}/"
                        f"{label}"
                    ),
                    "chip": chip,
                    "label": label,
                    "disk": disk,
                    "path": path,
                    "slow": (
                        _sensor_speed[path]
                        > SLOW_SENSOR_MS
                    ),
                    "crit": sensor_limit(base),
                    "cpu": is_cpu_sensor(
                        chip,
                        label,
                        path,
                    ),
                    "main": False,
                }
            )

        mark_main(chip_sensors)

        for sensor in chip_sensors:
            sensor["primary"] = (
                sensor["main"]
                and (
                    sensor["cpu"]
                    or bool(sensor["disk"])
                )
            )

        out += chip_sensors

    return out


def mark_main(sensors):
    """Elegge il sensore principale di un chip."""

    for wanted in MAIN_LABELS:
        for sensor in sensors:
            if sensor["label"] == wanted:
                sensor["main"] = True
                return

    for sensor in sensors:
        if sensor["label"].startswith(
            "Package"
        ):
            sensor["main"] = True
            return

    if sensors:
        sensors[0]["main"] = True


def temp_worker():
    """Legge periodicamente le sonde lente."""

    global _slow_temps

    while True:
        values = {}

        for sensor in _sensors:
            if not sensor["slow"]:
                continue

            value = read_int(
                sensor["path"]
            )

            if value is not None:
                values[
                    sensor["key"]
                ] = value / 1000

        _slow_temps = values

        time.sleep(TEMP_INTERVAL)


def read_temps():
    """Legge tutti i sensori disponibili."""

    out = []

    for sensor in _sensors:
        if sensor["slow"]:
            if (
                sensor["key"]
                not in _slow_temps
            ):
                continue

            celsius = _slow_temps[
                sensor["key"]
            ]

        else:
            value = read_int(
                sensor["path"]
            )

            if value is None:
                continue

            celsius = value / 1000

        out.append(
            {
                "key": sensor["key"],
                "chip": sensor["chip"],
                "label": sensor["label"],
                "disk": sensor["disk"],
                "temp": round(
                    celsius,
                    1,
                ),
                "crit": sensor["crit"],
                "cpu": sensor["cpu"],
                "main": sensor["main"],
                "primary": sensor["primary"],
            }
        )

    return out


# =============================================================================
# FREQUENZA CPU
# =============================================================================

CPUFREQ_ROOT = (
    "/sys/devices/system/cpu"
)

_freq_paths = []
_freq_static = {}


def cpu_frequency_paths():
    """Trova la migliore sorgente di frequenza per ogni CPU.

    Ordine:

      1. cpuinfo_avg_freq
      2. scaling_cur_freq
      3. cpuinfo_cur_freq

    Non tutti i driver Linux espongono gli stessi file.
    """

    paths = []

    cpu_count = (
        os.cpu_count()
        or 0
    )

    for cpu in range(cpu_count):
        base = (
            f"{CPUFREQ_ROOT}/"
            f"cpu{cpu}/cpufreq"
        )

        if not os.path.isdir(base):
            paths.append(None)
            continue

        selected = None

        for field in (
            "cpuinfo_avg_freq",
            "scaling_cur_freq",
            "cpuinfo_cur_freq",
        ):
            path = (
                f"{base}/"
                f"{field}"
            )

            if os.path.exists(path):
                selected = path
                break

        paths.append(selected)

    return paths


def cpu_frequency_fallback():
    """Fallback tramite /proc/cpuinfo.

    Restituisce:

        cpu_number -> MHz
    """

    result = {}

    try:
        with open(
            "/proc/cpuinfo",
            encoding="utf-8",
            errors="replace",
        ) as f:

            current_cpu = None
            fallback_index = 0

            for raw_line in f:
                line = raw_line.strip()

                if not line:
                    if current_cpu is not None:
                        fallback_index = max(
                            fallback_index,
                            current_cpu + 1,
                        )

                    current_cpu = None
                    continue

                if ":" not in line:
                    continue

                key, value = line.split(
                    ":",
                    1,
                )

                key = key.strip().lower()
                value = value.strip()

                if key == "processor":
                    try:
                        current_cpu = int(value)
                    except ValueError:
                        current_cpu = fallback_index

                elif key in (
                    "cpu mhz",
                    "clock",
                ):
                    if current_cpu is None:
                        current_cpu = fallback_index

                    try:
                        cleaned = (
                            value
                            .replace("MHz", "")
                            .replace("mhz", "")
                            .strip()
                        )

                        mhz = round(
                            float(cleaned)
                        )

                        if mhz > 0:
                            result[
                                current_cpu
                            ] = mhz

                    except ValueError:
                        pass

    except OSError:
        pass

    return result


def find_cpufreq_base():
    """Trova una directory cpufreq valida."""

    for path in _freq_paths:
        if path:
            return os.path.dirname(path)

    return None


def scan_cpufreq():
    """Scansiona le sorgenti di frequenza disponibili."""

    global _freq_paths
    global _freq_static

    _freq_paths = cpu_frequency_paths()

    base = find_cpufreq_base()

    if not base:
        _freq_static = {
            "max": 0,
            "governor": "",
            "driver": "",
            "boost": "",
        }
        return

    def field(name):
        data = read_file(
            f"{base}/{name}"
        )

        return (
            data.strip()
            if data
            else ""
        )

    max_freq = read_int(
        f"{base}/cpuinfo_max_freq"
    )

    if max_freq is None:
        max_freq = read_int(
            f"{base}/scaling_max_freq"
        )

    ceiling = (
        round(max_freq / 1000)
        if max_freq
        else 0
    )

    governor = field(
        "scaling_governor"
    )

    driver = field(
        "scaling_driver"
    )

    boost = field("boost")

    if not boost:
        global_boost = read_file(
            "/sys/devices/system/cpu/"
            "cpufreq/boost"
        )

        boost = (
            global_boost.strip()
            if global_boost
            else ""
        )

    _freq_static = {
        "max": ceiling,
        "governor": governor,
        "driver": driver,
        "boost": boost,
    }


def cpu_freq():
    """Restituisce la frequenza delle CPU logiche in MHz.

    Prima usa cpufreq. Per le CPU che non espongono una frequenza tramite
    cpufreq prova /proc/cpuinfo.
    """

    cpu_count = (
        os.cpu_count()
        or 0
    )

    if cpu_count <= 0:
        return None

    fallback = (
        cpu_frequency_fallback()
    )

    cores = []

    for cpu in range(cpu_count):
        mhz = 0

        path = (
            _freq_paths[cpu]
            if cpu < len(_freq_paths)
            else None
        )

        if path:
            value = read_int(path)

            if (
                value is not None
                and value > 0
            ):
                mhz = round(
                    value / 1000
                )

        if mhz <= 0:
            mhz = fallback.get(
                cpu,
                0,
            )

        cores.append(mhz)

    live = [
        value
        for value in cores
        if value > 0
    ]

    if not live:
        return None

    out = dict(_freq_static)

    out["cores"] = cores
    out["avg"] = round(
        sum(live)
        / len(live)
    )
    out["low"] = min(live)
    out["peak"] = max(live)

    return out


# =============================================================================
# PRESSIONE PSI
# =============================================================================

PSI_RESOURCES = (
    "cpu",
    "io",
    "memory",
)


def psi_read():
    """Legge Pressure Stall Information."""

    out = {}

    for name in PSI_RESOURCES:
        data = read_file(
            f"/proc/pressure/{name}"
        )

        if not data:
            continue

        entry = {}

        for line in data.splitlines():
            fields = line.split()

            if not fields:
                continue

            kind = fields[0]

            for pair in fields[1:]:
                key, _, value = pair.partition("=")

                try:
                    number = float(value)
                except ValueError:
                    continue

                if key == "total":
                    entry[kind] = number

                elif key == "avg60":
                    entry[
                        kind + "Avg60"
                    ] = number

        out[name] = entry

    return out


def pressure(prev, cur, dt):
    """Calcola la pressione nell'intervallo."""

    out = {}

    if dt <= 0:
        return out

    for name in PSI_RESOURCES:
        after = cur.get(name)

        if not after:
            continue

        before = (
            prev.get(name)
            or {}
        )

        entry = {}

        for kind in (
            "some",
            "full",
        ):
            if kind not in after:
                continue

            delta = (
                after[kind]
                - before.get(
                    kind,
                    after[kind],
                )
            )

            entry[kind] = round(
                min(
                    100.0,
                    max(
                        0.0,
                        delta
                        / 1e6
                        / dt
                        * 100,
                    ),
                ),
                1,
            )

            entry[
                kind + "Avg60"
            ] = round(
                after.get(
                    kind + "Avg60",
                    0.0,
                ),
                1,
            )

        out[name] = entry

    return out


# =============================================================================
# STATO DEL SISTEMA
# =============================================================================

_health = {}


def kernel_state():
    """Kernel in esecuzione e ultimo kernel installato."""

    running = os.uname().release

    latest = ""
    newest = 0.0

    try:
        for entry in os.scandir("/boot"):
            if not entry.name.startswith(
                "vmlinuz-"
            ):
                continue

            try:
                stamp = (
                    entry.stat().st_mtime
                )
            except OSError:
                continue

            if stamp > newest:
                newest = stamp

                latest = entry.name[
                    len("vmlinuz-") :
                ]

    except OSError:
        pass

    return {
        "running": running,
        "latest": latest or running,
        "rebootPending": (
            bool(latest)
            and latest != running
        ),
    }


def failed_units():
    """Unit systemd fallite."""

    out = {
        "system": 0,
        "user": 0,
        "names": [],
    }

    for scope in (
        "system",
        "user",
    ):
        try:
            result = subprocess.run(
                [
                    "systemctl",
                    f"--{scope}",
                    "--failed",
                    "--no-legend",
                    "--plain",
                ],
                capture_output=True,
                text=True,
                timeout=15,
            )

            lines = (
                result.stdout.splitlines()
            )

        except (
            OSError,
            subprocess.SubprocessError,
        ):
            continue

        names = [
            line.split()[0]
            for line in lines
            if line.split()
        ]

        out[scope] = len(names)
        out["names"] += names[:3]

    return out


def updates():
    """Pacchetti aggiornabili."""

    out = {
        "dnf": 0,
        "flatpak": 0,
        "samples": [],
        "packagekit": bool(
            shutil.which("pkcon")
        ),
    }

    if shutil.which("dnf"):
        try:
            result = subprocess.run(
                [
                    "dnf",
                    "check-update",
                    "-q",
                ],
                capture_output=True,
                text=True,
                timeout=120,
            )

            stdout = result.stdout

        except (
            OSError,
            subprocess.SubprocessError,
        ):
            stdout = ""

        for line in stdout.splitlines():
            if not line.strip():
                break

            fields = line.split()

            if len(fields) != 3:
                continue

            out["dnf"] += 1

            if len(out["samples"]) < 3:
                out["samples"].append(
                    fields[0].rsplit(
                        ".",
                        1,
                    )[0]
                )

    if shutil.which("flatpak"):
        try:
            result = subprocess.run(
                [
                    "flatpak",
                    "remote-ls",
                    "--updates",
                ],
                capture_output=True,
                text=True,
                timeout=120,
            )

            stdout = result.stdout

        except (
            OSError,
            subprocess.SubprocessError,
        ):
            stdout = ""

        out["flatpak"] = len(
            [
                line
                for line in stdout.splitlines()
                if line.strip()
            ]
        )

    return out


def health_worker():
    """Aggiorna stato generale e sensori."""

    global _health
    global _sensors

    waited = UPDATE_INTERVAL

    while True:
        try:
            state = dict(_health)

            state["kernel"] = (
                kernel_state()
            )

            state["units"] = (
                failed_units()
            )

            if waited >= UPDATE_INTERVAL:
                state["updates"] = updates()
                waited = 0.0

            _health = state

            _sensors = scan_sensors()
            scan_cpufreq()

        except Exception:
            pass

        time.sleep(HEALTH_INTERVAL)

        waited += HEALTH_INTERVAL


def net_errors(iface):
    """Errori di rete."""

    out = {
        "rxErrors": 0,
        "rxDropped": 0,
        "txErrors": 0,
        "txDropped": 0,
    }

    if not iface:
        return out

    base = (
        f"/sys/class/net/{iface}"
        "/statistics"
    )

    for key, name in (
        ("rxErrors", "rx_errors"),
        ("rxDropped", "rx_dropped"),
        ("txErrors", "tx_errors"),
        ("txDropped", "tx_dropped"),
    ):
        value = read_int(
            f"{base}/{name}"
        )

        if value is not None:
            out[key] = value

    return out


def uptime():
    """Secondi dall'avvio."""

    try:
        data = read_file(
            "/proc/uptime"
        )

        return round(
            float(
                data.split()[0]
            )
        )

    except (
        AttributeError,
        IndexError,
        ValueError,
    ):
        return 0


# =============================================================================
# MAIN
# =============================================================================

def main():
    """Ciclo principale."""

    global CPU_NAME
    global GPU_NAME
    global _sensors

    parse_args()

    CPU_NAME = cpu_model()
    GPU_NAME = gpu_model()

    iface = default_iface()

    prev_cpu = cpu_times()
    # una entrata per interfaccia, non solo per quella di default: vedi il
    # ciclo principale piu' sotto
    prev_net_all = {name: net_bytes(name) for name in list_ifaces()}
    # interfaccia -> quando ha portato traffico l'ultima volta (IFACE_MEMORY)
    iface_seen = {}

    prev_procs = proc_cpu_times()

    prev_total = sum(
        total
        for _, total in prev_cpu
    )

    prev_t = time.monotonic()

    rapl = find_rapl()
    prev_energy = rapl_energy(rapl)

    _sensors = scan_sensors()

    scan_cpufreq()

    prev_psi = psi_read()
    prev_vm = vmstat()

    oom_at_start = prev_vm.get(
        "oom_kill",
        0,
    )

    threading.Thread(
        target=ram_worker,
        daemon=True,
    ).start()

    threading.Thread(
        target=disk_space_worker,
        daemon=True,
    ).start()

    threading.Thread(
        target=temp_worker,
        daemon=True,
    ).start()

    threading.Thread(
        target=smart_worker,
        daemon=True,
    ).start()

    threading.Thread(
        target=health_worker,
        daemon=True,
    ).start()

    prev_disk = disk_counters()

    while True:
        time.sleep(INTERVAL)

        now = time.monotonic()

        dt = (
            now - prev_t
            or INTERVAL
        )

        prev_t = now

        # ---------------------------------------------------------------------
        # CPU
        # ---------------------------------------------------------------------

        cur_cpu = cpu_times()

        cores = []

        for (
            (prev_busy, prev_total_core),
            (cur_busy, cur_total_core),
        ) in zip(
            prev_cpu,
            cur_cpu,
        ):
            delta_total = (
                cur_total_core
                - prev_total_core
            )

            if delta_total > 0:
                pct = round(
                    (
                        cur_busy
                        - prev_busy
                    )
                    / delta_total
                    * 100,
                    1,
                )
            else:
                pct = 0.0

            cores.append(pct)

        cur_total = sum(
            total
            for _, total in cur_cpu
        )

        cur_procs = proc_cpu_times()

        cpu_apps = top_cpu(
            prev_procs,
            cur_procs,
            cur_total - prev_total,
            TOP_COUNT,
        )

        prev_cpu = cur_cpu
        prev_procs = cur_procs
        prev_total = cur_total

        # ---------------------------------------------------------------------
        # POTENZA CPU
        # ---------------------------------------------------------------------

        cpu_watts = None

        energy = rapl_energy(rapl)

        if (
            energy is not None
            and prev_energy is not None
        ):
            delta = (
                energy
                - prev_energy
            )

            if (
                delta < 0
                and rapl
                and rapl["max"] > 0
            ):
                delta += rapl["max"]

            if delta >= 0:
                cpu_watts = round(
                    delta
                    / 1e6
                    / dt,
                    1,
                )

        prev_energy = energy

        # ---------------------------------------------------------------------
        # GPU
        # ---------------------------------------------------------------------

        smi = (
            smi_query()
            if BACKEND == "smi"
            else None
        )

        gpu_watts, gpu_limit = (
            gpu_power(smi)
        )

        power = {
            "cpu": cpu_watts,
            "gpu": (
                round(
                    gpu_watts,
                    1,
                )
                if gpu_watts is not None
                else None
            ),
            "gpuLimit": gpu_limit,
            "total": round(
                (cpu_watts or 0)
                + (gpu_watts or 0),
                1,
            ),
        }

        gpu_list = gpu_procs()

        # ---------------------------------------------------------------------
        # DISCHI
        # ---------------------------------------------------------------------

        cur_disk = disk_counters()

        disk_list = disks(
            prev_disk,
            cur_disk,
            dt,
        )

        prev_disk = cur_disk

        # ---------------------------------------------------------------------
        # RETE
        # ---------------------------------------------------------------------

        # ricalcolata a ogni giro, non solo all'avvio: e' cosi' che una VPN
        # accesa dopo che la dashboard e' gia' partita cambia interfaccia
        # primaria senza bisogno di riavviare sysmon.py
        iface = default_iface()

        errors = net_errors(iface)

        cur_net_all = {name: net_bytes(name) for name in list_ifaces()}

        # Il totale e' quello della sola interfaccia primaria. Sommare tutte
        # le interfacce conterebbe due volte lo stesso traffico: quello di un
        # tunnel passa anche dalla scheda fisica che lo incapsula, e quello di
        # un container passa sia dal suo veth sia dal bridge a cui e'
        # agganciato. La primaria pero' e' ricalcolata a ogni giro, quindi
        # quando si alza una VPN il grafico ci si sposta da solo.
        rx_delta = tx_delta = 0

        for name, (rx, tx) in cur_net_all.items():
            # un'interfaccia comparsa in questo giro (VPN appena alzata, un
            # container appena avviato) non ha un "prima": il delta parte da
            # zero invece che da un salto inventato
            prev_rx, prev_tx = prev_net_all.get(name, (rx, tx))
            drx = max(0, int((rx - prev_rx) / dt))
            dtx = max(0, int((tx - prev_tx) / dt))

            if drx > 0 or dtx > 0:
                iface_seen[name] = now

            if name == iface:
                rx_delta = drx
                tx_delta = dtx

        # le interfacce viste di recente, non solo quelle attive in questo
        # istante: vedi IFACE_MEMORY
        iface_seen = {
            name: at
            for name, at in iface_seen.items()
            if now - at <= IFACE_MEMORY and name in cur_net_all
        }

        net = {
            "rx": rx_delta,
            "tx": tx_delta,
            "iface": iface or "—",
            "interfaces": sorted(iface_seen),
        }

        prev_net_all = cur_net_all

        # ---------------------------------------------------------------------
        # PSI
        # ---------------------------------------------------------------------

        cur_psi = psi_read()

        psi = pressure(
            prev_psi,
            cur_psi,
            dt,
        )

        prev_psi = cur_psi

        # ---------------------------------------------------------------------
        # MEMORIA
        # ---------------------------------------------------------------------

        cur_vm = vmstat()

        memory = mem()

        for output_key, vm_key in (
            ("swapIn", "pswpin"),
            ("swapOut", "pswpout"),
        ):
            delta = (
                cur_vm.get(
                    vm_key,
                    0,
                )
                - prev_vm.get(
                    vm_key,
                    cur_vm.get(
                        vm_key,
                        0,
                    ),
                )
            )

            memory[output_key] = max(
                0,
                int(
                    delta
                    * PAGE_SIZE
                    / dt
                ),
            )

        memory["majFaults"] = max(
            0,
            round(
                (
                    cur_vm.get(
                        "pgmajfault",
                        0,
                    )
                    - prev_vm.get(
                        "pgmajfault",
                        0,
                    )
                )
                / dt
            ),
        )

        oom = cur_vm.get(
            "oom_kill",
            0,
        )

        prev_vm = cur_vm

        # ---------------------------------------------------------------------
        # HEALTH
        # ---------------------------------------------------------------------

        health = dict(_health)

        health["uptime"] = uptime()

        health["oomKills"] = oom

        health["oomSinceStart"] = max(
            0,
            oom - oom_at_start,
        )

        health["net"] = errors

        health["smart"] = next(
            (
                data.get(
                    "error",
                    "",
                )
                for data in _smart.values()
                if data.get("error")
            ),
            "",
        )

        # ---------------------------------------------------------------------
        # JSON
        # ---------------------------------------------------------------------

        payload = {
            "cores": cores,

            "cpu": (
                round(
                    sum(cores)
                    / len(cores),
                    1,
                )
                if cores
                else 0.0
            ),

            "cpuName": CPU_NAME,

            "gpuName": GPU_NAME,

            "mem": memory,

            "net": net,

            "freq": cpu_freq(),

            "temps": read_temps(),

            "pressure": psi,

            "health": health,

            "gpu": gpu(smi),

            "topCpu": cpu_apps,

            "topGpu": top_gpu(
                gpu_list,
                TOP_COUNT,
            ),

            "topVram": top_vram(
                gpu_list,
                TOP_COUNT,
            ),

            "topRam": _top_ram,

            "power": power,

            "disks": disk_list,
        }

        sys.stdout.write(
            json.dumps(payload)
            + "\n"
        )

        sys.stdout.flush()


if __name__ == "__main__":
    try:
        main()

    except (
        KeyboardInterrupt,
        BrokenPipeError,
    ):
        os._exit(0)