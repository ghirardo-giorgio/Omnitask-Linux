pragma Singleton

import QtQuick
import Quickshell

// Azioni che un pannello puo' chiedere alla shell: aprire una finestra, o
// togliere di mezzo la dashboard.
//
// Serve perche' i pannelli non sono piu' figli diretti di Dashboard.qml ma
// vengono caricati da un Loader: un segnale dichiarato dentro un pannello non
// avrebbe nessuno a cui arrivare. Passando di qui, chi emette e chi ascolta non
// devono conoscersi.
Singleton {
    id: root

    signal openServices
    signal openProcesses
    signal openHardware
    signal openNetwork
    signal openOptions
    // Quale telefono aprire: il nome di KDE Connect, che phone_adb.py sa
    // risolvere da solo in indirizzo o serial.
    signal openPhone(string device)
    // Lo stesso telefono, ma aprendo la finestra gia' in riassociazione: e'
    // dal pannello che ci si accorge che non risponde piu', ed e' li' che sta
    // il pulsante.
    signal repairPhone(string device)
    // Il comando IA la chiede prima di premere dei tasti: la finestra della
    // dashboard e' quella che li intercetterebbe.
    signal hideWindow
    // Il selettore di colore dei grafici. Passa di qui per la stessa ragione di
    // tutto il resto: un pannello sta dentro un Loader e non puo' disegnare
    // niente sopra la dashboard. `series` e' [{ id, label, fallback }].
    signal pickColor(var series, real x, real y)
}
