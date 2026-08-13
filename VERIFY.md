# Phase 6 — verification

Everything below needs Xcode and the physical devices, so it runs on the Mac.
Nothing here was executed in the cloud container: it has no Swift toolchain
(`which swiftc` returns nothing, `uname` is Linux x86_64), so the code in this
commit is unbuilt.

Run it with:

    cd ~/Developer/Groove && git pull
    xcodegen generate && open Groove.xcodeproj

## 6.1 — every screen, both themes, populated and empty

| screen | Pines | Clubhouse | band on | band off | empty | populated |
|---|---|---|---|---|---|---|
| Today | | | | | | |
| Form | | | | | | |
| Setup | | | | | | |
| Onboarding | | | | | | |
| Watch | | | n/a | n/a | | |
| iPad second screen | | | | | | |

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

## 6.5 — the ten invariants

Verified by inspection in this commit; re-check after any merge.

1. `wasArmedForThisSwing` — RoutineDetector.swift:103,119,209
2. Config crosses via `ConfigSync.push` — PhoneController.swift:16,389
3. `takeawayIdx = max(0, t - removed)` — RoutineDetector.swift:146
4. Confidence computed before `template.learn` — RoutineDetector.swift:250,253
5. Thresholds wrist 180 / pelvis 35 — SwingAnalyzer.swift:13,14
6. Pelvis snapshot at the impact event — PhoneController.swift:238
7. `setActive(false)` exactly once, in `endSession()` — AudioHost.swift:158
8. Watch spools until acked — WatchController.swift:167
9. `persist()` guards on example mode — PhoneController.swift:344
10. `WKBackgroundModes` on the watch — Support/GrooveWatch-Info.plist:33
