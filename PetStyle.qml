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

    readonly property var spacing: ({
            xs: 3,
            sm: 6,
            lg: 12
        })

    readonly property int cornerRadius: 4
}
