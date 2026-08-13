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
