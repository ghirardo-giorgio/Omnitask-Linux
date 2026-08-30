# Da dove viene questo codice

Bitmochi, di Ghaith Alsirawan — <https://github.com/Gsirawan/Bitmochi>, MIT
(vedi `LICENSE` qui accanto). Portato dal commit
`36d0e42f9e8a1cc2de00ac954a8a04f774d5ac92` il 2026-08-29.

Nato come plugin per la shell di **Omarchy** (`omarchy plugin add …`). Questa
macchina gira GNOME e Omarchy non c'e': il plugin non e' installato, e' portato
dentro come pannello della dashboard (`panels/PetPanel.qml`).

## Cosa e' arrivato, e in che stato

| qui | dall'originale | stato |
|---|---|---|
| `Pet.js` | `Pet.js` | **verbatim** — `diff` vuoto |
| `Sprites.js` | `Sprites.js` | **verbatim** — `diff` vuoto |
| `assets/` | `assets/` | **verbatim** — 96 PNG, `diff -r` vuoto |
| `PetRoom.qml` | `Room.qml` | **otto** modifiche, elencate sotto |
| `../panels/PetPanel.qml` | `Panel.qml` | **riscritto**: quello era la finestra flottante di Omarchy, che qui e' la colonna della dashboard. Solo la parte di stato e' portata, ed e' segnalata riga per riga |
| — | `BarWidget.qml` | **non portato**: e' l'icona nella barra, e questa dashboard su GNOME una barra non ce l'ha |
| — | `tools/`, `tests/`, `docs/` | non servono a chi non ritaglia gli sprite |
| `qmldir` | — | **nuovo**: senza, `import "../pet"` da `panels/` non trova niente e PetRoom resta «is not a type» — vedi sotto |

`Pet.js` e `Sprites.js` sono verbatim per scelta, non per pigrizia: il primo e'
la simulazione intera (JavaScript puro, `.pragma library`, nessuna dipendenza da
Qt — si incolla in `node` e gira), il secondo e' la mappa dei fotogrammi. Sono
le due cose che a monte cambiano piu' spesso, e tenerle intatte vuol dire che
un aggiornamento futuro e' una copia.

## Le otto modifiche a `PetRoom.qml`

Quest'elenco e' il motivo per cui questo file esiste: senza, il giorno che a
monte esce una versione nuova nessuno sa piu' cosa rimettere a mano.

1. **Gli import.** `import qs.Commons` e `import qs.Ui` — i moduli della shell
   di Omarchy — diventano `import ".."`, la riga che ogni file di questa
   dashboard deve avere per vedere i singleton della radice (lo verifica
   `scripts/panels.py`). `pragma ComponentBehavior: Bound`, `QtQuick` e
   `QtQuick.Effects` restano dov'erano.

2. **`Color.` → `PetColor.`, `Style.` → `PetStyle.`** — rinomina meccanica, 22
   e 26 righe. In Omarchy quei due singleton portano il tema scelto
   dall'utente; qui li scrivono `../PetColor.qml` e `../PetStyle.qml` sulla
   palette del resto della dashboard. Il nome ha il prefisso perche' la radice
   e' lo stesso spazio di nomi in cui l'utente mette i suoi pannelli, e
   `Color` e' una parola troppo comune per prendersela.

3. **`component Button`**, in fondo al file accanto a `component StatBar`. Il
   `Button` veniva da `qs.Ui`; questo ha la stessa forma delle altre etichette
   cliccabili della dashboard (`Choice` in `panels/HeartPanel.qml`).

4. **Le stringhe passano da `I18n.t()`.** L'italiano e' la chiave, le altre
   cinque lingue stanno in `lang/*.json` — e' la regola di casa, vedi
   `AGENTS.md`. Aggiunta anche `ageText()`, che chiama `Pet.formatAge()` e
   traduce il solo valore che e' una frase invece di una misura
   (`"under a minute"`): il conto resta dov'era, nel JS.

5. **La carta commemorativa**, arrivata qui da `Panel.qml` (righe 695-790
   dell'originale) insieme al `signal memorialDismissed()`. E' disegno, questo
   file conosce gia' `memorialPending`, e tenendola qui la lapide si risolve
   con la stessa `Qt.resolvedUrl()` di tutti gli altri sprite — da `panels/`
   avrebbe cercato in `panels/assets/`, che non esiste.

6. **Le caratteristiche dai sensori.** Tre proprieta' nuove sul root —
   `extraStats`, `particleTraits` e `particleMax` — due `Repeater`
   dentro `statsGrid` che riusa il `component StatBar` gia' li', e uno di
   `PetMolecules` dentro `roomArea`, dietro al pet — uno per caratteristica
   che chiede le molecole, perche' due nuvole diverse convivono benissimo.

   `StatBar` ha guadagnato due campi: `readout`, che sostituisce il numero
   quando la barra viene da un sensore (li' la percentuale e' il benessere
   calcolato, e cio' che serve leggere e' «1120 ppm»), e `unknown`, per il
   sensore che non risponde — che non e' zero, e una barra vuota lo dice mentre
   una barra a zero direbbe «sta malissimo».

   Questo file continua a non decidere niente: `PetTraits` calcola,
   `panels/PetPanel.qml` passa, qui si disegna. `PetMolecules.qml` sta nella
   radice e non qui, perche' e' roba nostra.

   Sulla geometria non serve altro: `chromeHeight` somma gia'
   `statsGrid.implicitHeight`, quindi la griglia che cresce restringe la stanza
   da se' e `spriteScale` si rifa'. E' il progetto dell'autore che regge — ed
   e' anche il motivo per cui dopo una modifica qui si guarda il log: quelle
   catene sono tenute aperte apposta per non chiudersi in un ciclo di binding.

7. **Il pavimento e' un grafico, e c'e' un fondale.** Tre proprieta' nuove —
   `terrainValues`, `terrainRise`, `background` — piu' la funzione
   `groundY(fracX)`, che e' il cuore della modifica: dice a che altezza sta il
   suolo sotto una certa frazione della larghezza. Col terreno spento torna
   `baseboard.y` e la stanza e' identica a prima.

   Le tre righe che citavano `baseboard.y` per appoggiarci qualcosa — il pet e
   lo sporco — adesso chiamano `groundY()`. Il resto di quelle espressioni,
   compresi i `Math.max` e il `breathLift` dentro e non fuori, e' intatto: le
   ragioni scritte li' valgono ancora tutte.

   Il battiscopa si nasconde quando il terreno e' acceso, perche' due linee di
   pavimento una sotto l'altra sono una di troppo.

   Il fondale e' un `Image` dichiarato ALLA RADICE, prima di `mainColumn`:
   copre tutto il pannello — intestazione, stanza, barre e pulsanti — e in QML
   l'ordine di dichiarazione e' l'ordine di disegno, quindi tutto il resto,
   terreno compreso, gli finisce sopra. Si adatta da solo: piu' piccolo del
   pannello viene ingrandito di un numero INTERO con `smooth: false` (le regole
   degli sprite, per lo stesso motivo), piu' grande viene rimpicciolito col
   filtro morbido — che e' l'opposto, e va bene, perche' e' l'opposto anche il
   problema. Sopra c'e' un velo regolabile, o il nome del pet su un'immagine
   mossa non si legge.

   Colore e trasparenza del rilievo sono proprieta' (`terrainColor`,
   `terrainOpacity`): sopra un fondale scelto dall'utente il grigio del tema
   puo' sparire, e allora si sceglie.

   Il disegno della curva sta in `../PetTerrain.qml`, che e' roba nostra.

8. **Gli oggetti che cadono.** Due proprieta' nuove sul root — `drops` e
   `dropSeconds` — due segnali (`dropCaught`, `dropExpired`) e un `PetDrops`
   dentro `roomArea`, fra lo sporco e il pet.

   E' l'altra meta' delle caratteristiche dai sensori (modifica 6): quelle
   spingono le statistiche di qualche punto all'ora e si leggono su una barra,
   questi cadono quando una soglia resta superata per qualche minuto e valgono
   una decina di punti in un colpo — ma solo se il pet ci passa sopra mentre
   girovaga, cosa che spesso non succede. Il fatto che spesso non succeda e' la
   meccanica, non un difetto.

   Vale la stessa divisione del lavoro: `PetTraits` tiene il catalogo,
   `panels/PetPanel.qml` decide quando cade e scrive le statistiche, qui si
   disegna e si riferisce. `PetDrops.qml` sta nella radice perche' e' roba
   nostra, come `PetMolecules.qml`.

   Sulla geometria non serve niente di nuovo: la misura e' `petH / 3` e il
   suolo lo da' `groundY()` della modifica 7, cioe' i due numeri che questo
   file gia' aveva.


## Il `qmldir`, che nell'originale non c'era

Non e' una scelta di stile, e' l'unico modo che funziona. Quickshell intercetta
gli URL dei `.qml` (schema `qs:@/qs/…`), e sotto quell'intercettazione un
`import "../pet"` scritto in `panels/PetPanel.qml` si carica senza errori e non
porta dentro niente: `PetRoom is not a type`, che e' l'unica cosa che si vede.
Con la cartella dichiarata come modulo — una riga, `PetRoom 1.0 PetRoom.qml` —
funziona. Provato, non dedotto: le due prove stanno nel log.

Da cui la regola per chi aggiunge un file a `pet/`: se serve da QML, va anche
scritto nel `qmldir`, o non esiste.

## Cosa non e' stato toccato, e perche'

I commenti inglesi. Non sono decorazione: raccontano guasti misurati
dall'autore — un adulto da 144 px in una stanza da 140 px, 145 `ReferenceError`
in tre minuti — e sono l'unica traccia del perche' quel codice e' scritto cosi'.
Valgono la stessa regola di `MemoryWindow.qml`: **non si semplificano**. In
particolare le due catene `width/height → stableChrome → spriteScale → unit →
roomArea` sono tenute aperte apposta per non chiudersi in un ciclo di binding, e
`chromeHeight` non deve mai leggere `roomArea.height`.

## Come si aggiorna

```sh
git clone https://github.com/Gsirawan/Bitmochi.git /tmp/bitmochi
diff -u /tmp/bitmochi/Room.qml pet/PetRoom.qml   # cosa e' nostro
cp /tmp/bitmochi/Pet.js /tmp/bitmochi/Sprites.js pet/
cp -r /tmp/bitmochi/assets pet/
```

Poi le otto modifiche qui sopra su `Room.qml` nuovo, e `touch shell.qml` —
gli asset e i `.js` non fanno ricaricare la shell da soli.
