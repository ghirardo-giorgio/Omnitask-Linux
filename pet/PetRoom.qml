// Bitmochi — la stanza del pet. File di terzi, portato dentro la dashboard.
//
// Originale: Room.qml di https://github.com/Gsirawan/Bitmochi (MIT, vedi
// LICENSE qui accanto), scritto per la shell di Omarchy. I commenti inglesi
// qui sotto sono dell'autore e non si traducono: raccontano guasti misurati
// sul campo — un adulto da 144 px in una stanza da 140, 145 ReferenceError in
// tre minuti — e riscriverli cancellerebbe l'unica traccia del perche' il
// codice e' fatto cosi'. Valgono la stessa regola di MemoryWindow.qml: non si
// semplificano.
//
// Le modifiche di questo porting sono cinque, elencate una per una in
// UPSTREAM.md. In breve: gli import di Omarchy, la rinomina Color/Style in
// PetColor/PetStyle, il componente Button che prima veniva da qs.Ui, le
// stringhe passate da I18n e la carta commemorativa arrivata qui da Panel.qml.

// 🔴 Bound, not the default Unbound. Under Unbound, a Repeater hands its
// delegate `modelData`/`index` by injecting them into the delegate's QML
// CONTEXT, and a delegate whose root is a component defined in another file
// does not see that injection: every reference resolves to nothing and
// throws ReferenceError once per delegate per re-evaluation.
// That shipped once in this plugin — 145 ReferenceErrors in three minutes,
// a headline feature rendering absolutely nothing, and BOTH static checkers
// reporting clean the whole time. The feature that carried the bug has since
// been removed, but the rule it bought stays and is enforced here: Bound
// switches the whole file to the explicit contract, so every delegate must
// DECLARE what the model owes it as a `required property` and every outer id
// it touches is bound at compile time. It applies to every component in this
// file, which is why the one remaining Repeater below declares its own.
pragma ComponentBehavior: Bound
import QtQuick
// Used for exactly ONE thing now: the sleep mark's tint. It used to do two,
// the other being an urgent wash over an ill pet — a colour filter standing
// in for art that did not exist. Art for sick, sad, hungry, tired and angry
// exists now, so the filter is gone and the drawing is drawn instead. The
// sleep mark still needs it: that sprite is dark ink cut for white paper and
// is very nearly invisible on the dark card, so it is
// recoloured at render time rather than repainted in the asset.
// The module is part of qt6-declarative and Omarchy's own shell imports it
// in four files (its bar tray recolours every symbolic icon with the same
// `colorization` property this file uses), so it is present wherever the
// shell itself runs.
import QtQuick.Effects
import ".."
import "Pet.js" as Pet
import "Sprites.js" as Sprites

// Room.qml — the room itself: floor, the pet wandering it, waste, stat
// meters and the four care buttons. Everything here is display and
// input; Panel.qml owns the actual state (persistence, timers, the machine
// mood reading) and just hands this component a `pet` object to draw and
// listens for the two signals below.
//
// Note the property is named `pet`, not `state` — `state` is QtQuick Item's
// own built-in property (the States/Transitions framework) and shadowing it
// would be a real bug, not a style choice.
Item {
  id: root

  required property var pet          // the full simulated state (Pet.js shape)
  property real moodFactor: 1.0      // from the /proc machine-mood hook
  property bool memorialPending: false // a death ceremony is waiting to be shown
  // 🔴 Whether the panel this Room lives in is actually open/visible right
  // now. Panel.qml's KeyboardPanel stays instantiated (and this whole Room
  // tree alive) for as long as the shell runs, per BarWidget.qml's own
  // always-active Loader — so every Timer in here that only matters while
  // someone can actually see the room (wander, blink, the hatch countdown
  // tick) must be gated on this, not just on the pet's stage. Defaults to
  // true so an embedding that never binds it behaves as it always did.
  property bool panelOpen: true
  // 🔴 How long the illness window is, in ms — supplied by Panel.qml, which
  // owns the simulation. This file must NOT carry its own copy of a Pet.js
  // constant: two copies of the same number is how a presentation quietly
  // starts disagreeing with the model it is presenting. 0 means "nobody
  // supplied one" and is handled, not assumed away: see `sickFrac`.
  property real sickWindowMs: 0

  signal careRequested(string action) // "feed" | "play" | "clean" | "sleep"
  signal petRequested()
  // Aggiunto dal porting: la carta commemorativa stava in Panel.qml, che
  // qui non c'e'. Chi la congeda deve dirlo al pannello, che e' l'unico a
  // poter scrivere su pet.json.
  signal memorialDismissed()

  // Aggiunto dal porting (modifica 8): quello che cade dal cielo. Come per
  // `careRequested`, qui si riferisce e basta — chi decide che cosa fa un
  // peperoncino e chi lo scrive su pet.json e' il pannello.
  signal dropCaught(string key)
  signal dropExpired(string key)

  // Le caratteristiche da disegnare come molecole nell'aria, e il tetto di
  // ognuna. Arrivano dal pannello invece che lette da PetTraits qui dentro:
  // questo file disegna e basta, chi sceglie cosa mostrare sta fuori, come
  // per `pet`.
  //
  // Plurale, e non per completezza: era singolare e con due caratteristiche a
  // molecole accese la seconda non disegnava niente.
  property var particleTraits: []
  property int particleMax: 40

  // ---- Aggiunto dal porting (modifica 8): gli oggetti che cadono ---------
  //
  // Gli oggetti a terra adesso e quanto ci restano. Arrivano dal pannello gia'
  // risolti — glifo e segno, non la caratteristica che li ha fatti cadere —
  // per la stessa ragione di `particleTraits`: questo file non conosce il
  // catalogo, e non deve saperlo per disegnare una mela.
  property var drops: []
  property int dropSeconds: 6

  // ---- Aggiunto dal porting (modifica 10): il cartellino e i suoni --------
  //
  // Che cosa e' appena caduto e perche', gia' scritto: `{ glyph, text, kind }`
  // — «🔋 Solare carica +500 mAh». Arriva risolto dal pannello per la stessa
  // ragione di `drops`: questo file non conosce le caratteristiche, e non deve
  // conoscerle per disegnare una riga di testo. Nullo = nessun cartellino.
  property var notice: null

  // Quanto resta a schermo. Quattro secondi: meno non basta a leggere una riga
  // se si stava guardando altro, di piu' e' un'etichetta appiccicata sopra la
  // stanza mentre l'oggetto e' gia' a terra da un pezzo.
  property int noticeSeconds: 4

  // Se i suoni sono accesi. Lo stato non e' nostro — sta nei panelParams e lo
  // scrive il pannello — perche' questa e' la stanza, non le impostazioni: qui
  // si disegna un pulsante premuto o no.
  property bool soundOn: true
  signal soundToggled

  // ---- Aggiunto dal porting (modifica 7): il pavimento e' un grafico ------
  //
  // La serie su cui camminare — storico di Home Assistant o misura di sistema,
  // la sceglie il pannello — e il fondale. Vuoti tutti e due, la stanza e'
  // quella di prima: pavimento piatto e nessuno sfondo.
  property var terrainValues: []
  property real terrainRise: 0.4

  // ---- Aggiunto dal porting (modifica 7): la profondita' del rilievo ------
  //
  // Quanto il pet rimpicciolisce salendo sulla curva: 0 lo lascia della stessa
  // misura dappertutto — il comportamento di prima — e 0.25 vuol dire che in
  // cima al rilievo e' i tre quarti di quanto e' nella valle. E' l'unica cosa
  // che da' profondita' a una stanza disegnata di lato: la cima della collina
  // e' il fondo, e una cosa in fondo e' piu' piccola.
  //
  // 🔴 Il tetto e' 1, cioe' il pet non diventa mai piu' GRANDE della misura
  // che `spriteScale` gli ha dato. Quel numero e' un budget: e' calcolato
  // sull'altezza che resta alla stanza, e ingrandire oltre vorrebbe dire
  // scavalcarlo — con `roomArea.clip` a tagliare la testa del pet nella valle
  // dei pannelli bassi. Piu' vicino qui vuol dire «meno lontano», non «piu'
  // grande del normale».
  property real terrainDepth: 0.25
  // Il colore del rilievo e quanto lascia vedere. Vuoto = quello del tema, che
  // e' il grigio del testo: sopra un fondale scelto da chi usa la dashboard
  // puo' non andare bene, e allora si sceglie.
  property color terrainColor: PetColor.foreground
  property real terrainOpacity: 0.35
  property url background: ""
  property real backgroundDim: 0.35

  // La y del suolo sotto una certa frazione della larghezza. E' l'unica cosa
  // che il resto della stanza deve sapere del terreno: il pet, lo sporco e la
  // lapide ci si appoggiano sopra chiamando questa, e con il terreno spento
  // torna esattamente il battiscopa di prima.
  function groundY(fracX) {
    if (!terrainShape.active)
      return baseboard.y;
    return terrainShape.y + terrainShape.surfaceY(fracX);
  }

  // Quanto e' lontano il pet nel punto in cui si trova: 1 sul fondo della
  // valle, `1 - terrainDepth` in cima al rilievo. Col terreno spento e' 1
  // sempre, quindi la stanza torna esattamente quella di prima.
  //
  // 🔴 Sulla FORMA della curva (`heightAt`, che e' gia' normalizzata sulla
  // serie) e non sui pixel che il rilievo occupa davvero: se dipendesse anche
  // da `terrainRise`, abbassare il rilievo perche' ci stia il pet
  // spegnerebbe di riflesso la prospettiva. E' la stessa scelta che
  // PetTerrain fa per la curva — qui interessa la forma, la misura sta sulla
  // barra.
  //
  // ⚠️ L'uovo si misura a meta' stanza perche' e' li' che sta: il suo `y`
  // chiama `groundY(0.5)`, non `groundY(petFracX)`, e leggere due punti
  // diversi vorrebbe dire un uovo scalato per una collina su cui non poggia.
  //
  // ⚠️ Nessun `Behavior`: mentre il pet cammina questo insegue `petFracX`,
  // che e' gia' animato, e quando arriva un campione nuovo salta quanto salta
  // il suolo sotto i piedi — cioe' insieme a `groundY`, che e' l'unico modo
  // per cui i piedi restino sulla curva.
  readonly property real depthScale: {
    const d = Math.max(0, Math.min(1, root.terrainDepth));
    if (!terrainShape.active || d <= 0)
      return 1;
    const f = root.pet.stage === "egg" ? 0.5 : root.petFracX;
    return 1 - d * terrainShape.heightAt(f);
  }

  // 🔴 Both dimensions are supplied by the panel (which anchors this to fill
  // its body area), so no width/height binding here. implicitHeight is a
  // plain constant deliberately: deriving it from mainColumn would make the
  // root's implicit height depend on roomArea's height, which depends on the
  // root's height — a loop waiting for the first embedding that does not
  // anchor us.
  implicitWidth: 260
  implicitHeight: 320

  // 🔴 THE WIDTH AXIS — the first half of the room's one integer scale
  // (`spriteScale`, further down, is the number everything actually draws
  // at). Every sprite in here is a PNG cut at a fixed canvas size, and a
  // pixel-art PNG drawn at a fractional scale gets uneven pixel widths —
  // some source pixels two screen pixels wide, their neighbours one — which
  // reads as a badly resized image rather than as pixel art. Whole numbers
  // only, and the SAME whole number for every sprite, so the pet, its mess
  // and its heart stay in honest proportion to each other at every size.
  //
  // 170 is the divisor because the adult canvas is 64 px wide: at the
  // default 340 px panel (a ~310 px room) this lands on 2, i.e. a 128 px
  // adult, which is the size the previous renderer drew. The clamp at 4 is
  // what stops the widest panel from filling the room with one enormous pet.
  //
  // ⚠️ NOT named `scale`: Item.scale is a real QQuickItem property and
  // shadowing it here would silently transform every child of this root.
  readonly property int widthScale: Math.max(1, Math.min(4, Math.round(width / 170)))

  // 🔴 THE HEIGHT AXIS, and it is not optional. Width alone shipped a panel
  // 320 wide by 280 tall in which the adult came out 144 px tall inside a
  // 140 px room: pinned to the room's top edge, feet through the floor line,
  // its bottom rows cut off flush against the "Hunger / Energy" row, which
  // reads as the pet overlapping the stat bars. A panel is two numbers and
  // the user can drag either of them; the sprite has to answer to both.
  //
  // 🔴 DERIVED FROM RAW INPUTS ONLY — `root.height` and the chrome's own
  // implicit heights — and NEVER from `roomArea.height`. `roomArea.height`
  // subtracts `chromeHeight` from our height, `unit` is `spriteScale * 3`,
  // and the pet's size is `spriteScale` times a canvas: reading the room's
  // height back into the scale closes that ring into a binding loop, which
  // Qt reports as a WARNING and then quietly evaluates with a stale value.
  // A layout that is merely wrong is easier to catch than one that is wrong
  // only on the first frame, so this side of the ring stays open by
  // construction. The rows summed below are text and buttons at
  // `PetStyle.font.body`; not one of them reads `spriteScale`, so the chain
  // `width/height -> stableChrome -> spriteScale -> unit -> roomArea` is a
  // straight line.
  //
  // 0.8 of the leftover height, because the pet must not fill the room edge
  // to edge: below it sits the baseboard (16% of the room, capped at 30 px)
  // and above it the `petFracY` band it wanders through. Reserving a fifth
  // is what pays for both; measured over the whole 5-width x 8-height x
  // 11-state grid, the pet is never taller than the room and never touches
  // the skirting except in the 15 cells noted below. A larger fraction buys
  // one more scale step in a handful of panels and takes the floor away in
  // all of them.
  //
  // ⚠️ The `Math.max(1, ...)` is a FLOOR, not decoration — but how often it
  // actually fires depends on `stableChrome`, which is a sum of Qt text
  // metrics and cannot be measured anywhere but on a running shell.
  // Algebraically it is the same number as the ILL-state `chromeHeight`
  // further down, since it is that same set of rows. The floor bites only
  // once `stableChrome > height - tallestStageHeight / 0.8`, which in the
  // shortest panel the settings allow (240 px) means above about 150 px; at
  // or below that every cell earns its scale outright. Where it does fire,
  // those cells get a 1x pet whose feet sit a few px into the skirting band:
  // not clipped, nothing pushed off the panel, and the alternative is a pet
  // smaller than its own art. Accepted deliberately.
  //
  // 🔴 Do NOT write a measured value for `stableChrome` into this comment.
  // An earlier version gave one — "81 px of budget", implying 159 — that
  // contradicted the ill-state figure stated below it, and the next person to
  // budget against the number had to recompute the whole fit grid under both
  // to find out which half of the file was lying.
  readonly property int heightScale: Math.max(1, Math.min(4,
    Math.floor((height - stableChrome) * 0.8 / Sprites.tallestStageHeight())))

  // 🔴 ONE INTEGER scale for the whole room: the smaller of the two, so the
  // pet fits whichever axis is the tighter one. Both inputs are already
  // whole and clamped 1..4, so this is too — nothing downstream has to
  // re-check it, and `petW`/`petH`, the mirror's `origin.x` and every prop
  // stay on whole pixels at every size the settings allow.
  //
  // 🔴 It is a function of `width` and `height` and NOTHING ELSE. Not the
  // stage, not the pet's health, not what is currently on screen: the pet
  // changes size when, and only when, the user drags the panel.
  readonly property int spriteScale: Math.min(widthScale, heightScale)

  // 🔴 The chrome height the SCALE is budgeted against, and it is deliberately
  // NOT `chromeHeight` below. `chromeHeight` is what is on screen right now,
  // and it changes with the pet: an egg shows a hatch countdown and neither
  // the stat meters nor the care buttons (42 px), a healthy pet shows the
  // meters and the buttons (109 px), an ill one adds the notice row on top
  // (128 px). Budget the scale against the live number and the pet halves
  // itself the instant its egg hatches, and halves and un-halves again every
  // time it falls ill and recovers — the same "the pet changed size and I
  // did not touch the panel" complaint this whole budget exists to end,
  // just moved to a different trigger.
  //
  // So: the largest chrome ANY state can produce — header + a notice row +
  // meters + buttons, with the four gaps that layout needs. It is an upper
  // bound on `chromeHeight` in every state (an egg has no meters, a healthy
  // pet has no notice), so a scale that fits this budget fits the real room
  // with room to spare, and it depends on nothing that changes as the pet
  // lives its life. Do NOT "simplify" this back to `chromeHeight`.
  //
  // ⚠️ An invisible row still reports its `implicitHeight` — a Column skips
  // it when laying out, it does not stop measuring it — so the meters and
  // the buttons are measurable while an egg is on screen. Verified, not
  // assumed.
  //
  // ⚠️ The gap is read off `mainColumn.spacing` rather than from
  // `PetStyle.spacing.sm`. It is the gap the Column will actually lay out with
  // — already rounded — so the two can never disagree, and it keeps the
  // static checker able to resolve every name in this binding.
  readonly property real stableChrome: Math.ceil(
      headerRow.implicitHeight
    + Math.max(hatchText.implicitHeight, sickText.implicitHeight)
    + statsRow.implicitHeight
    + actionsRow.implicitHeight
    + mainColumn.spacing * 4)

  // The layout unit — gaps, margins, how far the heart floats up. It is a
  // multiple of spriteScale rather than an independent number so the whole
  // room grows in one step instead of the art and the spacing drifting
  // apart. At the default panel this is 6 px, near the 5 px the retired
  // cell-based maths used, so the room's proportions are unchanged.
  readonly property int unit: spriteScale * 3

  // How much of our height the fixed chrome (header, notices, stat meters,
  // care buttons) actually consumes, so the room area can take everything
  // that is left. Counted from the CURRENTLY VISIBLE rows only: a Column
  // skips invisible children entirely, spacing included, so an egg — which
  // shows neither stats nor care buttons — correctly gets a much taller
  // floor than an adult does. `n` is the number of visible siblings, which
  // is also the number of gaps once roomArea itself is counted.
  readonly property real chromeHeight: {
    var n = 1
    var h = headerRow.implicitHeight
    if (hatchText.visible) { h += hatchText.implicitHeight; n++ }
    if (sickText.visible) { h += sickText.implicitHeight; n++ }
    if (statsRow.visible) { h += statsRow.implicitHeight; n++ }
    if (actionsRow.visible) { h += actionsRow.implicitHeight; n++ }
    // ⚠️ Rounded UP, and this is not cosmetic. Text.implicitHeight is a real
    // — 18.5 px is normal — so an unrounded sum puts roomArea's HEIGHT on a
    // fraction, and every Math.round() inside the room is then relative to a
    // half-pixel origin, which is the one thing nearest-neighbour sampling
    // cannot survive: one source row gets sampled twice and its neighbour
    // not at all. The rows ABOVE the room are rounded at their own heights
    // for the same reason, so roomArea's Y is whole too.
    return Math.ceil(h + PetStyle.spacing.sm * n)
  }

  // The IDLE frame set for the current stage, and the three props. Each is
  // { frames: [path...], w, h } where w/h are the PNG's OWN pixel size —
  // multiplied by spriteScale at every draw site, never used raw.
  //
  // 🔴 This one, and ONLY this one, sizes the pet. `petW`/`petH` below are
  // the idle canvas at every moment of the pet's life, mood or no mood: it is
  // what petGrid measures, what the mirror takes its origin from and what the
  // heart and the sleep mark are centred over. A mood canvas is bigger (see
  // Sprites.js), and letting that bigger number anywhere near petGrid is
  // exactly how "the pet grew when it got hungry" would ship.
  readonly property var bodySprite: Sprites.forStage(pet.stage, pet.adultForm)

  // How the pet is, as a plain string: "sick" | "hungry" | "tired" | "sad" |
  // "angry" | "none". A pure function of the state in Pet.js, so the whole
  // rule is testable in node rather than only observable by starving a pet.
  //
  // 🔴 NOT latched, and deliberately so. It is a binding over `pet`, which
  // Panel.qml replaces wholesale on every reconcile and on every care action,
  // so feeding a starving pet returns it to its idle art on the very next
  // frame. There is no mood the pet can get into and not get out of.
  readonly property string moodNow: Pet.moodFor(pet)

  // The mood frame set, or NULL when the ordinary idle art should be drawn —
  // which is the normal case, and the only case for an egg.
  //
  // 🔴 `adultForm` is passed and is NOT optional. Adult C's idle loop is
  // airborne — the crowned form has its feet off the ground in both frames —
  // while every adult mood frame stands on the floor line, so the mood spec
  // carries a per-form `lift` that cancels the difference. Drop the argument
  // and a crowned pet sinks 2-4 source px the moment a stat reaches 20.
  // Sprites.js states the measurements; this is where they are spent.
  readonly property var moodSprite: Sprites.forMood(pet.stage, moodNow, pet.adultForm)

  // What is actually on screen. Frames and source size only; NEVER geometry.
  readonly property var currentSprite: moodSprite ? moodSprite : bodySprite
  readonly property int frameCount: currentSprite.frames.length
  readonly property var wasteSpec: Sprites.prop("waste")
  readonly property var heartSpec: Sprites.prop("heart")
  readonly property var sleepSpec: Sprites.prop("sleep")

  readonly property int petW: bodySprite.w * spriteScale
  readonly property int petH: bodySprite.h * spriteScale

  // 🔴 How far OUTSIDE petGrid the mood art hangs, on all four sides. A mood
  // canvas is the idle canvas plus `pad` source pixels on every side, with
  // the body sitting at the same place inside it, so drawing the mood Image
  // at (-moodInset, -moodInset) at size (mood canvas * scale) puts the body
  // exactly where the idle sprite's body is — the same screen pixel, not
  // approximately the same one. Zero whenever no mood art is drawn, which
  // makes the expression below arithmetically identical to `anchors.fill`
  // for a well pet.
  //
  // ⚠️ `pad` and `spriteScale` are both whole numbers, so this is one too and
  // the sprite stays on the pixel grid. Sprites.js states the same rule at
  // the other end; this is where it is spent.
  readonly property int moodInset: moodSprite ? moodSprite.pad * spriteScale : 0

  // 🔴 How far ABOVE the inset position the mood canvas is drawn, so that the
  // drawn body keeps the floor line of the IDLE FORM ACTUALLY ON SCREEN. It
  // is 0 for every stage and for adult forms A and B, whose idle art stands
  // on the same row the mood art does; it is 3 source px for adult C, whose
  // idle art hovers. Vertical only — the mirror's origin, petGrid and every
  // horizontal argument in this file are untouched by it.
  //
  // ⚠️ Whole pixels, for the same reason moodInset is: `lift` and
  // `spriteScale` are both integers.
  readonly property int moodLift: moodSprite ? moodSprite.lift * spriteScale : 0

  // 🔴 Is the pose the pet is currently drawn in a LYING one? The child tired
  // row is drawn flat on its belly and the adult tired row curled up asleep,
  // and a sleeping drawing walked across the floor reads as a broken sprite.
  // Authored in Sprites.js beside the frames it describes; spent below on
  // `stillChance` and `riseBand`, which are the same two dials the neglect
  // levels turn, so this composes with them rather than overriding them.
  readonly property bool moodRests: moodSprite ? moodSprite.rests === true : false

  // An egg is never ill — Pet.js has nothing to make ill yet — so illness is
  // gated on the stage as well as on the flag.
  readonly property bool sickNow: pet.stage !== "egg" && pet.sick === true

  // 🔴 Can this scenegraph run a shader at all? The one re-colouring left in
  // this file is a MultiEffect, and a MultiEffect on the SOFTWARE backend
  // draws literally nothing — not a degraded version, nothing. That is not a
  // hypothetical: it is exactly what a headless verification run hit, and
  // the cause was reported by the renderer itself (`Loading backend
  // software`). Omarchy on real hardware runs an RHI backend and the effect
  // draws; a software fallback happens on a machine with no working GPU path,
  // and there the SLEEP mark would be the sleep button's only feedback and
  // would silently not appear.
  //
  // ⚠️ It no longer has anything to do with the ILL pet. Illness used to be
  // an urgent wash over the sprite, with an opacity pulse as the shader-free
  // fallback; both are gone, because the pet now has a drawn sick face and a
  // machine with no GPU path draws that exactly as well as one with.
  //
  // GraphicsInfo.api is QtQuick's own answer to this question, attached to
  // this item and notified when the item lands on a window. Before that it
  // reports Unknown, which is read OPTIMISTICALLY here — the effect path is
  // the normal path, and only a scenegraph that has positively identified
  // itself as software takes the fallbacks below.
  readonly property bool effectsAvailable: GraphicsInfo.api !== GraphicsInfo.Software

  // A dummy dependency that forces the two time-based bindings below
  // (hatch fraction, the hatch countdown text) to re-evaluate roughly once
  // a second. This is the one per-second tick in the whole plugin, it does
  // nothing but flip an int, and it only runs while there is an egg on
  // screen to show a countdown for.
  property int _tick: 0
  Timer {
    interval: 1000
    running: root.pet.stage === "egg" && root.panelOpen
    repeat: true
    onTriggered: root._tick++
  }

  readonly property real hatchFrac: {
    var _dep = root._tick
    if (pet.stage !== "egg") return 1
    // A frozen egg (never opened, or waiting behind a memorial) has a bornAt
    // still sitting at construction time, which can be hours ago. Reading
    // the clock would paint a fully-cracked egg for the single frame between
    // this Room becoming visible and markFirstOpen() resetting bornAt.
    if (pet.awaitingFirstOpen === true || pet.memorialSeen === false) return 0
    var elapsed = Date.now() - pet.bornAt
    if (elapsed < 0) elapsed = 0 // clock skew: never negative progress
    return Math.max(0, Math.min(1, elapsed / Math.max(1, pet.hatchDurationMs)))
  }

  // The egg is the one stage indexed by TIME rather than by the idle tick:
  // all six of its frames are a single progression from whole shell to open
  // shell, so hatch progress picks the frame directly. Six equal sixths —
  // frames 1-2 are whole, 3-6 crack progressively, so the shell visibly
  // comes apart across the window rather than jumping in three steps.
  readonly property int displayFrameIndex: {
    if (pet.stage === "egg")
      return Math.max(0, Math.min(root.frameCount - 1, Math.floor(hatchFrac * root.frameCount)))
    // Held rather than cycled once neglect reaches the top level. Frame 0 is
    // the calm stand in every stage's idle set, and the first frame of the
    // authored loop in every mood set — in both cases the pose the set was
    // chosen to start on, so the hold needs no art of its own.
    //
    // ⚠️ A mood loop can be ONE frame (the child's sad row draws its tear on
    // frame 1 and nowhere else), and that frame is then held whatever the
    // neglect level. The modulo below handles it; nothing special-cases it.
    if (!root.idleCycling) return 0
    return root.idleFrame % Math.max(1, root.frameCount)
  }

  readonly property string displayFrame: currentSprite.frames[Math.min(displayFrameIndex, currentSprite.frames.length - 1)]

  // The SLEEP MARK overlay for the frame currently on screen, or "" when this
  // frame has none — which is every frame of every mood except the baby and
  // child tired rows, and every idle frame of every stage including the egg.
  //
  // 🔴 The tired rows sit on a white ground, so the zZ beside the sleeping
  // head is dark ink: measured against the panel's card it sits
  // at 1.00-1.41:1 while the dragon's own body sits at 2.05-2.81:1. It is not
  // there. It is also the only thing that makes a lying-down pose read as
  // "asleep" rather than "dead", in a plugin that has a death — so it is cut
  // into its own transparent PNG (Sprites.js, THE SLEEP MARK) and recoloured
  // to the theme's foreground below.
  //
  // ⚠️ Indexed with the SAME index and the SAME clamp as `displayFrame`, off
  // an array Sprites.js builds to the same length as `frames`, so the mark on
  // screen can never be one frame out of step with the body under it.
  readonly property string displayGlyph: {
    if (!moodSprite || !moodSprite.glyphs) return ""
    var g = moodSprite.glyphs[Math.min(displayFrameIndex, moodSprite.glyphs.length - 1)]
    return g ? g : ""
  }

  function secondsToHatch() {
    var _dep = root._tick
    // Same reason as hatchFrac above: a frozen egg's window has not opened
    // yet, so it reads as the full duration rather than as "0s" left over
    // from a clock that was never running.
    if (pet.awaitingFirstOpen === true || pet.memorialSeen === false)
      return Math.ceil(pet.hatchDurationMs / 1000)
    var remain = Math.ceil((pet.bornAt + pet.hatchDurationMs - Date.now()) / 1000)
    return Math.max(0, remain)
  }

  // Pet.formatAge() resta verbatim e da' "2h 14m": cifre e unita' che si
  // leggono uguali in tutte e sei le lingue. L'unico valore che e' una frase
  // e' il caso sotto il minuto, e si traduce quello invece di riscrivere in
  // QML il conto che sta gia' nel JS.
  function ageText(ms) {
    var t = Pet.formatAge(ms)
    return t === "under a minute" ? I18n.t("meno di un minuto") : t
  }

  function stageLabel() {
    if (pet.stage === "baby") return I18n.t("Cucciolo")
    if (pet.stage === "child") return I18n.t("Bambino")
    if (pet.stage === "adult") return I18n.t("Adulto")
    return ""
  }

  // ---- Idle/blink frame swap. A Timer flips an index; QtQuick draws the
  //      resulting frame. Nothing here runs per rendered frame.
  property int idleFrame: 0
  Timer {
    id: blinkTimer
    interval: Math.round((root.walking ? 380 : 1400) * root.frameHold)
    // 🔴 Also gated on `idleCycling`: at level 3 the loop stops and the
    // frame below is held. An idle loop running at the healthy rate under an
    // urgent wash made an ill pet look MORE animated than a well one, which
    // is the opposite of the thing being communicated.
    running: root.pet.stage !== "egg" && !root.memorialPending && root.panelOpen && root.idleCycling
    repeat: true
    onTriggered: root.idleFrame = (root.idleFrame + 1) % Math.max(1, root.frameCount)
  }

  // ---- NEGLECT, READ OFF HOW THE PET MOVES ---------------------------
  //
  // 🔴 A neglected pet has to be recognisable from its BEHAVIOUR. Until now
  // illness changed exactly two things a person could see — a line of urgent
  // text and an urgent wash over the sprite — plus one thing they could not:
  // `effectiveMood *= 0.55`, which divided BOTH the walk animation and the
  // pause between walks by the same number. Scaling both by the same number
  // is the entire problem. The pet spent an identical 36.2% of its time in
  // motion either way, covered the same ground, crossed the same floor end
  // to end, and cycled its idle frames at exactly the healthy rate; it
  // simply played the same choreography at 0.55x tape speed. With nothing on
  // screen to compare against that is not a signal: a pet on hunger 0 and
  // hygiene 0 trotting cheerfully around its room reads as a bug, because it
  // is one.
  //
  // So neglect is graded into four levels here, and each level changes what
  // the pet DOES: how often it moves, how far it goes, how far off the floor
  // it gets, and whether its idle loop runs at all.
  //
  // 🔴 Level 0 is the shipped behaviour, unchanged. Every dial below is
  // exactly 1.0 there and every random draw happens in the same order with
  // the same bounds, so a well pet is untouched by all of this. That is a
  // hard requirement, not a nicety: a regression in normal behaviour would
  // be worse than the bug this fixes.
  //
  // 🔴 Nothing here touches the simulation. Pet.js was never the defect — it
  // correctly marked this pet ill, wrote the timestamp, and would have
  // killed it on schedule. It was this file that failed to say so.
  readonly property int zeroStats: {
    if (root.pet.stage === "egg") return 0
    var n = 0
    if (root.pet.hunger <= 0) n++
    if (root.pet.energy <= 0) n++
    if (root.pet.happiness <= 0) n++
    if (root.pet.hygiene <= 0) n++
    return n
  }

  // The same threshold the bar's attention dot already uses, so the room and
  // the bar agree about when something has started to go wrong.
  readonly property bool anyStatLow: root.pet.stage !== "egg"
    && (root.pet.hunger <= 20 || root.pet.energy <= 20
        || root.pet.happiness <= 20 || root.pet.hygiene <= 20)

  // How far through the illness window the pet is, 0..1.
  //
  // ⚠️ `pet.lastSeen` is read as the clock dependency ON PURPOSE, and it is
  // the only reason this needs no Timer of its own: Panel.qml replaces the
  // whole `pet` object on every reconcile (15 s with the panel open, 60 s
  // always), so this re-evaluates then. Making the dependency explicit is
  // the point — if reconcile ever starts handing back the same object when
  // nothing changed, this line is what has to be looked at.
  readonly property real sickFrac: {
    var _dep = root.pet.lastSeen
    if (!root.sickNow) return 0
    if (!(root.sickWindowMs > 0)) return 0
    var since = root.pet.sickSince
    if (typeof since !== "number" || !isFinite(since)) return 0
    var el = Date.now() - since
    if (el < 0) el = 0 // clock skew: never negative progress
    return Math.max(0, Math.min(1, el / root.sickWindowMs))
  }

  // 0 well · 1 struggling · 2 ill · 3 failing.
  //
  // Level 3 is "and this has been going on": a third of the way through the
  // illness window, or two stats on the floor at once. That is the
  // difference between "one stat is low" and "this pet has been in trouble
  // for a while". ⚠️ The two clauses are an OR for a reason, and which one
  // fires changed when the window went to twelve hours: a third of it is now
  // four hours, but the second stat bottoms out sooner than that, so from
  // full stats level 3 is reached at about five hours by the zero-count
  // clause rather than at four by the fraction.
  readonly property int neglectLevel: {
    if (root.pet.stage === "egg" || root.memorialPending) return 0
    if (root.sickNow)
      return (root.sickFrac >= 0.33 || root.zeroStats >= 2) ? 3 : 2
    return root.anyStatLow ? 1 : 0
  }

  // ---- The six dials -------------------------------------------------
  //
  // 🔴 `walkStretch` and `pauseStretch` are deliberately DIFFERENT numbers.
  // Scaling them together is exactly what made the old 0.55 invisible: it
  // preserved the ratio of moving time to standing time, which is the thing
  // an eye actually reads as energy. Here the pause grows faster than the
  // walk slows, so the share of the time the pet is in motion genuinely
  // falls: 36% well · 23% struggling · 10% ill · 0% failing.
  readonly property real walkStretch: root.neglectLevel >= 2 ? 2.3
                                    : (root.neglectLevel === 1 ? 1.35 : 1.0)
  readonly property real pauseStretch: root.neglectLevel >= 2 ? 3.4
                                     : (root.neglectLevel === 1 ? 1.7 : 1.0)
  // Probability that a wander tick decides to stand still rather than walk.
  // 1.0 stops the pet entirely — Math.random() never returns 1.
  //
  // 🔴 A resting pose takes the same 1.0, so an asleep pet does not travel.
  // It is a SECOND way to reach the top of this scale, not a replacement for
  // the neglect levels: hungry, sad, angry and sick still walk at 0.45 / 0.7
  // / 1.0 exactly as they did, which is where the four levels stay readable.
  readonly property real stillChance: (root.moodRests || root.neglectLevel >= 3) ? 1.0
                                    : (root.neglectLevel === 2 ? 0.7
                                    : (root.neglectLevel === 1 ? 0.45 : 0.3))
  // How far one hop may carry the pet, as a fraction of the floor. At 0.84
  // (well) the pet may go anywhere; below it, it shuffles near where it
  // already stands instead of crossing the room.
  readonly property real roamSpan: root.neglectLevel >= 3 ? 0.0
                                 : (root.neglectLevel === 2 ? 0.2
                                 : (root.neglectLevel === 1 ? 0.52 : 0.84))
  // The band above the floor line the pet is allowed to wander up into. It
  // sags to the floor as neglect deepens and is pinned there at level 3.
  //
  // 🔴 And pinned there by a resting pose too. Without this the curled-up
  // sleeping adult would hover up to 16% of the room's height off the ground
  // at neglect level 1 — the same defect as the sliding, on the other axis.
  readonly property real riseBand: (root.moodRests || root.neglectLevel >= 3) ? 0.0
                                 : (root.neglectLevel === 2 ? 0.05
                                 : (root.neglectLevel === 1 ? 0.16 : 0.32))
  // Multiplier on how long each frame of the idle/walk loop is held.
  readonly property real frameHold: root.neglectLevel >= 2 ? 2.1
                                  : (root.neglectLevel === 1 ? 1.3 : 1.0)
  // At the extreme the idle loop stops and ONE frame is held, so the pet
  // stops looking animated and starts looking listless. Frame 0 is the
  // quieter of the two poses in every stage's set (the calm stand, not the
  // open-mouthed one), which is why the hold lands there and needs no new
  // art to do it.
  readonly property bool idleCycling: root.neglectLevel < 3

  // Two things have to happen at the instant the level changes rather than
  // whenever the next wander tick comes round, which at level 3 can be the
  // better part of a minute away.
  //
  // Worse: the pet sinks to the floor. `petFracY` is assigned by the wander
  // tick, not bound, so nothing else would ever bring it down — and the
  // Behavior on it turns this one assignment into a slow visible sag rather
  // than a jump.
  //
  // Better: care has to feel like it worked. The timer is restarted short so
  // the pet is up and moving again inside a second, instead of the player
  // feeding it and watching nothing happen for half a minute.
  onNeglectLevelChanged: {
    if (root.neglectLevel >= 3) {
      root.walking = false
      root.petFracY = 0
    } else {
      wanderTimer.interval = 700
      wanderTimer.restart()
    }
  }

  // The same two instants, for the same two reasons, when the pet lies DOWN
  // rather than when it gets worse. `stillChance` and `riseBand` above only
  // take effect at the NEXT wander tick, which can be most of a minute away,
  // and `petFracY` is assigned by that tick rather than bound — so without
  // this the pet would fall asleep in mid-air and stay there.
  //
  // ⚠️ Stated and accepted: a walk already in flight is NOT cancelled. The
  // Behavior on petFracX keeps animating to the destination it was given, so
  // a pet that falls asleep mid-step finishes that step (up to one walk
  // duration) before it settles. Stopping a running Behavior is a Qt
  // behaviour that cannot be checked without Qt on this machine, and the
  // failure mode of guessing wrong is a teleporting pet; one last step is the
  // safe half of the trade. The sag to the floor below IS immediate, because
  // it is an ordinary assignment through the same Behavior.
  onMoodRestsChanged: {
    if (root.moodRests) {
      root.walking = false
      root.petFracY = 0
    } else if (root.neglectLevel < 3) {
      // Waking up has to feel like the care worked, on the same short restart
      // the level change uses — and must NOT restart a level-3 pet, which is
      // meant to be lying still whatever its mood says.
      wanderTimer.interval = 700
      wanderTimer.restart()
    }
  }

  // ---- The one movement a failing pet keeps ---------------------------
  // A pet that has stopped walking, stopped cycling its frames and sunk to
  // the floor is the point of level 3 — but a completely motionless sprite
  // reads as a frozen panel rather than as an animal in trouble. One slow
  // rise and fall of a single SOURCE pixel (multiplied by spriteScale, so it
  // stays on the integer grid at every panel size) says "still breathing"
  // and says nothing else. It is the only animation left at level 3, and it
  // needs no shader — see the note on the illness wash below.
  property real breathLift: 0
  SequentialAnimation {
    id: breathAnim
    running: root.neglectLevel >= 3 && root.panelOpen
             && !root.memorialPending && root.pet.stage !== "egg"
    loops: Animation.Infinite
    // A stopped animation leaves the property where it last set it — the
    // same trap eggWobble documents further down.
    onRunningChanged: if (!running) root.breathLift = 0
    NumberAnimation { target: root; property: "breathLift"; to: 1; duration: 2600; easing.type: Easing.InOutSine }
    NumberAnimation { target: root; property: "breathLift"; to: 0; duration: 2600; easing.type: Easing.InOutSine }
  }

  // ---- Wander-and-idle pathing. A Timer occasionally picks a new spot or
  //      decides to stand still; a Behavior animates the move.
  //      Sped up under machine load — flavour only, and it never
  //      affects any stat.
  //
  // ⚠️ The sick branch that used to live in here has moved into the level
  // system above, where the walk and the pause can be stretched by DIFFERENT
  // amounts. The low-energy branch stays exactly where it was: a tired pet
  // is a mood, not a diagnosis, and energy 25 with everything else full is
  // still a well pet.
  readonly property real effectiveMood: {
    var m = root.moodFactor
    if (pet.stage !== "egg" && pet.energy <= 25) m *= 0.7
    return Math.max(0.35, m)
  }

  property bool walking: false
  property real petFracX: 0.5
  // Which way the pet is drawn. Every source frame in assets/pets faces
  // RIGHT, so without this the pet moonwalks the whole time it is heading
  // left.
  //
  // 🔴 LATCHED at the moment a destination is chosen (wanderTimer below),
  // never derived from petFracX. While the Behavior animates it, petFracX is
  // an interpolated in-between value, and a continuous comparison against it
  // jitters as the pet closes on its destination — the sprite can flip
  // mid-stride, which is a worse artefact than the moonwalk this fixes.
  //
  // 🔴 It PERSISTS when the pet stops. Nothing here resets it on idle,
  // sleep, feeding, a click or a stage change: a pet that snaps back to
  // face right every time it stands still is worse than one that never
  // turns at all.
  property bool facingLeft: false
  // 0 = feet on the floor line, 1 = up near the room's ceiling — see the
  // petGrid `y` binding below. Kept low so the pet reads as standing IN the
  // room rather than floating near the header.
  property real petFracY: 0.12

  readonly property int walkDurationMs: Math.round(Math.max(500, 1500 * root.walkStretch / root.effectiveMood))

  Behavior on petFracX {
    enabled: root.pet.stage !== "egg"
    NumberAnimation { duration: root.walkDurationMs; easing.type: Easing.InOutQuad }
  }
  Behavior on petFracY {
    enabled: root.pet.stage !== "egg"
    NumberAnimation { duration: root.walkDurationMs; easing.type: Easing.InOutQuad }
  }

  Timer {
    id: wanderTimer
    interval: 2200
    running: root.pet.stage !== "egg" && !root.memorialPending && root.panelOpen
    repeat: true
    onTriggered: {
      // 🔴 The change a person reads instantly: at level 3 `stillChance` is
      // 1.0 and this branch is taken every time — the pet stops going
      // anywhere at all. The Timer keeps RUNNING rather than being switched
      // off, so the moment care lifts the level the next decision is taken
      // on the normal cadence instead of waiting out a stopped timer.
      if (Math.random() < root.stillChance) {
        root.walking = false
      } else {
        root.walking = true
        // 🔴 THE ORDER IS THE WHOLE TRICK. petFracX is read here while it
        // still holds the CURRENT position; reading it after the assignment
        // below would compare the new destination with itself, the test
        // would never be true, and the pet would never turn — while still
        // linting clean and still running.
        //
        // ⚠️ The 0.02 dead band is deliberate, not redundant. A destination
        // landing almost exactly where the pet already stands carries no
        // meaningful direction, and flipping the sprite for it reads as a
        // twitch. Below the band the pet simply keeps facing the way it was.
        var target
        if (root.roamSpan >= 0.84) {
          // The shipped path, untouched: anywhere on the floor.
          target = 0.08 + Math.random() * 0.84
        } else {
          // A short shuffle out from where it already stands, clamped into
          // the same 0.08..0.92 strip. A neglected pet does not cross the
          // room; it moves a body length and gives up.
          target = root.petFracX + (Math.random() * 2 - 1) * root.roamSpan
          target = Math.max(0.08, Math.min(0.92, target))
        }
        if (Math.abs(target - root.petFracX) > 0.02)
          root.facingLeft = (target < root.petFracX)
        root.petFracX = target
        root.petFracY = Math.random() * root.riseBand
      }
      wanderTimer.interval = Math.round(Math.max(900, (1600 + Math.random() * 2600) * root.pauseStretch / root.effectiveMood))
    }
  }

  // ---- Click-the-pet reaction: the interaction that has to feel
  //      better than anything else here. Immediate — it does not wait for
  //      Panel.qml's round trip through Pet.applyPet() before playing.
  // 🔴 Aggiunto dal porting (modifica 7): la cima VISIVA del pet, che con la
  // prospettiva accesa non e' piu' `petGrid.y`. Lo Scale della profondita'
  // rimpicciolisce attorno ai piedi, quindi la testa scende di tutta l'altezza
  // persa e un cuore fatto partire dal bordo dell'Item resterebbe a mezz'aria
  // sopra un pet che non c'e' — proprio nella valle in cui il pet e' piu'
  // grande no, ma sulla collina si'. Con `terrainDepth: 0` o terreno spento
  // vale `petGrid.y`, cioe' esattamente il numero di prima.
  function petTopY() {
    return petGrid.y + petGrid.height * (1 - root.depthScale)
  }

  function burstHeart() {
    heartEffect.x = Math.round(petGrid.x + petGrid.width / 2 - heartEffect.width / 2)
    heartEffect.y = Math.round(root.petTopY() - root.unit)
    heartEffect.targetY = heartEffect.y - root.unit * 3
    heartEffect.opacity = 1
    heartAnim.restart()
  }

  // ---- Click-the-egg reaction. The egg has no stats to affect (Pet.js's
  //      applyPet()/applyCare() are deliberately no-ops on an egg — there is
  //      nothing to feed or play with yet), but it is the ONLY interactive-
  //      looking thing on screen for the whole 60-90s hatch window, which is
  //      exactly the window everything else in here is built around: the
  //      first sixty seconds, and the hatch. A click must not be a dead end.
  function burstEggBump() {
    eggBump.restart()
  }

  function burstSleepMark() {
    sleepEffect.x = Math.round(petGrid.x + petGrid.width / 2 - sleepEffect.width / 2)
    sleepEffect.y = Math.round(root.petTopY() - root.unit)
    sleepEffect.targetY = sleepEffect.y - root.unit * 3
    sleepEffect.opacity = 1
    sleepAnim.restart()
  }

  // Il fondale, che si adatta da solo a qualunque misura gli si dia.
  //
  // 🔴 Sta alla RADICE e non dentro roomArea, quindi copre tutto il pannello —
  // intestazione, stanza, barre e pulsanti — e non la sola stanza. Dichiarato
  // prima di mainColumn: in QML l'ordine di dichiarazione e' l'ordine di
  // disegno, quindi tutto il resto, terreno compreso, gli finisce sopra.
  //
  // 🔴 Due regimi, e la differenza non e' pignoleria: un disegno a pixel
  // INGRANDITO deve crescere di un numero intero di volte con
  // nearest-neighbour, o diventa la fotografia sfocata di un disegno; una
  // fotografia RIMPICCIOLITA vuole il filtro morbido, o si riempie di
  // scalettature. La stessa immagine non puo' volere tutti e due, quindi si
  // guarda da che parte si sta andando e si sceglie.
  //
  // Prima qui c'era `implicitWidth * spriteScale`, che dava per scontato che il
  // file fosse disegnato alla misura di partenza. Un'immagine gia' grande
  // veniva moltiplicata lo stesso e se ne vedeva un francobollo.
  Item {
    id: backdropArea

    anchors.fill: parent
    // L'immagine che copre puo' sporgere: senza questo uscirebbe dal pannello
    // e si sovrapporrebbe a quello sotto nella colonna.
    clip: true
    visible: root.background != ""

    Image {
      id: backdrop

      source: root.background

      // La misura vera del file. sourceSize resta non impostato di proposito:
      // e' l'unita' su cui si calcola tutto il resto, e impostarlo la
      // cambierebbe sotto i piedi al calcolo stesso.
      readonly property real srcW: implicitWidth
      readonly property real srcH: implicitHeight

      // Quanto va scalata per COPRIRE il pannello — il massimo dei due
      // rapporti, non il minimo: con il minimo resterebbero due bande vuote ai
      // lati o sopra, e il fondo della dashboard si vedrebbe attraverso.
      readonly property real cover: backdrop.srcW > 0 && backdrop.srcH > 0
                                    ? Math.max(backdropArea.width / backdrop.srcW, backdropArea.height / backdrop.srcH)
                                    : 1
      readonly property bool enlarging: backdrop.cover > 1

      // Ingrandendo si arrotonda PER ECCESSO a un intero: per eccesso perche'
      // un intero per difetto lascerebbe scoperto un bordo, e intero perche' e'
      // l'unica cosa che tiene i pixel quadrati.
      readonly property real factor: backdrop.enlarging ? Math.ceil(backdrop.cover) : backdrop.cover

      width: Math.round(backdrop.srcW * backdrop.factor)
      height: Math.round(backdrop.srcH * backdrop.factor)
      // Centrata sui due assi: quello che avanza si taglia per meta' da una
      // parte e per meta' dall'altra, che e' il modo in cui un'immagine di
      // proporzioni diverse si comporta meno peggio.
      x: Math.round((backdropArea.width - width) / 2)
      y: Math.round((backdropArea.height - height) / 2)

      smooth: !backdrop.enlarging
      mipmap: !backdrop.enlarging
    }

    // Il velo. Sopra un'immagine qualunque il nome del pet, le barre e i
    // pulsanti possono diventare illeggibili, e un pannello bello che non si
    // legge e' un pannello rotto. Si regola con `backgroundDim` nei
    // panelParams: a zero l'immagine e' com'e', a uno e' nera.
    Rectangle {
      anchors.fill: parent
      color: "#0d1117"
      opacity: root.backgroundDim
    }
  }

  Column {
    id: mainColumn
    anchors.fill: parent
    // Whole pixels: a fractional gap shifts every row below it onto a
    // fraction, the room included. See chromeHeight above for why that
    // matters to a pixel-art sprite.
    spacing: Math.round(PetStyle.spacing.sm)

    // ---- Header ------------------------------------------------------
    Row {
      id: headerRow
      width: parent.width
      height: Math.ceil(implicitHeight)   // whole pixels — see chromeHeight
      spacing: PetStyle.spacing.sm

      Text {
        // 🔴 The name arrives from the save file, which the user can edit, and
        // this panel lives inside a shell process that runs for days. The
        // default Text.AutoText sniffs its input and switches to rich text on
        // anything markup-shaped — at which point an <img> in a name is a
        // network fetch made by the shell. Pet.js bounds the string on the way
        // in; this is the other half of that, and every Text in this plugin
        // declares it so the rule is visible rather than remembered. A test
        // fails if any of them stops.
        textFormat: Text.PlainText
        width: parent.width - genBadge.width - PetStyle.spacing.sm
        text: root.pet.stage === "egg" ? I18n.t("Un uovo") : (root.pet.name + " · " + root.stageLabel())
        color: PetColor.foreground
        font.family: PetStyle.font.family
        font.pixelSize: PetStyle.font.body
        elide: Text.ElideRight
      }

      Rectangle {
        id: genBadge
        radius: PetStyle.cornerRadius
        color: Qt.rgba(PetColor.accent.r, PetColor.accent.g, PetColor.accent.b, 0.18)
        width: genText.implicitWidth + PetStyle.spacing.sm * 2
        height: genText.implicitHeight + 4
        Text {
          textFormat: Text.PlainText
          id: genText
          anchors.centerIn: parent
          text: I18n.t("Gen %1").arg(root.pet.generation)
          color: PetColor.accent
          font.family: PetStyle.font.family
          font.pixelSize: PetStyle.font.body
        }
      }
    }

    // ---- Stats (modifica 9 del porting) -----------------------------------
    //
    // Una riga sola, in cima, senza barre: un'icona e il numero. Le barre
    // costavano quattro righe di chrome — due righe di griglia, testo piu'
    // barra ognuna — e le pagava la stanza, che e' la cosa che si guarda.
    //
    // 🔴 Quattro celle di larghezza UGUALE (`width / 4`) invece di un Row
    // spaziato: cosi' il numero sta sempre nello stesso posto e la riga non
    // balla quando una statistica passa da 98 a 100. Sono scritte a mano, non
    // generate da un modello, per la stessa ragione per cui lo erano le barre —
    // un modello JS ricostruito a ogni cambio di statistica ricreerebbe i
    // delegate una volta al secondo.
    Row {
      id: statsRow
      visible: root.pet.stage !== "egg"
      width: parent.width
      height: Math.ceil(implicitHeight)   // whole pixels — see chromeHeight
      spacing: 0

      StatCell { icon: "🍗"; value: root.pet.hunger; width: statsRow.width / 4 }
      StatCell { icon: "⚡"; value: root.pet.energy; width: statsRow.width / 4 }
      StatCell { icon: "😊"; value: root.pet.happiness; width: statsRow.width / 4 }
      StatCell { icon: "🧼"; value: root.pet.hygiene; width: statsRow.width / 4 }
    }

    Text {
      textFormat: Text.PlainText
      id: hatchText
      visible: root.pet.stage === "egg"
      width: parent.width
      height: Math.ceil(implicitHeight)   // whole pixels — see chromeHeight
      text: { var _dep = root._tick; return I18n.t("si schiude fra %1 s…").arg(root.secondsToHatch()) }
      color: PetColor.foreground
      opacity: 0.7
      font.family: PetStyle.font.family
      font.pixelSize: PetStyle.font.body
    }

    Text {
      textFormat: Text.PlainText
      id: sickText
      visible: root.pet.stage !== "egg" && root.pet.sick === true
      width: parent.width
      height: Math.ceil(implicitHeight)   // whole pixels — see chromeHeight
      // Escalates with the level for the same reason the behaviour does: an
      // hour of this must not read the same as the first minute of it. Both
      // strings are one line at the same pixel size, so `stableChrome` — and
      // therefore the pet's size — cannot move when this changes.
      text: root.neglectLevel >= 3 ? I18n.t("Sta molto male — ha bisogno di cure adesso")
                                   : I18n.t("Non sta bene — ha bisogno di cure")
      color: PetColor.urgent
      font.family: PetStyle.font.family
      font.pixelSize: PetStyle.font.body
    }

    // ---- The room itself ----------------------------------------------
    Item {
      id: roomArea
      width: root.width
      // Everything the chrome does not need. The floor line stays pinned to
      // the bottom, so extra panel height becomes headroom above the pet —
      // it is NOT a second axis for it to walk along.
      //
      // 🔴 There is NO minimum here any more, and removing it was a fix, not
      // a tidy-up. It used to read `Math.max(root.unit * 10, ...)`, which at
      // scale 4 is a 120 px floor — and a Column does not clip, so whenever
      // that floor exceeded the space actually left, the room pushed the stat
      // meters and the care buttons down and off the bottom of the panel. At
      // 700x240 half the button row was gone: Feed, Play, Clean and Sleep,
      // simply not there. The minimum's job — "a short panel still has a room
      // rather than a sliver" — is now done properly by `heightScale` above,
      // which refuses to hand out a scale the leftover height cannot seat, so
      // the floor can never be reached again and only ever did harm.
      // `Math.max(0, ...)` remains so an embedding shorter than its own chrome
      // gets a zero-height room instead of a negative one.
      //
      // ⚠️ `clip` stays. It is the last-resort guard, not the layout: with the
      // scale now height-aware the pet fits at every size the settings allow,
      // and this is what catches an embedding that never asked us.
      height: Math.floor(Math.max(0, root.height - root.chromeHeight))
      clip: true

      PetTerrain {
        id: terrainShape

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        // Il rilievo occupa la fascia bassa: sopra ci deve stare il pet, che a
        // scala 3 e' alto 216 px.
        height: Math.round(roomArea.height * 0.55)
        values: root.terrainValues
        running: root.panelOpen
        rise: root.terrainRise
        // Il bordo e' lo stesso colore ma piu' deciso del riempimento: e' cio'
        // che tiene leggibile il profilo quando il velo del fondale e' basso e
        // sotto passa un'immagine mossa.
        fillColor: Qt.rgba(root.terrainColor.r, root.terrainColor.g, root.terrainColor.b, root.terrainOpacity)
        lineColor: Qt.rgba(root.terrainColor.r, root.terrainColor.g, root.terrainColor.b, Math.min(1, root.terrainOpacity + 0.35))
      }

      Rectangle {
        id: baseboard
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        // Proportional, but capped: at 800 px tall a plain 16% skirting
        // board is a 100 px slab that eats the room it is supposed to floor.
        height: Math.round(Math.max(10, Math.min(30, roomArea.height * 0.16)))
        // Col terreno acceso sparisce: due linee di pavimento una sotto
        // l'altra sono una di troppo, e quella vera e' la curva.
        visible: !terrainShape.active
        color: Qt.rgba(PetColor.foreground.r, PetColor.foreground.g, PetColor.foreground.b, 0.06)
        Rectangle {
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          height: 1
          color: Qt.rgba(PetColor.foreground.r, PetColor.foreground.g, PetColor.foreground.b, 0.22)
        }
      }

      // Aggiunto dal porting (modifica 6): l'aria della stanza.
      //
      // Sta DIETRO al pet e davanti al solo battiscopa. Davanti coprirebbe
      // proprio la cosa che si guarda, e a quaranta molecole il pet
      // sparirebbe dentro la sua stessa CO2 — che sara' pure poetico ma
      // toglie l'unica informazione che il pannello esiste per dare.
      // Una nuvola per caratteristica: ognuna con il suo conteggio, la sua
      // altezza di ristagno e il suo timer. Si sovrappongono, ed e' giusto —
      // l'aria della stanza e' una sola, e quello che ci galleggia dentro sono
      // cose diverse.
      Repeater {
        model: root.particleTraits

        delegate: PetMolecules {
          required property var modelData

          anchors.fill: parent
          anchors.bottomMargin: baseboard.height
          trait: modelData
          scale: root.spriteScale
          running: root.panelOpen
          maxCount: root.particleMax
        }
      }

      // Waste: one sprite per uncleaned unit, capped the same way the
      // stat itself is capped. Clicking any one of them cleans all of it —
      // the room never asks the player to hunt down individual specks.
      Repeater {
        model: Math.min(root.pet.wasteCount, 5)
        // 🔴 `index` is DECLARED, not relied on as an injection: under
        // `pragma ComponentBehavior: Bound` an undeclared `index` is not
        // available at all, and under Unbound it would be available but
        // empty — the silent failure mode the pragma at the top of this
        // file exists to remove.
        delegate: Image {
          id: wasteItem
          required property int index

          // 🔴 Qt.resolvedUrl, not the bare relative string. A relative URL
          // in a QML binding resolves against the document that CONTAINS the
          // binding, which is this file and is correct — but the string
          // itself arrives from a .pragma library, and making the resolution
          // explicit here means it can never quietly start resolving against
          // something else.
          source: Qt.resolvedUrl(root.wasteSpec.frames[0])
          // Decode at the PNG's own size so nothing is resampled on load…
          sourceSize.width: root.wasteSpec.w
          sourceSize.height: root.wasteSpec.h
          // …and draw it at a whole multiple of that size with nearest-
          // neighbour filtering, which is what keeps a source pixel exactly
          // spriteScale screen pixels wide.
          width: root.wasteSpec.w * root.spriteScale
          height: root.wasteSpec.h * root.spriteScale
          smooth: false
          mipmap: false

          // Every prop canvas shares one floor line two rows above its own
          // bottom edge, so sitting the canvas ON the baseboard puts the
          // mess on the floor with a small, consistent gap.
          //
          // Col terreno acceso il pavimento non e' piu' una riga sola, quindi
          // si chiede il suolo alla frazione in cui questo pezzo si trova: uno
          // sporco che galleggia sopra una valle e' esattamente il genere di
          // dettaglio che disfa l'illusione.
          y: Math.round(root.groundY((wasteItem.x + wasteItem.width / 2) / Math.max(1, roomArea.width)) - wasteItem.height)
          // Measured from the sprite's OWN width, never a guessed multiple
          // of the layout unit — a guess is what once hung the first mess
          // over the room's right-hand edge. 0.6 rather than 1.0 because the
          // 32 px canvas is mostly transparent margin: a full-width stride
          // would scatter five little messes across the whole floor.
          x: Math.round(Math.max(root.unit,
                                 roomArea.width - root.unit - wasteItem.width
                                 - wasteItem.index * Math.round(wasteItem.width * 0.6)))
          MouseArea {
            anchors.fill: parent
            anchors.margins: -4
            cursorShape: Qt.PointingHandCursor
            onClicked: root.careRequested("clean")
          }
        }
      }

      // ---- Aggiunto dal porting (modifica 8): quello che cade dal cielo ---
      //
      // Dietro al pet e davanti allo sporco, cioe' nello stesso posto della
      // nuvola e per il motivo opposto: davanti coprirebbe il muso proprio
      // nell'istante della raccolta, mentre dietro il pet che ci sale sopra
      // nasconde l'oggetto — che e' esattamente come si legge «l'ha preso».
      PetDrops {
        anchors.fill: parent
        drops: root.drops
        groundSeconds: root.dropSeconds

        // Un terzo del pet, e cresce con lui: `petH` e' gia' l'altezza dello
        // sprite per la scala intera, quindi qui non entra nessun numero di
        // pixel scritto a mano.
        itemSize: Math.max(10, Math.round(root.petH / 3))
        margin: root.unit

        // Il pet, per riferimento: e' un id di questo file letto nel contesto
        // di questo file, non un delegate che guarda fuori.
        target: petGrid

        // Il suolo e' una curva e ogni oggetto cade in un punto suo: serve la
        // funzione, non una quota. Stessa chiamata dello sporco qui sopra.
        groundAt: f => root.groundY(f)

        running: root.panelOpen && root.pet.stage !== "egg" && !root.memorialPending

        onCaught: key => {
          // Il cuoricino solo per i regali: e' gia' il modo in cui questa
          // stanza dice «bene», e per un peperoncino sarebbe una bugia.
          const d = root.drops.find(x => x.key === key)
          if (d && d.kind === "bonus")
            root.burstHeart()
          root.dropCaught(key)
        }

        onExpired: key => root.dropExpired(key)
      }

      // A container rather than the Image itself, so the wobble/bump
      // transforms and the pet sprite below all live in one coordinate space
      // and rotate together. Its size is the IDLE sprite's size — never the
      // mood canvas's — so every existing binding that measures
      // `petGrid.width/height` is unchanged, mood or no mood.
      Item {
        id: petGrid
        width: root.petW
        height: root.petH
        transformOrigin: Item.Center

        // ---- Facing ------------------------------------------------------
        // The entire flip. It is instant on purpose: a mirror is how sprite
        // games have always turned a character around and it cannot look
        // broken. ⚠️ Do NOT animate xScale through zero — the pet would pass
        // through zero width, which at this frame rate reads as the pet
        // briefly vanishing rather than as it turning.
        //
        // It sits on petGrid rather than on petSprite so that whatever
        // petGrid holds mirrors as one piece. The heart, the sleep mark, the
        // waste and the tombstone are SIBLINGS of this Item and stay
        // unmirrored — a mirrored "z" glyph reads as a rendering bug. The bar
        // icon does not walk and is not touched at all.
        //
        // ⚠️ origin.x is a whole pixel at every size this can take. Every
        // IDLE canvas is an EVEN number of pixels wide (48/52/56/64) and
        // spriteScale is a whole number 1..4, so petW is even and petW/2 is
        // an integer. A half-pixel origin would resample the texture and
        // undo exactly the crispness the integer scale above exists for.
        //
        // 🔴 A mood frame mirrors correctly about this SAME origin, and that
        // is arithmetic rather than luck: the mood image spans
        // -pad*s .. (w + pad)*s, whose midpoint is w*s/2 — petGrid.width / 2
        // exactly. The mood canvas is therefore symmetric about the mirror
        // axis, so a mirrored mood body lands where a mirrored idle body
        // would, and a prop drawn to the pet's right appears on its left
        // when it turns round, which is what a prop should do.
        //
        // ⚠️ Composes with the two transforms already on this Item —
        // eggWobble's `rotation` and eggBump's `scale` — because all three
        // turn about the same centre. They also never co-occur with a flip:
        // both are egg-only and the gate below makes an egg unmirrorable.
        //
        // 🔴 Gated on the stage: an egg has no direction, and a pet that
        // died facing left must not leave its successor's egg mirrored.
        //
        // 🔴 Aggiunto dal porting (modifica 7): il secondo Scale e' la
        // PROSPETTIVA — il pet in cima al rilievo e' lontano, e una cosa
        // lontana e' piu' piccola. Sta in una lista insieme allo specchio
        // invece che dentro di esso perche' i due hanno origini diverse e
        // ragioni diverse: lo specchio gira attorno al centro, questo
        // rimpicciolisce attorno ai PIEDI (`origin.y: petGrid.height`), che e'
        // l'unica origine per cui il pet resta appoggiato al suolo mentre
        // cambia misura. Con l'origine al centro si staccherebbe dalla curva
        // di mezza altezza persa, ed e' proprio la cosa che `groundY()`
        // esiste per non far succedere.
        //
        // ⚠️ I due commutano, quindi l'ordine nella lista non conta: lo
        // specchio e' ±1 attorno a `width / 2` e la scala e' uniforme attorno
        // a un'origine che sta sulla stessa ascissa. Verificato in aritmetica,
        // non lasciato al caso — e vale anche per `eggBump`, che anima la
        // `scale` dell'Item attorno al suo centro.
        //
        // ⚠️ QUI la nitidezza si paga, ed e' voluto: `spriteScale` e' intero
        // apposta perche' un ingrandimento frazionario da' pixel di larghezza
        // diversa, e questo e' frazionario per definizione. La differenza e'
        // che quello e' la misura di riposo del pet — quella che si guarda
        // ferma — e questo e' il pet che cammina su una collina: si vede il
        // movimento, non la griglia. Con `terrainDepth: 0` non esiste, e con
        // il terreno spento non e' mai diverso da 1.
        transform: [
          Scale {
            origin.x: petGrid.width / 2
            xScale: root.facingLeft && root.pet.stage !== "egg" ? -1 : 1
          },
          Scale {
            origin.x: petGrid.width / 2
            origin.y: petGrid.height
            // ⚠️ Nessun `Behavior` su questi due, e non per dimenticanza: il
            // valore insegue `petFracX`, che e' gia' animato, quindi un
            // Behavior riavvierebbe un'animazione a ogni fotogramma della
            // camminata — e la scala arriverebbe sulla cima della collina
            // dopo i piedi, che sul suolo non sono animati.
            xScale: root.depthScale
            yScale: root.depthScale
          }
        ]
        // ⚠️ Rounded. An integer SIZE is only half of crisp pixel art: drawn
        // at a fractional x the same texture is sampled half a pixel off and
        // the edges shimmer as the pet walks.
        x: Math.round(root.pet.stage === "egg"
           ? (roomArea.width - width) / 2
           : root.unit * 2 + root.petFracX * Math.max(1, roomArea.width - root.unit * 4 - width))
        // ⚠️ Clamped at 0: at the bottom of the panel-height range the pet
        // can be taller than the space above the floor, and an unclamped
        // subtraction puts it at a negative y — drawn out of the room and
        // over the header. Pinned to the room's top edge instead, with
        // roomArea's clip catching whatever still does not fit.
        // ⚠️ `breathLift` is INSIDE the Math.max, not subtracted after it:
        // outside, a pet already pinned at y = 0 in the shortest panels
        // would be lifted to a negative y and drawn over the header. It is
        // exactly 0 at every level below 3, so this expression is
        // arithmetically identical to the shipped one for a well pet.
        // 🔴 `baseboard.y` e' diventato `root.groundY(root.petFracX)`: il suolo
        // sotto il pet, che col terreno spento E' baseboard.y e col terreno
        // acceso e' la curva. Tutto il resto dell'espressione — i tre casi, i
        // Math.max, il breathLift dentro e non fuori — resta com'era, e le
        // ragioni sono ancora quelle scritte qui sopra.
        y: Math.round(root.pet.stage === "egg"
           ? Math.max(0, root.groundY(0.5) - height - root.unit * 3)
           : Math.max(0, root.groundY(root.petFracX) - height - root.breathLift * root.spriteScale
                         - root.petFracY * Math.max(1, roomArea.height - baseboard.height - height)))

        // ---- THE PET, idle or in a mood ---------------------------------
        //
        // One Image draws both, and it is never tinted: a mood REPLACES the
        // idle frames rather than colouring them, which is the whole point
        // of those frames existing.
        //
        // ⚠️ There is exactly ONE overlay in the whole pipeline and it is
        // directly below — the sleep mark, which had to leave the body frame
        // because it is dark ink and the panel is dark. It draws no part of
        // the dragon; the body is still one Image and still untinted.
        //
        // 🔴 The geometry is written out rather than `anchors.fill: parent`
        // because a mood canvas is 8 source pixels larger than the idle
        // canvas on every side, and those 8 pixels must hang OUTSIDE petGrid
        // instead of squeezing the body into it. petGrid stays the idle size
        // — so the pet's position, its size, the mirror's origin and the
        // heart's centring are all untouched by mood — and the extra band is
        // spent on the bowl, the thought bubble and the sleep mark.
        //
        // ⚠️ With no mood, `moodInset` is 0 and `currentSprite` IS
        // `bodySprite`, so these four lines evaluate to (0, 0, petW, petH):
        // exactly what `anchors.fill: parent` produced. A well pet is drawn
        // by the same arithmetic it always was.
        //
        // ⚠️ Both offsets are negative, so a mood frame's outermost padding
        // can reach past roomArea's edge and be clipped there. Measured on
        // the 27 frames the table actually ships, the art inside that band
        // extends at most 6 source px to the right of the body canvas and
        // 1 px below it, against the 2 * unit == 6 * spriteScale of floor the
        // pet's own x binding always leaves at each end — so nothing the
        // frame holds is cut, at any panel size, mirrored or not.
        // 🔴 That budget is no longer only a comment: tests/logic-tests.js
        // decodes every frame forMood() can name and holds it.
        //
        // 🔴 `moodLift` is subtracted on Y and on Y ONLY. It is 0 for every
        // stage and for adult forms A and B, so this line is arithmetically
        // the shipped one for all of them; for adult C, whose idle art hovers
        // and whose mood art does not, it is the 3 source px that stop a
        // crowned pet dropping to the floor when it gets hungry. The highest
        // ink in any shipped mood frame is at canvas row 12, so lifting by 3
        // still leaves it inside the canvas and inside the room.
        Image {
          id: petSprite
          x: -root.moodInset
          y: -root.moodInset - root.moodLift
          width: root.currentSprite.w * root.spriteScale
          height: root.currentSprite.h * root.spriteScale
          source: Qt.resolvedUrl(root.displayFrame)
          sourceSize.width: root.currentSprite.w
          sourceSize.height: root.currentSprite.h
          smooth: false
          mipmap: false
        }

        // ---- THE SLEEP MARK ----------------------------------------------
        //
        // The zZ beside the sleeping head, lifted out of the
        // frame above so it can be recoloured, and drawn back over it. Same
        // reasoning and same mechanism as the sleep EFFECT further down:
        // where the art lives is an extraction decision, how it sits on a
        // given theme is a rendering one.
        //
        // 🔴 THE GEOMETRY IS petSprite's, READ OFF petSprite — not recomputed
        // from the same inputs. The overlay PNG is the same padded canvas as
        // the mood frame with the same body offset inside it, so "the same
        // rectangle" is the whole registration story: the mark lands on the
        // pixel it occupies in the source frame at every spriteScale, and
        // it cannot drift when moodInset or moodLift is next touched, because there is
        // no second copy of that arithmetic to forget to update.
        //
        // 🔴 IT MIRRORS WITH THE PET, and that is a decision, not an
        // accident of where it is declared. The comment on petGrid's Scale
        // says a mirrored "z" reads as a rendering bug, and it is right about
        // the sleep EFFECT — that one is centred over the pet, so leaving it
        // unmirrored costs nothing. This mark is different: it is drawn at a
        // fixed offset from the HEAD. Left unmirrored it would sit over the
        // pet's back, or off it entirely, while the head faced the other way
        // — a mark that has come loose from the animal reads as a broken
        // sprite, where a mirrored letter reads at worst as a stylised one.
        // Counter-flipping it about its own centre was considered and is
        // WORSE: the trail ascends from the small z by the mouth to the big Z
        // furthest away, and un-flipping the group reverses that order, so
        // the trail would run backwards INTO the pet's head. Attachment and
        // direction beat letterform. This is also exactly what the art does
        // today, so nothing about the pet's turn changes but the colour.
        //
        // ⚠️ Empty for every stage and mood that ships no mark, including the
        // egg, which has no moods at all — those draw precisely what they
        // drew before this Item existed.
        Item {
          id: sleepMark
          visible: root.displayGlyph !== ""
          x: petSprite.x
          y: petSprite.y
          width: petSprite.width
          height: petSprite.height

          Image {
            id: sleepMarkImage
            anchors.fill: parent
            // Guarded: Qt.resolvedUrl("") resolves to this DOCUMENT, so an
            // unguarded binding would ask the image loader for Room.qml.
            source: root.displayGlyph !== "" ? Qt.resolvedUrl(root.displayGlyph) : ""
            sourceSize.width: root.currentSprite.w
            sourceSize.height: root.currentSprite.h
            smooth: false
            mipmap: false
            // 🔴 THE FALLBACK IS THE SOURCE INK, untouched. On the software
            // scenegraph a MultiEffect draws literally nothing, and there
            // the choice is between the frame as it was cut and no mark at
            // all. As cut it is correct on a light theme and invisible
            // on a dark one — which is exactly where this plugin already was
            // before the mark was cut out at all, so the fallback is never
            // worse than what shipped, and on real hardware it is never
            // reached.
            visible: !root.effectsAvailable
            layer.enabled: root.effectsAvailable
          }

          MultiEffect {
            anchors.fill: sleepMarkImage
            source: root.effectsAvailable ? sleepMarkImage : null
            visible: root.effectsAvailable
            // 🔴 `brightness: 1.0` IS LOAD-BEARING. MultiEffect's colorization
            // is not a tint, it is a MULTIPLY BY SOURCE LUMINANCE: its shader
            // computes `gray = dot(rgb, (0.299, 0.587, 0.114))` and then
            // `rgb = gray * colorizationColor`. Ink at luminance 0.13 comes
            // out at 0.13 of the foreground — still black, on a black panel.
            // Measured across six themes, colorization alone moves this glyph
            // from 1.00-1.41:1 to 1.00-1.41:1, which is to say nowhere.
            // Adding brightness first raises the premultiplied source above
            // 1.0, so `gray` saturates and the glyph becomes what it should
            // always have been: an ALPHA MASK painted in the theme's own
            // foreground, antialiasing intact. Same measurement then gives
            // 10.0-14.0:1 on the dark themes and 5.4-6.1:1 on the light ones.
            brightness: 1.0
            colorization: 1.0
            colorizationColor: PetColor.foreground
          }
        }

        SequentialAnimation {
          id: eggWobble
          running: root.pet.stage === "egg" && !root.memorialPending && root.panelOpen
          loops: Animation.Infinite
          // A stopped Animation leaves the property at whatever it last set
          // — it does not snap back to a bound default. Without this, a
          // hatch landing mid-wobble would leave the baby tilted forever.
          onRunningChanged: if (!running) petGrid.rotation = 0
          NumberAnimation { target: petGrid; property: "rotation"; to: 9; duration: 620; easing.type: Easing.InOutSine }
          NumberAnimation { target: petGrid; property: "rotation"; to: -9; duration: 620; easing.type: Easing.InOutSine }
        }

        MouseArea {
          anchors.fill: parent
          anchors.margins: -6
          cursorShape: Qt.PointingHandCursor
          enabled: root.pet.stage !== "egg" && !root.memorialPending
          onClicked: {
            root.burstHeart()
            root.petRequested()
          }
        }

        // A small always-available reaction to clicking the egg itself: a
        // quick squash-bump, purely visual, no stat effect (there is nothing
        // to affect yet) and nothing sent up to Panel.qml — so the very
        // first click anybody makes here produces something, not nothing.
        MouseArea {
          anchors.fill: parent
          anchors.margins: -6
          cursorShape: Qt.PointingHandCursor
          enabled: root.pet.stage === "egg" && !root.memorialPending
          onClicked: root.burstEggBump()
        }

        SequentialAnimation {
          id: eggBump
          NumberAnimation { target: petGrid; property: "scale"; to: 1.18; duration: 90; easing.type: Easing.OutQuad }
          NumberAnimation { target: petGrid; property: "scale"; to: 1.0; duration: 170; easing.type: Easing.InOutQuad }
        }
      }

      Image {
        id: heartEffect
        property real targetY: 0
        source: Qt.resolvedUrl(root.heartSpec.frames[0])
        sourceSize.width: root.heartSpec.w
        sourceSize.height: root.heartSpec.h
        width: root.heartSpec.w * root.spriteScale
        height: root.heartSpec.h * root.spriteScale
        smooth: false
        mipmap: false
        opacity: 0
      }
      ParallelAnimation {
        id: heartAnim
        NumberAnimation { target: heartEffect; property: "opacity"; to: 0; duration: 650; easing.type: Easing.InQuad }
        NumberAnimation { target: heartEffect; property: "y"; to: heartEffect.targetY; duration: 650; easing.type: Easing.OutQuad }
      }

      // 🔴 The one PROP that cannot be drawn as it was cut. Its mean opaque
      // ink measures rgb(29,28,29), which is the same near-black every dark
      // theme paints its own panel card in — the sleep marks are dark ink on
      // a white ground, and on that card they are, measurably,
      // not visible: 1.00-1.41:1 across four dark palettes. Recoloured at render time to the
      // theme's foreground rather than repainted in the asset, because where
      // the art lives is an extraction decision and how it sits on a given
      // theme is a rendering one.
      //
      // ⚠️ The BAKED-IN zZ inside the tired mood frames had the same problem
      // and now takes the same route; see THE SLEEP MARK inside petGrid,
      // which carries the full derivation of the two effect properties below.
      Item {
        id: sleepEffect
        property real targetY: 0
        width: root.sleepSpec.w * root.spriteScale
        height: root.sleepSpec.h * root.spriteScale
        opacity: 0

        Image {
          id: sleepImage
          anchors.fill: parent
          source: Qt.resolvedUrl(root.sleepSpec.frames[0])
          sourceSize.width: root.sleepSpec.w
          sourceSize.height: root.sleepSpec.h
          smooth: false
          mipmap: false
          // Hidden but layered: the effect below samples it as a texture,
          // and drawing the near-black original underneath would only muddy
          // the recoloured copy. Same shape as the shell's own tray icon.
          // The layer itself is switched off where no shader can consume it,
          // so no offscreen surface is allocated for nothing.
          visible: false
          layer.enabled: root.effectsAvailable
        }

        // 🔴 THE FALLBACK, and why it is a letter rather than the sprite:
        // the tinted copy below is drawn by a shader, and on the SOFTWARE
        // scenegraph a MultiEffect draws nothing at all. With the original
        // hidden (it has to be — near-black ink on a near-black panel is
        // what the tint exists to fix) the sleep button would have had no
        // feedback whatsoever on such a machine. Re-tinting is exactly what
        // is unavailable here, and the mark occupies a small off-centre
        // patch of its canvas, so a backing plate would be a pale slab with
        // the ink in one corner. The art's own mark IS the letter z; drawn
        // as text it needs no shader, no palette and no knowledge of where
        // in the PNG the ink happens to sit.
        Text {
          textFormat: Text.PlainText
          visible: !root.effectsAvailable
          anchors.centerIn: parent
          text: "z"
          color: PetColor.foreground
          font.family: PetStyle.font.family
          font.bold: true
          font.pixelSize: Math.max(12, root.spriteScale * 14)
        }

        MultiEffect {
          anchors.fill: sleepImage
          source: root.effectsAvailable ? sleepImage : null
          visible: root.effectsAvailable
          // 🔴 `brightness: 1.0` and the reason for it are written out in full
          // over the sleep MARK above. Short version: colorization multiplies
          // by source luminance, so on its own it recoloured this near-black
          // prop to a near-black version of the foreground and left it at
          // 1.00-1.41:1 against the dark themes — the comment above this Item
          // described a fix that the shader was not performing. With the
          // brightness step the mean ink of sleep_1.png measures 10.0-14.0:1
          // on four dark themes and 5.7-6.1:1 on two light ones.
          brightness: 1.0
          colorization: 1.0
          colorizationColor: PetColor.foreground
        }
      }
      ParallelAnimation {
        id: sleepAnim
        NumberAnimation { target: sleepEffect; property: "opacity"; to: 0; duration: 900; easing.type: Easing.InQuad }
        NumberAnimation { target: sleepEffect; property: "y"; to: sleepEffect.targetY; duration: 900; easing.type: Easing.OutQuad }
      }

      // ---- Aggiunto dal porting (modifica 10): il cartellino di che cosa e'
      //      caduto, in cima alla stanza.
      //
      // 🔴 Dichiarato per ULTIMO fra i figli della stanza, e non e' un caso:
      // in QML l'ordine di dichiarazione e' l'ordine di disegno, e questo deve
      // stare sopra il pet, gli oggetti e le molecole — sotto ci finirebbe
      // proprio nel momento in cui c'e' qualcosa da leggere.
      Rectangle {
        id: noticeCard

        // Il testo si tiene anche quando `notice` torna nullo: la dissolvenza
        // dura piu' del cambio, e senza questa copia l'ultimo mezzo secondo di
        // cartellino sarebbe un rettangolo vuoto.
        property var shown: null

        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        anchors.topMargin: root.unit
        width: Math.min(parent.width - root.unit * 2, noticeRow.implicitWidth + root.unit * 2)
        height: noticeRow.implicitHeight + root.unit
        radius: PetStyle.cornerRadius
        color: Qt.rgba(PetColor.surface.r, PetColor.surface.g, PetColor.surface.b, 0.92)
        border.width: 1
        border.color: noticeCard.shown && noticeCard.shown.kind === "malus" ? PetColor.urgent : PetColor.accent

        opacity: 0
        // Invisibile vuol dire anche fuori dai clic: il cartellino sta sopra la
        // stanza, e la stanza si clicca per accarezzare il pet.
        visible: opacity > 0

        Behavior on opacity {
          NumberAnimation { duration: 220; easing.type: Easing.InOutQuad }
        }

        Timer {
          id: noticeTimer

          interval: root.noticeSeconds * 1000
          onTriggered: noticeCard.opacity = 0
        }

        Connections {
          target: root

          function onNoticeChanged() {
            if (!root.notice) {
              noticeCard.opacity = 0;
              return;
            }
            noticeCard.shown = root.notice;
            noticeCard.opacity = 1;
            noticeTimer.restart();
          }
        }

        Row {
          id: noticeRow

          anchors.centerIn: parent
          spacing: PetStyle.spacing.xs

          Text {
            textFormat: Text.PlainText
            anchors.verticalCenter: parent.verticalCenter
            text: noticeCard.shown ? noticeCard.shown.glyph : ""
            // La stessa scelta della riga delle statistiche: l'emoji alla
            // misura del corpo, perche' alla misura del font arcade non si
            // riconoscerebbe piu'.
            font.family: "Noto Color Emoji"
            font.pixelSize: PetStyle.font.body
          }

          Text {
            textFormat: Text.PlainText
            anchors.verticalCenter: parent.verticalCenter
            width: Math.min(implicitWidth, roomArea.width - root.unit * 4 - PetStyle.font.body * 2)
            elide: Text.ElideRight
            text: noticeCard.shown ? noticeCard.shown.text : ""
            color: PetColor.foreground
            font.family: PetStyle.arcadeFamily
            font.pixelSize: PetStyle.arcadeBody
          }
        }
      }
    }

    // ---- Care actions ------------------------------------------------------
    Row {
      id: actionsRow
      visible: root.pet.stage !== "egg"
      width: parent.width
      spacing: PetStyle.spacing.sm
      Button { text: I18n.t("Cibo"); enabled: !root.memorialPending; onClicked: root.careRequested("feed") }
      Button { text: I18n.t("Gioca"); enabled: !root.memorialPending; onClicked: root.careRequested("play") }
      Button { text: I18n.t("Pulisci"); enabled: !root.memorialPending; onClicked: root.careRequested("clean") }
      Button {
        text: I18n.t("Dormi")
        enabled: !root.memorialPending
        onClicked: { root.burstSleepMark(); root.careRequested("sleep") }
      }

      // Aggiunto dal porting (modifica 10). Un'icona sola e nessuna parola,
      // per due ragioni: sta in fondo a una riga che in tedesco e' gia' al
      // limite della colonna, e il simbolo dell'altoparlante barrato dice da
      // solo quello che direbbe la parola, in tutte e sei le lingue.
      //
      // ⚠️ Non e' disabilitato durante la cerimonia, al contrario delle quattro
      // cure: quelle agiscono sul pet — che in quel momento e' morto — mentre
      // questo e' un interruttore dell'interfaccia, e uno che si prende un
      // suono a sorpresa deve poterlo spegnere anche li'.
      Button {
        text: root.soundOn ? "🔊" : "🔇"
        onClicked: root.soundToggled()
      }
    }
  }

  // ---- La cerimonia ------------------------------------------------------
  // Arrivata qui da Panel.qml del plugin (righe 695-790), dove stava dentro la
  // finestra flottante di Omarchy. Ci sta bene: e' disegno, `memorialPending`
  // questo file lo conosce gia', e tenendola qui la lapide si risolve con la
  // stessa Qt.resolvedUrl() di tutti gli altri sprite — da panels/ avrebbe
  // cercato in panels/assets/.
  //
  // Non e' una punizione: e' un cartellino sobrio che dice il nome, l'eta' e
  // la generazione, e consegna l'uovo che aspetta gia'. Dichiarata dopo
  // mainColumn perche' deve dipingere sopra la stanza.
  Rectangle {
    id: memorial
    anchors.fill: parent
    visible: root.memorialPending
    color: Qt.rgba(0, 0, 0, 0.5)

    // Si mangia i clic destinati alla stanza qui sotto.
    MouseArea { anchors.fill: parent }

    Rectangle {
      anchors.centerIn: parent
      width: parent.width * 0.82
      radius: PetStyle.cornerRadius
      color: PetColor.surface
      border.width: 1
      border.color: PetColor.border
      // Mai piu' alta dello spazio in cui e' centrata: al minimo dell'altezza
      // regolabile il contenuto e' piu' alto della stanza, e senza questo la
      // carta uscirebbe tagliata da tutte e due le parti insieme.
      height: Math.min(root.height,
                       memorialColumn.implicitHeight + PetStyle.spacing.lg * 2)

      Column {
        id: memorialColumn
        anchors.centerIn: parent
        spacing: PetStyle.spacing.sm
        width: parent.width - PetStyle.spacing.lg * 2

        // La lapide e' disegnata alla SUA scala intera, non a quella della
        // stanza: la carta e' una frazione costante del pannello, e prendere
        // la scala del pet la farebbe crescere dentro un cartellino che non
        // cresce. Due o tre, mai una frazione — a stanza bassa gli altri
        // cinque elementi ne lasciano per due.
        Image {
          id: tombImage
          anchors.horizontalCenter: parent.horizontalCenter
          readonly property var spec: Sprites.prop("tomb")
          readonly property int tombScale:
            Math.max(2, Math.min(3, Math.floor((root.height - 150) / tombImage.spec.h)))
          source: Qt.resolvedUrl(tombImage.spec.frames[0])
          sourceSize.width: tombImage.spec.w
          sourceSize.height: tombImage.spec.h
          width: tombImage.spec.w * tombImage.tombScale
          height: tombImage.spec.h * tombImage.tombScale
          smooth: false
          mipmap: false
        }

        Text {
          // L'altra stringa che arriva dal file e finisce a schermo — vedi la
          // nota sul nome nell'intestazione. Pet.js la valida campo per campo
          // prima che passi di qui.
          textFormat: Text.PlainText
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          text: root.pet.lastMemorial ? root.pet.lastMemorial.name : ""
          color: PetColor.foreground
          font.family: PetStyle.font.family
          font.pixelSize: PetStyle.font.body
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          text: root.pet.lastMemorial
            ? I18n.t("Generazione %1 · vissuto %2")
                .arg(root.pet.lastMemorial.generation)
                .arg(root.ageText(root.pet.lastMemorial.ageMs))
            : ""
          color: PetColor.foreground
          opacity: 0.75
          font.family: PetStyle.font.family
          font.pixelSize: PetStyle.font.body
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          text: I18n.t("Un uovo nuovo aspetta.")
          color: PetColor.accent
          font.family: PetStyle.font.family
          font.pixelSize: PetStyle.font.body
        }

        Button {
          anchors.horizontalCenter: parent.horizontalCenter
          text: I18n.t("Continua")
          onClicked: root.memorialDismissed()
        }
      }
    }
  }

  // Il pulsante che prima veniva da qs.Ui. Stessa forma delle altre etichette
  // cliccabili della dashboard (vedi `Choice` in panels/HeartPanel.qml): un
  // riquadro largo quanto la parola che porta, che si accende al passaggio.
  //
  // `enabled` conta davvero: mentre la carta commemorativa e' a schermo i
  // quattro pulsanti restano visibili ma spenti, e uno spento deve *sembrare*
  // spento — altrimenti si preme e non succede niente, che e' l'unica cosa
  // peggiore di un pulsante assente.
  component Button: Rectangle {
    id: button

    property string text: ""
    property bool enabled: true

    signal clicked

    readonly property bool active: button.enabled && buttonHover.hovered

    implicitWidth: buttonLabel.implicitWidth + 16
    implicitHeight: Math.ceil(buttonLabel.implicitHeight) + 8
    radius: PetStyle.cornerRadius
    color: button.active ? PetColor.surfaceHover : "transparent"
    border.width: 1
    border.color: button.enabled ? (button.active ? PetColor.accent : PetColor.border)
                                 : PetColor.borderMuted

    Text {
      id: buttonLabel

      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: button.text
      color: !button.enabled ? PetColor.disabled
                             : (button.active ? PetColor.accent : PetColor.foreground)
      font.family: PetStyle.font.family
      font.pixelSize: PetStyle.font.body
    }

    HoverHandler {
      id: buttonHover

      cursorShape: button.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
    }

    TapHandler {
      onSingleTapped: {
        if (button.enabled)
          button.clicked();
      }
    }
  }

  // Every reference to this component's own properties is qualified through
  // `statBar`. Unqualified they resolved by walking the scope chain, which
  // works but is the same "it is found somewhere out there" pattern that hid
  // the delegate bug — and it is what qmllint was flagging alongside it.
  // Una statistica nella riga in cima: l'icona e il numero, e nient'altro —
  // il `component StatBar` che stava qui, etichetta piu' barra, non c'e' piu'.
  component StatCell: Item {
    id: cell
    required property string icon
    required property real value

    implicitHeight: cellGroup.implicitHeight

    // Il gruppo icona+numero, centrato nella cella. Le due misure sono diverse
    // apposta — vedi sotto — quindi si allineano al centro l'una dell'altra e
    // non a una baseline comune, che con un glifo bitmap a colori non vuol dire
    // niente.
    //
    // ⚠️ Le anchors stanno QUI DENTRO e non sui figli di un Row: i figli di un
    // positioner non possono usare le anchors, e Qt lo dice a runtime — una
    // riga di log invece di un layout.
    Item {
      id: cellGroup
      anchors.centerIn: parent
      implicitWidth: iconText.implicitWidth + PetStyle.spacing.xs + valueText.implicitWidth
      implicitHeight: Math.max(iconText.implicitHeight, valueText.implicitHeight)
      width: implicitWidth
      height: implicitHeight

      Text {
        textFormat: Text.PlainText
        id: iconText
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        text: cell.icon
        // 🔴 Alla misura del CORPO e non a quella del font arcade: a 8 px
        // un'emoji non si riconosce piu', e l'icona qui e' l'unica cosa che
        // dice DI QUALE statistica sia il numero — le etichette non ci sono
        // piu'. La famiglia e' dichiarata perche' e' il font a colori che si
        // vuole (verificato installato), non un fallback qualunque scelto da
        // Qt.
        font.family: "Noto Color Emoji"
        font.pixelSize: PetStyle.font.body
      }

      Text {
        textFormat: Text.PlainText
        id: valueText
        anchors.left: iconText.right
        anchors.leftMargin: PetStyle.spacing.xs
        anchors.verticalCenter: parent.verticalCenter
        text: Math.round(cell.value)
        // La soglia e' quella che aveva la barra: sotto 20 il colore d'allarme.
        // Senza barra e' il numero a portarlo, o l'unica cosa che diceva
        // «questa e' messa male» se ne andrebbe insieme al rettangolo.
        color: cell.value <= 20 ? PetColor.urgent : PetColor.foreground
        font.family: PetStyle.arcadeFamily
        font.pixelSize: PetStyle.arcadeBody
      }
    }
  }
}
