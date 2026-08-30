pragma Singleton

import QtQuick
import Quickshell

// I colori che il pannello del pet chiede al tema.
//
// Bitmochi e' scritto per la shell di Omarchy, dove un singleton `Color` porta
// i colori del tema scelto dall'utente; qui quel tema non c'e' e i colori sono
// quelli che usano tutti gli altri pannelli (vedi panels/HeartPanel.qml). Il
// nome e' `PetColor` e non `Color` di proposito: la radice e' lo stesso spazio
// di nomi in cui l'utente mette i suoi pannelli, e piantarci dentro una parola
// come «Color» vuol dire prendersela per sempre.
//
// Vanno dichiarati `color` e non `string`: pet/PetRoom.qml legge `.r/.g/.b`
// per calcolare l'alpha delle barre, e una stringa quei campi non li ha.
Singleton {
    id: palette

    // Il testo, e le due tinte che dicono «va bene» e «non va».
    readonly property color foreground: "#c9d1d9"
    readonly property color urgent: "#f85149"

    // L'accento passa da Settings come ogni altra serie della dashboard: cosi'
    // il pet entra nel selettore dei colori invece di essere l'unica cosa che
    // non si puo' cambiare.
    readonly property color accent: Settings.colorFor("pet", "#58a6ff")

    // Il cartellino della cerimonia e i pulsanti: gli stessi grigi dei
    // riquadri del resto della dashboard.
    readonly property color surface: "#161b22"
    readonly property color surfaceHover: "#21262d"
    readonly property color border: "#30363d"

    // Un bordo e un testo che dicono «spento» senza sparire: mentre la carta
    // commemorativa e' a schermo i quattro pulsanti restano al loro posto, e
    // devono sembrare inerti, non assenti.
    readonly property color borderMuted: "#21262d"
    readonly property color disabled: "#484f58"
}
