"""Dove stanno i programmi esterni che la dashboard chiama.

Di suo ogni script cercava il proprio nel PATH, e finche' i programmi sono
quelli della distribuzione va benissimo. Il caso che rompe questa regola e'
quando ce ne sono *due* e serve il secondo: l'`adb` di Fedora, per esempio, e'
compilato senza mDNS (`adb mdns services` risponde "unknown host service"),
mentre quello dell'SDK Android che sta nella home ce l'ha. Il PATH non e' il
posto giusto per dirlo: quello della sessione grafica non e' quello del
terminale — la dashboard gira con quattro voci in croce ereditate da GNOME, e
un `export` in .zshrc non la raggiunge nemmeno per sbaglio.

Da qui l'ordine: prima la variabile d'ambiente, che serve per una prova al
volo; poi il file di configurazione, che e' la scelta che resta; poi il PATH,
che e' come si e' sempre comportata la dashboard e continua a comportarsi se
il file non c'e'.

File: ~/.config/quickshell/tools.json

    {
      "adb": "~/Android/Sdk/platform-tools/adb",
      "scrcpy": "",
      "smartctl": "/usr/sbin/smartctl"
    }

Un valore vuoto vuol dire "cercalo nel PATH come prima": e' l'assenza di una
scelta, non una scelta. `~` e le variabili si espandono. Un valore senza
barre e' un nome da cercare nel PATH, cosi' si puo' scrivere `adb-google`
senza doverne sapere il percorso.

Un percorso scritto qui e sbagliato non spegne niente: si ripiega sul PATH e
il motivo finisce in `trouble()`, che chi ha un posto dove dirlo — gli `hints`
di `phone_adb.py status` — riporta all'utente. Un tool che sparisce in
silenzio dopo che qualcuno ha scritto il suo percorso a mano sarebbe la
diagnosi peggiore di tutte: quella che non c'e'.
"""

import json
import os
import shutil

CONFIG = os.path.join(
    os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config"),
    "quickshell",
    "tools.json",
)

# Letto una volta per processo. Gli script della dashboard sono comandi brevi o
# monitor lunghi: nei primi non fa in tempo a cambiare, nei secondi un riavvio
# del monitor e' comunque necessario perche' il nuovo binario venga usato.
_wanted = None
_trouble = []


def _config():
    """La mappa nome → percorso scritta dall'utente, o vuota."""
    global _wanted

    if _wanted is not None:
        return _wanted

    _wanted = {}

    try:
        with open(CONFIG, encoding="utf-8") as fh:
            data = json.load(fh)
    except FileNotFoundError:
        return _wanted
    except (OSError, ValueError) as e:
        _trouble.append("%s illeggibile: %s" % (CONFIG, e))
        return _wanted

    if not isinstance(data, dict):
        _trouble.append("%s: serve un oggetto nome → percorso" % CONFIG)
        return _wanted

    for name, value in data.items():
        if isinstance(value, str) and value.strip():
            _wanted[name] = value.strip()

    return _wanted


def _resolve(value):
    """Un percorso scritto a mano, ridotto a un eseguibile che esiste davvero."""
    path = os.path.expanduser(os.path.expandvars(value))

    # Senza barre e' un nome, non un percorso: cercarlo nel PATH e' proprio
    # quello che si vuole quando si scrive "adb-google".
    if os.sep not in path:
        return shutil.which(path)

    return path if os.access(path, os.X_OK) and os.path.isfile(path) else None


def which(name, env=True):
    """Il programma `name`, o None. Sostituisce `shutil.which` senza sorprese.

    `env` si spegne per i tool che nessuno vorrebbe mai puntare da fuori: la
    variabile d'ambiente e' comoda per provare un binario diverso, ma un
    processo figlio che eredita `DASHBOARD_DNF` non e' una cosa che si vuole
    scoprire per caso.
    """
    if env:
        chosen = os.environ.get("DASHBOARD_" + name.upper().replace("-", "_"))

        if chosen:
            found = _resolve(chosen)

            if found:
                return found

            _trouble.append("DASHBOARD_%s: «%s» non e' eseguibile" % (
                name.upper().replace("-", "_"), chosen,
            ))

    wanted = _config().get(name)

    if wanted:
        found = _resolve(wanted)

        if found:
            return found

        _trouble.append("tools.json, %s: «%s» non e' eseguibile" % (name, wanted))

    return shutil.which(name)


def trouble():
    """Cosa non ha funzionato di quello che l'utente ha scritto a mano.

    Si chiama dopo le `which`, non prima: e' il tentativo di risolvere un nome
    a scoprire che il percorso non va, e finche' nessuno chiede quel tool non
    c'e' niente da dire.
    """
    return list(_trouble)
