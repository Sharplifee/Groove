# GROOVE

Drops your audio at takeaway so you hear the strike, then stacks every swing on
impact so consistency stops being a feeling.

Written but **never compiled** — no macOS toolchain was available. Expect to fix
a handful of compiler complaints on first build.

---

## Files

| File | iOS target | watchOS target |
|---|:--:|:--:|
| `Shared/Models.swift` | ✓ | ✓ |
| `Shared/SwingAnalyzer.swift` | ✓ | ✓ |
| `Shared/RoutineDetector.swift` | ✓ | ✓ |
| `Watch/WatchController.swift` |  | ✓ |
| `Watch/WatchRootView.swift` |  | ✓ |
| `Phone/AudioHost.swift` | ✓ |  |
| `Phone/PhoneController.swift` | ✓ |  |
| `Phone/Views.swift` | ✓ |  |
| `Phone/Onboarding.swift` | ✓ |  |
| `Shared/ConfigSync.swift` | ✓ | ✓ |

New iOS App → add a watchOS App target for it. Delete both auto-generated
`ContentView`/`App` stubs; `@main` is already declared here.

## Capabilities — get these exactly right or it dies in your pocket

### iOS target

**Signing & Capabilities → Background Modes → Audio, AirPlay, and Picture in Picture.**

`Info.plist`:

```
UIBackgroundModes              <array><string>audio</string></array>
NSMicrophoneUsageDescription   Opens your mic for a moment at impact so you hear the ball. Nothing is recorded.
NSMotionUsageDescription       Reads rotation from your pocket to measure how your swing sequences.
```

### watchOS target

**HealthKit capability.** Note the key here is `WKBackgroundModes`, **not**
`UIBackgroundModes` — an easy one to get wrong, and it fails silently.

`Info.plist`:

```
WKBackgroundModes                <array><string>workout-processing</string></array>
NSMotionUsageDescription         Reads your swing from your wrist.
NSHealthShareUsageDescription    Keeps sensors running for the length of a session.
NSHealthUpdateUsageDescription   Saves a workout while recording.
```

Signing: team `XF783932R2`. iPhone 16 Pro is already a registered device.

---

## Background execution — how it actually stays alive

Two independent mechanisms, one per device. Both are load-bearing.

**Watch:** `HKWorkoutSession`. The only sanctioned way to hold CoreMotion at
100 Hz with the screen off on watchOS. If Workouts is denied, sensors stop the
instant the wrist drops — `WatchController.blocker` says so rather than letting
it fail quietly.

**Phone:** a silent audio session held for the whole range session. iOS grants
an `audio`-background-mode app execution **only while a session is active and
producing samples**. Between swings this app has nothing to play, so without the
keepalive it's suspended within seconds of the screen locking: CoreMotion stops,
`sendMessage` stops arriving, and the duck works once and never again. An earlier
revision also called `setActive(false)` on every disarm, which guaranteed it.

`LocalAudioHost` runs two tiers over one never-deactivated session:

| Tier | Category | When | Cost |
|---|---|---|---|
| Keepalive | `.playback` + `.mixWithOthers`, silent source node | whole session | none — no input node, so earbuds stay on A2DP |
| Armed | `.playAndRecord` + `.duckOthers` | ~4 s around a swing | forces HFP, mono 8–16 kHz |

Changing category on an already-active session keeps execution unbroken.
`setActive(false)` is called exactly once, in `endSession()`. Interruptions (a
call, Siri) are observed and the session reactivated on `.ended`, or the app
stays backgrounded but dead for the rest of the round.

**App Review will ask about two things.** A silent-audio keepalive is a known
rejection trigger when it's a pretext. Here the app genuinely plays and records
audio as its core function, which is defensible — be ready to explain it. Same
for continuous microphone access.

**The phone app must be running.** `sendMessage` only lands if it's alive; if
force-quit, events queue via `transferUserInfo` and the duck never fires. Both
UIs say so, and `phoneReady` warns on the wrist.

---

## How it works

**Arming, not predicting.** A real pre-shot routine is a *sequence* of stable
holds with sharp edges between them — settle, set, address. A loose rehearsal
drifts continuously. `SwingAnalyzer.plateaus` segments the pre-swing window into
those holds and `RoutineSignature` reduces them to five features. The detector
only fires the duck from the armed state.

**It labels itself.** A struck ball produces an impact transient; a rehearsal
doesn't. Every swing self-labels after the fact, so `RoutineTemplate` trains
continuously from the first session with nothing to tag. Cold start uses a
hand-tuned prior until eight real reps exist.

**Correct fast, don't predict well.** A missed duck costs one strike; a false
duck costs a second of dipped audio. So arm generously — and if no impact
arrives within 3 s, restore immediately.

**Session gate.** No ducking before the first struck ball of a session. You're
warming up and your routine isn't consistent yet.

**The duck is iOS's, not ours.** We hold `.playAndRecord` with `.mixWithOthers`
+ `.duckOthers` and sit silent. Producing audio makes iOS duck the other app
(≈ −20 dB, close to the 10% target). There is no API to reach into Spotify.

**Timing.** Takeaway → phone (30–80 ms) → mic live (40–200 ms) = 70–280 ms,
against ~1.1 s until impact. Triggering on the downswing would leave ~250 ms and
slower earbuds would miss it entirely.

**Ensemble.** Traces are impact-aligned *and* time-normalized. Skip the
normalization and a fast swing smears against a slow one, and you read tempo
difference as inconsistency.

---

## Known limits — real, not hedging

- **Series 7 clipping.** ±16 g accelerometer, no high-g sensor (Series 8+ only).
  Impact will saturate. `metrics.clipped` flags it and the UI says so; treat
  peak acceleration as a floor.
- **100 Hz vs a 5 ms strike.** We detect the shock envelope, not the spike.
  ±10 ms timing — fine for tempo, wrong for anything finer.
- **No ball data.** No carry, spin, face angle, or strike location. This
  measures your body. Keep a launch monitor for the ball.
- **HFP quality dip.** Recording on Bluetooth earbuds forces mono 8–16 kHz.
  Scoped to the ~4 s shot window by arming late and disarming after.
- **Battery.** 100 Hz plus a workout session on a 2021 watch: budget 2–3 hours.
- **Paired-device route** is declared in `AudioRoute` and the `AudioHost`
  protocol but not implemented — `LocalAudioHost` is the only conformer, and the
  Setup picker no longer offers it. It falls back to the built-in mic if set.
- **Club identification** doesn't exist. No sensor gives it.

## Invariants — these were bugs once, don't reintroduce them

- **Capture is independent of arming.** Every takeaway is tracked and every
  swing is logged, armed or not. Arming decides one thing: whether the duck
  fires. Coupling them made the first-strike gate an unescapable deadlock and
  meant calibration (ducking off) recorded nothing.
- **Config crosses devices via `ConfigSync`, never `UserDefaults`.** Phone and
  watch have separate defaults domains. The watch detector depends on
  handedness, wrist, and sensitivity, and silently ran on defaults until this
  existed.
- **The audio session is torn down after every swing** (`scheduleDisarm`).
  Leaving it open pins Bluetooth earbuds to HFP for the whole session.
- **`impactIndex` skips 250 ms after takeaway and takes the first threshold
  crossing**, not the global max — otherwise the takeaway spike or a club drop
  wins.
- **Plateau segmentation runs at 10 Hz, not 100 Hz.** It's expensive and a hold
  lasts a second.
- **The phone app must be running** for `sendMessage` to land. Both UIs say so.
- **Never call `setActive(false)` outside `endSession()`.** Dropping the session
  between swings suspends the app and kills everything downstream.
- **Permissions are requested in onboarding, not discovered mid-round.**
  `Permissions` owns the state and `blocker` names what's wrong in one line.
- **Never call `setActive(false)` outside `endSession()`.** Dropping the session
  between swings suspends the app and kills everything downstream.
- **Permissions are requested in onboarding, not discovered mid-round.**
  `Permissions` owns the state and `blocker` names what's wrong in one line.
- **`takeawayIdx` is offset whenever the buffer trims.** It's an absolute index
  into a rolling buffer; without the offset it drifts one position per sample
  and every metric reads garbage.
- **Swing confidence is computed at completion from that swing's own signature**,
  before `template.learn`. Reusing `armConfidence` let an unarmed rehearsal
  inherit the previous swing's score — the exact field calibration averages.
- **Impact thresholds are per sensor position.** Wrist 180, pelvis 35. The wrist
  number on pelvis data never crosses, so the metric returns nil forever.
- **Pelvis sequencing is snapshotted at the impact event**, not when the swing
  arrives — `transferUserInfo` can lag well past the 15 s pelvis buffer.
- **Swings spool on the watch until the phone acks them**, and the phone dedupes
  by swing id because retries are expected.
- **Never call `setActive(false)` outside `endSession()`.** Dropping the audio
  session between swings suspends the app in the pocket and kills CoreMotion,
  watch messages, and the duck along with it.
- **Permissions are requested in onboarding, not discovered mid-round.**
  `Permissions` owns the state and `blocker` names what's wrong in one line.

## Interaction rules — deliberate, don't undo them

- **The watch owns the session.** There is no phone-side start button. The phone
  is in a back pocket and cannot be a control surface; it mirrors `sessionStart`
  and `sessionEnd` from the watch.
- **The Range tab is not a live dashboard.** It's what you see before you start
  and after you finish. Anything live belongs on the watch.
- **Two haptics, both outside the swing.** One when it arms (you're still), one
  after a swing is captured (you're done). Nothing fires at takeaway — buzzing a
  player's wrist as their backswing begins is the worst possible moment.
- **One consistency word.** It is always *Repeatability*, always a percentage,
  always lower-is-better. Never "variation", "CV", or "band width" in user copy.
- **Amber = the app is doing something. Red = destructive only.** Recording is
  never red.
- **Sensitivity is named, not numeric.** "0.62" means nothing to a golfer.
- **Deletes confirm and can be undone.** A mis-tap shouldn't cost a rep.

## First run

`OnboardingView` gates the app until it's done: what this is → the two questions
that can't be inferred (handedness, watch wrist) → calibration. Calibration has
the player take ~8 real shots and ~8 rehearsals with ducking off, then shows the
actual separation found via `SeparationBar` before the detector is trusted. If
separation is under 0.10 it says so plainly and recommends the strict setting
rather than pretending it works.

## First session

Start the watch, put the phone in your back pocket, hit 150+ balls with a normal
mix of real swings and rehearsals — including the deliberate rehearsals, which
are the hard case. Then read **Repeatability** and the ensemble on the Profile tab.
If the band is tight and rehearsals aren't triggering the duck, it works.
