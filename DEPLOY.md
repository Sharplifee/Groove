# Getting Groove onto the phone

Push to `main` → GitHub builds, signs, and ships to TestFlight → it appears on
your phone. No Mac, no cable, no Xcode.

That pipeline is built and working except for **one step Apple will not let any
API perform**. Do it once and every push after that is automatic.

---

## The one manual step

App Store Connect has no app record for `com.connor.groove`, so the upload has
nothing to upload *to*. `POST /v1/apps` returns:

    403 FORBIDDEN_ERROR
    The resource 'apps' does not allow 'CREATE'.
    Allowed operations are: GET_COLLECTION, GET_INSTANCE, UPDATE

Apple allows reading and updating apps over the API but not creating them. It
has to be done in the browser, once, and takes about two minutes.

1. Go to **appstoreconnect.apple.com** → **Apps** → **+** → **New App**
2. Fill in exactly:
   - **Platforms** — tick **iOS** only
   - **Name** — `Groove` *(if taken, anything unique; it's changeable later)*
   - **Primary Language** — English (U.S.)
   - **Bundle ID** — choose **Groove — com.connor.groove** from the dropdown.
     It is already registered (Apple resource `BW3Y9S5B4L`), so it will be in
     the list.
   - **SKU** — `GROOVE001`
   - **User Access** — Full Access
3. **Create**. Nothing else — no screenshots, no description, no pricing. Those
   are only needed for App Store review, and TestFlight doesn't need review.

Then either push any commit, or trigger the workflow by hand from the Actions
tab, and the build lands in TestFlight roughly 10 minutes later.

---

## What is already done

- **Bundle IDs registered.** `com.connor.groove` did not exist in the developer
  account — only `com.connor.groove.watchkitapp` did. Registered as
  `BW3Y9S5B4L`.
- **Repository secrets set** — `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8`,
  `TEAM_ID`. All four came from the credentials store; nothing had to be
  exported off a Mac.
- **Signing works.** The runner authenticates with the App Store Connect API
  key and mints its own certificate and provisioning profiles
  (`-allowProvisioningUpdates`). Run 31681656996 archived and exported a signed
  `Groove.ipa` containing both the phone app and the watch app.
- **It compiles.** `build-check.yml` proves it on every push: Xcode 16.4,
  Swift 6.1.2, 16 files across both targets, zero errors.

## Why the old workflow never worked

It wanted a distribution certificate as a `.p12` plus two provisioning
profiles, base64'd into four secrets that were never added. Every run since the
repo was created died at "Import signing certificate" without ever reaching the
compiler. It never needed any of them — Xcode signs from the API key alone.

## The two workflows

| workflow | when | what it proves |
|---|---|---|
| `build-check.yml` | every push | it compiles, both targets, no signing |
| `testflight.yml` | every push | it builds, signs, and ships to your phone |

Do not add `-sdk iphonesimulator` to either. It overrides the SDK for every
target in the scheme including the embedded watch app, and watchOS sources then
compile against iOS — `HKLiveWorkoutBuilder` comes back "unavailable in iOS".
The destination alone resolves the right SDK per target.
