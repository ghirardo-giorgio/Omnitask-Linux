pragma Singleton

import QtQuick
import QtMultimedia
import Quickshell

// I quattro suoni della stanza del pet: il preavviso di un bonus, quello di un
// malus, il tonfo a terra e la raccolta.
//
// I file li genera `scripts/make_sfx.py` in `sfx/` — onde quadre a 22 kHz,
// qualche kilobyte l'una — invece di arrivare da un pacchetto scaricato: cosi'
// non c'e' una licenza da portare dietro e suonano come il pet e' disegnato.
//
// 🔴 `SoundEffect` e non `MediaPlayer`: tiene il campione decodificato in
// memoria e lo fa partire senza latenza, che e' l'unica cosa che conta per un
// suono legato a un fotogramma — un MediaPlayer riapre la sorgente a ogni
// play() e il tonfo arriverebbe dopo il rimbalzo. In cambio vuole WAV PCM, ed
// e' il motivo per cui lo script genera WAV e non Ogg.
//
// ⚠️ Le sorgenti passano da PluginPaths e non da Qt.resolvedUrl(): dentro
// Quickshell i documenti si risolvono su uno schema suo (`qs:@/…`) che il
// decoder audio non sa aprire. Stessa ragione, e stessa soluzione, del font in
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

    // ---- Le voci -----------------------------------------------------------
    //
    // Una per suono e caricate all'avvio, non una sola con la sorgente che
    // cambia: cambiare `source` rimette lo stato a Loading, e un suono chiesto
    // durante quel caricamento non parte affatto.
    function play(name: string) {
        if (!root.enabled)
            return;

        switch (name) {
        case "warnBonus":
            warnBonus.play();
            break;
        case "warnMalus":
            warnMalus.play();
            break;
        case "land":
            land.play();
            break;
        case "catch":
            catchSfx.play();
            break;
        }
    }

    SoundEffect {
        id: warnBonus

        source: "file://" + PluginPaths.of("sfx/warn_bonus.wav")
        volume: root.volume
    }

    SoundEffect {
        id: warnMalus

        source: "file://" + PluginPaths.of("sfx/warn_malus.wav")
        volume: root.volume
    }

    SoundEffect {
        id: land

        source: "file://" + PluginPaths.of("sfx/land.wav")
        // Il tonfo sta sotto gli altri: e' il piu' frequente dei quattro — uno
        // per ogni oggetto, raccolto o no — e alla pari degli altri diventa il
        // suono che si sente di piu' pur essendo quello che dice meno.
        volume: root.volume * 0.7
    }

    SoundEffect {
        id: catchSfx

        source: "file://" + PluginPaths.of("sfx/catch.wav")
        volume: root.volume
    }
}
