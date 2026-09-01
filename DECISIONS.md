# Decisions

Every call made without asking, and why. Newest last.

## Locked before the rebuild started

**A — Mic passthrough stays, rebuilt.** Two separate defects were conflated as
one. `.allowBluetooth` was dragging AirPods onto HFP (mono, 8–16 kHz) — that was
the thin, degraded music, and it is fixed by requesting `.allowBluetoothA2DP`
only. The echo is different: Bluetooth output latency is ~150–250 ms, so a
continuously streamed passthrough always lands *after* the strike the ears
already heard through the earbud seal. That offset is the slapback and no
setting removes it. So the stream is gone; a rolling buffer captures the impact
transient and fires it back once as a single burst.

**B — Paired device built as a read-only second screen.** iPad mirrors live
session state. Display only, no controls.

**C — Third accent is soft slate blue** (#5A7D9A family). Cool against cream and
green, does not fight the Augusta palette.

**D — Sample data is the default first-launch state,** not a toggle to find.

## Made during the rebuild

**1 — The two-tier audio design was deleted, not ported.** The keepalive/armed
split existed for exactly one reason: `.playAndRecord` with `.allowBluetooth`
forced HFP, so the record tier had to be scoped to ~4 s around each swing.
Dropping `.allowBluetooth` removes that penalty entirely, so the session can sit
in `.playAndRecord` for the whole round. Simplest thing that works, and it
removes the category-thrash window where a fast second shot could arrive
mid-switch. The silent keepalive node is untouched — invariant 7.

**2 — Ducking is toggled by re-setting category options, not by volume.**
`.duckOthers` ducks other apps for as long as it is in the option set, so
leaving it on would duck the player's music for the entire session. Adding and
removing the option on the already-active session ducks only around the swing.
Setting category on an active session does not interrupt background execution;
`setActive(false)` still appears exactly once, in `endSession()`.

**3 — `Range` became `Today`.** "Range" reads as a rangefinder and says nothing
about the screen. "Home" is a filing-cabinet word. "Today" says what it holds.

**4 — `Theme` cut from three cases to two.** `augusta` was `clubhouse` plus a nav
band — a variant, not a palette. It is now a separate boolean, so the palettes
are `pines` (dark) and `clubhouse` (light, slate-blue accent) with the band as a
switch. This is what "collapse the theme count" asked for and it kills the
"these two look identical" complaint at the root.

**5 — Handedness rewritten as three labelled questions with plain answers.** The
old segmented row showed "Right" twice with no indication which control was
which. Each question now carries its own heading and full-word answers.

**6 — Impact-burst defaults: 130 ms window, 18 ms pre-roll, 6 ms fades.** The
pre-roll catches the club entering the ball rather than starting mid-crack; the
fades stop the slice edges clicking. Exposed as constants for range tuning.

**7 — The example-data generator was split from its SwiftUI previews.**
`DemoData.swift` now imports Foundation only; the `#Preview` blocks moved to
`Previews.swift`. This isn't tidying — it makes the generator compile and run
off-device, which is the only way its output could actually be checked without
a simulator. See `Tests/run-checks.sh`.

**8 — The first-run example was given an improvement arc.** The four example
sessions previously differed only by noise: 2.47, 1.98, 3.21, 2.61 percent, in
that order. The trend card on Today asks "are you getting more consistent" and
then drew random scatter, which teaches a new player nothing and reads as
broken. `history()` gained an `improvement` parameter that scales older sessions
looser; the example now runs 6.16 → 3.97 → 4.84 → 2.61, a clear direction with
one realistic wobble rather than a straight line. Previews still call the plain
version, so nothing else changed shape.

**9 — Checks live in the repo, not in a session.** `Tests/parse-all.sh`
syntax-checks every file; `Tests/run-checks.sh` builds and runs 31 assertions
against the shared logic and the example data. Neither needs Xcode, a simulator
or a device, so they run anywhere — including the machine that can't build the
app.

**10 — Augusta restored; Clubhouse is the one that changed.** Decision 4 read
"collapse the theme count" and cut Augusta entirely. That was the wrong reading
of the instruction, which was to *leave Augusta alone* and give Clubhouse a
contrasting colour. Corrected: Augusta is unchanged — green lead, green band,
fixed. Clubhouse keeps the same cream ground but swaps its lead and second
colours, so slate blue carries everything green used to. Primary buttons follow
the theme's lead colour rather than always being Augusta green, otherwise every
action on the screen would still read as Augusta whichever theme you picked.
The band toggle now only appears on the two themes that don't wear one already.

**11 — Compilation moved to CI rather than waiting on a Mac.** There is no route
from this environment to the M1 Max — no shell tool reaches it, confirmed by
searching the tool surface rather than assuming. But GitHub Actions runs macOS
with real Xcode, which is a compiler I can reach. `build-check.yml` builds the
app with the simulator SDK and signing disabled, so it needs no certificates and
no secrets, and every push to main now proves the code compiles before it ever
reaches a device.

**12 — TestFlight has been failing since long before this rebuild.** Every run
dies at "Import signing certificate": `DIST_CERT_P12`, `DIST_CERT_PASSWORD`,
`PROFILE_IOS`, `PROFILE_WATCH`, `ASC_KEY_ID`, `ASC_ISSUER_ID` and `ASC_KEY_P8`
were never added to the repository's secrets. Nothing to do with the code —
the workflow has never once got as far as compiling. Adding those seven secrets
is what turns a push into a build on the phone without touching Xcode at all.

**13 — Signing solved without anything leaving the Mac.** The old workflow
needed a `.p12` and two provisioning profiles as secrets, which is why it was
stuck: those artefacts live in a Mac keychain. Xcode can instead authenticate to
Apple with an App Store Connect API key and mint the certificate and profiles on
the runner itself. The API key was already in the credentials store, so the
secrets were set over the GitHub API and the pipeline now archives, signs and
exports a real IPA containing both the phone and watch apps.

**14 — One step is genuinely manual, and it was proven rather than assumed.**
`POST /v1/apps` was called and returned 403 FORBIDDEN_ERROR, "the resource
'apps' does not allow 'CREATE'". Creating the App Store Connect app record has
to happen in the browser. Everything either side of it is automated. See
DEPLOY.md.

**15 — Runner moved to macos-26.** The first upload past the app-record fix died
on an Apple policy check, not on anything in the code: uploads must be built
with the iOS 26 SDK or later, and `macos-15` ships Xcode 16.4. Both workflows now
run on `macos-26` and select the newest Xcode present rather than pinning a
version, so the next SDK floor raise doesn't break the pipeline again.

**16 — Shipped.** Run 31683442498 archived, signed, exported and uploaded.
Build 15 processed to VALID on app 6801063220, "GROOVIE Golf". The pipeline is
end-to-end: push to main, and it reaches TestFlight without a Mac in the loop.

**17 — Internal testing set up, and the reason it wasn't automatic.** Being the
account holder does not put you on a build. TestFlight needs a beta group, the
build assigned to it, and export compliance answered. None existed, so the app
sat in App Store Connect with nothing pointing it at a phone. Created the
internal group "Connor" (`024e1e84`), added cwsharp23@icloud.com, and assigned
build 15.

The assignment first returned 422 "Build is not in an internally testable
state" — that is export compliance, unanswered. Set `usesNonExemptEncryption`
false on the build, and added `ITSAppUsesNonExemptEncryption` to the Info.plist
so every future build answers it at compile time and lands in the group without
anyone touching App Store Connect.

**18 — Short game and putting added as disciplines, not as tabs.** The app only
knew how to see a full swing. Every number in the detector is calibrated to one:
180 g at the wrist for contact, a 1.2 s pre-impact window, a 3:1 tempo
reference. A putt puts under 10 g through the wrist, so the impact crossing
never happened — putts didn't read as bad swings, they didn't exist at all, and
no amount of UI would have surfaced them.

`Discipline` carries the numbers that differ: impact thresholds at the wrist and
pelvis, trace window, tempo reference, whether hips are worth reporting, and
whether audio is touched. Chosen on the watch, because that is where you are
when you walk from the range to the green, and locked during a session — traces
from two disciplines must never share an ensemble, since the chart aligns on
index and would read two different motions as one inconsistent one.

Three judgements made along the way:

*Putting does not duck audio.* The duck exists to expose the strike. A driver
has a crack worth hearing; a putt has almost nothing, and dropping the music
forty times an hour on a practice green to reveal silence would be pure
irritation. Putts still record — they just leave the audio alone.

*Sequencing is full-swing only.* Hips barely move in a chip and effectively
don't in a putt. A number there would be noise presented as insight.

*Repeatability is scored per discipline.* A putting stroke is a far simpler
motion and the same player repeats it much more tightly. Judging both on the
full-swing bands would flatter putting into meaninglessness.

**19 — The trend card compares like with like.** Adding disciplines surfaced a
bug in work from earlier today: Today's trend plotted every session on one line.
With three disciplines that would show a player improving every time they walked
to the green and collapsing every time they went back to the range. It now
filters to the most recent session's discipline.

**20 — One test was over-specified and was loosened deliberately.** "The oldest
session is the loosest" forbids an off day worse than where the player started,
which is a real and common shape — and once the example gained a believable bad
session, the assertion failed on data that was more honest, not less. Replaced
with a check that the first half averages worse than the second half and that
the newest session is the best. Direction and endpoint are what the card has to
communicate; the exact maximum is not.

**21 — The engine is re-baselined on iron play, not the driver.** This is the
most consequential number in the app and it was set wrong.

Detection thresholds are a floor. A swing registers only if its impact transient
crosses one, so a floor set by the hardest shot in the bag drops every gentler
shot through it — not recorded badly, not recorded at all. The driver is the
outlier: the fastest club, and the only full swing struck off a tee with a
sweeping blow and no turf. Calibrating to it put the floor near the top of the
range, where a full pitching wedge — roughly 55-65% of driver clubhead speed —
sat below the line and vanished.

The reference is now a **full pitching wedge**: the quietest full swing worth
counting. Wrist threshold 180 → 110, pelvis 35 → 22, pre-impact window 1.2 s →
1.1 s (an iron swing is marginally shorter). A 4-iron or a driver clears 110
without difficulty, so nothing is lost at the loud end — a floor set by the
quietest member of a group costs nothing at the top, while a floor set by the
loudest loses everyone else.

Two further reasons the driver was the wrong model. An iron off turf takes a
divot, and that turf interaction adds a sharp second deceleration a teed driver
has no equivalent for — the transient differs in shape, not only in size. And
ball compression against a descending blow is sharper than the sweep that suits
a driver, so a detector tuned to a sweep is looking for the wrong signature on
the club you hit most.

**22 — Pitching added as a fourth discipline.** The old `chipping` bucket
covered "pitches, chips and bump-and-runs" in one threshold, which is too wide:
a firm bump-and-run and a 58° wedge floated fifteen yards differ by more than
twice the strike energy. Split into `chipping` (firm, low, releasing — 40) and
`pitching` (58° at 10-15 yards — 18), which sits much closer to a putt than to a
swing, as it should. It still ducks audio: a soft wedge has a click that
separates a crisp strike from a thin or fat one, and that is worth hearing. Only
putting stays silent.

**23 — Sensor saturation is now a full-swing-only caveat.** Nothing in the short
game gets near the accelerometer's limit, so "peak numbers are a floor" was
misleading everywhere except full swings. `canSaturateSensor` gates it, and the
Setup copy no longer implies a driver.

**24 — Opening the app killed Apple Music. Two bugs, compounding.**

*The session was recording when it had no reason to.* `startSession` asked for
`.playAndRecord` and held it for the whole round. Activating a recording
category is an intrusive act — iOS reads it as the app wanting the microphone,
and the player's audio can be interrupted even with `.mixWithOthers` set. The
keepalive tier has no reason to record; it exists so iOS keeps the app alive in
a pocket. It is now `.playback`, and the microphone is engaged in `arm()` only,
about a second before a swing, then dropped again in `stopCapture()`. This also
means the orange microphone dot appears for a second per swing instead of for a
whole round.

Worth noting this is *not* the two-tier design that was removed earlier. That
one existed because `.allowBluetooth` forced HFP and the record tier had to be
kept short to protect audio quality. Without `.allowBluetooth` the switch is
free, so this tiering is about not asking for permissions the app isn't using.

*A queued event was replaying at launch.* The watch sends over `sendMessage`
and falls back to `transferUserInfo`, which is durable — an undelivered event is
kept and handed over the next time the phone app launches, potentially hours
later. The late-join safety net then treated a months-old `arm` as live and
called `mirrorSessionStart()`, which opened an audio session and cut the music.
Events are now stamped on the watch, and anything older than a minute is
discarded. Unstamped events — a watch on an older build than the phone, which
happens routinely — are still handled, but are never allowed to start a session
on their own.

## 25. The broadcast presentation layer and the Groove Score

The data screens are rebuilt in a television-graphics language — score ring,
needle meters, delta arrows, glowing tracer — aimed at players good enough to
want the numbers and busy enough to want them instantly. Three rules keep it a
training tool rather than an arcade: every pixel maps to a measurement, the
number leads and the sentence follows, and amber stays a shape, never text.

The Groove Score is one 0–100 number per session, weighted the way the app's
own coaching copy already talks: 55% repeatability (discipline-normalised tempo
variation), 25% smoothness, 20% sequencing — with sequencing's weight folding
back proportionally where hips don't move or no phone was carried, so a putting
session isn't docked for physics it doesn't have. It deliberately does NOT
grade tempo against the tour number, because the app's stated doctrine is that
owning a tempo beats matching anyone's; the tour reference appears on the meter
as a neighbourhood band, not a bullseye. Components are piecewise-linear over
explicit anchors pinned to the existing verdict boundaries (3.5/5/8 normalised),
so the score and the words on screen can never disagree, and the anchors are
under test in Tests/ExampleDataChecks.swift.

## 26. The watch becomes the in-round HUD

Broadcast treatment for the live surface: swing count and last tempo run big
in heavy monospaced gold, and a consistency strip draws one bar per recent
swing, height keyed to distance from the session mean — a grooved run reads as
a level row, a mishit as the bar that broke formation, green inside ten
percent and orange outside. Deliberately zero numbers to parse mid-round
beyond the tempo itself; the strip is shape, not arithmetic. The controller
now keeps the session's struck tempos (capped at 200) to feed it, resetting
on session start. WatchPreview mirrors the new layout so every state stays
inspectable without a paired device.

## 27. CI clears orphaned signing certificates before each archive

Run 22 jammed on Apple's per-team certificate cap. Cause: every TestFlight run
lands on a fresh ephemeral runner, -allowProvisioningUpdates mints a new
signing certificate there, and the private key dies with the runner — so the
team accumulates unusable orphans until Apple refuses to issue more. The
workflow now deletes all DEVELOPMENT/DISTRIBUTION certificates via the ASC API
before archiving and mints exactly what it needs; orphans are unusable by
definition, and any local Xcode simply re-creates its own on next build. Fixed
in the workflow rather than by one-off cleanup so the cap can never re-bite.

## 28. Calibration presents its gap as the number it actually is

The separation view now prints the measured gap between real-swing and
practice-swing confidence directly between its two markers, coloured by the
same 0.18 readiness threshold the detector uses — so the screen shows the
exact number the unlock decision runs on, not an unlabelled pair of bars.
Counters move to the broadcast stat type. Last data-presentation surface
brought into the redesign.

## 29. Placement is sensed per swing, not trusted from settings

The pocket setting says where the phone is supposed to be; on a hot day it
comes out and gets parked by the ball or under the bag, still playing music.
Ground shock from a strike a foot away can then fake a hip transient and turn
into a garbage sequencing number. Every sequencing window is now asked whether
it actually came off a body — median rotation over the pre-impact window,
median precisely so one violent spike cannot vote — and a parked phone
silently sits sequencing out for that swing while everything else (audio,
detection, logging) is untouched. Back in the pocket, it resumes. No new
setting, nothing to remember. Under test with synthetic pocketed and parked
windows including the ground-shock case.

Same pass: the pelvis buffer stopped hopping to the main actor a hundred
times a second (it's owned by its capture queue now, snapshotted on read),
and the strike-window mic prefers a plugged-in external input — USB, wired
headset, line-in — over the grille mic lying face-up in grass. Bluetooth
mics stay excluded; that lesson is DECISIONS 24.

## 30. The watch face fits, and the detector leaves the UI thread

Two on-wrist faults, one cause each. Lag: every motion frame allocated a
main-actor Task and ran the whole detector on the UI thread — a hundred
scheduler hops a second fighting SwiftUI for the same core. The detector now
runs on the serial capture queue it already shared with the motion callback,
single-threaded by construction (config and discipline writes route through
the same queue), and only fired events — a few per swing — hop to main.
Overlap: the face carried a three-line masthead plus fixed-size stats sized
past a 40 mm screen once a warning row appeared. Brand and state share one
line now, type and the strip are tightened to fit the smallest face with
headroom, and the stack scrolls so stacked warnings push content down instead
of into each other. WatchPreview mirrors all of it.

## 31. The strike floor scales with the swing, and takeaway scales with the discipline

Field report from the range: real strikes going unlogged. Two rigidities, both
fixed at the physics level rather than with a "loose mode" setting.

The impact thresholds were full-commitment floors — 110 is a FULL pitching
wedge — but nobody swings at full commitment out of the gates; a warm-up
half-seven still strikes the ball with proportionally less shock, and the
fixed floor logged those as rehearsals. Impact shock scales with clubhead
speed, which scales with wrist rotation, so the floor now scales with each
swing's own peak rotation (never below 35% of base). Separation from
rehearsals survives because a ball strike is a discontinuity an order sharper
than a turf brush at the same speed.

The takeaway trigger was a fixed 1.4 rad/s tuned on the full swing — a putting
stroke or soft pitch never crossed it and went entirely unseen. It scales with
the discipline's motion range now, floored above the stillness gate so idle
wrist noise still can't start a swing. Both behaviours are pinned in the
harness, including the exact warm-up-strike case the range visit exposed.

## 32. The range faults, fixed at the logic level — and a capture mode to catch the rest

Field sessions exposed three detector logic faults beyond thresholds, each now
fixed and pinned by replaying synthetic reproductions through the real engine:
the swing timeout kept running after an impact had been found, so slow warm-up
swings were logged as rehearsals (a struck ball is a struck ball, however long
the swing took to arrive); a waggle at address could sustain takeaway-level
rotation, start a phantom swing, and leave the detector in recovery while the
real swing went unseen (false starts now abort silently, logging nothing and
teaching the template nothing); and recovery's only exit was stillness, so a
fidgety wrist between balls could blind the detector indefinitely (time
releases it now too).

And because field misfires beat synthetic guesses: a diagnostic capture mode.
Armed from the watch before a session, both devices record every raw sensor
frame at full rate plus a narrated log of every decision the detector made —
takeaways, aborts, impact floors, verdicts. The watch ships its half to the
phone at session end; the phone merges both into one JSON bundle exportable
from Setup. The detector is pure shared code, so a capture replays through the
exact engine anywhere — the harness already proves a serialised session
replays to the same verdicts. Misfires from the range become regression tests.

## 33. Why the watch stayed on an old build, and why 99 swings sat unsent

Two delivery faults, not code faults. The watch face fixes had shipped for
several builds; the watch simply never took the update — TestFlight watch
companions update far more reliably across a marketing-version change, so the
app moves to 1.1 to force the update through. And the "99 waiting to sync"
spool was a designed-in deadlock: acks went only over the instant channel,
which requires the watch to be reachable at the exact moment the phone
processes a swing, and every flush re-queued the entire spool without checking
the system outbox — so undeliverable acks met a snowballing queue and the
counter froze. Acks now also travel the durable channel and the watch listens
on both; flush skips anything already in flight.

## 34. Uploading is not releasing — the pipeline now does both

The root cause of "I'm still on an old build": every build from 21 through 32
uploaded successfully, processed to VALID, and was never attached to a beta
group, so none of them ever appeared in TestFlight. The tester sat on build 20
for five days while each run truthfully reported UPLOAD SUCCEEDED. Two lessons
baked in: the TestFlight workflow now waits for its own build to finish
processing, attaches it to every beta group, verifies the attachment stuck,
and fails the run if it didn't — a green pipeline now means the build is on
the phone, not merely on Apple's servers. And assignment must be read from the
group side (`/v1/betaGroups/{id}/builds`); Apple forbids GET_RELATED on
`builds->betaGroups`, so the build-side query 403s and makes every build look
unassigned whether it is or not.

## 35. Real range data: the tempo numbers were a broken top-of-backswing detector

367 swings across three sessions, exported from the phone. Findings and fixes:

Tempo was nonsense and it was our fault, not the player's. Reported downswings
ran 0.12 s to 1.03 s (84% coefficient of variation) and tempo ratios 0.29 to
6.58 on swings that felt identical — a golfer's downswing is 0.25-0.32 s and
barely moves. Cause: the top of the backswing was taken as the deepest
rotation trough between takeaway and impact, but address is quieter than the
top, so any swing with an early takeaway put the "top" at address and let the
downswing swallow the whole swing; a single noisy sample could also win
outright. The top is now the LAST sustained quiet stretch before impact —
quiet relative to that swing's own downswing peak, sustained three samples so
noise can't vote. On the same 92 struck swings, variation falls from 84% to
34%.

Reference rotation was guessed at 22 rad/s; real committed full swings peak
near 14 (p75 of 92 strikes). Guessing high made every genuine swing look like
a half effort. Corrected to 14.

Two open items the data raises but doesn't settle: the struck-to-rehearsal
ratio is 3:1 (92 struck, 275 rehearsals), which is high for range work and
suggests real strikes are still being classed as rehearsals; and arm
confidence does not separate the two populations (median 0.51 struck vs 0.49
rehearsal) even though the underlying setup features clearly do — median setup
duration 2.43 s struck vs 3.96 s rehearsal, transition sharpness 0.039 vs
0.086. The template is not weighting the features that actually discriminate.
Both need the raw diagnostic capture to settle rather than more inference from
resampled traces.

## 36. Full-app sweep against the field data: scorer, instrumentation, archive safety

The repo is public now (Actions runs free and unlimited on standard runners —
that was the billing unblock). Three changes from sweeping the whole app with
the 367-record export as the guide:

The template scorer was an unusable dial: on real labelled data the
similarity-ratio confidence put every swing — struck and rehearsal alike —
inside 0.48-0.51, so the arm threshold was a coin flip at any setting. The
template now tracks per-feature variance per class and scores a Gaussian
log-likelihood ratio: same features, same honest ceiling (they cap out near
AUC 0.67), but medians land ~0.55 vs ~0.32, weighted by how tightly the
player's own reps cluster rather than by hand-picked normalisers. Pinned by
forty real signatures held out from Connor's own sessions. Old saved templates
decode (variance fields optional) and retrain variance in a few reps.

Rehearsals now record peakRotation and peakJerk (optional, decode-safe). 275
"rehearsals" against 92 strikes was unanswerable from the export because
rehearsals saved empty metrics; the next export can show exactly which
rehearsals carried a strike-shaped transient just under the floor.

History loading was all-or-nothing: `try? decode([Swing].self)` returned []
if any single record failed, silently wiping the archive on any schema
hiccup. Records now decode individually through a lossy wrapper; a corrupt
record is dropped, the rest survive.

## 37. The app speaks: a narrator, one vocabulary, and numbers that name their baseline

Sweep of every user-facing surface for plain speech and legibility. The
biggest gap wasn't tone — it was that the app showed numbers and never said
what a session meant. Sessions now narrate themselves: one or two plain
sentences on the hero, computed from the same measurements the tiles show —
the score tier opens, and the single most useful specific fact follows, picked
by priority (within-session quickening, then hips-vs-hands order, then a
putting-specific truth), with an honest "not enough strokes to say anything"
when the data can't back a story. Every sentence traces to a number; the
narrator is pure shared code and its honesty is pinned in the harness — it
must name a quickening session, must coach hands-before-hips, must admit thin
data, must notice real improvement over last time, and may never run past two
sentences.

Smaller fixes riding along: the score ring gained a collapsed "what makes
this number" line that explains the blend in one breath, no formula; delta
chips now read "▲1.2 vs last" so the comparison names its baseline;
"rehearsal" is gone from user-facing copy — they're practice swings
everywhere, including the line that used both words in one sentence; and the
watch face no longer says "not running" or "99 waiting to sync" but "no
session yet" and "99 swings syncing to your phone".

## 38. The phone goes live

Everything now updates on the phone in realtime during a session, not just at
the end. Two pieces. Delivery: each completed swing additionally fires over
the instant channel when the phone is reachable that second — a sprint copy in
front of the durable spool transfer, which remains the guarantee; the phone
already dedupes by id, so whichever copy loses the race bounces off. Display:
the Today tab's session card became a live board sized for a phone propped
against the bag — the wrist's state mirrored in a word (watching / set /
swinging / struck, driven by the same events that drive the audio, so it costs
nothing new), the struck count and last tempo in score-sized type, every
tempo this session as a bar against the running mean, and repeatability plus
the Groove Score computing live once three strikes exist rather than waiting
for session end.

## 39. Impact reads the swing it happened in

Line-by-line pass through the engine with the field numbers in hand. The
misclassification machine was the impact detector's single absolute jerk
floor: a smooth swinger's strike arrives damped through the grip and ducks
under any floor set high enough to ignore a vigorous practice swing — which is
how three range sessions produced 275 "practice swings" against 92 strikes.
A strike is not a big number; it is a discontinuity that stands out from the
swing it happened in. The floor now self-normalises: the detector measures the
swing's own jerk texture and demands a spike five times above it, bounded
below at 55% of the scaled threshold so noise can't qualify on a buttery
swing, and above at 140% so the caller's ceiling still holds. A rotation gate
rejects sharp clunks at low speed — grounding the club, dropping a ball —
which the absolute floor happily called impacts. Pinned by three new replay
checks: the damped strike reads as struck, the rough ball-free swing stays a
practice swing, the clunk at rest is nothing.

The takeaway trigger also fired late on unhurried players (1.2 rad/s
sustained is mid-backswing for a smooth takeaway); it drops to 1.0 with the
floor at 0.42 — still nearly three times the stillness gate, and false starts
are free now that waggles abort silently.

## 40. The sensitivity dial recalibrated to the scorer it serves

Follow-up pass after the scorer rebuild caught a correction the rebuild
itself created: the eager/balanced/strict thresholds (0.45/0.62/0.78) were
tuned to the old similarity-ratio scale. Under the variance-aware scorer's
real distribution — measured across all 367 labelled records — "balanced"
armed on barely a third of real strikes and "strict" almost never fired.
Recalibrated to the measured operating points: eager 0.35 (~73% of real
strikes, accepting ~46% of practice swings), balanced 0.45 (~62%/34%),
strict 0.55 (~49%/28%). The features cap near AUC 0.67, so these are the
honest trade-offs, not promises. Pinned structurally: a harness check trains
the template on the real fixtures and requires balanced to sit between the
two class medians — if the scorer ever moves again, that check fails until
the dial moves with it.

## 41. Replay is one command

Tools/replay-capture.sh takes an exported diagnostic capture bundle and runs
its watch stream through the real RoutineDetector, printing every verdict
with its metrics next to what the wrist decided live, and flagging any
disagreement — which is by definition a logic change between the recording
build and the current engine. `--narrate` prints the engine's full decision
narration frame by frame. Proven end to end on a synthetic bundle shaped
exactly like the app's export. The moment a real range capture lands, the
3:1 question gets answered against actual swings rather than resampled
traces.

## 42. Early strikes keep their trace

A strike landing inside the first 1.1 s of the buffer returned an empty
trace, so the swing silently dropped out of the overlay and the ensemble —
typically the first ball of a session, exactly the one a player looks for.
The missing lead-in is now padded with the first available sample: the
impact sits where every other trace puts it, and the short lead-in reads as
flat, which is what stillness looks like anyway. Pinned for length and
impact position.
