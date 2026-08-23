#!/usr/bin/env python3
"""Inventario dell'hardware di questa macchina, in un unico JSON.

Lo leggono in due: il pannello Hardware della dashboard e il server MCP. E'
roba che non cambia mai — una scheda PCI non compare mentre guardi — quindi si
esegue su richiesta invece di stare nel ciclo di sysmon.py, che gira ogni due
secondi e non ha nessun motivo di rileggere la scheda madre.

Le fonti sono sysfs quando basta e i comandi di sistema quando servono i nomi:
/sys/bus/pci sa che driver e' legato a 00:1f.3, ma non sa che quel numero e'
una scheda audio Realtek — il nome sta nel database di pci.ids, che lspci ha
gia' in casa. Il contrario vale per il driver, che lspci -k stampa in un
formato scomodo mentre sysfs lo espone come link simbolico.

Tutto senza privilegi tranne i moduli di RAM: quelli stanno nella tabella DMI,
che il kernel lascia leggere solo a root. Senza sudo si riporta il totale della
memoria e si dice come sbloccare il resto, invece di far finta che gli slot non
esistano.
"""
import json
import os
import re
import subprocess
import sys

TIMEOUT = 10

SYS_PCI = "/sys/bus/pci/devices"
SYS_USB = "/sys/bus/usb/devices"
SYS_NET = "/sys/class/net"
SYS_BLOCK = "/sys/block"
SYS_DMI = "/sys/class/dmi/id"

# Le classi PCI che nessuno intende quando dice "che schede ho": ponti, host
# bridge e la ferramenta interna del chipset. Restano nell'elenco completo, ma
# marcate, cosi' chi legge puo' tenerle fuori senza indovinare dai nomi.
INTERNAL_CLASSES = {"0600", "0604", "0601", "0805", "0880", "1080", "0806", "1300"}

# I tipi di telaio della specifica SMBIOS, solo quelli che si incontrano.
CHASSIS = {
    "1": "altro", "2": "sconosciuto", "3": "desktop", "4": "desktop basso",
    "5": "pizza box", "6": "mini tower", "7": "tower", "8": "portatile",
    "9": "laptop", "10": "notebook", "11": "handheld", "13": "all in one",
    "14": "sub notebook", "15": "desktop appoggiato", "16": "lunch box",
    "17": "server", "18": "expansion chassis", "23": "rack",
    "30": "tablet", "31": "convertibile", "32": "detachable",
}

# Le classi di interfaccia USB, per dire cos'e' un dispositivo quando il nome
# non lo dice ("USB Receiver" puo' essere qualsiasi cosa).
USB_CLASSES = {
    "01": "audio", "02": "rete", "03": "input", "05": "physical",
    "06": "immagini", "07": "stampante", "08": "archiviazione",
    "09": "hub", "0a": "dati", "0b": "smart card", "0d": "sicurezza",
    "0e": "video", "0f": "sanitario", "10": "audio/video",
    "e0": "wireless", "ef": "misto", "fe": "specifico", "ff": "proprietario",
}


def read(path, default=""):
    try:
        with open(path, "r", errors="replace") as handle:
            return handle.read().strip()
    except OSError:
        return default


def read_int(path, default=None):
    value = read(path)
    try:
        return int(value)
    except ValueError:
        return default


def link_name(path):
    """L'ultimo pezzo di un link simbolico, che per i driver e' il nome."""
    try:
        return os.path.basename(os.path.realpath(path))
    except OSError:
        return ""


def run(args, timeout=TIMEOUT):
    try:
        done = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
        return done.stdout
    except (OSError, subprocess.SubprocessError):
        return ""


def modules_of(sysfs_dir):
    """I moduli che il kernel caricherebbe per un dispositivo.

    Serve quando il driver non e' legato: dice comunque quale sarebbe. Si
    ricava dal modalias, che e' esattamente cio' su cui fa il match modprobe.
    """
    alias = read(os.path.join(sysfs_dir, "modalias"))
    if not alias:
        return []
    out = run(["modprobe", "-R", alias]).split()
    return [m for m in out if m]


# ------------------------------------------------------------------- board


def board():
    """Scheda madre e BIOS, dalla tabella DMI che il kernel espone in sysfs.

    I numeri di serie stanno accanto a questi file e sono leggibili solo da
    root: non si tenta nemmeno di leggerli, perche' identificano la macchina e
    qui non servono a niente.
    """
    chassis = read(os.path.join(SYS_DMI, "chassis_type"))
    return {
        "vendor": read(os.path.join(SYS_DMI, "board_vendor")),
        "model": read(os.path.join(SYS_DMI, "board_name")),
        "version": read(os.path.join(SYS_DMI, "board_version")),
        "product": read(os.path.join(SYS_DMI, "product_name")),
        "family": read(os.path.join(SYS_DMI, "product_family")),
        "system_vendor": read(os.path.join(SYS_DMI, "sys_vendor")),
        "chassis": CHASSIS.get(chassis, chassis),
        "bios": {
            "vendor": read(os.path.join(SYS_DMI, "bios_vendor")),
            "version": read(os.path.join(SYS_DMI, "bios_version")),
            "date": read(os.path.join(SYS_DMI, "bios_date")),
            "release": read(os.path.join(SYS_DMI, "bios_release")),
        },
    }


# --------------------------------------------------------------------- cpu


def cpu():
    """Il processore, da lscpu piu' quel che sysfs sa sulle frequenze."""
    fields = {}
    out = run(["lscpu", "-J"])
    try:
        for row in json.loads(out).get("lscpu", []):
            fields[row.get("field", "").rstrip(":")] = row.get("data", "")
    except ValueError:
        pass

    if not fields:
        # lscpu manca o e' cambiato: /proc/cpuinfo basta per il nome.
        for line in read("/proc/cpuinfo").splitlines():
            if ":" in line:
                key, _, value = line.partition(":")
                fields.setdefault(key.strip(), value.strip())

    def number(key, cast=float):
        try:
            return cast(fields.get(key, "").replace(",", "."))
        except ValueError:
            return None

    cores = number("Core(s) per socket", int)
    sockets = number("Socket(s)", int)

    # Il governor e' per core, ma sono sempre tutti uguali: si legge il primo.
    governor = read("/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor")
    driver = read("/sys/devices/system/cpu/cpu0/cpufreq/scaling_driver")

    return {
        "model": fields.get("Model name", fields.get("model name", "")),
        "vendor": fields.get("Vendor ID", fields.get("vendor_id", "")),
        "architecture": fields.get("Architecture", ""),
        "threads": number("CPU(s)", int),
        "cores": (cores * sockets) if cores and sockets else cores,
        "sockets": sockets,
        "threads_per_core": number("Thread(s) per core", int),
        "mhz_max": number("CPU max MHz"),
        "mhz_min": number("CPU min MHz"),
        "microcode": fields.get("Microcode", ""),
        "virtualization": fields.get("Virtualization", ""),
        # Le cache arrivano gia' formattate ("512 KiB (16 istanze)"): tenerle
        # com'erano evita di reinventare la conversione.
        "cache": {
            level: fields[key]
            for level, key in (
                ("L1d", "L1d cache"), ("L1i", "L1i cache"),
                ("L2", "L2 cache"), ("L3", "L3 cache"),
            )
            if key in fields
        },
        "governor": governor,
        "frequency_driver": driver,
        "numa_nodes": number("NUMA node(s)", int),
    }


# ------------------------------------------------------------------ memory


def meminfo(key):
    match = re.search(rf"^{key}:\s+(\d+) kB", read("/proc/meminfo"), re.M)
    return int(match.group(1)) * 1024 if match else None


def memory():
    """Totale della RAM sempre, banchi solo se dmidecode e' concesso.

    La tabella DMI e' l'unico posto dove stanno marca, modello e velocita' dei
    moduli: il kernel non li espone altrove, quindi senza root non ci sono
    ripieghi da tentare — si dice come concederlo e si va avanti.
    """
    out = {
        "total_bytes": meminfo("MemTotal"),
        "swap_total_bytes": meminfo("SwapTotal"),
        "modules": [],
    }

    dump = run(["sudo", "-n", "dmidecode", "-t", "16", "-t", "17"], timeout=15)
    if not dump.strip():
        out["detail"] = "denied"
        out["note"] = (
            "Marca, velocita' e slot dei banchi stanno nella tabella DMI, che "
            "solo root puo' leggere. Per concederla: sudo install -m 0440 -o "
            "root -g root scripts/quickshell-hardware.sudoers "
            "/etc/sudoers.d/quickshell-hardware"
        )
        return out

    out["detail"] = "full"

    # dmidecode separa i record con una riga vuota e li apre con "Handle".
    for block in dump.split("\n\n"):
        rows = dict(
            (line.split(":", 1)[0].strip(), line.split(":", 1)[1].strip())
            for line in block.splitlines()
            if ":" in line and line.startswith("\t")
        )

        if "Number Of Devices" in rows:
            out["slots_total"] = int(rows["Number Of Devices"])
            continue

        if "Locator" not in rows or "Size" not in rows:
            continue

        size = rows["Size"]
        if size in ("No Module Installed", "Unknown"):
            continue

        amount, _, unit = size.partition(" ")
        try:
            scale = {"MB": 1024 ** 2, "GB": 1024 ** 3, "TB": 1024 ** 4}.get(unit, 1)
            size_bytes = int(amount) * scale
        except ValueError:
            size_bytes = None

        speed = rows.get("Configured Memory Speed", rows.get("Speed", ""))
        rate = re.match(r"(\d+)", speed)

        out["modules"].append({
            "slot": rows.get("Locator", ""),
            "bank": rows.get("Bank Locator", ""),
            "size_bytes": size_bytes,
            "type": rows.get("Type", ""),
            "form": rows.get("Form Factor", ""),
            # La velocita' configurata e quella massima del banco divergono
            # spesso: un modulo da 3600 che gira a 2133 perche' l'XMP non e'
            # attivo e' esattamente il tipo di cosa che si viene a cercare qui.
            "speed_mts": int(rate.group(1)) if rate else None,
            "rated_mts": int(re.match(r"(\d+)", rows.get("Speed", "")).group(1))
            if re.match(r"(\d+)", rows.get("Speed", "")) else None,
            "manufacturer": rows.get("Manufacturer", ""),
            "part": rows.get("Part Number", ""),
            "rank": rows.get("Rank", ""),
        })

    out["slots_used"] = len(out["modules"])
    return out


# --------------------------------------------------------------------- pci


def pci_names():
    """Nomi leggibili per ogni slot PCI, dal database di lspci.

    -mm e' il formato stabile pensato per essere letto da un programma, -nn
    aggiunge gli identificativi numerici accanto ai nomi.
    """
    out = {}
    for line in run(["lspci", "-mm", "-nn"]).splitlines():
        # slot "Classe [0300]" "Marca [10de]" "Modello [2504]" -rXX -pXX ...
        parts = re.findall(r'"([^"]*)"', line)
        slot = line.split(" ", 1)[0]
        if len(parts) < 3 or not slot:
            continue

        def split_id(text):
            match = re.match(r"^(.*?)\s*\[([0-9a-f]{4})\]$", text)
            return (match.group(1), match.group(2)) if match else (text, "")

        name, class_id = split_id(parts[0])
        vendor, vendor_id = split_id(parts[1])
        device, device_id = split_id(parts[2])

        out[slot] = {
            "class": name,
            "class_id": class_id,
            "vendor": vendor,
            "vendor_id": vendor_id,
            "device": device,
            "device_id": device_id,
            "subsystem": split_id(parts[4])[0] if len(parts) > 4 else "",
        }
    return out


def pci():
    """Ogni dispositivo PCI con il driver che lo sta guidando adesso."""
    names = pci_names()
    out = []

    if not os.path.isdir(SYS_PCI):
        return out

    for address in sorted(os.listdir(SYS_PCI)):
        path = os.path.join(SYS_PCI, address)
        # lspci scrive gli slot senza il dominio quando e' 0000, come quasi
        # sempre; sysfs lo scrive sempre.
        slot = address[5:] if address.startswith("0000:") else address
        info = dict(names.get(slot, names.get(address, {})))

        if not info:
            # Senza lspci restano gli identificativi grezzi: meno leggibili,
            # ma il dispositivo esiste lo stesso e va elencato.
            info = {
                "class": "",
                "class_id": read(os.path.join(path, "class"))[2:6],
                "vendor": "",
                "vendor_id": read(os.path.join(path, "vendor"))[2:],
                "device": "",
                "device_id": read(os.path.join(path, "device"))[2:],
                "subsystem": "",
            }

        driver = link_name(os.path.join(path, "driver"))
        entry = dict(info)
        entry["slot"] = slot
        entry["driver"] = driver if os.path.exists(os.path.join(path, "driver")) else ""
        entry["modules"] = [] if entry["driver"] else modules_of(path)
        entry["internal"] = info.get("class_id", "") in INTERNAL_CLASSES
        entry["link_speed"] = read(os.path.join(path, "current_link_speed"))
        entry["link_width"] = read(os.path.join(path, "current_link_width"))
        out.append(entry)

    return out


def by_class(devices, prefixes):
    return [d for d in devices if d.get("class_id", "").startswith(tuple(prefixes))]


# --------------------------------------------------------------------- usb


def usb():
    """I dispositivi USB collegati, hub compresi ma marcati.

    Ogni dispositivo ha una o piu' interfacce, ed e' l'interfaccia ad avere il
    driver: una cuffia USB e' insieme audio e input, e con due driver diversi.
    """
    out = []

    if not os.path.isdir(SYS_USB):
        return out

    for name in sorted(os.listdir(SYS_USB)):
        # Le voci con i due punti sono interfacce, non dispositivi.
        if ":" in name:
            continue

        path = os.path.join(SYS_USB, name)
        vendor_id = read(os.path.join(path, "idVendor"))
        if not vendor_id:
            continue

        drivers = []
        classes = []
        for interface in sorted(os.listdir(SYS_USB)):
            if not interface.startswith(name + ":"):
                continue
            face = os.path.join(SYS_USB, interface)
            driver = link_name(os.path.join(face, "driver"))
            if driver and driver not in drivers:
                drivers.append(driver)
            kind = read(os.path.join(face, "bInterfaceClass")).lower()
            label = USB_CLASSES.get(kind, kind)
            if label and label not in classes:
                classes.append(label)

        speed = read_int(os.path.join(path, "speed"))
        out.append({
            "path": name,
            "bus": read_int(os.path.join(path, "busnum")),
            "device": read_int(os.path.join(path, "devnum")),
            "vendor_id": vendor_id,
            "product_id": read(os.path.join(path, "idProduct")),
            "vendor": read(os.path.join(path, "manufacturer")),
            "product": read(os.path.join(path, "product")),
            "serial_present": os.path.exists(os.path.join(path, "serial")),
            "speed_mbit": speed,
            # 480 Mbit/s e' USB 2.0, 5000 e' 3.0: la cifra dice piu' della
            # versione dichiarata, che sui hub e' spesso ottimistica.
            "version": read(os.path.join(path, "version")).strip(),
            "classes": classes,
            "drivers": drivers,
            "hub": read(os.path.join(path, "bDeviceClass")) == "09",
            "root_hub": name.endswith("-0") or re.fullmatch(r"usb\d+", name) is not None,
        })

    return out


# ----------------------------------------------------------------- network


def network(devices):
    """Solo le schede vere: le decine di bridge di Docker non sono hardware.

    Il discrimine e' il link `device` in sysfs, che c'e' soltanto quando
    dietro l'interfaccia esiste un pezzo di silicio.
    """
    out = []

    if not os.path.isdir(SYS_NET):
        return out

    slots = {d["slot"]: d for d in devices}

    for name in sorted(os.listdir(SYS_NET)):
        path = os.path.join(SYS_NET, name)
        device = os.path.join(path, "device")
        if not os.path.exists(device):
            continue

        real = os.path.realpath(device)
        slot = os.path.basename(real)
        if slot.startswith("0000:"):
            slot = slot[5:]
        card = slots.get(slot, {})

        speed = read_int(os.path.join(path, "speed"))
        out.append({
            "name": name,
            "driver": link_name(os.path.join(device, "driver")),
            "model": (card.get("device", "") or "").strip(),
            "vendor": (card.get("vendor", "") or "").strip(),
            "bus": "pci" if slot in slots else ("usb" if "/usb" in real else "altro"),
            "slot": slot if slot in slots else "",
            "mac": read(os.path.join(path, "address")),
            # -1 vuol dire "il driver non lo sa", tipico del Wi-Fi.
            "speed_mbit": speed if speed and speed > 0 else None,
            "carrier": read(os.path.join(path, "carrier")) == "1",
            "mtu": read_int(os.path.join(path, "mtu")),
            "wireless": os.path.exists(os.path.join(path, "wireless"))
            or os.path.exists(os.path.join(path, "phy80211")),
            "state": read(os.path.join(path, "operstate")),
        })

    return out


# ------------------------------------------------------------------- audio


def audio(devices):
    """Schede audio come le vede ALSA, piu' il driver di ognuna.

    /proc/asound/cards da' nome e collocazione, /proc/asound/modules il modulo
    del kernel per lo stesso indice: le due liste vanno lette insieme, ed e'
    l'unico posto dove il legame scheda-driver e' scritto per esteso.
    """
    modules = {}
    for line in read("/proc/asound/modules").splitlines():
        parts = line.split()
        if len(parts) == 2:
            modules[parts[0].strip()] = parts[1]

    cards = []
    text = read("/proc/asound/cards")
    # Ogni scheda occupa due righe: intestazione con indice, nome breve,
    # driver e modello, poi la riga lunga con dove e' attaccata. Il trattino
    # che separa driver e modello ha spazi intorno, quello dentro "USB-Audio"
    # no: e' l'unica cosa che distingue i due, e senza spazi obbligatori il
    # driver diventava "USB" e il nome "Audio - ROG Strix Fusion".
    entries = re.findall(
        r"^\s*(\d+)\s+\[(.+?)\s*\]:\s*(\S+)\s+-\s+(.*?)\n\s+(.*)$",
        text,
        re.M,
    )
    for index, short, driver, name, detail in entries:
        bus = "usb" if "usb" in detail.lower() else "pci"
        cards.append({
            "index": int(index),
            "id": short,
            "name": name,
            "driver": driver,
            "module": modules.get(index, ""),
            "bus": bus,
            "detail": detail.strip(),
        })

    # Il controller sul bus, che ALSA non nomina: "HD-Audio Generic" diventa
    # "Starship/Matisse HD Audio Controller" con marca e modello veri.
    controllers = [{
        "slot": d["slot"],
        "vendor": d.get("vendor", ""),
        "device": d.get("device", ""),
        "vendor_id": d.get("vendor_id", ""),
        "device_id": d.get("device_id", ""),
        "driver": d.get("driver", ""),
    } for d in by_class(devices, ["0403", "0401"])]

    return {
        "cards": cards,
        "controllers": controllers,
        "server": sound_server(),
    }


def sound_server():
    """Chi sta gestendo l'audio: si guarda il socket, non il processo.

    Un pipewire avviato e morto lascia il processo per qualche istante; il
    socket c'e' solo se qualcuno lo sta servendo davvero.
    """
    runtime = os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")
    if os.path.exists(os.path.join(runtime, "pipewire-0")):
        return "PipeWire"
    if os.path.exists(os.path.join(runtime, "pulse", "native")):
        return "PulseAudio"
    return "ALSA"


# ----------------------------------------------------------------- storage


def storage():
    """I dischi fisici: niente loop, niente RAM disk, niente partizioni."""
    out = []

    if not os.path.isdir(SYS_BLOCK):
        return out

    for name in sorted(os.listdir(SYS_BLOCK)):
        if name.startswith(("loop", "ram", "zram", "dm-", "sr")):
            continue

        path = os.path.join(SYS_BLOCK, name)
        sectors = read_int(os.path.join(path, "size"), 0) or 0
        real = os.path.realpath(path)

        if name.startswith("nvme"):
            device = os.path.join(path, "device", "device")
            transport = "nvme"
        else:
            device = os.path.join(path, "device")
            transport = "usb" if "/usb" in real else "sata"

        out.append({
            "name": name,
            "model": read(os.path.join(path, "device", "model")),
            "vendor": read(os.path.join(path, "device", "vendor")),
            "firmware": read(os.path.join(path, "device", "firmware_rev"))
            or read(os.path.join(path, "device", "rev")),
            # I settori di sysfs sono sempre da 512 byte, anche sui dischi che
            # internamente ne usano 4096: la conversione e' fissa.
            "size_bytes": sectors * 512,
            "rotational": read(os.path.join(path, "queue", "rotational")) == "1",
            "removable": read(os.path.join(path, "removable")) == "1",
            "transport": transport,
            "driver": link_name(os.path.join(device, "driver")),
        })

    return out


# ---------------------------------------------------------------- displays


def displays():
    """Le uscite video della scheda grafica e cosa c'e' attaccato."""
    out = []
    base = "/sys/class/drm"

    if not os.path.isdir(base):
        return out

    for name in sorted(os.listdir(base)):
        if "-" not in name:
            continue
        path = os.path.join(base, name)
        status = read(os.path.join(path, "status"))
        if not status:
            continue
        out.append({
            # card1-DP-2 -> DP-2: il numero della scheda non interessa a
            # nessuno finche' ce n'e' una sola.
            "connector": name.split("-", 1)[1],
            "card": name.split("-", 1)[0],
            "status": status,
            "enabled": read(os.path.join(path, "enabled")) == "enabled",
        })

    return out


# ------------------------------------------------------------------ report


def collect():
    devices = pci()
    graphics = by_class(devices, ["0300", "0302", "0380"])

    return {
        "ok": True,
        "board": board(),
        "cpu": cpu(),
        "memory": memory(),
        "graphics": [{
            "slot": d["slot"],
            "vendor": d.get("vendor", ""),
            "device": d.get("device", ""),
            # Senza lspci i nomi restano vuoti: gli identificativi numerici
            # arrivano comunque da sysfs, e con quelli il dispositivo si cerca.
            "vendor_id": d.get("vendor_id", ""),
            "device_id": d.get("device_id", ""),
            "driver": d.get("driver", ""),
            "modules": d.get("modules", []),
            "link_speed": d.get("link_speed", ""),
            "link_width": d.get("link_width", ""),
        } for d in graphics],
        "audio": audio(devices),
        "network": network(devices),
        "storage": storage(),
        "displays": displays(),
        "usb": usb(),
        "pci": devices,
    }


SECTIONS = ("board", "cpu", "memory", "graphics", "audio",
            "network", "storage", "displays", "usb", "pci")


if __name__ == "__main__":
    wanted = sys.argv[1] if len(sys.argv) > 1 else ""

    if wanted and wanted not in SECTIONS:
        json.dump(
            {"ok": False, "error": f"sezione sconosciuta: {wanted}",
             "valid": list(SECTIONS)},
            sys.stdout,
        )
        sys.stdout.write("\n")
        raise SystemExit(1)

    report = collect()
    if wanted:
        report = {"ok": True, wanted: report[wanted]}

    json.dump(report, sys.stdout)
    sys.stdout.write("\n")
