# CLAUDE.md

Le regole di questo progetto stanno in [AGENTS.md](AGENTS.md): leggilo prima di
modificare qualcosa. In breve, le due che costano di piu' se si ignorano:

- **`MemoryWindow.qml` non si semplifica** — ogni guardia e ogni timer copre un
  guasto misurato, e chi li toglie rompe la memoria delle finestre giorni dopo.
- **`HomeAssistant.historyEntities` non si scrive** da un pannello: si usa
  `watchHistory()` / `unwatchHistory()`.

E una nota di metodo: qui l'aspetto non si puo' verificare da soli (niente
screenshot, niente qmllint), quindi `qs -c dashboard log` dice se il QML compila
e il resto si chiede a chi ha lo schermo davanti.
