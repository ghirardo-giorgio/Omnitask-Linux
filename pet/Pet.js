.pragma library
// Pet.js — the whole simulation, as pure functions over a plain JS state
// object. Nothing in here touches QML, a file, or a process: it is called by
// Panel.qml, which owns persistence, and is trivially unit-testable outside
// Quickshell if anyone ever wants to (paste into `node`, it just runs).
//
// The load-bearing idea: everything is computed from (now - lastSeen), never
// from a per-tick simulation loop. That is what lets the pet "live" while the
// shell is closed, and it is also what makes the three long-absence traps
// solvable in closed form instead of by looping minute-by-minute through
// a two-month gap:
//   * a sickness window is tracked by its START timestamp (sickSince), not by
//     a counter that needs feeding every tick — so "how long has it been
//     continuously sick" is just `now - sickSince`, valid across a shell
//     restart of any length;
//   * death is evaluated ONCE per reconcile() call, against that one window,
//     so a two-month absence can produce at most one death no matter how far
//     past the threshold `now - sickSince` ends up being. The new egg's own
//     clock (lastSeen, bornAt) is reset to "now", not to "bornAt + leftover
//     time", so the remainder of the absence is never replayed against the
//     next generation.

// ---- Tuning constants ------------------------------------------------------
// All durations in milliseconds. Two very different clocks on purpose:
// the EGG is tuned so that somebody who has just installed this sees it hatch
// inside a minute; everything from baby onward is "slow, honest time".

var EGG_HATCH_MIN_MS = 60 * 1000
var EGG_HATCH_MAX_MS = 90 * 1000

var BABY_DURATION_MS = 60 * 60 * 1000        // 1 h as a baby
var CHILD_DURATION_MS = 3 * 60 * 60 * 1000   // 3 h as a child, then adult

// Time-to-zero for each stat's baseline passive decay, i.e. "how long could
// you ignore this stat, starting from full, before it bottoms out".
var HUNGER_ZERO_MS = 5 * 60 * 60 * 1000
var ENERGY_ZERO_MS = 8 * 60 * 60 * 1000
var HAPPINESS_ZERO_MS = 6 * 60 * 60 * 1000
var HYGIENE_ZERO_MS = 4 * 60 * 60 * 1000
// Extra hygiene decay per currently-uncleaned waste item, same units (points
// per ms) as the baseline rate below — ignoring waste makes hygiene fall
// faster, which is the whole reason waste matters mechanically.
var HYGIENE_WASTE_PENALTY_RATE = (100 / HYGIENE_ZERO_MS) * 0.6

var WASTE_INTERVAL_MS = 40 * 60 * 1000       // a new mess roughly every 40 min
var MAX_WASTE = 5

// 🔴 Waste is anchored, not ticked. `lastWasteAt` is the wall-clock instant
// the room was last accounted for — the moment the most recent mess appeared,
// or the moment it was last cleaned/frozen/hatched. It is to WASTE_INTERVAL_MS
// exactly what sickSince is to DEATH_SICK_MS, and it exists because the naive
// form of this rule silently destroyed time:
//
//     wasteCount += Math.floor(elapsedSinceLastTick / WASTE_INTERVAL_MS)
//
// Panel.qml runs an unconditional 60 s reconcile timer, so while anybody is
// watching `elapsedSinceLastTick` is 60000 and Math.floor(60000 / 2400000) is
// 0 — forever. The remainder was thrown away on every tick, so the room never
// got dirty while the panel was open, Clean had nothing to do, and the
// hygiene penalty and the wasteCount >= 3 sickness path never fired at all.
// Anchoring makes sixty 60 s ticks and one 3600 s tick produce the identical
// room, which is the property the whole reconcile design exists to hold.

// "Sustained neglect" — continuous, uninterrupted sickness for this long
// causes the death ceremony. Recovering even briefly (any care that pushes
// every stat back above zero) resets the clock, because the sickness is no
// longer continuous.
//
// Twelve hours, and the length is a deliberate trade, not a round number:
// the whole point of this plugin is the pet, so somebody who tries it,
// forgets it overnight and comes back should find the pet they left, not a
// tombstone. Working back from the code above gives the real budget. Hygiene
// is the fastest stat to bottom out (HYGIENE_ZERO_MS, four hours from full),
// and waste makes it faster still: a mess every forty minutes, each adding
// HYGIENE_WASTE_PENALTY_RATE (15 points/hour) on top of the baseline 25, so
// from full stats hygiene reaches zero at 2 h 17 min, not four hours. That
// is when sickSince is stamped, and death lands DEATH_SICK_MS after it:
//
//     2 h 17 min  +  12 h  =  ~14 h 17 min, full stats to ceremony
//
// (If the shell was off for the whole absence, one reconcile spans the gap,
// no waste accrues along the way and hygiene takes its unpenalised four
// hours — so that path is 16 h. 14 h 17 min is the worst case of the two.)
var DEATH_SICK_MS = 12 * 60 * 60 * 1000

// The ceiling on how much decay one absence may apply, so a very long one
// cannot land as a wall of damage. Chosen generously (a month) — the actual
// protection against "reopening after two months churns through nine
// generations" is the one-window death rule above, not this number; this is
// the belt, that is the suspenders.
var MAX_ELAPSED_MS = 30 * 24 * 60 * 60 * 1000

var STAT_MIN = 0
var STAT_MAX = 100

var NAMES = [
  "Puff", "Nib", "Coro", "Miso", "Blip", "Yuzu", "Toffi", "Pixi",
  "Dott", "Mochi", "Wobo", "Suzu", "Chirp", "Bram", "Kip", "Lumi"
]

// The longest name this file ever writes is 5 characters. The cap is generous
// on purpose — it exists to bound what comes back OUT of the save file, not to
// second-guess what went in.
var MAX_NAME_LEN = 24

// ---- Small helpers ---------------------------------------------------------

function clamp(v, lo, hi) {
  if (typeof v !== "number" || isNaN(v)) return lo
  return Math.max(lo, Math.min(hi, v))
}

function clampStat(v) { return clamp(v, STAT_MIN, STAT_MAX) }

function isFiniteNumber(v) { return typeof v === "number" && isFinite(v) }

function pickName() {
  return NAMES[Math.floor(Math.random() * NAMES.length)]
}

// Every string that comes back out of the save file and can reach the screen
// goes through here first. The file is user-writable and the shell process
// that renders it runs for days, so what is read back is treated as hostile
// input rather than as something this code wrote.
//
// Truncation, not rejection: an over-long name is a wrong name, not evidence
// that the whole save is corrupt, and the rule everywhere else in this file is
// to keep whatever can still be read. Returns "" when nothing usable survives,
// so each caller picks its own fallback rather than inheriting one.
function sanitizeDisplayString(v) {
  if (typeof v !== "string") return ""
  // Control characters and line breaks go first and unconditionally: a newline
  // in the header row is a layout defect quite apart from anything else.
  // Control characters and line breaks go first and unconditionally: a newline
  // in the header row is a layout defect quite apart from anything else.
  var cleaned = v.replace(/[\u0000-\u001F\u007F]/g, "")
  // 🔴 Then the three characters that can make a string parse as markup, and
  // THIS is the load-bearing line. Text.PlainText on every Text inside this
  // plugin is not enough, because the name does not stay inside this plugin:
  // BarWidget hands it to the bar's tooltip, which is Omarchy's own component
  // rendering with the default Text.AutoText — not ours to change, and it can
  // change again without us. A value that leaves this file has to be inert
  // wherever it lands, including in sinks that do not exist yet. Without < >
  // and & there is no tag and no entity for any renderer to find.
  cleaned = cleaned.replace(/[<>&]/g, "").trim()
  if (cleaned.length > MAX_NAME_LEN) cleaned = cleaned.slice(0, MAX_NAME_LEN).trim()
  return cleaned
}

// The memorial is the one part of the save that outlives the pet it describes,
// and both of its display fields reach a Text element. It is validated field
// by field like every other object in sanitizeState(), never accepted whole.
//
// 🔴 A memorial that cannot yield a name is discarded outright rather than
// shown under an invented one. Same rule as the waste anchor below: fail to
// *unknown*, never to *plausible*. Showing a random name over the grave of the
// pet somebody actually lost would be a lie, and the caller already knows how
// to have no memorial at all.
function sanitizeMemorial(v) {
  if (!v || typeof v !== "object") return null
  var name = sanitizeDisplayString(v.name)
  if (name.length === 0) return null
  return {
    name: name,
    ageMs: (isFiniteNumber(v.ageMs) && v.ageMs >= 0) ? v.ageMs : 0,
    generation: (isFiniteNumber(v.generation) && v.generation >= 1) ? Math.floor(v.generation) : 1
  }
}

function randomHatchDuration() {
  return EGG_HATCH_MIN_MS + Math.floor(Math.random() * (EGG_HATCH_MAX_MS - EGG_HATCH_MIN_MS))
}

// Formats an age in ms as something a memorial/badge can show, e.g.
// "3h 12m", "2d 4h", "41m". Never negative, never empty.
function formatAge(ms) {
  var total = Math.max(0, Math.floor((isFiniteNumber(ms) ? ms : 0) / 1000))
  var days = Math.floor(total / 86400)
  var hours = Math.floor((total % 86400) / 3600)
  var mins = Math.floor((total % 3600) / 60)
  if (days > 0) return days + "d " + hours + "h"
  if (hours > 0) return hours + "h " + mins + "m"
  if (mins > 0) return mins + "m"
  return "under a minute"
}

// ---- Fresh state ------------------------------------------------------------

// `carry` optionally carries forward what survives a death or a corrupt-file
// reset: the generation counter, and (only from an actual death) the
// memorial to show once. Both are optional; callers that have nothing to
// carry just pass {}. `nowMs` is likewise optional — reconcile() is careful
// to pass its own clock through so the whole call stays a pure function of
// its argument (see the death branch below); call sites outside reconcile()
// have no such clock in scope and are fine falling back to Date.now().
//
// 🔴 TWO different freezes, and an egg gets exactly one of them:
//
//   * `memorialSeen: false` — set only on an egg a DEATH produced. Frozen
//     until the ceremony for the previous generation is dismissed.
//   * `awaitingFirstOpen: true` — set on every OTHER fresh egg, i.e. the
//     one a first install (or a corrupt-state reset) produces. Frozen until
//     the panel is genuinely opened by a human for the first time.
//
// The second one exists because BarWidget.qml holds an always-active Loader:
// Panel.qml — and therefore this state object — is constructed at SHELL
// LOAD, not at first open. Without the freeze, somebody who installs the
// plugin at 09:00 and clicks the bar icon at 11:00 opens onto an adult pet
// and never sees the hatch, which is the whole point of the thing. They are
// deliberately mutually exclusive: a reborn egg must NOT also wait for a
// "first open" that has already happened, or it would never hatch at all.
function freshEgg(carry, nowMs) {
  carry = carry || {}
  var now = isFiniteNumber(nowMs) ? nowMs : Date.now()
  return {
    stage: "egg",
    adultForm: "",
    generation: isFiniteNumber(carry.generation) && carry.generation >= 1 ? Math.floor(carry.generation) : 1,
    name: pickName(),
    bornAt: now,
    hatchDurationMs: randomHatchDuration(),
    stageEnteredAt: now,
    lastSeen: now,
    hunger: STAT_MAX,
    energy: STAT_MAX,
    happiness: STAT_MAX,
    hygiene: STAT_MAX,
    wasteCount: 0,
    lastWasteAt: now,
    sick: false,
    sickSince: null,
    careScore: 0,
    lastMemorial: carry.lastMemorial || null,
    memorialSeen: carry.lastMemorial ? false : true,
    awaitingFirstOpen: carry.lastMemorial ? false : true
  }
}

// ---- Naming ----------------------------------------------------------------

// The one string a user puts into the save file on purpose. It goes through
// exactly the same gate as a string read back OUT of that file — one bound,
// not two that can drift apart the first time somebody edits only one of them.
//
// A name that survives nothing leaves the pet's current one alone rather than
// blanking the header: clearing the box is not a request to be nameless, and
// there is no way to express that anyway. Returns the SAME object when nothing
// changed, so the caller can skip a needless write to disk.
function withName(state, rawName) {
  var name = sanitizeDisplayString(rawName)
  if (name.length === 0 || name === state.name) return state
  var next = {}
  for (var k in state) next[k] = state[k]
  next.name = name
  return next
}

// ---- Corrupt/partial state recovery ----------------------------------------
//
// Called with whatever FileView handed back — which may be "" (file absent,
// FileView.onLoadFailed), or garbage (truncated write, a hand edit, a future
// version's schema). Never throws; always returns a valid state.
function sanitizeState(rawText) {
  var text = typeof rawText === "string" ? rawText : ""
  var parsed = null
  try {
    parsed = JSON.parse(text)
  } catch (e) {
    parsed = null
  }

  if (parsed === null || typeof parsed !== "object") {
    // Unreadable. Best-effort salvage of just the generation counter from
    // the raw bytes — it is kept if it can still be read at all, by a regex
    // scan rather than a parse, so even a file that is JSON-shaped garbage
    // everywhere else still keeps its generation.
    var carry = {}
    var m = /"generation"\s*:\s*(\d+)/.exec(text)
    if (m) {
      var g = parseInt(m[1], 10)
      if (isFiniteNumber(g) && g >= 1) carry.generation = g
    }
    return freshEgg(carry)
  }

  // Structurally present but possibly wrong-typed fields: validate every one
  // individually rather than trusting the object wholesale. Anything that
  // doesn't check out falls back to a fresh egg, but a valid generation
  // counter sitting next to broken fields is still preserved — a stat being
  // garbage is not evidence the generation counter is.
  var stage = parsed.stage
  var validStage = (stage === "egg" || stage === "baby" || stage === "child" || stage === "adult")
  var generation = isFiniteNumber(parsed.generation) && parsed.generation >= 1 ? Math.floor(parsed.generation) : null

  if (!validStage) {
    return freshEgg({ generation: generation })
  }

  var bornAt = isFiniteNumber(parsed.bornAt) ? parsed.bornAt : null
  var lastSeen = isFiniteNumber(parsed.lastSeen) ? parsed.lastSeen : null
  if (bornAt === null || lastSeen === null) {
    return freshEgg({ generation: generation })
  }

  var memorial = sanitizeMemorial(parsed.lastMemorial)

  var state = {
    stage: stage,
    adultForm: (parsed.adultForm === "A" || parsed.adultForm === "B" || parsed.adultForm === "C") ? parsed.adultForm : "",
    generation: generation || 1,
    name: sanitizeDisplayString(parsed.name) || pickName(),
    bornAt: bornAt,
    hatchDurationMs: isFiniteNumber(parsed.hatchDurationMs) ? parsed.hatchDurationMs : randomHatchDuration(),
    stageEnteredAt: isFiniteNumber(parsed.stageEnteredAt) ? parsed.stageEnteredAt : bornAt,
    lastSeen: lastSeen,
    hunger: isFiniteNumber(parsed.hunger) ? clampStat(parsed.hunger) : STAT_MAX,
    energy: isFiniteNumber(parsed.energy) ? clampStat(parsed.energy) : STAT_MAX,
    happiness: isFiniteNumber(parsed.happiness) ? clampStat(parsed.happiness) : STAT_MAX,
    hygiene: isFiniteNumber(parsed.hygiene) ? clampStat(parsed.hygiene) : STAT_MAX,
    wasteCount: isFiniteNumber(parsed.wasteCount) ? Math.max(0, Math.min(MAX_WASTE, Math.floor(parsed.wasteCount))) : 0,
    // 🔴 Save-format migration. A pet.json written before this field existed
    // has no `lastWasteAt` at all, and a live generation-1 pet can be in
    // exactly that state. The default is `lastSeen` — the last instant the
    // simulation is known to have run — so an old save loads as "the room was
    // accounted for when we last looked" and its first mess arrives one whole
    // WASTE_INTERVAL_MS later, with no burst on load. Defaulting to bornAt
    // instead would hand a months-old pet an instant roomful.
    // A present-but-nonsense value falls back to that same default rather
    // than being trusted. The accepted range is the only one the simulation
    // can ever write: reconcile() moves the anchor in whole intervals and
    // never leaves it more than one WASTE_INTERVAL_MS behind the clock, and
    // it can never be ahead of lastSeen. Anything outside that — a string, a
    // null, a NaN, a negative, a hand edit, a far-future timestamp from a
    // clock that ran backwards, or an anchor from a year ago — is not a
    // slightly-wrong anchor, it is not an anchor, so it defaults. That also
    // means a corrupt file can never burst the room on load.
    lastWasteAt: (isFiniteNumber(parsed.lastWasteAt)
                  && parsed.lastWasteAt <= lastSeen
                  && parsed.lastWasteAt >= lastSeen - WASTE_INTERVAL_MS)
                 ? parsed.lastWasteAt : lastSeen,
    sickSince: isFiniteNumber(parsed.sickSince) ? parsed.sickSince : null,
    careScore: isFiniteNumber(parsed.careScore) ? parsed.careScore : 0,
    lastMemorial: memorial,
    // ⚠️ Tied to the memorial itself, not read independently of it. A pending
    // ceremony with nothing to show would open a blank panel over a frozen
    // egg, so a discarded memorial takes its "unseen" flag with it — exactly
    // the invariant freshEgg() maintains at the other end.
    memorialSeen: (memorial !== null && parsed.memorialSeen === false) ? false : true,
    // 🔴 Backward compatibility: a pet.json written before this field
    // existed has no `awaitingFirstOpen` at all, and `undefined === true` is
    // false — so an already-living pet loads UNFROZEN, exactly as it did
    // before. The freeze can only ever be inherited by an egg: a file
    // claiming it on a hatched stage is ignored outright, so the flag can
    // never get stuck on a pet that has already been seen.
    awaitingFirstOpen: (stage === "egg") && parsed.awaitingFirstOpen === true
  }
  state.sick = state.sickSince !== null
  return state
}

function serializeState(state) {
  // A plain, explicit shape — never `JSON.stringify(state)` directly, so a
  // stray property never sneaks into the file and back out as if it had
  // meaning. Every field sanitizeState() knows how to read is written here.
  return JSON.stringify({
    stage: state.stage,
    adultForm: state.adultForm,
    generation: state.generation,
    name: state.name,
    bornAt: state.bornAt,
    hatchDurationMs: state.hatchDurationMs,
    stageEnteredAt: state.stageEnteredAt,
    lastSeen: state.lastSeen,
    hunger: state.hunger,
    energy: state.energy,
    happiness: state.happiness,
    hygiene: state.hygiene,
    wasteCount: state.wasteCount,
    lastWasteAt: state.lastWasteAt,
    sickSince: state.sickSince,
    careScore: state.careScore,
    lastMemorial: state.lastMemorial,
    memorialSeen: state.memorialSeen,
    awaitingFirstOpen: state.awaitingFirstOpen === true
  }, null, 2) + "\n"
}

// ---- Egg hatch progress, for the crack-stage art and a subtle countdown ----
//
// ⚠️ Nothing in the QML calls this, and that is not an oversight. Room.qml
// needs the same fraction as a BINDING that re-evaluates off its own
// one-second tick, and a binding cannot notice that the wall clock moved by
// calling a plain function — so `Room.qml`'s `hatchFrac` is a second copy of
// this rule, written where the tick is. Two copies of one rule is the hazard
// this file warns about elsewhere, so the copies are pinned together:
// tests/logic-tests.js pulls the expression out of Room.qml and checks it
// agrees with THIS function over a grid of eggs and clocks.
//
// 🔴 So do not delete this as dead code. Deleting it deletes the guard, and
// the QML copy is then free to drift on its own.
function hatchProgress(state, nowMs) {
  if (state.stage !== "egg") return 1
  // A frozen egg has made no progress by definition, whichever freeze holds
  // it. Its bornAt is still sitting at whenever the object happened to be
  // constructed, which for a never-opened egg is shell-load time and would
  // otherwise read as "fully cracked, hatching in 0s" the moment the panel
  // first paints.
  if (state.awaitingFirstOpen === true || state.memorialSeen === false) return 0
  var elapsed = nowMs - state.bornAt
  if (elapsed < 0) elapsed = 0 // clock skew: never negative progress
  return clamp(elapsed / Math.max(1, state.hatchDurationMs), 0, 1)
}

// ---- Which mood the pet is in, as a plain string ---------------------------
//
// This is a pure function of the state and nothing else: no clock, no art, no
// knowledge that mood art exists at all. It answers "how is this pet?"; which
// PNGs that becomes is Sprites.js's problem, and where they are drawn is
// Room.qml's. Keeping the three apart is what lets the whole selection be
// tested exhaustively in node over a grid of stat combinations.
//
// 🔴 The rule is fixed by design and is not open to improvement here:
//   1. sick               -> "sick"
//   2. else the LOWEST stat, if it is <= 20 -> hunger "hungry" · energy
//      "tired" · happiness "sad" · hygiene "angry"
//   3. else               -> "none", i.e. the ordinary idle art
//
// ⚠️ Ties resolve to the EARLIEST entry in the order written above, so the
// answer is deterministic and a reader can reproduce it by hand. That
// falls out of the strict `<` below — a later stat has to be genuinely lower
// to displace an earlier one — and it is the whole reason the comparison is
// not `<=`.
//
// ⚠️ An egg has no moods. It has no stats worth the name either, but the
// stage test is what makes that explicit rather than incidental.
//
// ⚠️ A non-numeric stat is skipped rather than treated as zero. sanitizeState
// guarantees numbers, so this can only fire on a hand-built object; skipping
// means the worst case is "no mood", never a mood chosen from a NaN.

// The same threshold the bar's attention dot and Room.qml's `anyStatLow`
// already use, so the bar, the room's behaviour and the pet's face agree
// about when something has started to go wrong.
var MOOD_LOW_STAT = 20

// 🔴 Order is load-bearing — it is the documented tie-break. Do not sort it.
var MOOD_BY_STAT = [
  { stat: "hunger", mood: "hungry" },
  { stat: "energy", mood: "tired" },
  { stat: "happiness", mood: "sad" },
  { stat: "hygiene", mood: "angry" }
]

function moodFor(state) {
  if (!state || state.stage === "egg") return "none"
  if (state.sick === true) return "sick"
  var bestMood = "none"
  var bestValue = 0
  for (var i = 0; i < MOOD_BY_STAT.length; i++) {
    var v = state[MOOD_BY_STAT[i].stat]
    if (!isFiniteNumber(v)) continue
    if (v > MOOD_LOW_STAT) continue
    if (bestMood === "none" || v < bestValue) {
      bestMood = MOOD_BY_STAT[i].mood
      bestValue = v
    }
  }
  return bestMood
}

// ---- The one function that advances time -----------------------------------
//
// Returns { state, justHatched, justDied }. `state` is always a full, valid
// state object — this never mutates its argument.
function reconcile(state, nowMs) {
  nowMs = isFiniteNumber(nowMs) ? nowMs : Date.now()

  if (state.stage === "egg") {
    // 🔴 An egg's clock can be FROZEN, and there are two reasons for it —
    // one mechanism, deliberately, so both behave identically (see the long
    // comment on freshEgg()).
    //
    // (1) memorialSeen === false — a reborn egg, frozen until its
    //     predecessor's death ceremony has been dismissed.
    //     Panel.dismissMemorial() is the only thing that flips it back, and
    //     it resets bornAt there to the moment of dismissal. Without this
    //     guard, a reconcile() call landing while the memorial is still on
    //     screen (the panel's reconcile Timer keeps ticking every 15s
    //     regardless of what overlay is showing) would hatch — or even walk
    //     this generation straight past baby into child/adult — entirely
    //     behind the still-displayed ceremony for the PREVIOUS generation,
    //     so the player never sees this generation's egg at all.
    //
    // (2) awaitingFirstOpen === true — a first-install egg, frozen until a
    //     human actually opens the panel. Panel.markFirstOpen() (via
    //     beginFirstOpen() below) is the only thing that flips it back, and
    //     it likewise resets bornAt to that instant. Panel.qml is
    //     constructed at SHELL LOAD by BarWidget.qml's always-active Loader,
    //     and Panel.qml also runs an unconditional 60s reconcile Timer so
    //     the BAR stays honest while the panel is closed — which together
    //     mean that without this guard the egg hatches, grows up and can
    //     even die entirely unobserved, and the one moment this whole
    //     design is built around — the first sixty seconds, the hatch —
    //     never happens for the person who installed it at all.
    //
    // Note this branch still advances lastSeen: the pet is "alive and
    // waiting", not paused mid-decay, and an egg has no stats to decay.
    if (state.memorialSeen === false || state.awaitingFirstOpen === true) {
      var frozen = {}
      for (var fk in state) frozen[fk] = state[fk]
      frozen.lastSeen = nowMs
      // A frozen pet accrues no waste AND banks none: the anchor rides
      // forward with the clock, so however long the freeze lasted, the
      // moment it lifts the room's accrual clock starts from now.
      frozen.lastWasteAt = nowMs
      return { state: frozen, justHatched: false, justDied: null }
    }
    var elapsedSinceBorn = nowMs - state.bornAt
    if (elapsedSinceBorn < 0) elapsedSinceBorn = 0 // clock skew: not hatched early because of it
    if (elapsedSinceBorn >= state.hatchDurationMs) {
      var hatched = {
        stage: "baby",
        adultForm: "",
        generation: state.generation,
        name: state.name,
        bornAt: state.bornAt,
        hatchDurationMs: state.hatchDurationMs,
        stageEnteredAt: nowMs,
        lastSeen: nowMs,
        hunger: STAT_MAX, energy: STAT_MAX, happiness: STAT_MAX, hygiene: STAT_MAX,
        wasteCount: 0,
        // A newborn's room is clean as of this instant, not as of whenever
        // the egg happened to be laid.
        lastWasteAt: nowMs,
        sick: false, sickSince: null,
        careScore: 0,
        lastMemorial: state.lastMemorial,
        memorialSeen: state.memorialSeen,
        // Unreachable while frozen (the guard above returns first), written
        // explicitly anyway because this object is built field-by-field
        // rather than copied — a missing field here would read back as
        // undefined and quietly re-freeze nothing.
        awaitingFirstOpen: false
      }
      return { state: hatched, justHatched: true, justDied: null }
    }
    var stillEgg = {}
    for (var k in state) stillEgg[k] = state[k]
    stillEgg.lastSeen = nowMs
    // An egg makes no mess, so its accrual clock has nothing to measure and
    // must not run up a debt to be paid the instant it hatches.
    stillEgg.lastWasteAt = nowMs
    return { state: stillEgg, justHatched: false, justDied: null }
  }

  // ---- baby / child / adult ------------------------------------------------
  var rawElapsed = nowMs - state.lastSeen
  var elapsed = rawElapsed < 0 ? 0 : Math.min(rawElapsed, MAX_ELAPSED_MS)

  var hungerRate = STAT_MAX / HUNGER_ZERO_MS
  var energyRate = STAT_MAX / ENERGY_ZERO_MS
  var happinessRate = STAT_MAX / HAPPINESS_ZERO_MS
  var hygieneRate = (STAT_MAX / HYGIENE_ZERO_MS) + state.wasteCount * HYGIENE_WASTE_PENALTY_RATE

  var stats = [
    { key: "hunger", start: state.hunger, rate: hungerRate },
    { key: "energy", start: state.energy, rate: energyRate },
    { key: "happiness", start: state.happiness, rate: happinessRate },
    { key: "hygiene", start: state.hygiene, rate: hygieneRate }
  ]

  var next = {}
  for (var kk in state) next[kk] = state[kk]

  var earliestZeroOffset = null
  for (var i = 0; i < stats.length; i++) {
    var s = stats[i]
    var ended = s.start - s.rate * elapsed
    next[s.key] = clampStat(ended)
    if (ended <= 0 && s.rate > 0) {
      var crossOffset = s.start / s.rate
      if (earliestZeroOffset === null || crossOffset < earliestZeroOffset) earliestZeroOffset = crossOffset
    }
  }

  // ---- Waste, accrued against the anchor (see lastWasteAt at the top) ----
  //
  // The anchor is bounded on both sides before it is used:
  //   * never later than now — a future timestamp from a hand-edited save or
  //     a clock that jumped backwards would otherwise yield negative elapsed;
  //   * never earlier than MAX_ELAPSED_MS ago, so a pet returned to after a
  //     year gets a month's worth of accrual and then the cap, not a year's.
  //
  // 🔴 The floor is MAX_ELAPSED_MS, deliberately NOT this tick's own `elapsed`.
  // Flooring at `nowMs - elapsed` would drag the anchor forward to the start
  // of every 60 s tick, which is the original defect wearing a new field name:
  // it re-derives "time since the last tick" and throws the remainder away
  // exactly as before. It would also mean a feed or a play — both of which
  // advance lastSeen without reconciling — silently wiped the room's accrual.
  var wasteAnchor = isFiniteNumber(state.lastWasteAt) ? state.lastWasteAt : state.lastSeen
  if (wasteAnchor > nowMs) wasteAnchor = nowMs
  if (wasteAnchor < nowMs - MAX_ELAPSED_MS) wasteAnchor = nowMs - MAX_ELAPSED_MS

  var produced = Math.floor((nowMs - wasteAnchor) / WASTE_INTERVAL_MS)
  var wasteCapacity = Math.max(0, MAX_WASTE - state.wasteCount)

  if (produced <= 0) {
    // Nothing yet — and crucially the anchor does NOT move, so the part of an
    // interval already served carries into the next tick. Thirty-nine minutes
    // plus two more minutes is a mess; it is not a restarted clock.
    next.wasteCount = state.wasteCount
    next.lastWasteAt = wasteAnchor
  } else if (produced > wasteCapacity) {
    // More was earned than the room can hold. Clamp, and advance the anchor
    // to NOW rather than banking the overflow: a player who lets the room
    // fill and then cleans it gets a clean room for a full interval, not one
    // that instantly re-fills from credit accumulated while it was already
    // full. The banked credit is therefore bounded by one WASTE_INTERVAL_MS.
    next.wasteCount = MAX_WASTE
    next.lastWasteAt = nowMs
  } else {
    // Exactly what was earned, and the remainder carries: the anchor moves
    // by whole intervals only, never to `nowMs`. This is what makes sixty
    // 60 s ticks and one 3600 s tick land on the same wasteCount AND the
    // same anchor.
    next.wasteCount = state.wasteCount + produced
    next.lastWasteAt = wasteAnchor + produced * WASTE_INTERVAL_MS
  }

  var neglectedNow = (next.hunger <= 0 || next.energy <= 0 || next.happiness <= 0 || next.hygiene <= 0)
  if (neglectedNow) {
    if (state.sickSince === null || state.sickSince === undefined) {
      // Newly neglected within this window: the sickness genuinely started
      // at the earliest computed zero-crossing, not "now" — an honest
      // continuous-neglect clock, not one that only starts once someone
      // happens to look.
      next.sickSince = state.lastSeen + (earliestZeroOffset || 0)
    } else {
      // Was already sick and still is: the window never closed, so the
      // start time does not move. This is what makes DEATH_SICK_MS mean
      // "continuous", not "cumulative".
      next.sickSince = state.sickSince
    }
  } else {
    next.sickSince = null
  }
  next.sick = next.sickSince !== null

  // ---- Death: at most one, per the analysis in the file header ----------
  if (next.sick && (nowMs - next.sickSince) >= DEATH_SICK_MS) {
    var memorial = { name: state.name, ageMs: nowMs - state.bornAt, generation: state.generation }
    var reborn = freshEgg({ generation: state.generation + 1, lastMemorial: memorial }, nowMs)
    return { state: reborn, justHatched: false, justDied: memorial }
  }

  // ---- Stage progression, purely on real time since birth ----------------
  var ageMs = nowMs - state.bornAt
  var childAt = state.hatchDurationMs + BABY_DURATION_MS
  var adultAt = childAt + CHILD_DURATION_MS

  if (next.stage === "baby" && ageMs >= childAt) {
    next.stage = "child"
    next.stageEnteredAt = nowMs
  }
  if ((next.stage === "child") && ageMs >= adultAt) {
    next.stage = "adult"
    next.stageEnteredAt = nowMs
    if (next.adultForm === "") next.adultForm = decideAdultForm(next, nowMs)
  }

  next.lastSeen = nowMs
  return { state: next, justHatched: false, justDied: null }
}

// Which adult you get is determined by accumulated care quality — care
// actions per hour alive, at the moment adulthood is reached.
function decideAdultForm(state, nowMs) {
  var hoursAlive = Math.max(0.01, (nowMs - state.bornAt) / (60 * 60 * 1000))
  var perHour = state.careScore / hoursAlive
  if (perHour >= 1.2) return "A"
  if (perHour >= 0.4) return "B"
  return "C"
}

// ---- Lifting the first-open freeze ------------------------------------------
//
// The counterpart to Panel.dismissMemorial(), and deliberately the same
// shape: flip the flag AND restart the egg's clock at this instant, because
// bornAt is still sitting at whenever the object was constructed (shell
// load, possibly hours ago). Without the bornAt reset the very next
// reconcile() would see an already-expired hatch window and hatch on the
// spot — which is the exact bug the freeze exists to prevent, just moved one
// call later.
//
// Idempotent and safe to call on anything: a state that is not waiting is
// returned untouched, so the panel can call this on every open without
// having to know whether it is the first one.
function beginFirstOpen(state, nowMs) {
  if (!state || state.awaitingFirstOpen !== true) return state
  var now = isFiniteNumber(nowMs) ? nowMs : Date.now()
  var out = {}
  for (var k in state) out[k] = state[k]
  out.awaitingFirstOpen = false
  // Only an egg has a clock to restart, and only if the memorial freeze is
  // not also holding it — in that case dismissMemorial() owns the reset and
  // doing it here as well would just move the same timestamp twice.
  if (out.stage === "egg" && out.memorialSeen !== false) {
    out.bornAt = now
    out.stageEnteredAt = now
  }
  out.lastSeen = now
  // The freeze banked nothing; unfreezing starts the accrual clock here.
  out.lastWasteAt = now
  return out
}

function refreshSickAfterCare(state) {
  var out = {}
  for (var k in state) out[k] = state[k]
  var neglected = (out.hunger <= 0 || out.energy <= 0 || out.happiness <= 0 || out.hygiene <= 0)
  if (!neglected) {
    out.sickSince = null
    out.sick = false
  }
  return out
}

// ---- Care actions -----------------------------------------------------------
// Every one is a no-op on an egg (nothing to feed yet) and always clamps.

function applyCare(state, action, nowMs) {
  if (state.stage === "egg") return state
  nowMs = isFiniteNumber(nowMs) ? nowMs : Date.now()
  var out = {}
  for (var k in state) out[k] = state[k]

  if (action === "feed") {
    out.hunger = clampStat(out.hunger + 40)
    out.happiness = clampStat(out.happiness + 5)
    out.careScore += 1
  } else if (action === "play") {
    out.happiness = clampStat(out.happiness + 30)
    out.energy = clampStat(out.energy - 8)
    out.careScore += 1
  } else if (action === "clean") {
    out.wasteCount = 0
    // Cleaning restarts the accrual clock. Without this the remainder that
    // had already built up would survive the sweep, and a room cleaned at
    // minute 39 of an interval would be dirty again a minute later — which
    // reads as the button not having worked.
    out.lastWasteAt = nowMs
    out.hygiene = clampStat(out.hygiene + 35)
    out.happiness = clampStat(out.happiness + 5)
    out.careScore += 1
  } else if (action === "sleep") {
    out.energy = clampStat(out.energy + 50)
    out.happiness = clampStat(out.happiness + 2)
    out.careScore += 1
  } else {
    return state
  }

  out.lastSeen = nowMs
  return refreshSickAfterCare(out)
}

// The click-the-pet interaction: it has to feel good above
// everything else in the plugin. Small, immediate, always-available, with a
// gentle diminishing return so it can't be macro'd into a full happiness bar
// in three seconds — but it is never disabled and never on a cooldown.
function applyPet(state, nowMs) {
  if (state.stage === "egg") return state
  nowMs = isFiniteNumber(nowMs) ? nowMs : Date.now()
  var out = {}
  for (var k in state) out[k] = state[k]
  var gain = Math.max(2, Math.round(8 * (1 - out.happiness / 100)))
  out.happiness = clampStat(out.happiness + gain)
  out.careScore += 0.25
  out.lastSeen = nowMs
  return refreshSickAfterCare(out)
}

function needsAttention(state) {
  // 🔴 The memorial test has to come BEFORE the egg test, not after it. A
  // pending memorial only ever sits on an EGG (freshEgg() is what sets
  // memorialSeen: false, and it only makes eggs), so with the egg test first
  // this branch was unreachable and the bar never once signalled that a
  // death had happened while the panel was closed — the single event most
  // worth coming back for.
  if (state.memorialSeen === false) return true
  // A never-opened egg is waiting, not needing: it must not wear the urgent
  // dot. BarWidget.qml invites the first click with a gentle rock and its
  // tooltip instead, which reads as deliberate rather than as an alarm.
  if (state.stage === "egg") return false
  if (state.sick) return true
  if (state.hunger <= 20 || state.energy <= 20 || state.happiness <= 20 || state.hygiene <= 20) return true
  if (state.wasteCount >= 3) return true
  return false
}

// Machine-mood: a load-average number in, an animation-speed
// multiplier out. Never fatal to anything — a null reading (couldn't read
// /proc, or not parseable yet) is neutral, not zero and not an error state.
function moodFactorFromLoad(load1) {
  if (!isFiniteNumber(load1) || load1 < 0) return 1.0
  if (load1 < 0.15) return 0.7 // machine's idle: drowsier, slower wander
  return Math.min(2.2, 1 + load1 * 0.5) // busier: livelier, shorter intervals
}
