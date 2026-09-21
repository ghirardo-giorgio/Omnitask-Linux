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
| `PetRoom.qml` | `Room.qml` | **dieci** modifiche, elencate sotto |
| `../panels/PetPanel.qml` | `Panel.qml` | **riscritto**: quello era la finestra flottante di Omarchy, che qui e' la colonna della dashboard. Solo la parte di stato e' portata, ed e' segnalata riga per riga |
| — | `BarWidget.qml` | **non portato**: e' l'icona nella barra, e questa dashboard su GNOME una barra non ce l'ha |
| — | `tools/`, `tests/`, `docs/` | non servono a chi non ritaglia gli sprite |
| `qmldir` | — | **nuovo**: senza, `import "../pet"` da `panels/` non trova niente e PetRoom resta «is not a type» — vedi sotto |

`Pet.js` e `Sprites.js` sono verbatim per scelta, non per pigrizia: il primo e'
la simulazione intera (JavaScript puro, `.pragma library`, nessuna dipendenza da
Qt — si incolla in `node` e gira), il secondo e' la mappa dei fotogrammi. Sono
le due cose che a monte cambiano piu' spesso, e tenerle intatte vuol dire che
un aggiornamento futuro e' una copia.

## Le dieci modifiche a `PetRoom.qml`

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

6. **Le caratteristiche dai sensori.** Due proprieta' nuove sul root —
   `particleTraits` e `particleMax` — e un `Repeater` di `PetMolecules` dentro
   `roomArea`, dietro al pet: uno per caratteristica che chiede le molecole,
   perche' due nuvole diverse convivono benissimo.

   ⚠️ Questa modifica era piu' grande: c'erano anche `extraStats` e un secondo
   `Repeater` che dava una barra a ogni caratteristica dentro la griglia delle
   statistiche, e `StatBar` aveva guadagnato `readout` e `unknown` per il
   valore vero e per il sensore che non risponde. La **modifica 9** ha portato
   via le barre tutte insieme, quelle del gioco e quelle dai sensori, quindi
   qui adesso restano le sole molecole. Il campo `bar` del catalogo e la sua
   spunta nelle opzioni ci sono ancora e non fanno niente — c'e' scritto in
   `PetTraits.qml`, accanto a `barTraits`.

   Questo file continua a non decidere niente: `PetTraits` calcola,
   `panels/PetPanel.qml` passa, qui si disegna. `PetMolecules.qml` sta nella
   radice e non qui, perche' e' roba nostra.

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

   La prospettiva e' la stessa modifica vista dall'altro lato: `terrainDepth`
   e la proprieta' derivata `depthScale` — quanto il pet e' lontano nel punto
   in cui sta, 1 nella valle e `1 - terrainDepth` sulla cima — piu' un secondo
   `Scale` nella lista `transform` di `petGrid`, con l'origine sui PIEDI
   invece che al centro come quello dello specchio. Il tetto e' 1: il pet non
   diventa mai piu' grande della misura che `spriteScale` gli ha dato, perche'
   quel numero e' un budget sull'altezza della stanza e scavalcarlo vuol dire
   il pet tagliato da `roomArea.clip`.

   Con questa c'e' `petTopY()`, che e' la cima VISIVA del pet: gli effetti
   fratelli di `petGrid` — il cuore e il segno del sonno — partivano da
   `petGrid.y`, che con la scala attorno ai piedi non e' piu' dove sta la
   testa. Col terreno spento o `terrainDepth: 0` vale `petGrid.y`, cioe' il
   numero di prima.

   ⚠️ Qui la nitidezza intera di `spriteScale` si paga per scelta: la scala
   della prospettiva e' frazionaria per definizione. Non e' in contraddizione
   con il resto del file — quello e' la misura di riposo del pet, questa e' il
   pet in cammino su una collina — ma chi porta su una versione nuova sappia
   che e' una deroga voluta, non una svista.

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

9. **Le statistiche sono una riga di icone in cima, e non ci sono piu' barre.**
   Il `component StatBar` — etichetta piu' rettangolo — e' sostituito da
   `component StatCell`, e la `Grid` a due colonne che stava SOTTO la stanza da
   una `Row` di quattro celle subito sotto l'intestazione. Ogni cella e'
   un'emoji e un numero: 🍗 fame, ⚡ energia, 😊 felicita', 🧼 pulizia.

   Le barre costavano quattro righe di chrome e le pagava la stanza, che e' la
   cosa che si guarda — dentro ci cammina il pet sul grafico della modifica 7.
   Con una riga sola il chrome cala di una ventina di pixel, e `heightScale`
   puo' rispondere con un passo di scala in piu': **il pet puo' venire piu'
   grande**, ed e' voluto.

   Le celle sono larghe un quarto della riga ognuna, non spaziate: il numero
   sta sempre nello stesso posto e la riga non balla quando una statistica
   passa da 98 a 100. E sono scritte a mano, non generate da un modello, per la
   stessa ragione per cui lo erano le barre.

   L'icona e il numero sono due `Text` distinti perche' hanno misure diverse:
   l'emoji resta a `PetStyle.font.body` (a 8 px non si riconosce, ed e' l'unica
   cosa che dice di quale statistica sia il numero, visto che le etichette non
   ci sono piu') e il numero va in **Press Start 2P a 8 px**, che e' il font
   arcade caricato da `../PetStyle.qml` — `fonts/` nella radice, OFL, roba
   nostra. La soglia d'allarme che era il colore della barra e' passata sul
   numero: sotto 20 diventa `PetColor.urgent`.

   ⚠️ Il font arcade sta sui NUMERI e non su tutto il pannello. A 8 px
   monospaziati «Sta molto male — ha bisogno di cure adesso» e' gia' larga
   quanto la colonna in italiano, e nelle altre cinque lingue di piu': gli
   avvisi, i pulsanti e il cartellino restano nel font della dashboard.

   Sulla geometria cambiano due nomi e nient'altro: `stableChrome` e
   `chromeHeight` sommavano `statsGrid.implicitHeight` e adesso sommano
   `statsRow.implicitHeight`. Le catene restano quelle, e restano aperte.

10. **Il cartellino di che cosa e' caduto, e l'interruttore dei suoni.** Tre
    proprieta' nuove sul root — `notice`, `noticeSeconds`, `soundOn` — un
    segnale (`soundToggled`), un `Rectangle` in cima a `roomArea` e un quinto
    pulsante nella riga delle cure.

    Il cartellino dice **perche'** e' arrivato un oggetto: «🔋 Solare carica
    +500 mAh». Senza, con cinque caratteristiche attive un oggetto che compare
    e' una sorpresa invece di un riscontro — e le caratteristiche a passo
    (modifica del catalogo, non di questo file) rendono la cosa frequente.
    Arriva gia' scritto dal pannello, come `drops`: questo file non conosce le
    caratteristiche e non deve conoscerle per disegnare una riga di testo.

    🔴 E' dichiarato per ULTIMO fra i figli della stanza: in QML l'ordine di
    dichiarazione e' l'ordine di disegno, e sotto ci finirebbe proprio nel
    momento in cui c'e' qualcosa da leggere.

    L'interruttore e' un'icona sola (🔊 / 🔇) e nessuna parola: sta in fondo a
    una riga che in tedesco e' gia' al limite della colonna. Non e' disabilitato
    durante la cerimonia, al contrario delle quattro cure: quelle agiscono sul
    pet, questo e' un interruttore dell'interfaccia, e chi si prende un suono a
    sorpresa deve poterlo spegnere anche li'.

    ⚠️ I suoni NON stanno in questo file. Il tonfo e la raccolta li fa
    `../PetDrops.qml` dove i due fatti succedono, il preavviso lo fa il
    pannello quando decide la caduta, e li riproduce `../PetSfx.qml` — tutta
    roba nostra. Qui c'e' solo il pulsante che dice al pannello di cambiare
    idea.


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

Poi le dieci modifiche qui sopra su `Room.qml` nuovo, e `touch shell.qml` —
gli asset e i `.js` non fanno ricaricare la shell da soli.
