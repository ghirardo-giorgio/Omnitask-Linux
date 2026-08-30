.pragma library
// Sprites.js — the frame-role map. It answers exactly one question: "which
// PNG do I draw for this state?" It holds no pixels, no palettes and no
// colours; every path below points at a file in assets/, cut from the
// design sheet by tools/slice_sheet.py.
//
// It replaced a file of dot patterns. That renderer gave every cell ONE
// theme role, which is a fine way to draw a shape and a hopeless way to draw
// this art: the dragon is multi-colour, outlined and shaded, and a
// one-role-per-cell grid turns it into a coloured blob. The panel chrome —
// text, stat bars, the card, the badges — is still fully theme-driven; the
// creature is not, because it is a drawing and drawings own their colours.
//
// ---- Paths are RELATIVE, and that is deliberate ----------------------
// Every string here is relative to the plugin root ("assets/pets/egg_1.png").
// The QML that consumes them wraps each one in Qt.resolvedUrl(), which
// resolves against the URL of the QML document doing the asking — all three
// of which live at the plugin root beside assets/. Keeping the absolute-URL
// step in QML rather than here is what lets this stay a `.pragma library`
// with no QML dependencies at all.
//
// ---- Sizes are SOURCE sizes ------------------------------------------
// `w`/`h` are the PNG's own pixel dimensions, never screen sizes. The caller
// multiplies by an INTEGER scale (Room.qml's spriteScale, or 1 in the bar).
// Nothing here may ever hand back a fractional size: a pixel-art sprite
// drawn at 1.5x gets uneven pixel widths and looks worse than no art at all.

// Canvas sizes, per stage, as produced by the slicer. One shared floor line
// per stage, so two frames of the same stage never disagree about where the
// ground is.
var SIZE_EGG   = { w: 48, h: 52 }
var SIZE_BABY  = { w: 52, h: 56 }
var SIZE_CHILD = { w: 56, h: 60 }
var SIZE_ADULT = { w: 64, h: 72 }
var SIZE_PROP  = { w: 32, h: 32 }
var SIZE_BAR   = { w: 20, h: 20 }

function petFrames(name, indices) {
  var out = []
  for (var i = 0; i < indices.length; i++)
    out.push("assets/pets/" + name + "_" + indices[i] + ".png")
  return out
}

// ---- Frame roles ------------------------------------------------------
//
// 🔴 THE ACCESSORY RULE, stated once so it is never broken: an idle loop
// must never mix a frame that HAS an accessory with one that does not. The
// satchel and the crown are the entire difference between adult B and adult
// C — blinking them on and off does not read as animation, it reads as a
// glitched pet. That is why B's loop starts at frame 4 and C's at frame 5
// rather than at the obvious frame 1.

// The egg is the exception: all six frames, indexed by hatch progress rather
// than by an idle tick. 1-2 are whole, 3-6 crack progressively, so the shell
// visibly comes apart across the hatch window instead of jumping.
var egg = { frames: petFrames("egg", [1, 2, 3, 4, 5, 6]), w: SIZE_EGG.w, h: SIZE_EGG.h }

// Both upright and the same height, so the idle swap reads as breathing
// rather than as the pet bobbing up and down.
var baby = { frames: petFrames("baby", [1, 6]), w: SIZE_BABY.w, h: SIZE_BABY.h }

// 🔴 The child row's six source frames vary 27% in height — frame 4 is the
// tallest of them. 1 and 6 are the closest pair; any loop containing 4 makes
// the child visibly grow and shrink on every tick.
var child = { frames: petFrames("child", [1, 6]), w: SIZE_CHILD.w, h: SIZE_CHILD.h }

// Form A: all six frames are the same height and none carries an accessory,
// so the pair is a free choice.
var adultA = { frames: petFrames("adult_a", [1, 6]), w: SIZE_ADULT.w, h: SIZE_ADULT.h }

// 🔴 Form B: the satchel only exists from frame 3 onwards. Frames 1-2 have
// no satchel and must stay out of the loop.
var adultB = { frames: petFrames("adult_b", [4, 6]), w: SIZE_ADULT.w, h: SIZE_ADULT.h }

// 🔴 Form C: the crown only exists from frame 5 onwards. Frames 3-4 have the
// wings but no crown, so they cannot be paired with 5 or 6.
var adultC = { frames: petFrames("adult_c", [5, 6]), w: SIZE_ADULT.w, h: SIZE_ADULT.h }

// Props are single-frame on purpose: they appear for well under a second
// (the heart, the sleep mark) or sit still (the waste, the marker), and an
// animated prop competes with the pet for the eye.
var props = {
  waste: { frames: ["assets/props/waste_1.png"], w: SIZE_PROP.w, h: SIZE_PROP.h },
  heart: { frames: ["assets/props/heart_1.png"], w: SIZE_PROP.w, h: SIZE_PROP.h },
  sleep: { frames: ["assets/props/sleep_1.png"], w: SIZE_PROP.w, h: SIZE_PROP.h },
  tomb:  { frames: ["assets/props/tomb_1.png"],  w: SIZE_PROP.w, h: SIZE_PROP.h }
}

// ---- 🔴 WHY assets/pets/ AND assets/props/ HOLD MORE THAN THIS FILE NAMES --
//
// The tables above reach 16 of the 36 files in assets/pets/ and 4 of the 16 in
// assets/props/. The other 32 (~100 KB) are the REMAINDER OF THE SLICED ROWS
// and they are kept deliberately, not left behind:
//
//   assets/pets/   adult_a_2..5 · adult_b_1,2,3,5 · adult_c_1..4 ·
//                  baby_2..5 · child_2..5                          (20 files)
//   assets/props/  waste_2..4 · heart_2..4 · sleep_2..4 ·
//                  tomb_2..4                                       (12 files)
//
// WHICH frames a loop uses is the one judgement in this file that is expected
// to move. Every reason a pair was picked — the accessory rule, the child
// row's 27% height spread, form C's airborne idle — is equally a reason it
// could be re-picked, and a complete row on disk makes that a two-number edit
// here. Prune to what is referenced today and the same change becomes a
// re-cut of the source sheet: a different task, with a different set of
// hazards, and this repository has already paid for a bad cut three times
// (a sheared crown, paper surviving between the legs, printed rule lines on a
// floor row). The frames are also the only place a replacement pair can come
// from, so pruning them forecloses the choice rather than tidying up after it.
//
// ⚠️ Stated cost rather than hidden: installing a plugin clones the whole
// repository, so those ~100 KB land on every machine that installs this one.
// At this size that is the price of the option and it is judged worth paying;
// at ten times it, it would not be.
//
// 🔴 tests/logic-tests.js asserts all 32 are present, exactly as it does for
// the six child_angry frames further down, so a later sweep for dead weight
// fails the suite instead of quietly closing a door. assets/moods/ is the
// other way round and is described at child_angry: everything there that this
// file cannot name was pruned except those six.

// ---- MOOD ART ---------------------------------------------------------
//
// There is a set of frames for the dragon sad, sick, hungry, tired and
// angry, and these are those frames. They replace the idle frames outright
// while the mood lasts —
// there is no tint, no filter and no overlay anywhere in the pipeline any
// more, because a colour wash over a drawing that already says "unwell" only
// muddies it.
//
// ---- Why the mood canvas is BIGGER, and why that does not move the pet ----
//
// A mood is usually a prop: a food bowl on the floor, a thought bubble beside
// the head, a sleep mark above it, a thermometer. Fit that into the idle
// canvas and either the body shrinks (so the pet changes size the moment it
// gets hungry) or the prop is amputated at the canvas edge (which is what
// shipped in an earlier cut — a thermometer reduced to three columns, a sleep
// mark reduced to a 6 px sliver that read as dirt).
//
// So a mood canvas is the idle canvas plus MOOD_PAD on EVERY side, and the
// slicer places the BODY inside it at exactly the offset it occupies in the
// idle canvas. The renderer then draws the mood Image inset by
// `-MOOD_PAD * spriteScale` on both axes. Body source pixel (xb, yb) lands at
// `petGrid.x + xb * scale` in both cases — algebraically identical, not
// approximately — so the pet neither moves nor resizes when its mood changes.
//
// 🔴 MOOD_PAD must stay a whole number: `MOOD_PAD * spriteScale` is a screen
// offset and spriteScale is an integer, so an integer pad is what keeps the
// sprite on the pixel grid. A fractional one resamples every mood frame.
//
// 🔴 The padded canvas is an even number of pixels wide in every stage
// (52/56/64 body + 2*8), so the mirror's `origin.x` — petGrid.width / 2,
// which is the IDLE width — stays whole, and the mood image's own centre
// coincides with it exactly: -8*s + (w + 16)*s / 2 == w*s / 2. A mirrored
// mood frame therefore lands where a mirrored idle frame would.
var MOOD_PAD = 8

// 🔴 THE FRAME TABLE. Chosen by eye from the contact sheet, one row per
// stage x mood. It is a DESIGN DECISION, not a measurement.
//
// Three rounds were spent teaching a program to infer, from pixels, which
// frames actually show a mood, and it was wrong three different ways: a
// detached-blob test missed a tear drawn attached to the cheek; a
// channel-difference colour space found palette drift rather than novelty; a
// saturation floor excluded the baby's paler tear. The machinery is deleted.
// There are fifteen rows of six frames; a person looked at them.
//
// ⚠️ Do NOT re-derive these numbers, and do NOT fall back to another frame
// when one looks unhelpful. Frame 1 of the adult sad / hungry / tired / angry
// rows is indistinguishable from idle at the panel sizes this plugin runs
// at, which is exactly why the table starts those loops later.
//
// `row` is the file prefix in assets/moods/; `frames` are its 1-based frame
// numbers, in the order they are looped. A one-frame loop is held, not
// animated — that is a fact about the art, stated rather than hidden.
//
// 🔴 `rests: true` marks a loop the pet must NOT be walked around in. It is
// authored here beside the frames, by the same eye and for the same reason:
// the pose is a fact about the drawing, so it belongs next to the drawing.
// See THE RESTING POSES below for what it costs and why it is not inferred.
//
// 🔴 `zz` lists the frames of a row that ship a SEPARATE sleep-mark overlay,
// `<row>_<n>_zz.png`, holding the drawn zZ and nothing else. See THE SLEEP
// MARK below for why the mark does not live in the body frame any more. The
// numbers are frame numbers, not indices into `frames`, so the two lists read
// the same way; a frame listed in `frames` but not in `zz` simply has no
// overlay, which is the normal case for every row except the tired ones.
var moodLoops = {
  baby_angry:   { row: "baby_angry",   frames: [1, 2] }, // steam puff, same pose both frames
  baby_hungry:  { row: "baby_hungry",  frames: [1, 2] }, // bowl on the floor in both
  baby_sad:     { row: "baby_sad",     frames: [3, 4] }, // tear visible, matched poses
  baby_sick:    { row: "baby_sick",    frames: [1, 2] }, // green body reads instantly
  // 🔴 rests: the baby stands, but it stands with its eyes shut under a zZ.
  // Uniform with the other two tired rows rather than special-cased by
  // stage — see THE RESTING POSES below.
  baby_tired:   { row: "baby_tired",   frames: [5, 6], rests: true, zz: [5, 6] }, // lidded eyes AND the zZ

  // ⛔ child + angry draws the child SAD frames. This is the single stage
  // exception to "every stage has its own art for every mood", and it exists
  // because the art is MISSING, not because of design: the child_angry row in
  // Pet_design_sheet_for_game_202608212222.png (y 4326..4617) is a bust —
  // head, neck, chest and front arms, no legs — cut off by the printed row
  // border of the source sheet. Re-measured, the gap from the
  // keyed body's lowest pixel to the cell's bottom border is -5, -2, -1, -1,
  // -1, 0 source px across the six frames: the drawing crosses its own
  // border, where every other row of the sheet clears it by 12 to 69. Because
  // a body is normalised on sqrt(silhouette area), that bust would scale to a
  // full body's footprint and stand a giant legless head on the floor line.
  // ⚠️ Consequence, stated and accepted: a dirty child and an unhappy child
  // look identical, and both are static. That is a ruling, not an accident.
  // 🔴 assets/moods/child_angry_1..6 STAY ON DISK, ON PURPOSE. Every other
  // mood frame this file cannot name was deleted before the repository was
  // published, so these six are now the only unreachable files in
  // assets/moods/ — and they are a drop-in, not a leftover. When the redrawn
  // row lands, this line becomes { row: "child_angry", frames: [...] } and
  // nothing else in the plugin changes. A later sweep for dead weight will
  // find exactly these six and must LEAVE THEM; tests/logic-tests.js asserts
  // all six are present so that deleting them fails the suite.
  child_angry:  { row: "child_sad",    frames: [1] },

  child_hungry: { row: "child_hungry", frames: [1, 2] }, // bowl in both
  child_sad:    { row: "child_sad",    frames: [1] },    // ⚠️ the tear is on frame 1 ONLY; 2-6 are cheerful
  child_sick:   { row: "child_sick",   frames: [1, 2] }, // green body, stable pose
  child_tired:  { row: "child_tired",  frames: [5, 6], rests: true, zz: [5, 6] }, // lying FLAT on its belly AND the zZ

  // ⚠️ `adult_angry` and `adult_tired` are cut from the `-2` sheets
  // (the alternates), which ship over the originals; the
  // slicer named them plainly, so these indices are the ALT file's indices.
  adult_angry:  { row: "adult_angry",  frames: [5, 6] }, // the big steam puffs
  // ⚠️ The adult hungry source strip has only FOUR frames, not six. That is
  // the art, not a slicing bug, and it needs no special case: 2 and 3 exist.
  adult_hungry: { row: "adult_hungry", frames: [2, 3] }, // food thought-bubble, contents differ so it animates
  adult_sad:    { row: "adult_sad",    frames: [5, 6] }, // open mouth AND the full tear stream
  adult_sick:   { row: "adult_sick",   frames: [1, 2] }, // thermometer: a red vertical on a green body, reads at any size
  // ⚠️ NO `zz`, and that is the art rather than an omission. The adult tired
  // row is the one tired row with no sleep mark at all: both
  // shipped frames decompose into a SINGLE connected component at every alpha
  // threshold from 1 upward, so there is nothing detached to lift out. An
  // adult therefore sleeps with its eyes shut and no zZ over it. Recorded so
  // the next reader does not go looking for adult_tired_5_zz.png.
  adult_tired:  { row: "adult_tired",  frames: [5, 6], rests: true }  // eyes shut, no mark drawn
}

// ---- THE RESTING POSES ------------------------------------------------
//
// 🔴 A mood is art AND a body language, and the two have to agree. The child
// tired row lies FLAT ON ITS BELLY and the adult tired row is CURLED UP
// ASLEEP. Those are not standing poses, and the room walks a pet that is only
// one stat low: at neglect level 1 it still takes about 400 walks an hour,
// covers ~339 px of a ~280 px floor every minute, flips end-for-end about 193
// times an hour, and drifts up to 16% of the room's height off the ground.
// Play a sleeping drawing through that and you get a curled-up dragon gliding
// sideways through the air, which reads as a broken sprite rather than as a
// tired animal.
//
// So a resting loop pins the pet: no new walks, and no drift off the floor.
// Room.qml spends this on `stillChance` and `riseBand`, the same two dials
// the neglect levels already turn, so it composes with them instead of
// fighting them — a resting pet is simply at the still end of a scale that
// still exists. The four levels keep grading movement for hungry, sad, angry
// and sick, which is where they remain visible.
//
// ⚠️ Stated cost, not hidden: a walk already in flight when the pet falls
// asleep finishes its glide (up to one walk duration, ~1.5-3.5 s) before the
// pet settles. Cancelling a running Behavior mid-flight is the kind of Qt
// detail that cannot be checked without Qt on the machine, and a wrong guess
// there teleports the pet; letting one last step finish is the safe half of
// that trade.
//
// ⚠️ NOT inferred from the pixels — authored, like the frame table, for the
// reason given below. It is measurable (the drawn body of `child_tired`
// is 33 x 22 source px against a standing child's 22 x 38, and `adult_tired`
// is 39 x 26 against a standing adult's 33 x 55), but "which drawings are
// lying down" is a fact about a drawing and a person can just answer it.

// ---- 🔴 THE SLEEP MARK, AND WHY IT IS NOT IN THE BODY FRAME -------------
//
// The tired rows sit on a white ground, so the zZ beside the sleeping head
// is DARK INK. Measured against a dark panel card it lands at
// 1.00-1.41:1 contrast while the dragon's own body lands at 2.05-2.81:1 —
// which is to say it is not there. That matters more than it sounds: a
// lying-down pose with no zZ over it does not read as "asleep", it reads as
// "dead", and this plugin has a death.
//
// So the mark is CUT OUT of the body frame into its own transparent overlay,
// `<row>_<n>_zz.png`, on the same padded canvas and at the same offset — the
// renderer draws it with the same geometry as the body frame, so it lands on
// the exact pixel it occupies in the source frame, at every sprite scale,
// with no second set of coordinates to keep in step. Room.qml then recolours it to the
// theme's foreground at render time.
//
// 🔴 Where the art LIVES is an extraction decision; how it SITS on a given
// theme is a rendering one. That is the same rule the sleep-effect prop
// already follows, and it is why the overlay keeps the source ink rather
// than being repainted white: the split is lossless (body + overlay
// reconstruct the source frame pixel for pixel), so nothing in the frame is
// discarded to make it legible.
//
// ⚠️ The mark was identified by CONNECTIVITY, not by colour: the dragon is
// outlined in its own near-black ink, so a colour test would have eaten the
// outline, while the mark is drawn floating and touches nothing at any alpha
// threshold. tools/cut_sleep_marks.py states the full reasoning and can be
// re-run against a recut sheet.

// ---- 🔴 THE ADULT FORMS AND THE MOOD ART: A STATED GAP ------------------
//
// There is ONE adult mood row per mood, and the dragon in it wears neither
// the satchel nor the crown. The three adult forms differ by exactly those
// two accessories (see THE ACCESSORY RULE above), and the form is the reward
// for how well the pet was raised — so on today's art a satchelled or crowned
// adult reverts to a plain one for as long as any stat is at or below 20, and
// gets its accessory back when it is fed.
//
// 🔴 That is MISSING ART, and it is reported as such rather than worked
// around, on the same footing as `child_angry` above. Nothing here can invent
// a satchel: compositing one over a drawn pose is a second renderer and a
// second set of registration points, and blinking an accessory is the exact
// failure THE ACCESSORY RULE exists to forbid. The alternative — refusing to
// draw mood art at all for forms B and C — would cost two thirds of adult
// players the whole feature to protect a chest strap.
//
// ⚠️ It is not a per-frame blink: the accessory is absent for the WHOLE
// duration of a mood and present the whole rest of the time, so it reads as a
// state change rather than as a glitching sprite. That is the reason it is
// shippable, not a reason it is fine.
//
// ---- 🔴 THE BABY AND CHILD HORNS: THE SAME GAP, POINTING THE OTHER WAY -----
//
// The note above is written about the adult because that is where the gap is
// widest. It is not only there, and the direction reverses lower down the
// life stages: the baby and the child gain a gold accessory in some moods
// that their idle art does not have at all.
//
// Census of gold pixels per frame — hue 0.07-0.18, saturation >= 0.25, value
// >= 0.45, alpha >= 200 — over exactly the frames the table above loops:
//
//   baby idle      0,  0      child idle       0,  0     adult A idle  56, 64
//   baby angry    25, 25      child tired     15, 24     adult B idle  68, 92
//   baby tired    23, 23      child sick       0,  0     adult C idle  72, 59
//   baby sick      0,  0      child sad        1 (held)  adult tired   53, 58
//   baby sad       6,  0      child hungry     2,  9     adult sad     64, 71
//   baby hungry    0, 31                                 adult sick    66, 70
//
// So: a baby grows a pair of gold horns when it is cross or sleepy and loses
// them again the moment it is fed, and a child grows a gold crest along its
// back when it lies down tired. The adult never does — it carries gold in its
// idle frames too, which is why the three adult columns are flat.
//
// ⚠️ WHAT THE INSTRUMENT DOES AND DOES NOT SAY. The census counts the WHOLE
// frame, props included, so it locates a difference and does not name it.
// Three rows prove it must not be read as a horn count: `baby hungry` reads
// 0 and 31 across a pair with no horn in either frame — that is its food bowl
// going from white to tan — `baby sad` reads 6 and 0 for a pair with no horn
// either, and `child hungry` reads only 2 and 9 for a horn pair that is
// obvious at 16x. Every presence and absence claim in this note was confirmed
// by eye at 14-16x against the panel's own card colour; the numbers are the
// pointer, not the verdict.
//
// ⚠️ ACCEPTED, on exactly the footing of the satchel and the crown above and
// for the same reason: in every loop the table names bar one — the exception
// is the next paragraph — the accessory is either in all of that loop's frames
// or in none of them, so nothing flickers while a mood is held. The change
// happens at the mood boundary, where it reads as a state change. Closing it
// needs a frame that does not exist, and compositing horns onto a pose in code
// is the second renderer THE ADULT FORMS note has already refused once.
//
// 🔴 ONE PAIR IS NOT LIKE THE OTHERS, and it is written down here rather than
// quietly changed: `child_hungry_1` has a bare head and `child_hungry_2` has
// the horns, so the child hungry loop crosses that boundary INSIDE itself and
// alternates the two — which is the exact thing THE ACCESSORY RULE at the top
// of this file forbids. Only frames 1 and 2 of that row are on disk, so there
// is no consistent pair to move to; the fix is to hold one of them, the way
// `child_sad` already holds frame 1. WHICH one is a design call about which
// pose says "hungry", and THE FRAME TABLE above is explicit that such calls
// are authored rather than derived — so it is recorded here for that decision
// and not pre-empted by this file.
//
// The lookup below is per-form so that the drop-in is mechanical: the day a
// crowned dragon sad row exists, the files land as `adult_c_sad_*.png` and
// an `adult_c_sad` row is added to moodLoops. Nothing else changes.
function moodRowKey(stage, mood, adultForm) {
  if (stage === "adult") {
    var formKey = "adult_" + adultFormLetter(adultForm) + "_" + mood
    if (moodLoops[formKey]) return formKey
  }
  return stage + "_" + mood
}

// The three adult forms as the rest of this file spells them. Anything that
// is not A or C is B, which is the same rule forStage() uses — so an absent
// or unrecognised form resolves the same way everywhere rather than two
// different ways in two files.
function adultFormLetter(adultForm) {
  if (adultForm === "A") return "a"
  if (adultForm === "C") return "c"
  return "b"
}

// ---- 🔴 THE FORM C LIFT -------------------------------------------------
//
// Adult C's idle loop is AIRBORNE. It is the winged, crowned form and both
// of its idle frames have the feet off the ground: measured
// on the largest connected component, `adult_c_5` floors at source row
// 69/69/69/68 and `adult_c_6` at 68/68/67/67, at alpha >0 / >=100 / >=128 /
// >=200. Every adult mood frame floors at row 71 at all four thresholds, and
// so do adult A (71 flat) and adult B (71 flat).
//
// Left alone, a crowned dragon would therefore SINK 2-4 source pixels — 4-8
// screen px at scale 2, 8-16 at scale 4 — the instant any stat
// reached 20, and rise again when it was fed. The padded canvas exists to
// stop the pet moving when its mood changes; this is the same requirement,
// answered on the axis the art itself disagrees on.
//
// So a mood canvas for form C is drawn `lift` SOURCE pixels higher. 3 is the
// value that minimises the worst error against BOTH idle frames at ALL FOUR
// thresholds: it lands the mood floor on row 68, which is 0-1 px from
// `adult_c_6` and 0-1 px from `adult_c_5`. (2 would land on 69 and be 2 px
// out against `adult_c_6` at the tighter thresholds.) 1 px is inside form C's
// own idle bob — its two frames already differ by 1-2 px as the wings beat —
// and inside the 1 px tolerance the suite enforces.
//
// 🔴 It is a whole number for the same reason MOOD_PAD is: `lift *
// spriteScale` is a screen offset and spriteScale is an integer.
// 🔴 Vertical only, so the mirror's origin and every horizontal argument
// above are untouched by it.
// ⚠️ It costs top clearance, and there is enough of it. The highest ink in
// any shipped mood frame is at canvas row 12 — four rows BELOW the body
// canvas's own top edge, which is canvas row 8 — so a 3 px lift still leaves
// it one row inside petGrid, and petGrid.y is clamped at 0. Nothing is pushed
// out of the room. tests/logic-tests.js holds that budget at 8 - 3 = 5.
//
// Keyed by the same lowercase letter adultFormLetter() returns, so there is
// one spelling of a form in this file rather than two.
var ADULT_MOOD_LIFT = { a: 0, b: 0, c: 3 }

// The idle canvas for a life stage, or null for a stage that has none. The
// egg is deliberately null: it has no moods, so nothing downstream has to
// remember that as a special case.
function stageCanvas(stage) {
  if (stage === "baby") return SIZE_BABY
  if (stage === "child") return SIZE_CHILD
  if (stage === "adult") return SIZE_ADULT
  return null
}

// Which MOOD sprite set to draw, or NULL when the ordinary idle art should be
// drawn instead. Null is the normal answer — a well pet, and every egg.
//
// Returns { frames, glyphs, w, h, pad, lift, rests }: w/h are the PADDED
// canvas's own pixel size, `pad` is the inset the renderer must apply and
// `lift` is how many further pixels it must raise the canvas — all in SOURCE
// pixels, to be multiplied by the same integer scale as everything else.
// `rests` is true when the pose is a lying one and the pet must not be walked
// around in it.
//
// 🔴 `glyphs` is the SLEEP MARK overlay, one entry per entry of `frames` and
// in the same order, each either a path or null. It is a parallel array
// rather than a second lookup precisely so the renderer can index it with the
// frame index it already has, and so a row whose overlay is missing yields
// null for that frame instead of a path to a file that is not there. Null is
// the answer for every mood except the baby and child tired rows.
//
// ⚠️ `mood` is a string from Pet.moodFor(): "sick" | "hungry" | "tired" |
// "sad" | "angry" | "none". Anything unrecognised returns null, so a typo or
// a future mood with no art yet draws the idle pet rather than nothing at all.
//
// ⚠️ `adultForm` is "A" | "B" | "C" and is ignored at every other stage. It
// selects the lift (see THE FORM C LIFT) and, when per-form mood art ever
// exists, the row (see THE ADULT FORMS AND THE MOOD ART). It is NOT optional
// for an adult: called without it, a crowned pet is drawn with form B's lift
// of 0 and sinks, which is exactly the defect the lift exists to close.
function forMood(stage, mood, adultForm) {
  var body = stageCanvas(stage)
  if (!body || !mood || mood === "none") return null
  var loop = moodLoops[moodRowKey(stage, mood, adultForm)]
  if (!loop) return null
  var out = []
  var glyphs = []
  var zz = loop.zz || []
  for (var i = 0; i < loop.frames.length; i++) {
    var n = loop.frames[i]
    out.push("assets/moods/" + loop.row + "_" + n + ".png")
    glyphs.push(zz.indexOf(n) >= 0
                ? "assets/moods/" + loop.row + "_" + n + "_zz.png"
                : null)
  }
  var lift = stage === "adult" ? ADULT_MOOD_LIFT[adultFormLetter(adultForm)] : 0
  return { frames: out, glyphs: glyphs,
           w: body.w + MOOD_PAD * 2, h: body.h + MOOD_PAD * 2,
           pad: MOOD_PAD, lift: lift, rests: loop.rests === true }
}

// The tallest ROOM canvas any life stage can ever put on screen. Room.qml
// sizes its one integer scale against THIS number rather than against the
// stage currently drawn, so the pet does not visibly halve or double the
// moment it grows up inside a panel the user never touched. Derived from
// the canvas constants above rather than typed out again in the QML, so a
// re-cut sheet with a taller adult cannot leave a stale number behind in a
// file nobody thought to open.
function tallestStageHeight() {
  return Math.max(SIZE_EGG.h, SIZE_BABY.h, SIZE_CHILD.h, SIZE_ADULT.h)
}

// Which ROOM sprite set to draw for a life stage. Returns { frames, w, h };
// the caller picks the frame (hatch progress for an egg, the idle tick for
// everything else).
function forStage(stage, adultForm) {
  if (stage === "egg") return egg
  if (stage === "baby") return baby
  if (stage === "child") return child
  if (adultForm === "A") return adultA
  if (adultForm === "C") return adultC
  return adultB
}

// Which BAR sprite to draw, as a single 20x20 frame drawn 1:1 — one source
// pixel per screen pixel, never scaled. The bar set is its own cut of the
// same design sheet, so the icon and the pet in the panel are visibly the
// same creature at a size the room art could not survive.
//
// 🔴 This NEVER returns null. `pet` is legitimately null for the window
// between the shell drawing the bar and FileView answering with the saved
// state, and an empty bar slot reads as a broken or uninstalled plugin. A
// null pet gets the egg — the state it is about to be in anyway — and
// BarWidget.qml draws that one dimmed, so "not awake yet" stays honest.
function forBar(stage, memorialPending, adultForm) {
  var name = "egg"
  if (memorialPending === true) name = "tomb"
  else if (stage === "baby") name = "baby"
  else if (stage === "child") name = "child"
  else if (stage === "adult") name = (adultForm === "A" ? "adult_a"
                                    : adultForm === "C" ? "adult_c"
                                    : "adult_b")
  return { frame: "assets/bar/" + name + "_1.png", w: SIZE_BAR.w, h: SIZE_BAR.h }
}

// One prop by name: "waste" | "heart" | "sleep" | "tomb". An unknown name
// falls back to the waste sprite rather than returning undefined — a missing
// prop must never take a binding down with it.
//
// 🔴 The lookup is an OWN-PROPERTY test, not a plain `props[name]`. `props` is
// an object literal, so it inherits from Object.prototype: a plain lookup of
// "__proto__", "constructor", "toString" or "valueOf" comes back TRUTHY —
// with a function or a prototype object, not a sprite — the `? :` below sees
// a hit, the documented fallback never fires, and the caller reads
// `.frames[0]` as undefined. That is a blank prop with nothing logged
// anywhere, which is the one failure mode this whole function exists to
// prevent. Every call site passes a string literal today, so this is closing
// a door rather than chasing a symptom; a fallback documented as total should
// be total, and the guard costs one comparison.
function prop(name) {
  var p = Object.prototype.hasOwnProperty.call(props, name) ? props[name] : null
  return p ? p : props.waste
}
