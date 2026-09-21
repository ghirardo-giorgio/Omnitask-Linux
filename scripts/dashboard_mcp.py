#!/usr/bin/env python3
"""MCP server exposing the Quickshell dashboard's live view of this machine.

Speaks MCP over stdio, which is JSON-RPC 2.0 with a small handshake, and
implements it by hand so it runs under any python3. The official SDK is only
installed inside one pyenv interpreter here, and this project has already been
bitten by a module that existed in one python and not the one that actually
ran the script (see the pynvml note in procmon.py).

Two sources, each chosen because it is the authoritative one for its data:

  * The running dashboard, over `qs ipc call`. CPU, disk and network are
    differences between consecutive samples, and the reverse-DNS and
    geolocation caches fill in asynchronously, so a freshly spawned script
    sees none of it. Home Assistant lives only inside QML, which does its own
    HTTP, so there is nowhere else to get it.

  * scripts/services.py, scripts/hardware.py and scripts/kdeconnect.py, run
    directly. Neither is
    differential and both are cheap: systemd units change while the dashboard
    holds a days-old startup snapshot, and the hardware inventory does not
    change at all. Running them here also means those two tools still answer
    when the dashboard is not up, which is the one case where "what is in this
    machine?" is most likely to be asked.

Everything is read-only except three tools: one acts on Home Assistant, and two
write the pixel pet's traits — the sensors that make objects fall into its room.
"""
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SERVICES = os.path.join(HERE, "services.py")
HARDWARE = os.path.join(HERE, "hardware.py")
PHONES = os.path.join(HERE, "kdeconnect.py")
PHONE_ADB = os.path.join(HERE, "phone_adb.py")

# The Quickshell config name, i.e. `qs -c dashboard`. The config lives at
# ~/.config/quickshell/dashboard, usually a symlink to the repository.
CONFIG = os.environ.get("QUICKSHELL_CONFIG", "dashboard")

PROTOCOL_VERSION = "2024-11-05"
SERVER_NAME = "quickshell-dashboard"
SERVER_VERSION = "1.0.0"

# Answers above roughly 128 KiB kill the IPC socket outright rather than being
# truncated, and get unreliable before that. Query.qml keeps replies far below
# it; this is only a sanity check on what comes back.
MAX_REPLY = 200_000


# --------------------------------------------------------------- dashboard


class DashboardUnavailable(Exception):
    """The dashboard is not running, so nothing live can be read.

    Worth its own exception because the honest answer is "I cannot see the
    system right now". Quietly falling back to a cold sample would report that
    nothing is using the network, which is a wrong answer rather than a
    missing one.
    """


# How to address the running dashboard.
#
# 🔴 `--any-display`, and it is not decoration: `qs ipc` only considers an
# instance live when it shares the CALLER's display connection, so without
# WAYLAND_DISPLAY in the environment it reports "no running instances" while the
# dashboard is right there on screen. An MCP server is started by whatever the
# user is chatting in — LM Studio from a desktop launcher, Hermes from a systemd
# unit — and neither is guaranteed to pass that variable through. Measured: with
# WAYLAND_DISPLAY stripped, every tool failed with "the dashboard is not
# answering. Start it with `qs -c dashboard`" against a dashboard that was
# running and visible, which is the worst kind of wrong answer — it sends the
# user to fix something that is not broken.
#
# The flags also go AFTER `ipc`: `qs -c name ipc call` works, `qs -i id ipc call`
# does not, and keeping both in one place is what stops that from being
# rediscovered.
IPC_FLAGS = ["-c", CONFIG, "--any-display"]


def ipc(function, request):
    """Call one of the dashboard's IPC functions with a JSON string argument."""
    try:
        done = subprocess.run(
            ["qs", "ipc"] + IPC_FLAGS + ["call", "dashboard", function,
                                         json.dumps(request)],
            capture_output=True,
            text=True,
            timeout=15,
        )
    except FileNotFoundError:
        raise DashboardUnavailable("`qs` is not on PATH; Quickshell does not appear to be installed")
    except subprocess.SubprocessError as exc:
        raise DashboardUnavailable(f"could not reach the dashboard: {exc}")

    out = done.stdout.strip()
    if done.returncode != 0 or not out:
        detail = (done.stderr or "").strip().splitlines()
        why = detail[-1] if detail else "no response"
        raise DashboardUnavailable(
            f"the dashboard is not answering ({why}). Start it with `qs -c {CONFIG}`."
        )

    if len(out) > MAX_REPLY:
        raise DashboardUnavailable("the reply was too large to be trusted; narrow the question")

    try:
        return json.loads(out)
    except json.JSONDecodeError:
        raise DashboardUnavailable(f"the dashboard replied with something that is not JSON: {out[:200]}")


def ask(topic, **params):
    params["topic"] = topic
    return ipc("query", params)


# ----------------------------------------------------------------- systemd


def services(scope="all", state="", query=""):
    """systemd units, read fresh rather than from the dashboard's startup copy."""
    try:
        done = subprocess.run(
            ["python3", SERVICES], capture_output=True, text=True, timeout=30
        )
        data = json.loads(done.stdout)
    except (OSError, subprocess.SubprocessError, json.JSONDecodeError) as exc:
        return {"ok": False, "error": f"could not list systemd units: {exc}"}

    scopes = ["user", "system"] if scope == "all" else [scope]
    rows = []
    totals = {}

    for which in scopes:
        units = data.get(which, [])
        totals[which] = len(units)
        for unit in units:
            if state and unit.get("active", "") != state:
                continue
            if query and query.lower() not in unit.get("name", "").lower() \
                    and query.lower() not in unit.get("description", "").lower():
                continue
            rows.append({
                "name": unit.get("name", ""),
                "scope": which,
                "description": unit.get("description", ""),
                # `active` is the unit's current state, `state` is whether it
                # is set to start at boot. Two different questions that read
                # confusingly alike, so they are spelled out here.
                "running": unit.get("active", ""),
                "detail": unit.get("sub", ""),
                "starts_at_boot": unit.get("state", ""),
            })

    # 697 units on this machine: everything must be filtered or capped.
    shown = rows[:60]
    return {
        "ok": True,
        "units": shown,
        "matched": len(rows),
        "shown": len(shown),
        "total_by_scope": totals,
        "note": "Read directly from systemctl, so this is current as of this call.",
    }


# Perche' un'unita' sta come sta, detto in inglese. I codici arrivano da
# services.py: il collector non scrive frasi, per la stessa ragione per cui non
# le scrive kdeconnect.py — la stessa risposta serve questo server in inglese e
# il pannello nella lingua scelta dall'utente.
CAUSES = {
    "exit-code": "the program ran and exited with a non-zero status — the reason is in what it printed, not in systemd",
    "signal": "the program was killed by a signal rather than exiting on its own",
    "core-dump": "the program crashed and dumped core (coredumpctl has the dump)",
    "timeout": "systemd gave up waiting: the unit passed a start, stop or runtime time limit",
    "watchdog": "the program stopped pinging systemd's watchdog",
    "start-limit-hit": "restarted too often too quickly, so systemd stopped trying — it needs `systemctl reset-failed` before it will start again",
    "oom-kill": "the kernel killed it to reclaim memory",
    "resources": "systemd could not set the unit up — a missing binary, a user or a namespace it could not create",
    "exec-condition": "the ExecCondition command said not to run",
    "protocol": "the unit did not speak the protocol its Type= promised, e.g. a notify service that never notified",
    "condition": "a Condition… in the unit file was not met, so it was skipped rather than started — this is not a failure",
    "assert": "an Assert… in the unit file was not met, which systemd treats as a failure",
    "not-found": "no such unit in that systemd",
    "running": "it is running",
    "stopped": "it is stopped, and stopped cleanly",
    "success": "the last run ended cleanly",
    "unknown": "systemd recorded no reason",
}


def diagnose(unit="", scope="all", lines=0):
    """Why units are in the state they are in, with the journal to prove it."""
    argv = ["python3", SERVICES, "diagnose"]

    if unit:
        argv.append(unit)

    if scope in ("user", "system"):
        argv += ["--scope", scope]

    if lines:
        argv += ["--lines", str(lines)]

    try:
        done = subprocess.run(argv, capture_output=True, text=True, timeout=90)
        data = json.loads(done.stdout)
    except (OSError, subprocess.SubprocessError, json.JSONDecodeError) as exc:
        return {"ok": False, "error": f"could not diagnose: {exc}"}

    if not data.get("ok"):
        return data

    for row in data.get("units", []):
        row["explanation"] = CAUSES.get(row.get("cause", ""), "")

    return {
        "ok": True,
        "units": data.get("units", []),
        "note": data.get("note", "") or (
            "Read live from systemctl and the journal. Nothing here has been "
            "changed: starting, stopping and resetting units is the person's "
            "to do."
        ),
    }


# ---------------------------------------------------------------- hardware


# Sections small enough to hand over whole. `pci` and `usb` are the long ones,
# so the summary keeps only what somebody means by "what is in this machine".
HARDWARE_SECTIONS = ("board", "cpu", "memory", "graphics", "audio",
                     "network", "storage", "displays", "usb", "pci")


def hardware(section="", query=""):
    """The machine's hardware inventory, read straight from sysfs and lspci.

    Static data, so there is nothing to gain from going through the dashboard
    — and one thing to lose: this way the answer survives the dashboard being
    closed.
    """
    args = ["python3", HARDWARE] + ([section] if section else [])

    try:
        done = subprocess.run(args, capture_output=True, text=True, timeout=30)
        data = json.loads(done.stdout)
    except (OSError, subprocess.SubprocessError, json.JSONDecodeError) as exc:
        return {"ok": False, "error": f"could not read the hardware inventory: {exc}"}

    if not data.get("ok"):
        return data

    if query:
        return hardware_search(data, query)

    if section:
        return data

    # No section asked for: everything except the two long lists, which are
    # summarised. Handing over 39 PCI devices and every USB hub to answer
    # "what graphics card is this?" is most of the reply and none of the point.
    full = dict(data)
    pci = full.pop("pci", [])
    usb = full.pop("usb", [])

    full["pci_summary"] = {
        "devices": len(pci),
        "internal_bridges": sum(1 for d in pci if d.get("internal")),
        "without_driver": [d.get("device", d.get("slot", "")) for d in pci
                           if not d.get("driver") and not d.get("internal")],
    }
    full["usb_summary"] = {
        "devices": sum(1 for d in usb if not d.get("root_hub")),
        "named": [" ".join(x for x in (d.get("vendor", ""), d.get("product", "")) if x)
                  or f"{d.get('vendor_id', '')}:{d.get('product_id', '')}"
                  for d in usb if not d.get("root_hub") and not d.get("hub")],
    }
    full["note"] = (
        "The full pci and usb lists were left out; ask again with "
        "section='pci' or section='usb', or pass query= to search every "
        "section at once."
    )
    return full


def hardware_search(data, query):
    """Every device in every section whose text mentions `query`.

    Answers "which driver is the sound card on?" without having to know that
    sound cards live under `audio` and their controller under `pci`.
    """
    wanted = query.lower()
    found = {}

    for name in HARDWARE_SECTIONS:
        value = data.get(name)
        if isinstance(value, list):
            rows = [row for row in value if wanted in json.dumps(row).lower()]
        elif isinstance(value, dict):
            rows = value if wanted in json.dumps(value).lower() else None
        else:
            continue
        if rows:
            found[name] = rows

    return {
        "ok": True,
        "query": query,
        "matched": found,
        "sections_matched": list(found),
        "note": "Sections with no match are omitted." if found
                else f"Nothing in the hardware inventory mentions '{query}'.",
    }


# ------------------------------------------------------------------ phones


def phones():
    """Battery and connection state of the paired KDE Connect devices.

    Read directly rather than through the dashboard for the same reason as
    systemd: the dashboard only polls this while its panel is on screen, so
    going through it would answer "no devices" whenever the panel is off.
    """
    try:
        done = subprocess.run(
            ["python3", PHONES], capture_output=True, text=True, timeout=20
        )
        data = json.loads(done.stdout)
    except (OSError, subprocess.SubprocessError, json.JSONDecodeError) as exc:
        return {"ok": False, "error": f"could not read the paired devices: {exc}"}

    if not data.get("ok"):
        return data

    # The collector reports codes; the model wants the reason spelled out, and
    # the difference between "off" and "not reporting" is the whole point of
    # not showing a zero.
    reasons = {
        "unpaired": "not paired with this machine",
        "unreachable": "paired but not reachable — the device is off, asleep, or on another network",
        "not_reported": "connected, but not reporting battery (its battery plugin is off)",
        "gsconnect_cannot_report": "only GSConnect knows this device, and GSConnect does not publish battery over D-Bus",
    }

    devices = data.get("devices", [])
    for device in devices:
        code = device.get("battery_unknown")
        if code:
            device["battery_unknown"] = reasons.get(code, code)

    paired = [d for d in devices if d.get("paired")]
    charged = [d for d in paired if d.get("battery")]

    return {
        "ok": True,
        # Which daemon answered. GSConnect cannot report battery at all, so a
        # missing percentage means something different depending on this.
        "source": data.get("source", ""),
        "devices": paired,
        # Devices the daemon can see but that are not paired with this machine
        # — typically another KDE Connect implementation on this same host.
        "unpaired_seen": len(devices) - len(paired),
        "lowest_battery": min(
            (d["battery"]["percent"] for d in charged), default=None
        ),
        "note": data.get("note", ""),
    }


def phone_adb(*args):
    """Run scripts/phone_adb.py and hand back its JSON.

    Everything that talks to a phone over ADB lives in that script rather than
    here: discovering the wireless-debugging port over mDNS, pairing, and
    picking which of three phones a command means are all decisions that have
    to be made the same way whether they were asked for from this server or
    from a terminal.
    """
    try:
        done = subprocess.run(
            ["python3", PHONE_ADB] + [str(a) for a in args],
            capture_output=True,
            text=True,
            timeout=120,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        return {"ok": False, "error": f"could not run the ADB helper: {exc}"}

    try:
        return json.loads(done.stdout)
    except json.JSONDecodeError:
        return {
            "ok": False,
            "error": (done.stderr or done.stdout or "the ADB helper said nothing").strip(),
        }


# ------------------------------------------------------------------- tools
#
# The descriptions are the prompt: they are phrased as the questions a person
# would actually ask, because that is what the model matches against.

TOOLS = [
    {
        "name": "capabilities",
        "description": (
            "What this dashboard can and cannot see right now, and what is degraded. "
            "Call this first: it reports whether connection attribution is complete, "
            "whether per-process traffic and GPU data are available, how old the "
            "geolocation database is, and whether a VPN is changing where traffic "
            "appears to come from. Answers from the other tools can be confidently "
            "wrong if you skip it."
        ),
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "overview",
        "description": (
            "A one-screen snapshot of the machine: CPU, memory, GPU, network "
            "throughput, power draw, and which programs are busiest. Use for "
            "'how is the system doing?'."
        ),
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "connections",
        "description": (
            "Who a program is talking to over the network and where those machines "
            "are: countries, IP addresses, hostnames, and which interface the "
            "traffic uses. Answers 'which countries are Brave's servers in?'. "
            "Results are aggregated across all processes of a program. Peers the "
            "geolocation database cannot place (anycast CDNs) are reported "
            "separately rather than dropped."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "program": {"type": "string", "description": "Program name or part of its command line, e.g. 'brave'. Omit for every program."},
                "country": {"type": "string", "description": "Only peers in this country, e.g. 'Germany'."},
            },
        },
    },
    {
        "name": "top",
        "description": (
            "Which processes are consuming the most of a resource right now. "
            "Use for 'what is eating my CPU / RAM / disk / network / GPU?'."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "resource": {"type": "string", "enum": ["cpu", "memory", "gpu", "disk", "network"]},
                "limit": {"type": "integer", "description": "How many to return (default 10, max 40)."},
            },
            "required": ["resource"],
        },
    },
    {
        "name": "process",
        "description": (
            "Everything about one program, with all its processes added up — a "
            "browser or an editor runs dozens. Ask by name, or by pid for one "
            "specific process."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "name": {"type": "string", "description": "Program name or part of it."},
                "pid": {"type": "integer", "description": "A specific process id instead of a name."},
            },
        },
    },
    {
        "name": "services",
        "description": (
            "systemd units on this machine: what is running, what failed, what "
            "starts at boot. Covers both the user session and the system. "
            "Set diagnose=true to be told *why* instead of *what*: it answers "
            "'why did X fail?' and 'what are those failed services about?' with "
            "systemd's own verdict on the unit (exit code or the signal that "
            "killed it, whether it timed out, dumped core, hit the restart "
            "limit, or never started because a condition was not met), the "
            "command it ran, the unit file it came from, and the last lines that "
            "unit wrote to the journal. Without a unit name it diagnoses every "
            "currently failed unit at once, which is the usual question. This "
            "reads; it never starts, stops or resets anything — say what you "
            "found and let the person act on it."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "scope": {"type": "string", "enum": ["user", "system", "all"], "description": "Default 'all'."},
                "state": {"type": "string", "description": "Only units in this state, e.g. 'active' or 'failed'."},
                "query": {"type": "string", "description": "Match against unit name or description."},
                "diagnose": {
                    "type": "boolean",
                    "description": (
                        "Explain why units are in the state they are in, "
                        "instead of listing them. With no unit given, every "
                        "unit that is failed right now."
                    ),
                },
                "unit": {
                    "type": "string",
                    "description": (
                        "diagnose only: the exact unit name, e.g. "
                        "'sshd.service'. A name that exists in both systemds is "
                        "reported for both."
                    ),
                },
                "lines": {
                    "type": "integer",
                    "description": (
                        "diagnose only: how many journal entries per unit "
                        "(default 40 for one unit, a third of that when "
                        "diagnosing them all; each entry is one line here, "
                        "trimmed)."
                    ),
                },
            },
        },
    },
    {
        "name": "hardware",
        "description": (
            "What this machine is made of: motherboard and BIOS, CPU, RAM "
            "modules and their speed, graphics card, sound card, network "
            "cards, disks, monitors, and every PCI and USB device — each with "
            "the driver the kernel has bound to it. Answers 'what sound card "
            "is this and what driver does it use?', 'is anything without a "
            "driver?', 'how much RAM can this board take?'. Static data, so "
            "it works even when the dashboard is not running."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "section": {
                    "type": "string",
                    "enum": list(HARDWARE_SECTIONS),
                    "description": "One section only. Omit for everything, with the pci and usb lists summarised.",
                },
                "query": {
                    "type": "string",
                    "description": "Search every section for a device, vendor or driver name, e.g. 'nvidia', 'realtek', 'snd_hda'.",
                },
            },
        },
    },
    {
        "name": "phones",
        "description": (
            "Battery level and connection state of the phones and tablets paired "
            "with this machine over KDE Connect (kdeconnectd or GSConnect). "
            "Answers 'how much battery has my phone got?', 'is it charging?', "
            "'is my phone connected?'. A device that is paired but switched off "
            "reports no battery rather than zero, and says which of the two it "
            "is. Works whether or not the dashboard is running."
        ),
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "phone_adb",
        "description": (
            "Read-only ADB view of the phones: which ones this machine can "
            "drive right now, whether their wireless debugging is on, whether "
            "one is waiting to be paired, what apps are installed on a "
            "connected phone, and what is written on its screen right now. "
            "Answers 'can I control my phone from here?', 'why is adb not "
            "seeing it?', 'what is the package name of the app I want to "
            "launch?', 'what does the screen say?'. ADB is a separate channel from KDE "
            "Connect: a phone can be paired for battery and clipboard and "
            "still be invisible to ADB. Call this before phone_control — the "
            "hints it returns say exactly what the user has to do on the "
            "handset, which is always where authorisation happens."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "section": {
                    "type": "string",
                    "enum": [
                        "status", "apps", "screen", "pointer", "camera",
                        "heart", "today", "vitals",
                    ],
                    "description": (
                        "status (default): every known phone and its ADB state. "
                        "apps: installed packages on one connected phone. "
                        "screen: every label on the screen right now, each "
                        "with its class, whether it can be tapped, and the "
                        "pixel to tap for it — read this before tapping "
                        "anything, and again afterwards to see what changed. "
                        "It reads the accessibility tree, so it needs the "
                        "screen to be ON: on a sleeping phone it says so, and "
                        "phone_control display=on (or unlock, if there is a "
                        "PIN) is what fixes it. Games, canvases and apps drawn "
                        "by hand expose no labels at all — there take a "
                        "screenshot instead, no ADB call can invent them. "
                        "pointer: where the mouse cursor sits right now, in "
                        "screen pixels, ready to hand straight to "
                        "phone_control tap. It needs a mouse on the phone: a "
                        "real one over USB or Bluetooth, or the fake HID one "
                        "that mirror gives it. A finger leaves no coordinates "
                        "at all — Android forgets a touch the moment it ends — "
                        "so this answers 'where did I leave the cursor', never "
                        "'where did the user last tap'. "
                        "camera: the lenses this phone has, with focal length "
                        "and closest focus distance, and which of them look "
                        "like a dedicated macro module. Read-only and works "
                        "even without the camera app installed. "
                        "heart: heart rate over the last `minutes`, one point "
                        "per minute with avg/min/max, gaps left as null. "
                        "today: steps, calories, distance, sleep, skin "
                        "temperature and weight for today. "
                        "vitals: what Health Connect holds and how fresh each "
                        "type is — the section to read when a number looks "
                        "wrong, because it says who wrote the data. "
                        "These last three need the HealthBridge app on the "
                        "phone and take about 6 seconds each. THE DELAY "
                        "MATTERS: the Fitbit app copies into Health Connect in "
                        "batches, so the newest heart sample is typically "
                        "20-30 MINUTES OLD. Always read `lag_seconds` and say "
                        "how old the reading is — never present it as the "
                        "current heart rate. Data Fitbit does not write at all "
                        "(HRV, SpO2, resting heart rate) comes back null."
                    ),
                },
                "device": {
                    "type": "string",
                    "description": (
                        "Which phone: part of its name ('moto g24'), its IP, or "
                        "its ADB serial. Optional when only one is connected — "
                        "with several, every section but status refuses to "
                        "guess and lists the names to choose from. A phone on "
                        "the cable and on wi-fi at once counts as one, not two."
                    ),
                },
                "query": {
                    "type": "string",
                    "description": (
                        "apps: filter the package list, e.g. 'whatsapp'. "
                        "screen: keep only labels containing this."
                    ),
                },
                "minutes": {
                    "type": "integer",
                    "description": (
                        "heart only: how far back to look, in minutes "
                        "(default 60). Given the batching delay, less than 60 "
                        "often comes back all gaps."
                    ),
                },
                "system": {
                    "type": "boolean",
                    "description": "apps only: include system packages (off by default).",
                },
            },
        },
    },
    {
        "name": "phone_control",
        "description": (
            "Act on a phone over ADB: connect or pair it, start an app, open a "
            "URL on it, tap a button by the words written on it, tap a raw "
            "coordinate, swipe, type, press a key, take a screenshot, or take "
            "a real photo with the phone camera. "
            "photo picks between the normal and the macro lens, reads any text "
            "in the shot with on-device OCR, and hands back both the text and a "
            "local image file — use it for 'photograph this component', 'what "
            "does this label say', 'read the markings on this chip'. When a "
            "region of interest is set the shot comes back already cropped to "
            "it, which makes the OCR both better and faster; set one with "
            "roi=left,top,right,bottom in 0..1 after looking at a first shot, "
            "or ask the person to frame it themselves with aim. "
            "The user authorises every phone on the handset itself — an RSA "
            "key prompt over USB, a six-digit code for wireless debugging — "
            "and this cannot bypass that. Pairing is done once and stays done: "
            "the port that worked is remembered, so a later connect usually "
            "needs no code and no mDNS. Only pair when the phone has never been "
            "paired with this machine, and it needs the code the phone is "
            "showing at that moment: ask the user to read it out. repair is for "
            "the opposite case, a phone that dropped an authorisation it once "
            "gave: it tells apart the revoked USB key (it makes the RSA prompt "
            "come back) from a wireless pairing the phone forgot (it clears the "
            "stale 'already paired' bookkeeping, and then pair with a fresh code "
            "is the way back in). forget drops "
            "the remembered port, for when the phone or the network changed. "
            "mirror opens scrcpy in a window on this machine — real-time screen "
            "and two-finger gestures, which ADB alone cannot do; it is for the "
            "person at the keyboard, not a way for you to see the screen (use "
            "screenshot or phone_adb section=screen for that). It gives the "
            "phone a fake HID mouse, so once the person has moved it inside "
            "that window phone_adb section=pointer can read the cursor back. "
            "Prefer tap_text over tap: it looks the label up "
            "in the accessibility tree and hits the button that contains it, "
            "which is what the user means by 'press Salute'. It fails rather "
            "than guessing when the label is not on screen or appears more "
            "than once. Raw tap and swipe take screen pixels, so read "
            "phone_adb section=screen (or take a screenshot) first instead of "
            "inventing coordinates."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "action": {
                    "type": "string",
                    "enum": [
                        "connect", "pair", "repair", "disconnect", "forget", "mirror",
                        "launch", "open",
                        "tap_text", "tap", "swipe", "text", "key", "screenshot",
                        "photo", "aim",
                    ],
                    "description": "What to do.",
                },
                "device": {
                    "type": "string",
                    "description": (
                        "Which phone: part of its name, its IP, or its ADB "
                        "serial. Required when more than one is connected."
                    ),
                },
                "code": {
                    "type": "string",
                    "description": "pair only: the six digits shown on the phone right now.",
                },
                "package": {
                    "type": "string",
                    "description": "launch only: package name, e.g. 'com.whatsapp'.",
                },
                "url": {
                    "type": "string",
                    "description": "open only: the address to open on the phone.",
                },
                "values": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": (
                        "tap: X Y. swipe: X1 Y1 X2 Y2 [duration_ms]. "
                        "key: HOME, BACK, POWER, ENTER… text: the words to type."
                    ),
                },
                "label": {
                    "type": "string",
                    "description": (
                        "tap_text only: the words on the button, as the phone "
                        "shows them, e.g. 'Salute'."
                    ),
                },
                "index": {
                    "type": "integer",
                    "description": (
                        "tap_text only: which one, when the label appears more "
                        "than once (0 is the first). Only after being told it does."
                    ),
                },
                "path": {
                    "type": "string",
                    "description": (
                        "screenshot: where to save the PNG (default /tmp). "
                        "photo: where to save the JPEG (default /tmp)."
                    ),
                },
                "mode": {
                    "type": "string",
                    "enum": ["normal", "macro"],
                    "description": (
                        "photo and aim: which optics. macro focuses at a few "
                        "centimetres and is the one for component markings, "
                        "labels and small print; normal cannot focus closer "
                        "than about ten centimetres."
                    ),
                },
                "roi": {
                    "type": "string",
                    "description": (
                        "photo only: the part of the frame that matters, as "
                        "left,top,right,bottom in 0..1 — e.g. '0.2,0.38,0.9,0.55'. "
                        "It is remembered per lens, so later shots stay cropped "
                        "to it; pass 'off' to go back to the whole frame."
                    ),
                },
                "camera": {
                    "type": "string",
                    "description": (
                        "photo only: force a lens by its id, from phone_adb "
                        "section=camera. With mode=macro this is also how the "
                        "phone gets calibrated: the id is remembered as its "
                        "macro lens."
                    ),
                },
                "zoom": {
                    "type": "string",
                    "description": (
                        "photo only: magnify the framing, e.g. '2.0' — 'off' "
                        "goes back to 1x. It is digital: the focal length is "
                        "fixed, so zooming crops the sensor and scales it up. "
                        "It does NOT reveal more detail — roi already crops "
                        "and keeps the real pixels, so prefer roi for reading "
                        "small print. Zoom earns its place when focus and "
                        "exposure need to settle on the subject rather than on "
                        "the whole scene. Remembered per lens."
                    ),
                },
                "torch": {
                    "type": "boolean",
                    "description": (
                        "photo only: keep the flash on during the shot. Macro "
                        "modules are dim and the phone shades the subject at "
                        "four centimetres, so this is often the difference "
                        "between readable and not."
                    ),
                },
                "full": {
                    "type": "boolean",
                    "description": (
                        "photo only: also download the untouched frame and the "
                        "full-resolution crop, not just the copy sized for "
                        "reading. Megabytes over the network — ask for it when "
                        "the small copy is not enough."
                    ),
                },
            },
            "required": ["action"],
        },
    },
    {
        "name": "home_assistant",
        "description": (
            "Current state of the Home Assistant entities this machine is "
            "connected to: sensors, switches, lights, people. Use for 'what is "
            "the temperature in the living room?' or 'is anything still on?'."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "domain": {"type": "string", "description": "Restrict to one domain, e.g. 'sensor', 'light', 'switch'."},
                "query": {"type": "string", "description": "Match against entity id or friendly name."},
            },
        },
    },
    {
        "name": "health",
        "description": (
            "Whether anything is wrong: temperatures, memory and IO pressure, "
            "out-of-memory kills, network errors, uptime, disk capacity, and a "
            "SMART verdict per disk — 'failing' when the drive itself says so, "
            "'warning' when it still claims to be fine but has pending or "
            "reallocated sectors, media errors or exhausted spare. Use this for "
            "'is a disk dying?'."
        ),
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "trend",
        "description": (
            "How a metric has moved since the dashboard started, summarised as "
            "minimum, maximum, average and first half versus second half. Use to "
            "answer 'is memory still climbing?', which a single reading cannot."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "metric": {
                    "type": "string",
                    "enum": [
                        "cpu", "memory", "gpu", "network_in", "network_out",
                        "heart_rate",
                    ],
                    "description": (
                        "heart_rate needs the Battito panel switched on, and "
                        "reports `gaps` — minutes the wristband sent nothing. "
                        "For a one-off reading that works without the panel, "
                        "use phone_adb section=heart instead."
                    ),
                },
            },
            "required": ["metric"],
        },
    },
    {
        "name": "home_assistant_set",
        "description": (
            "Change a Home Assistant entity: toggle it, or call a service on it. "
            "This is the only tool here that changes anything. The call is "
            "asynchronous, so re-read the entity afterwards to see the result."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "entity_id": {"type": "string", "description": "For example 'light.kitchen'."},
                "action": {"type": "string", "enum": ["toggle", "call"], "description": "'toggle' flips it; 'call' invokes a named service."},
                "service": {"type": "string", "description": "Service name when action is 'call', e.g. 'turn_on'."},
                "domain": {"type": "string", "description": "Service domain; defaults to the entity's own domain."},
                "data": {"type": "object", "description": "Extra service parameters, e.g. {\"brightness\": 128}."},
            },
            "required": ["entity_id", "action"],
        },
    },
    {
        "name": "pressure",
        "description": (
            "Why the machine is stalling and whose fault it is. Answers 'why "
            "did everything freeze for a minute?', 'what is eating the "
            "memory?', 'is it swapping?'. Reports two things that are easy to "
            "confuse and must not be: how long everything WAITED (CPU, disk, "
            "memory pressure), and who HOLDS the memory. They are usually "
            "different cgroups — whoever took the memory first waits for "
            "nothing, so per-cgroup pressure puts the victims on top. In "
            "`holders`, compare `shmem_bytes` against `memory_bytes`: page "
            "cache is dropped for free, shared memory can only be swapped, and "
            "a holder that is mostly shmem is the one that stalls everything. "
            "Read `name`, not the unit: every Electron app registers as "
            "'app-org.chromium.Chromium-<pid>.scope' and is not the browser."
        ),
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "pet_traits",
        "description": (
            "What the pixel pet's traits are wired to: every trait with its "
            "sensor, its current reading and how it makes objects fall, plus "
            "the catalogue of objects (apple, battery, chilli, bomb…) and every "
            "measure a trait can watch — the dashboard's own samples and the "
            "numeric Home Assistant entities. Read this before pet_trait_set: "
            "the item ids and the source strings it returns are the ones that "
            "call expects."
        ),
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "pet_trait_set",
        "description": (
            "Create or amend one of the pet's traits — this writes to the "
            "dashboard's configuration. A trait either feeds the pet's four "
            "stats continuously (role 'wellness') or drops an object into its "
            "room (role 'drop', the default). A dropping trait fires in one of "
            "two ways: on a threshold the value must hold ('above'/'below' with "
            "`threshold` and `hold_minutes`), or every so many units the value "
            "travels ('rise'/'fall' with `step`) — the second is the one for "
            "counters, e.g. an apple every 500 mAh of solar charge. Naming an "
            "existing `id` amends that trait; naming only a `source` creates a "
            "new one, already complete with sensible defaults."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "source": {"type": "string", "description": "'ha:<entity_id>' or 'sys:<key>', from pet_traits.sources. Required for a new trait."},
                "id": {"type": "string", "description": "Amend this existing trait instead of creating one."},
                "label": {"type": "string", "description": "What the panel calls it, e.g. 'Solare carica'."},
                "role": {"type": "string", "enum": ["drop", "wellness"], "description": "'drop' makes objects fall (default); 'wellness' feeds the four stats continuously."},
                "when": {
                    "type": "string",
                    "enum": ["above", "below", "rise", "fall"],
                    "description": "How it fires. 'above'/'below' watch where the value sits; 'rise'/'fall' count how far it travels.",
                },
                "step": {"type": "number", "description": "Units per object, for 'rise'/'fall'. E.g. 500 with a mAh sensor."},
                "threshold": {"type": "number", "description": "The line, for 'above'/'below'."},
                "hold_minutes": {"type": "number", "description": "How long the threshold must hold before the object falls."},
                "cooldown_minutes": {"type": "number", "description": "How long the trait rests after one object, in both modes."},
                "item": {"type": "string", "description": "Catalogue id from pet_traits.items (e.g. 'battery', 'apple', 'chili'), or an emoji to add a new object."},
                "item_label": {"type": "string", "description": "Name for a new emoji object."},
                "kind": {"type": "string", "enum": ["bonus", "malus"], "description": "Whether a NEW emoji object is a reward or a punishment."},
                "gift": {
                    "type": "object",
                    "description": "What collecting it does, in points: {\"energy\": 10}. Only the stats you name change; negative numbers punish.",
                    "properties": {
                        "hunger": {"type": "number"},
                        "energy": {"type": "number"},
                        "happiness": {"type": "number"},
                        "hygiene": {"type": "number"},
                    },
                },
            },
        },
    },
    {
        "name": "pet_trait_remove",
        "description": "Delete one of the pet's traits by id. This writes to the dashboard's configuration.",
        "inputSchema": {
            "type": "object",
            "properties": {"id": {"type": "string", "description": "Trait id, from pet_traits."}},
            "required": ["id"],
        },
    },
]


def call_tool(name, args):
    if name == "services":
        if args.get("diagnose") or args.get("unit"):
            return diagnose(
                unit=args.get("unit", ""),
                scope=args.get("scope", "all"),
                lines=args.get("lines", 0),
            )

        return services(
            scope=args.get("scope", "all"),
            state=args.get("state", ""),
            query=args.get("query", ""),
        )

    if name == "phones":
        return phones()

    if name == "phone_adb":
        section = args.get("section", "status")
        argv = []

        if args.get("device"):
            argv += ["--device", args["device"]]

        argv.append(
            section if section in (
                "apps", "screen", "pointer", "camera", "heart", "today", "vitals",
            )
            else "status"
        )

        if section in ("apps", "screen") and args.get("query"):
            argv += ["--query", args["query"]]

        if section == "heart" and args.get("minutes"):
            argv += ["--minutes", str(args["minutes"])]

        if section == "apps" and args.get("system"):
            argv.append("--system")

        return phone_adb(*argv)

    if name == "phone_control":
        action = args.get("action", "")
        argv = []

        if args.get("device"):
            argv += ["--device", args["device"]]

        if action == "pair":
            if not args.get("code"):
                return {"ok": False, "error": "pairing needs the six-digit code from the phone"}

            argv += ["pair", args["code"]]
        elif action == "launch":
            if not args.get("package"):
                return {"ok": False, "error": "launch needs a package name (see phone_adb apps)"}

            argv += ["launch", args["package"]]
        elif action == "open":
            if not args.get("url"):
                return {"ok": False, "error": "open needs a url"}

            argv += ["open", args["url"]]
        elif action in ("tap", "swipe", "text", "key"):
            values = [str(v) for v in (args.get("values") or [])]

            if not values:
                return {"ok": False, "error": f"{action} needs values"}

            argv += [action] + values
        elif action == "tap_text":
            if not args.get("label"):
                return {"ok": False, "error": "tap_text needs the label written on the button"}

            argv += ["tap-text", args["label"]]

            if args.get("index") is not None:
                argv += ["--index", args["index"]]
        elif action == "screenshot":
            argv.append("screenshot")

            if args.get("path"):
                argv += ["--out", args["path"]]
        elif action == "photo":
            argv += ["photo", "--mode", args.get("mode", "normal")]

            if args.get("path"):
                argv += ["--out", args["path"]]
            if args.get("roi"):
                argv += ["--roi", args["roi"]]
            if args.get("zoom"):
                argv += ["--zoom", str(args["zoom"])]
            if args.get("camera"):
                argv += ["--camera", str(args["camera"])]
            if args.get("torch"):
                argv.append("--torch")
            if args.get("full"):
                argv.append("--full")
        elif action == "aim":
            argv += ["aim", "--mode", args.get("mode", "macro")]
        elif action in ("connect", "repair", "disconnect", "forget", "mirror"):
            argv.append(action)
        else:
            return {"ok": False, "error": f"unknown action: {action}"}

        return phone_adb(*argv)

    if name == "hardware":
        return hardware(
            section=args.get("section", ""),
            query=args.get("query", ""),
        )

    if name == "home_assistant_set":
        return ipc("haAct", {
            "entity_id": args.get("entity_id", ""),
            "action": args.get("action", ""),
            "service": args.get("service", ""),
            "domain": args.get("domain", ""),
            "data": args.get("data", {}),
        })

    if name == "pressure":
        return ask("pressure")

    if name == "pet_traits":
        return ask("pet")

    if name == "pet_trait_set":
        return ipc("petAct", dict(
            {k: v for k, v in args.items() if v not in (None, "")},
            action="set",
        ))

    if name == "pet_trait_remove":
        return ipc("petAct", {"action": "remove", "id": args.get("id", "")})

    if name in ("capabilities", "overview", "health"):
        return ask(name)

    if name in ("connections", "top", "process", "home_assistant", "trend"):
        return ask(name, **{k: v for k, v in args.items() if v not in (None, "")})

    return {"ok": False, "error": f"unknown tool: {name}"}


# ------------------------------------------------------------- JSON-RPC


def result(request_id, payload):
    return {"jsonrpc": "2.0", "id": request_id, "result": payload}


def error(request_id, code, message):
    return {"jsonrpc": "2.0", "id": request_id, "error": {"code": code, "message": message}}


def handle(message):
    """One JSON-RPC message in, one reply out — or None for notifications."""
    method = message.get("method", "")
    request_id = message.get("id")
    params = message.get("params") or {}

    # Notifications carry no id and must never be answered.
    if request_id is None:
        return None

    if method == "initialize":
        return result(request_id, {
            "protocolVersion": PROTOCOL_VERSION,
            "capabilities": {"tools": {}},
            "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
        })

    if method == "ping":
        return result(request_id, {})

    if method == "tools/list":
        return result(request_id, {"tools": TOOLS})

    if method == "tools/call":
        name = params.get("name", "")
        args = params.get("arguments") or {}
        try:
            payload = call_tool(name, args)
        except DashboardUnavailable as exc:
            payload = {"ok": False, "error": str(exc)}
        except Exception as exc:  # never take the server down over one call
            payload = {"ok": False, "error": f"{type(exc).__name__}: {exc}"}

        failed = isinstance(payload, dict) and payload.get("ok") is False
        return result(request_id, {
            "content": [{"type": "text", "text": json.dumps(payload, indent=2)}],
            "isError": failed,
        })

    return error(request_id, -32601, f"method not found: {method}")


def main():
    # Line-delimited JSON on stdin, one reply per line on stdout. Anything the
    # server wants to say to a human goes to stderr: stdout is the protocol.
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            message = json.loads(line)
        except json.JSONDecodeError:
            continue

        reply = handle(message)
        if reply is None:
            continue

        sys.stdout.write(json.dumps(reply) + "\n")
        sys.stdout.flush()


if __name__ == "__main__":
    try:
        main()
    except (KeyboardInterrupt, BrokenPipeError):
        pass
