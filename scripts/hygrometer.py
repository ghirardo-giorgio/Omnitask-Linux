#!/usr/bin/env python3
"""L'igrometro analogico in Home Assistant, leggendone la lancetta.

Lo strumento e' un igrometro a molla: un quadrante, una lancetta rossa, niente
elettronica dentro e niente da collegare. L'unico modo di portarne fuori il
numero e' guardarlo, e a guardarlo c'e' gia' un programma —
~/Documents/Development/Python/Igrometer/main.py — che dalla webcam ricava
l'angolo della lancetta e lo trasforma in umidita' relativa, appoggiandosi a
una calibrazione fatta a mano: il rettangolo del quadrante, il centro, e i due
angoli che valgono 0% e 100%.

Quel programma pero' e' fatto per stare aperto: e' un ciclo con la sua finestra
OpenCV, l'anteprima dal vivo e i tasti per rimisurare. Qui serve il contrario —
una lettura sola, un numero, e via — quindi non lo si riscrive: lo si importa e
gli si chiede la misura che sa gia' fare. Cosi' la calibrazione resta una sola
per tutti e due, e il CSV dello strumento continua a riempirsi anche quando a
guardare l'igrometro e' il timer di systemd invece di una persona.

E' lo stesso mestiere di solar_meter.py, e ne segue la strada: un JSON su
stdout, il sensore creato al volo con /api/states, il timer che lo chiama ogni
dieci minuti.

Quale webcam guardare non e' scritto qui: lo sceglie il pannello e lo salva
nei panelParams della dashboard, che e' l'unico posto che vedono tutti e due —
il pannello quando si preme Leggi, e il timer di systemd, che nessuno avvia a
mano. Con --cameras si ottiene l'elenco di quelle attaccate, che e' quello che
il pannello mette nella tendina.

Va avviato con l'interprete del venv dell'Igrometro, l'unico che ha OpenCV:

    ~/Documents/Development/Python/Igrometer/.venv/bin/python hygrometer.py

Codici d'uscita, come per il tester solare:
  0  letto
  2  niente da leggere, ma e' un esito previsto: calibrazione mancante,
     lancetta non trovata, webcam occupata da un'altra finestra
  1  guasto vero: webcam assente, Home Assistant irraggiungibile
"""
import argparse
import contextlib
import datetime
import fcntl
import importlib.util
import json
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from ha import ha_call  # noqa: E402

IGROMETRO = os.path.expanduser("~/Documents/Development/Python/Igrometer")

ENTITY = "sensor.igrometro_umidita"

# Uscite: 0 letto, 2 niente da leggere ma va bene cosi', 1 guasto.
OK = 0
GUASTO = 1
NIENTE = 2

# La configurazione della dashboard: e' li' che il pannello scrive quale webcam
# guarda l'igrometro, e da li' la prende anche il timer di systemd, che il
# pannello non lo avvia lui.
CONFIG = os.path.expanduser("~/.config/quickshell/dashboard.json")

# VIDIOC_QUERYCAP, la domanda che si fa a un nodo /dev/videoN per sapere chi e'
# — il numero e' quello che uscirebbe da _IOR('V', 0, struct v4l2_capability).
# Serve perche' i nodi non sono le webcam: una sola telecamera ne accende due o
# tre (l'immagine, i metadati), e solo il primo si puo' aprire per guardarci
# dentro. Elencarli tutti vorrebbe dire offrire tre voci per una webcam sola,
# due delle quali non funzionano.
QUERYCAP = 0x80685600
QUERYCAP_FMT = "16s32s32sIII3I"
CAP_VIDEO_CAPTURE = 0x00000001
CAP_DEVICE_CAPS = 0x80000000


def descrivi(nodo):
    """Nome e mestiere di un nodo /dev/videoN, o None se non e' una webcam."""
    try:
        fd = os.open(nodo, os.O_RDONLY | os.O_NONBLOCK)
    except OSError:
        return None

    try:
        risposta = fcntl.ioctl(fd, QUERYCAP, b"\0" * struct.calcsize(QUERYCAP_FMT))
    except OSError:
        # Non parla v4l2, o non ci lascia chiedere: non e' roba da igrometro.
        return None
    finally:
        os.close(fd)

    campi = struct.unpack(QUERYCAP_FMT, risposta)
    scheda, capacita, del_nodo = campi[1], campi[4], campi[5]

    # device_caps dice cosa fa *questo* nodo, capabilities cosa fa l'apparecchio
    # intero: sui driver vecchi il primo non c'e', e allora vale il secondo.
    proprie = del_nodo if capacita & CAP_DEVICE_CAPS else capacita

    if not proprie & CAP_VIDEO_CAPTURE:
        return None

    return scheda.split(b"\0")[0].decode("utf-8", "replace").strip()


def elenca_webcam():
    """Le webcam attaccate, come le vede OpenCV: indice, nome, nodo.

    L'indice e' quello del nodo (/dev/video2 -> 2), che e' anche il numero che
    vuole cv2.VideoCapture: gli altri modi di contarle — la posizione
    nell'elenco, l'ordine di collegamento — cambiano quando se ne stacca una, e
    la scelta salvata punterebbe a un'altra telecamera.
    """
    trovate = []

    for nome in os.listdir("/dev"):
        if not nome.startswith("video") or not nome[5:].isdigit():
            continue

        nodo = "/dev/" + nome
        scheda = descrivi(nodo)

        if scheda is None:
            continue

        trovate.append({"indice": int(nome[5:]), "nome": scheda or nodo, "nodo": nodo})

    return sorted(trovate, key=lambda w: w["indice"])


def camera_scelta():
    """La webcam scelta dal pannello, o la prima per chi non ha mai scelto.

    Il numero sta nei panelParams della dashboard e non in un file di questo
    script: e' il pannello a farlo scegliere, e due posti dove scriverlo
    vorrebbero dire due posti che possono dire cose diverse.
    """
    try:
        with open(CONFIG, encoding="utf-8") as handle:
            scelta = json.load(handle)["panelParams"]["igrometro"]["camera"]
    except (OSError, ValueError, KeyError, TypeError):
        return 0

    try:
        return int(scelta)
    except (TypeError, ValueError):
        return 0


# Lo stdout vero, tenuto da parte prima di ogni dirottamento: mentre parla il
# programma dell'igrometro sys.stdout punta a stderr, e il JSON deve uscire
# comunque da dove lo aspetta chi ci ha chiamati.
STDOUT = sys.stdout


def emit(payload, code):
    json.dump(payload, STDOUT, ensure_ascii=False)
    STDOUT.write("\n")
    STDOUT.flush()
    sys.exit(code)


def load_tool(directory):
    """Importa main.py dell'Igrometro come modulo.

    Con importlib e non con `import main`: "main" e' un nome che prima o poi
    qualcun altro prende, e questo modulo ha da restare quello dell'igrometro.
    Importarlo non fa partire niente — il suo main() sta sotto
    `if __name__ == "__main__"`.
    """
    percorso = os.path.join(directory, "main.py")

    if not os.path.exists(percorso):
        emit({"ok": False, "error": f"non trovo il programma dell'igrometro in {percorso}"},
             GUASTO)

    spec = importlib.util.spec_from_file_location("igrometro", percorso)
    modulo = importlib.util.module_from_spec(spec)

    try:
        spec.loader.exec_module(modulo)
    except ImportError as exc:
        # Quasi sempre: avviato con l'interprete sbagliato, quello senza cv2.
        emit({"ok": False,
              "error": f"manca una libreria dell'igrometro ({exc}): "
                       f"serve l'interprete di {directory}/.venv"},
             GUASTO)

    return modulo


def open_camera(cv2, index):
    """La webcam, con le stesse impostazioni che usa il programma originale."""
    nodo = f"/dev/video{index}"

    if not os.path.exists(nodo):
        emit({"ok": False, "error": f"nessuna webcam su {nodo}"}, GUASTO)

    cap = cv2.VideoCapture(index)

    if not cap.isOpened():
        # Il nodo c'e' ma non si apre: la tiene qualcun altro. Succede ogni
        # volta che e' aperta la calibrazione, ed e' un'attesa, non un guasto —
        # per questo esce con 2 e systemd non dipinge il servizio di rosso.
        emit({"ok": False, "error": f"webcam {nodo} occupata da un altro programma"},
             NIENTE)

    cap.set(cv2.CAP_PROP_FRAME_WIDTH, 1280)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 720)
    # Buffer corto: si vuole l'immagine di adesso, non quella di prima.
    cap.set(cv2.CAP_PROP_BUFFERSIZE, 1)

    return cap


def inservibile(cv2, frame):
    """Perche' in questo fotogramma non c'e' niente da leggere, o None se c'e'.

    Prima si andava dritti a cercare la lancetta, e qualunque cosa andasse
    storta usciva come «lancetta non rilevata»: che manda a controllare
    l'inquadratura anche quando l'inquadratura non c'entra niente. Il 02/09/2026
    la webcam ha consegnato per tre ore fotogrammi bianchi *uniformi* — min 255,
    max 255, identici a posa 1 e guadagno 0, e uguali fuori da OpenCV con
    ffmpeg: non e' una scena, e' un buffer che il driver non ha mai riempito,
    perche' l'USB della C270 si stava resettando ogni pochi minuti
    («error -71» nel journal). Nessuna calibrazione rimedia a quello, e il
    messaggio deve mandare a guardare il cavo, non il quadrante.

    Le tre risposte, in ordine di quanto sono lontane dal quadrante: niente
    immagine, immagine piatta, immagine dove il quadrante non si distingue.
    """
    if frame is None:
        return "la webcam non consegna fotogrammi: guarda il collegamento"

    grigio = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
    minimo, massimo, media = int(grigio.min()), int(grigio.max()), float(grigio.mean())

    # Un'immagine vera ha sempre un po' di rumore: quattro livelli fra il punto
    # piu' scuro e il piu' chiaro non li fa nemmeno un muro bianco.
    if massimo - minimo < 4:
        return (f"la webcam consegna un fotogramma vuoto (tutto a {minimo}): "
                f"flusso USB interrotto, guarda il cavo o la porta")

    # Qui invece l'immagine c'e' ma il quadrante ci si perde dentro. Le soglie
    # sono larghe apposta: servono a distinguere «non si vede» da «non trovo la
    # lancetta», non a giudicare una fotografia.
    if media > 245:
        return "immagine bruciata dalla luce: sposta la lampada o la telecamera"

    if media < 20:
        return "troppo buio per vedere il quadrante"

    return None


def fuori_scala(angle, taratura):
    """La lancetta e' finita nella zona morta, fuori dall'arco della scala?

    Il programma dell'igrometro, quando l'angolo cade li' dentro, non dice «non
    so»: sceglie l'estremo piu' vicino e restituisce 0 o 100 (`angle_to_value`,
    main.py). E' la scelta giusta per un mezzo grado sotto lo zero, ma vale
    anche quando la lancetta e' stata letta male — la coda al posto della punta,
    un riflesso, il rosso di qualcos'altro — e allora quello 0 non e' una
    misura, e' un errore travestito. Successo il 28/08/2026 alle 09:10: angolo
    230,67°, cioe' un grado sotto lo zero, contro i 63,62° della lettura dieci
    minuti dopo — 167° in dieci minuti, che una lancetta non fa. E' finito nello
    storico di Home Assistant come 0,0% e ha schiacciato la scala del grafico
    per otto ore, mentre il pannello mostrava il 61%.

    Qui si rifa' lo stesso conto di `angle_to_value` per poterlo distinguere: un
    valore agli estremi *dentro* l'arco e' una misura vera e passa, uno che
    viene dalla zona morta no.
    """
    total = (taratura["angle_0"] - taratura["angle_100"]) % 360

    if total == 0:
        return False

    return (taratura["angle_0"] - angle) % 360 > total


def raggio_stimato(directory):
    """Vero se la calibrazione e' vecchia e il raggio se lo inventa il programma.

    main.py in quel caso lo ricava dalla ROI e tira avanti, che e' la scelta
    giusta per non fermarsi, ma resta una stima: chi guarda il pannello deve
    poterlo sapere e ricalibrare, invece di ereditare un'approssimazione per
    sempre senza saperlo.
    """
    try:
        with open(os.path.join(directory, "hygrometer_calibration.json"),
                  encoding="utf-8") as handle:
            return not json.load(handle).get("radius")
    except (OSError, ValueError):
        return False


def publish(value, angle, misura, stimato, dry_run):
    """Crea (o aggiorna) il sensore in Home Assistant.

    L'entita' nasce da /api/states e non da un'integrazione: il prezzo e' che
    un riavvio di Home Assistant se la dimentica finche' non arriva la lettura
    dopo — dieci minuti di buco al massimo.
    """
    attributi = {
        "friendly_name": "Igrometro",
        "unit_of_measurement": "%",
        "device_class": "humidity",
        "state_class": "measurement",
        "angolo": round(angle, 2),
        "campioni": misura["samples"],
        # La dispersione fra i campioni e' l'unico modo onesto di dire quanto
        # fidarsi: tre letture che cadono a due punti l'una dall'altra sono
        # una lancetta vista male, non una misura.
        "dispersione": round(misura["spread"], 1),
        "calibrazione": "raggio stimato" if stimato else "completa",
    }

    if dry_run:
        return False

    ha_call("/api/states/" + ENTITY, {
        "state": f"{value:.1f}",
        "attributes": attributi,
    })

    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--dir", default=IGROMETRO,
                        help="cartella del programma dell'igrometro")
    parser.add_argument("--camera", type=int, default=None,
                        help="indice della webcam (senza, quella scelta nel pannello)")
    parser.add_argument("--cameras", action="store_true",
                        help="elenca le webcam attaccate ed esci, senza guardare niente")
    parser.add_argument("--samples", type=int, default=3,
                        help="frame per misura, di cui si prende la mediana")
    parser.add_argument("--dry-run", action="store_true",
                        help="legge e stampa, senza scrivere ne' in Home Assistant ne' nel CSV")
    parser.add_argument("--no-log", action="store_true",
                        help="non aggiungere la riga al CSV dello strumento")
    args = parser.parse_args()

    # L'elenco delle webcam non ha bisogno ne' della calibrazione ne' di
    # OpenCV: e' la domanda che si fa *prima* di poter guardare, e deve
    # rispondere anche quando tutto il resto e' ancora da mettere a posto.
    if args.cameras:
        emit({"ok": True, "webcam": elenca_webcam()}, OK)

    camera = camera_scelta() if args.camera is None else args.camera

    directory = os.path.expanduser(args.dir)

    if not os.path.isdir(directory):
        emit({"ok": False, "error": f"cartella dell'igrometro inesistente: {directory}"},
             GUASTO)

    # Il programma dell'igrometro apre calibrazione e CSV per nome relativo:
    # la cartella giusta e' la sua, non quella di chi lo chiama.
    os.chdir(directory)

    stimato = raggio_stimato(directory)
    strumento = load_tool(directory)

    # Tutto quello che il programma stampa — "Calibrazione caricata", gli
    # errori di scrittura del log — finisce su stderr, dove il journal lo
    # raccoglie: su stdout ci va soltanto il JSON, che qualcuno legge.
    with contextlib.redirect_stdout(sys.stderr):
        if not strumento.load_calibration():
            emit({"ok": False,
                  "error": "calibrazione mancante o illeggibile: premi Calibra"},
                 NIENTE)

        taratura = strumento.calibration
        cap = open_camera(strumento.cv2, camera)

        # Un fotogramma di prova prima della misura: costa un frame e distingue
        # i guasti che con la lancetta non c'entrano.
        motivo = inservibile(strumento.cv2, strumento.grab_fresh_frame(cap))

        if motivo:
            cap.release()
            emit({"ok": False,
                  "quando": datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
                  "error": motivo},
                 NIENTE)

        try:
            misura = strumento.take_measurement(
                cap,
                tuple(taratura["roi"]),
                tuple(taratura["center"]),
                float(taratura["radius"]),
                taratura["angle_0"],
                taratura["angle_100"],
                max(1, args.samples),
            )
        finally:
            cap.release()

        istante = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")

        # Una prova non deve lasciare traccia: il CSV e' il diario dello
        # strumento, non il registro di chi lo stava provando.
        if not args.no_log and not args.dry_run:
            strumento.append_log(
                strumento.LOG_FILE,
                istante,
                None if misura is None else misura["value"],
                None if misura is None else misura["angle"],
                0 if misura is None else misura["samples"],
            )

    if misura is None:
        emit({"ok": False, "quando": istante,
              "error": "lancetta non rilevata: guarda l'inquadratura, o ricalibra"},
             NIENTE)

    value = float(misura["value"])
    angle = float(misura["angle"])

    # Fuori scala non e' una misura: e' l'esito previsto di una lancetta letta
    # male o davvero oltre il fondo, e va detto invece che pubblicato (uscita
    # 2, come «lancetta non rilevata» qui sopra).
    if fuori_scala(angle, taratura):
        emit({"ok": False, "quando": istante, "angolo": round(angle, 2),
              "error": "lancetta fuori scala: lettura scartata"},
             NIENTE)

    try:
        scritto = publish(value, angle, misura, stimato, args.dry_run)
    except SystemExit as exc:
        # ha_config() protesta cosi' quando url o token mancano: qui va
        # raccolto e detto in JSON, che e' l'unica lingua che il pannello legge.
        emit({"ok": False, "error": str(exc)}, GUASTO)
    except Exception as exc:
        emit({"ok": False, "error": f"Home Assistant non raggiungibile: {exc}"}, GUASTO)

    emit({"ok": True, "umidita": round(value, 1), "angolo": round(angle, 2),
          "campioni": misura["samples"], "dispersione": round(misura["spread"], 1),
          "quando": istante, "entita": ENTITY, "inviato": scritto,
          "raggio": "stimato" if stimato else "calibrato"}, OK)


if __name__ == "__main__":
    main()
