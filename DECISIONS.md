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
