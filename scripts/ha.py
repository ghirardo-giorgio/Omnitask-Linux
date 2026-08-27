#!/usr/bin/env python3
"""Le due funzioni con cui uno script parla a Home Assistant.

Stanno qui e non dentro chi le usa perche' gli strumenti che pubblicano un
sensore sono ormai due — il tester solare (solar_meter.py) e l'igrometro
(hygrometer.py) — e la seconda copia di un pezzo di codice e' quella che poi
resta indietro.

Solo libreria standard, e non e' un gusto: hygrometer.py gira sotto
l'interprete del venv dell'Igrometro, che ha OpenCV e numpy e nient'altro.
"""
import json
import os
import urllib.request

# Lo stesso file che legge HomeAssistant.qml. Non una copia della
# configurazione: proprio quel file. Un token in due posti e' un token che
# prima o poi ne vale mezzo.
HA_CONFIG = os.path.expanduser("~/.config/quickshell/home-assistant.json")


def ha_config():
    """Url e token, dallo stesso file che legge HomeAssistant.qml."""
    try:
        with open(HA_CONFIG) as handle:
            data = json.load(handle)
    except (OSError, ValueError) as exc:
        raise SystemExit(f"configurazione di Home Assistant illeggibile ({HA_CONFIG}): {exc}")

    if not data.get("url") or not data.get("token"):
        raise SystemExit(f"url o token mancanti in {HA_CONFIG}")

    return data["url"].rstrip("/"), data["token"]


def ha_call(path, payload=None, timeout=15):
    """Una chiamata alle API di Home Assistant, GET o POST secondo il payload."""
    url, token = ha_config()
    body = json.dumps(payload).encode() if payload is not None else None

    request = urllib.request.Request(
        url + path,
        data=body,
        headers={
            "Authorization": "Bearer " + token,
            "Content-Type": "application/json",
        },
        method="POST" if payload is not None else "GET",
    )

    with urllib.request.urlopen(request, timeout=timeout) as answer:
        return json.load(answer)
