# Regole di casa

Per chi lavora su questa dashboard: umano, o modello che gli e' stato messo
davanti. Sono poche e sono tutte costate un guasto.

## Cosa non si tocca

**`MemoryWindow.qml` non si semplifica.** Le guardie e i timer che sembrano
ridondanti sono l'unica cosa che tiene in piedi la memoria delle finestre, e chi
ne toglie uno non rompe niente subito: rompe la misura delle finestre qualche
giorno dopo, quando nessuno lega piu' le due cose. I vincoli di Qt su cui si
regge — provati, non dedotti — stanno scritti in cima al file:

1. `width` e `height` di una finestra **non sono scrivibili**;
2. `implicitWidth`/`implicitHeight` contano solo se **dichiarati**, e vengono
   letti quando la finestra viene mappata: assegnarli dopo non fa niente;
3. l'unico modo di far crescere una finestra gia' viva e' `minimumSize`.

Da cui la conseguenza che spiega l'ultimo blocco del file: se alla mappatura la
misura salvata non viene applicata — e su GNOME succede, quando il compositor
apre la finestra su uno schermo piu' piccolo di quello dove poi la sposta — da
QML non si rimedia piu'. Si rimedia chiedendolo al compositor
(`scripts/winplace.py`, estensione Window Calls). Prima di cambiare quel giro,
riprodurre il guasto: `winplace.py get Dashboard` da' il rettangolo del **bordo**,
`win.width`/`win.height` l'area cliente, e la differenza fra i due e' la
decorazione — si misura, non si indovina.

**`HomeAssistant.historyEntities` ha un padrone solo**: il `Binding` di
`panels/HaPanel.qml`. Un pannello che vuole lo storico di una sua entita' chiama
`HomeAssistant.watchHistory(id)` e la lascia andare con `unwatchHistory(id)`
(vedi `panels/IgrometroPanel.qml`). Scrivere quella proprieta' da un secondo
punto funziona finche' non si toccano le opzioni, poi smette — in silenzio.

## Come si scrive qui dentro

- **Pannelli**: stanno in `panels/` e cominciano con `import ".."`. Senza quella
  riga si caricano lo stesso, ma `Settings`, `I18n`, `HomeAssistant` e i
  componenti della dashboard restano `undefined`. `scripts/panels.py` lo
  verifica e lo dice.
- **Stringhe d'interfaccia**: italiano con gli accenti veri («è», «già»,
  «perché»), e ogni stringa nuova va tradotta in tutti e cinque i `lang/*.json`.
  L'italiano non e' un file: e' la chiave.
- **Commenti nel codice**: apostrofo ASCII (`e'`, `perche'`, `cosi'`), come tutto
  il resto del progetto. E dicono **perche'**, non cosa: il cosa si legge nella
  riga sotto.
- **Script**: un oggetto JSON per riga su stdout, e l'errore e' un campo, non una
  traccia Python. Chi pubblica una misura in Home Assistant esce con 0 se ha
  letto, **2** se non c'era niente da leggere (esito previsto: strumento
  occupato, buio, lancetta fuori campo) e 1 solo per un guasto vero — le unita'
  systemd dichiarano `SuccessExitStatus=2` apposta.
- **Segreti**: il token di Home Assistant sta in
  `~/.config/quickshell/home-assistant.json` e non entra mai nel QML.

## Come si verifica

La shell in esecuzione ricarica da sola al salvataggio di un `.qml`; i `.py` no,
per quelli serve `qs-dashboard restart`. Se una modifica non sembra avere
effetto: `touch shell.qml`.

`qs -c dashboard log` e' l'unico controllo disponibile — non ci sono `qmllint`,
`qmltestrunner` ne' PySide6, e GNOME nega la cattura dello schermo via D-Bus.
Quindi **l'aspetto non si verifica da soli**: si chiede a chi ha lo schermo
davanti, invece di dire che funziona.
