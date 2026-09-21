pragma Singleton

import QtQuick
import Quickshell

// Le misure che il pannello del pet chiede al tema: l'altra meta' di
// PetColor.qml, e per lo stesso motivo — in Omarchy le porta un singleton
// `Style`, qui le portiamo noi.
//
// I numeri non sono liberi. pet/PetRoom.qml calcola `stableChrome` sommando le
// righe di testo e i loro spazi per sapere quanto spazio resta al pet, e ne
// ricava una scala INTERA: cambiare `font.body` o `spacing.sm` sposta quel
// conto, e un pet che finisce a scala frazionaria non e' piu' pixel art, e'
// un'immagine ridimensionata male. Si cambiano guardando la stanza.
Singleton {
    id: style

    readonly property var font: ({
            // Vuoto vorrebbe dire nessun font: si passa quello
            // dell'applicazione, che e' quello che usano gli altri pannelli
            // (non dichiarano `font.family` affatto).
            family: Qt.application.font.family,
            body: 11
        })

    // ---- Il font da videogioco ---------------------------------------------
    //
    // Press Start 2P (OFL, in `fonts/` con la sua licenza): serve ai NUMERI
    // della riga di statistiche, non a tutto il pannello. Le frasi lunghe —
    // l'avviso di malattia, il conto alla schiusa, il cartellino
    // commemorativo — restano nel font della dashboard: a 8 px monospaziati
    // «Sta molto male — ha bisogno di cure adesso» e' gia' larga quanto la
    // colonna in italiano, e nelle altre cinque lingue di piu'.
    FontLoader {
        id: arcadeFont

        // PluginPaths risolve rispetto a QUESTO file e restituisce un percorso
        // di filesystem invece di un URL qs:@/ — la stessa ragione per cui gli
        // script Python partono da li'.
        source: "file://" + PluginPaths.of("fonts/PressStart2P-Regular.ttf")
    }

    // 🔴 PROPRIETA' LEGATE A `status`, e non due campi dentro `font` qui sopra:
    // quello e' un oggetto JS valutato una volta sola, mentre il caricamento di
    // un font e' ASINCRONO. Messe li' dentro, resterebbero per sempre sul
    // valore che avevano prima che il font fosse pronto — cioe' sul fallback,
    // in silenzio.
    readonly property string arcadeFamily: arcadeFont.status === FontLoader.Ready
                                           ? arcadeFont.name
                                           : style.font.family

    // 8 e' la griglia nativa di Press Start 2P: a quella misura il font e'
    // nitido come lo sono i pixel del pet, e ogni altro valore che non sia un
    // multiplo lo sfoca. Ma 8 px del font di sistema sarebbe illeggibile,
    // quindi il fallback torna alla misura del corpo.
    readonly property int arcadeBody: arcadeFont.status === FontLoader.Ready ? 8 : style.font.body

    readonly property var spacing: ({
            xs: 3,
            sm: 6,
            lg: 12
        })

    readonly property int cornerRadius: 4
}
