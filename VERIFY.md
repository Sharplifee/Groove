# Phase 6 — verification

## It compiles

`.github/workflows/build-check.yml` builds the app on a macOS runner with real
Xcode — simulator SDK, signing disabled, so it needs no certificates and no
secrets. Run 31680803075 on `1b915e9`:

    Xcode 16.4, Apple Swift 6.1.2
    16 source files compiled across both the phone and watch targets
    ** BUILD SUCCEEDED **
    0 errors

Every push to `main` re-runs it. Read the run summary for the error and warning
list; the full log is attached as an artifact.

Two errors on the first attempt turned out to be the workflow, not the code:
`-sdk iphonesimulator` overrides the SDK for every target in the scheme,
including the embedded watch app, so watchOS sources were compiled against the
iOS SDK and `HKLiveWorkoutBuilder` came back unavailable. The destination alone
resolves the right SDK per target. Don't re-add `-sdk`.

Four warnings remain, all the same shape: `WatchController`'s
`RoutineDetectorDelegate` methods are main-actor isolated where the protocol is
nonisolated. Harmless under the Swift 5 language mode this project pins, and an
error under Swift 6. Worth fixing before any move to Swift 6, not urgent now.

## What else has been verified, and how

A Swift 6.0.3 Linux toolchain was installed in the build container, so some of
this is no longer a matter of inspection:

- **Every file parses.** `Tests/parse-all.sh` runs `swiftc -parse` over all 14
  Swift files. Clean.
- **The shared logic type-checks in full.** `Models.swift`,
  `SwingAnalyzer.swift` and `RoutineDetector.swift` are Foundation-only and
  compile with no errors.
- **31 behavioural checks pass.** `Tests/run-checks.sh` builds and runs them:
  trace alignment against the chart's impact line, ensemble band ordering,
  self-labelling separation, JSON round-tripping, generator determinism, the
  lead-wrist derivation, sensitivity ordering, and the shape of the first-run
  example.

What that does **not** cover: SwiftUI, AVFoundation, CoreMotion and
WatchConnectivity do not exist off Apple platforms, so none of the view code or
the audio engine has been type-checked, and nothing has been run on hardware.
Expect the first Xcode build to surface type errors in the view layer.

Everything below still needs the physical devices. Compilation is now covered by
CI; behaviour on hardware is not.

Run it with:

    cd ~/Developer/Groove && git pull
    ./Tests/parse-all.sh && ./Tests/run-checks.sh
    xcodegen generate && open Groove.xcodeproj

## 6.1 — every screen, all three themes, populated and empty

| screen | Pines | Clubhouse | Augusta | empty | populated |
|---|---|---|---|---|---|
| Today | | | | | |
| Form | | | | | |
| Setup | | | | | |
| Onboarding | | | | | |
| Watch | | n/a | n/a | | |
| iPad second screen | | | | | |

Augusta wears its green bar as part of its identity; the other two have it as an
optional toggle. Check that Clubhouse now reads as clearly slate blue — lead
accent, chart trace, tab tint and primary buttons all moved, which is the fix
for the two light themes having been indistinguishable.

The Xcode canvas covers most of this without a device — `DemoData.swift`
carries previews for Today, Form, Setup, Onboarding, the paired screen, the
ensemble chart, and five watch states.

## 6.2 — a full range session

- [ ] Phone in a back pocket, screen off, watch starts the session
- [ ] App still alive after ten minutes idle in the pocket
- [ ] Music ducks at takeaway, not at address
- [ ] The strike burst fires once and does **not** echo
- [ ] Music returns after the tail, at full volume
- [ ] **Music never degrades.** `c.outputIsHighFidelity` must stay true for the
      whole session. If it ever goes false, HFP has been negotiated and the
      option set is wrong — check that `.allowBluetooth` has not crept back in
      anywhere near `setCategory`.
- [ ] Swings reach the phone and appear in Form
- [ ] Rehearsals are logged but do not duck

Burst shape is tunable at the top of `LocalAudioHost` — `burstWindow` 130 ms,
`burstPreRoll` 18 ms, `burstFade` 6 ms, `burstGain` 1.6. Expect to move these
once on a real range; the defaults are reasoned, not measured.

## 6.3 — fresh install

- [ ] Delete the app, reinstall, launch
- [ ] Onboarding runs
- [ ] Today and Form open **populated** with the four-session example
- [ ] The example marker sits at the top of both
- [ ] Export is refused while the example shows
- [ ] First real swing folds the example away and shows the real session
- [ ] Example never reaches `swings.json`

## 6.4 — accessibility

- [ ] Dynamic Type at the largest setting: no clipping, no truncation
- [ ] VoiceOver reads every stat, chart and control
- [ ] Contrast holds in both themes (token values are AA-checked in Theme.swift,
      but check the composed screens)

## 6.5 — the invariants

Re-check after any merge. The harness (`Tests/run-checks.sh`, 155 checks) pins
every engine item below; the rest are by inspection.

1. Capture is independent of arming — every episode is classified and logged
   whether or not audio was engaged (`RoutineDetector.close`)
2. Config crosses via `ConfigSync.push`, including `duckMode`
3. Rolling-buffer indices shift with every trim (`ingest`, episode fields)
4. Confidence is computed before `template.learn`, and only swings from a
   settled address teach the template
5. Thresholds per discipline (`Discipline.wristImpactThreshold` 110 / 40 / 18 / 9;
   pelvis 22 / 12 / 7 / 4) scaled by each swing's peak, never below the
   swing-speed floor
6. Pelvis snapshot at the "struck" event — `PhoneController.handle`
7. `setActive(false)` exactly once, in `LocalAudioHost.endSession()`
8. Watch spools in memory, persists on change, drains on either ack channel
9. `persist()` guards on example mode
10. `WKBackgroundModes` on the watch — Support/GrooveWatch-Info.plist
11. A strike is a spike: above the scaled floor, 3× the local texture, half
    the jump given back within three samples, only once the motion has
    reached swing speed, never in a motion with three stride lobes
12. Transient events (arm/disarm/takeaway/impact/restore/motion) are never
    queued durably; `sentAt` stamps every event
13. Frame time is `CMDeviceMotion.timestamp`, not delivery wall-clock
14. The replay tool never persists a template into the host's defaults
