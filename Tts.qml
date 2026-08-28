pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// La voce della dashboard: legge ad alta voce la risposta di Hermes.
//
// Il motore e' Audio8 TTS 0.1B in ONNX INT8, che gira in un venv suo e si
// pilota via HTTP — tutto il giro sta in scripts/tts.py, qui c'e' solo chi lo
// chiama e in che stato e'. Sta in un singleton, e non nel pannello Comando
// IA dov'e' nata la risposta, perche' l'interruttore si vede da due posti (il
// pannello e la finestra della chat) e uno stato duplicato in due viste
// diverge al primo clic.
//
// Acceso o spento e' una scelta che deve sopravvivere al riavvio: sta nei
// parametri del pannello, sezione "tts" di dashboard.json.
Singleton {
    id: root

    readonly property var defs: ({
            enabled: false,
            voice: "default",
            // 0 = il volume del canale, quello che l'utente ha gia' scelto
            // nel mixer; un numero fra 1 e 100 lo forza.
            volume: 0,
            port: 8024,
            // Oltre questo, una risposta non e' piu' da ascoltare: il modello
            // ci mette piu' o meno il doppio del tempo che dura l'audio, e
            // mezza pagina letta ad alta voce sono minuti di CPU.
            maxChars: 700,
            // Fotogrammi generabili per pezzo (~21.5 al secondo): e' il tetto
            // che tiene una frase che non finisce piu' dentro una durata
            // ragionevole.
            maxTokens: 320,
            // Minuti d'inattivita' dopo i quali il motore si spegne: tenerlo
            // acceso costa piu' di due giga di residente, e chi parla con
            // Hermes lo fa a raffiche, non di continuo. 0 = non spegnerlo.
            idleMinutes: 20
        })

    readonly property bool enabled: Settings.panelParam("tts", "enabled", defs.enabled)
    readonly property string voice: Settings.panelParam("tts", "voice", defs.voice)
    readonly property int volume: Settings.panelParam("tts", "volume", defs.volume)
    readonly property int port: Settings.panelParam("tts", "port", defs.port)
    readonly property int maxChars: Settings.panelParam("tts", "maxChars", defs.maxChars)
    readonly property int maxTokens: Settings.panelParam("tts", "maxTokens", defs.maxTokens)
    readonly property int idleMinutes: Settings.panelParam("tts", "idleMinutes", defs.idleMinutes)

    Component.onCompleted: Settings.declarePanelParams("tts", root.defs)

    // idle | avvio | sintesi | parla | error
    property string phase: "idle"
    property string message: ""

    readonly property bool speaking: ["avvio", "sintesi", "parla"].includes(root.phase)

    // La frase che aspetta il suo turno. Serve per un caso solo: una risposta
    // nuova mentre la precedente sta ancora parlando. Non si puo' riavviare il
    // processo nello stesso istante in cui lo si uccide — muore in modo
    // asincrono — quindi la frase resta qui e parte quando il posto e' libero.
    property string pending: ""

    readonly property string scriptPath: PluginPaths.of("scripts/tts.py")

    // L'interruttore. Spegnere zittisce anche quello che sta dicendo adesso:
    // chi lo preme mentre la voce parla vuole silenzio, non "da domani".
    function toggle() {
        const next = !root.enabled;

        Settings.setPanelParam("tts", "enabled", next);

        if (!next)
            root.stop();
    }

    // Quello che chiama chi ha una risposta da far sentire: se la voce e'
    // spenta non succede niente, ed e' giusto che a deciderlo sia qui e non
    // ogni chiamante.
    function say(text: string) {
        if (!root.enabled)
            return;

        root.speakNow(text);
    }

    // Legge comunque, interruttore o no: e' il "rileggi" di un messaggio.
    function speakNow(text: string) {
        if (!text || !text.trim().length)
            return;

        root.pending = text;

        if (speakProc.running) {
            // muore, e onExited fa partire quella in attesa
            speakProc.running = false;
            return;
        }

        root.launch();
    }

    function launch() {
        const text = root.pending;

        root.pending = "";

        if (!text.length)
            return;

        root.phase = "avvio";
        root.message = "";
        speakProc.command = ["python3", root.scriptPath, "--port", String(root.port), "speak", text, "--voice", root.voice, "--max-chars", String(root.maxChars), "--max-new-tokens", String(root.maxTokens)].concat(root.volume > 0 ? ["--volume", String(root.volume)] : []);
        speakProc.running = true;
        idleTimer.stop();
    }

    function stop() {
        root.pending = "";

        if (speakProc.running) {
            // Il segnale arriva a scripts/tts.py, che annulla la sintesi e
            // chiude il riproduttore: il buffer gia' in pancia non va suonato.
            speakProc.running = false;
        } else {
            // Nessun processo nostro, ma il motore puo' star generando per
            // conto di una shell ricaricata: si bussa lo stesso.
            stopProc.command = ["python3", root.scriptPath, "--port", String(root.port), "stop"];
            stopProc.running = true;
        }

        root.phase = "idle";
        root.message = "";
    }

    Process {
        id: speakProc

        stdout: SplitParser {
            onRead: line => {
                if (!line.trim().length)
                    return;

                let data;

                try {
                    data = JSON.parse(line);
                } catch (e) {
                    return;
                }

                if (!data.ok) {
                    root.phase = "error";
                    root.message = data.error ?? I18n.t("la voce non ha funzionato");
                    return;
                }

                if (data.stato) {
                    root.phase = data.stato;
                    return;
                }

                // l'ultima riga: la frase e' detta (o non c'era niente da dire)
                root.phase = "idle";
                root.message = "";
            }
        }

        onExited: {
            // L'uccisione non lascia nessuna riga: lo stato lo si chiude qui,
            // tranne quando c'e' un errore da leggere.
            if (root.pending.length) {
                root.launch();
                return;
            }

            if (root.phase !== "error")
                root.phase = "idle";

            if (root.idleMinutes > 0)
                idleTimer.restart();
        }
    }

    Process {
        id: stopProc
    }

    // Il motore resta acceso fra una frase e l'altra perche' caricarlo costa
    // una decina di secondi, ma tenerlo acceso costa due giga: dopo un po'
    // che nessuno parla si spegne, e la prima frase dopo paghera' l'attesa.
    Timer {
        id: idleTimer

        interval: Math.max(1, root.idleMinutes) * 60000
        onTriggered: {
            shutdownProc.command = ["python3", root.scriptPath, "--port", String(root.port), "shutdown"];
            shutdownProc.running = true;
        }
    }

    Process {
        id: shutdownProc
    }
}
