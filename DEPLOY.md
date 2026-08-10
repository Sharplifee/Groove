# Deploying Groove

## Read this first — it isn't Vercel

Sharp-OS and Atlas go live 60 seconds after a push because they're web. Groove
can't, and no amount of pipeline fixes that. Apple has no mechanism for pushing
new native code to a running app. Every change requires a compile on macOS, a
code signature, and a distribution step.

The webview-shell trick that makes momentum-customer feel instant doesn't rescue
this one either. That app is a thin wrapper around a hosted page, so the page
updates and the shell never changes. Groove can't work that way — it needs
`CoreMotion` at 100 Hz, `HKWorkoutSession`, and `AVAudioEngine`, and none of
those are reachable from a webview. The parts that make this app what it is are
precisely the parts that must be native.

So the question isn't how to get real-time. It's which of two loops you want.

## Loop A — local build, ~2-3 minutes

Fastest by a wide margin, and the lane already proven on this team (every
Momentum build to date was local `xcodebuild` + `altool`).

```bash
xcodegen generate
xcodebuild -scheme Groove -destination 'id=00008140-000E18EC1489801C' \
  -allowProvisioningUpdates build
xcrun devicectl device install app \
  --device 00008140-000E18EC1489801C build/.../Groove.app
```

Phone plugged in or on the same Wi-Fi. Watch app installs with it. Use this
whenever you're at the Mac — it's the only loop tight enough to iterate in.

## Loop B — push to main, ~20-30 minutes

`.github/workflows/testflight.yml` builds on a macOS runner, signs, and uploads
to TestFlight. You get a notification and tap update. Use it when you're away
from the Mac, or to get a build onto a device that isn't yours.

Timing, honestly: 8-12 min build, 5-15 min Apple processing, then whenever you
tap. It is not real-time and can't be made so.

### One-time setup

**1. Create the App Store Connect app record by hand.** `POST /v1/apps` returns
403 — this is documented in the credentials registry (row 405) and there is no
API path around it. App Store Connect → Apps → +, bundle ID `com.sharp.groove`.

**2. Add repo secrets** (Settings → Secrets → Actions). Everything except the
certificate is already in the registry:

| Secret | Where it comes from |
|---|---|
| `ASC_KEY_ID` | registry — App Store Connect Admin key |
| `ASC_ISSUER_ID` | registry — same row |
| `ASC_KEY_P8` | the `.p8`, base64'd: `base64 -i AuthKey_XXX.p8 \| pbcopy` |
| `DIST_CERT_P12` | export the distribution cert from Keychain, base64 it |
| `DIST_CERT_PASSWORD` | whatever you set on export |
| `PROFILE_IOS` | App Store profile for `com.sharp.groove`, base64'd |
| `PROFILE_WATCH` | App Store profile for the watch extension, base64'd |

Never commit any of these. The workflow reads them from the environment and
deletes the decoded files in the same step.

**3. Cost.** macOS runners bill at 10x, so the free private-repo allowance is
about 200 macOS-minutes a month — roughly 15-20 builds. The workflow ignores
markdown-only pushes and cancels superseded runs, but if you're iterating hard
you'll hit the ceiling. That's another argument for Loop A.

## "Adjustments on the go"

What that realistically means here:

- **Settings** — handedness, sensitivity, duck tail, demo mode — change live in
  Setup, no build required. `ConfigSync` pushes them to the watch mid-session.
- **Detection tuning** — thresholds, dwell times, plateau parameters — currently
  compiled in. If you want these adjustable on the go, they'd need lifting into
  `Config` and exposing in Setup. Say the word and it's a small change.
- **Anything structural** — new screens, new metrics, changed logic — needs a
  build. There is no way around that.

If the goal is tuning the detector at the range without a laptop, the honest fix
isn't a faster pipeline. It's moving the parameters you actually want to turn
into `Config`, so they're settings rather than code.
