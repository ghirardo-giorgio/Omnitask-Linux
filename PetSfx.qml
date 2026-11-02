pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// I quattro suoni della stanza del pet: il preavviso di un bonus, quello di un
// malus, il tonfo a terra e la raccolta.
//
// I file li genera `scripts/make_sfx.py` in `sfx/` — onde quadre a 22 kHz,
// qualche kilobyte l'una — invece di arrivare da un pacchetto scaricato: cosi'
// non c'e' una licenza da portare dietro e suonano come il pet e' disegnato.
//
// 🔴 `pw-play` e non `SoundEffect` (Qt Multimedia): il backend FFmpeg di
// Qt Multimedia 6.11 ha QTBUG-143167 — a ogni suono il thread audio tocca un
// QSocketNotifier dal thread sbagliato e Qt entra in un flood infinito di
// warning (`Invalid socket ... disabling...`) che ha scritto 6 GB di log in
// tmpfs (RAM) in 18 minuti, fino a swappare e congelare il desktop. Fino a
// Qt 6.12 niente Qt Multimedia nella shell: i WAV partono da pw-play, che
// parla diretto con PipeWire e non carica il backend incriminato.
//
// Le sorgenti passano da PluginPaths e non da Qt.resolvedUrl(): dentro
// Quickshell i documenti si risolvono su uno schema suo (`qs:@/…`) che il
// player non sa aprire. Stessa ragione, e stessa soluzione, del font in
// PetStyle.qml.
Singleton {
    id: root

    // L'interruttore, che sta nei panelParams come tutto il resto del pannello:
    // e' una preferenza della stanza — vale per tutti gli oggetti che cadono —
    // e sopravvive al riavvio della shell.
    readonly property bool enabled: Settings.panelParam("pet", "sound", true) === true

    // A meta' corsa di proposito: questi suoni arrivano non richiesti mentre si
    // sta facendo altro, e un effetto d'interfaccia a volume pieno e' il modo
    // piu' veloce per farsi spegnere del tutto.
    readonly property real volume: {
        const v = Settings.panelParam("pet", "soundVolume", 0.5);
        return typeof v === "number" && isFinite(v) ? Math.max(0, Math.min(1, v)) : 0.5;
    }

    // Un suono e un processo: pw-play non si riavvia mentre suona, quindi ogni
    // voce ha il suo Process dedicato e `play()` lo fa ripartire — un suono
    // interrotto al secondo colpo, non un processo che si accavalla.
    //
    // Il volume passa sulla riga di comando (`--volume` 0-1) invece che dentro
    // il comando: cosi' cambiare la preferenza non tocca il codice, e i Process
    // restano dichiarativi con la command list ricostruita dal binding.
    function play(name: string) {
        if (!root.enabled)
            return;

        switch (name) {
        case "warnBonus":
            warnBonus.running = false;
            warnBonus.command = sfxCommand("sfx/warn_bonus.wav", root.volume);
            warnBonus.running = true;
            break;
        case "warnMalus":
            warnMalus.running = false;
            warnMalus.command = sfxCommand("sfx/warn_malus.wav", root.volume);
            warnMalus.running = true;
            break;
        case "land":
            // Il tonfo sta sotto gli altri: e' il piu' frequente dei quattro —
            // uno per ogni oggetto, raccolto o no — e alla pari degli altri
            // diventa il suono che si sente di piu' pur essendo quello che
            // dice meno.
            land.running = false;
            land.command = sfxCommand("sfx/land.wav", root.volume * 0.7);
            land.running = true;
            break;
        case "catch":
            catchSfx.running = false;
            catchSfx.command = sfxCommand("sfx/catch.wav", root.volume);
            catchSfx.running = true;
            break;
        }
    }

    function sfxCommand(relPath: string, vol: real): var {
        return [
            "pw-play",
            "--volume",
            String(Math.max(0, Math.min(1, vol))),
            "file://" + PluginPaths.of(relPath)
        ];
    }

    Process {
        id: warnBonus
    }

    Process {
        id: warnMalus
    }

    Process {
        id: land
    }

    Process {
        id: catchSfx
    }
}
