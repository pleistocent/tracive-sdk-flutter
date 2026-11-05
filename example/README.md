# `tracive_sdk` example

A runnable app for `package:tracive_sdk`.

## Three flavors

| Flavor | Run | Talks to | Installs as |
|---|---|---|---|
| `demo` (default) | `flutter run` | nothing — `DemoBackend`, in-process | `….demo`, "Flutter Demo" |
| `sandbox` | `flutter run --flavor sandbox` | `https://api-sandbox.tracive.id/v1` | `….sandbox`, "Flutter Sandbox" |
| `production` | `flutter run --flavor production` | `https://api.tracive.id/v1` | the base id, "Tracive Flutter" |

**`demo` does not talk to a server.** It injects `DemoBackend` — an in-process
fake, about 190 readable lines in [`lib/demo_backend.dart`](lib/demo_backend.dart)
— as the client's HTTP transport, and pre-seeds a token, so a fresh clone runs
with no credentials and nothing to bill. `HttpTransport` is a one-method
interface precisely so that a fake is short enough to read; the same fake is how
you would widget-test your own checkout screen without a network.

**`sandbox` and `production` are the real integration**: the default transport,
the encrypted on-disk cache (`openTraciveCache()`), and **Authorize**, which
runs the OAuth round trip through the Tracive app and back to this one. Put the
client id Tracive issued you for each environment in
[`lib/flavor.dart`](lib/flavor.dart), and register that flavor's redirect on it —
they are separate registrations, and a sandbox client id is unknown to
production.

Each flavor installs as its own app. The SDK's token store and cache are not
keyed by environment, so one app rebuilt from sandbox to production would send
the sandbox grant to production and serve sandbox verdicts as production
answers. Separate apps need separate redirect schemes too, or the OS picks which
of them receives the authorization code. The per-flavor values live in
`lib/flavor.dart`, `productFlavors` in `android/app/build.gradle.kts`, and
`ios/Flavors/*.xcconfig`; Xcode has one scheme per flavor.

The redirects are private-use schemes (`tracive-flutter-sandbox://oauth/callback`)
only because this example controls no domain to host `assetlinks.json` or an
apple-app-site-association file on. A real integration uses an App Link /
Universal Link it owns — [`../SECURITY.md`](../SECURITY.md) says why.

## The launcher icon and the name

The example wears the Tracive app icon with a red "SDK" ribbon across the corner,
so it is not mistaken for the real Tracive app on a device that has both — and a
device that has both is the normal case, because the OAuth handshake needs the
real app.

**Both platforms' copies are committed**, along with the rest of
`example/android/` and `example/ios/`. That is the point of tracking those two
directories: while they were regenerated, every regeneration silently put back
the stock Flutter logo and the `Runner` display name, and nothing failed to say
so. The repository `.gitignore` has the full argument, and what is still left to
the Flutter tool.

The artwork is generated rather than drawn, and the Tracive app repository owns
the source:

```bash
# from the Tracive app repository
python3 scripts/generate_ribbon_icons.py --flutter-repo /path/to/tracive-sdk-flutter
```

Run it when the artwork changes, or when a Flutter or Xcode upgrade adds an icon
size — it reads the sizes out of each platform's own manifest (`Contents.json`
for iOS, the `mipmap-*` directories for Android) rather than a list of its own,
so it fills whatever the template declares. In between, the committed PNGs are
what the build uses.

The display name is `Tracive Flutter` for production, and "Flutter Sandbox" and
"Flutter Demo" for the other two — `TRACIVE_DISPLAY_NAME` in
`ios/Flavors/*.xcconfig`, `appLabel` in `productFlavors`. Keep each about that
short. iOS does not simply truncate a home-screen label that does not
fit — it tightens the tracking until the spaces close up, so an 18-character name
rendered as "TraciveSDKSa…", which reads as a typo rather than a long name; 15
still renders in full. The name says the platform rather than repeating "SDK",
which the ribbon already carries, and which would push this one to 19.

## Run it

```bash
cd example
flutter pub get
flutter run                        # demo
flutter run --flavor sandbox       # or --flavor production
```

The SDK is referenced by path (`tracive_sdk: {path: ../}`), so you are always
running the working tree, never a published version that may differ.

## What to try (demo)

| Do this | And notice |
|---|---|
| Press **Check** twice with `Source: cacheFirst` | "Backend calls this session" does **not** move the second time. That is a cache hit: zero credits, no network I/O. |
| Switch to `Source: server`, check again | The counter moves every time. Every one of those is a billed call. |
| Switch to `Source: cache`, press **Clear cache**, then **Check** | A `Cache miss` *error* — never a silent empty result, which a user would read as "not a scammer". |
| Turn on **Full detail**, check, then check again | Chronologies and comments appear on the server answer and are gone on the cache hit. Full detail is never cached. |
| Type `not-a-phone-number` and press **Check** | Rejected before any call is made, with the reason `not_e164`. Validation runs first because **a miss is billed**. |
| Press **Simulate 402** then **Check** | The typed `TraciveInsufficientCreditsException` — the one you should handle instead of polling `credits()`. |
| Look at the folded key under any result | `+62 812-3456-7891` became `PHONE_+6281234567891`. That folded string is both what goes on the wire and what the cache key is hashed from. |

## Report a scammer (any flavor)

**Report a scammer from a transaction** opens a mock transaction detail — an
amount, yesterday's date, a BCA account — with a **Report** button that calls
`openReportForm` with that account, that date and a receipt drawn in code (one
PNG, one small PDF). It makes no request and needs no grant, so it works in the
demo flavor too; what it needs is a Tracive app on the phone.

The picker chooses the build it opens:

| Target | Opens | Needs on the device |
|---|---|---|
| **Sandbox** (default) | `com.pleistocent.tracive.sandbox` | the sandbox Tracive app, which shows what arrived without submitting anything |
| **Production** | `com.pleistocent.tracive` | the production app — this opens a real report form |
| **Dev build (QA)** | `com.pleistocent.tracive.dev`, through `ReportFormTarget(...)` | a locally built dev Tracive app |

The dev build is reached through the SDK's explicit target override, which is
why this app's `AndroidManifest.xml` has a `<package>` entry for it and its
`Info.plist` lists `tracivedev` and `tracivedev-report`. A partner app needs
neither; it needs only `tracive-report` and `tracivesandbox-report` on iOS.

The result is shown under the button. With no Tracive app the install page
opens; with one too old to take attachments the form opens on the account alone.

## Two things the demo flavor is not

**It is not signed in the way your app will be.** Its token store is pre-seeded
with a fake token so the demo starts usable. The live flavors call
`client.authorize()`, which requires the Tracive app to be installed and a
registered redirect URI — see [`../doc/oauth.md`](../doc/oauth.md).

**Its cache is in memory**, so it runs anywhere, desktop included, with no
plugin. The live flavors pass `await openTraciveCache()`: SQLCipher on disk with
the key in Keystore/Keychain. See [`../doc/caching.md`](../doc/caching.md).

## Using it as your own experiment ground

Everything you have to supply — a client id and a redirect per environment,
`partnerUserId`, scopes — is marked `TODO(partner)`:

```bash
grep -rn "TODO(partner)" example
```

## Files worth reading

| File | Why |
|---|---|
| [`lib/main.dart`](lib/main.dart) | Client construction — note there is no API-key parameter, in any mode — plus the whole check flow and the `disclaimer` being surfaced. |
| [`lib/demo_backend.dart`](lib/demo_backend.dart) | The fake transport. Copy this shape for your own tests. |
| [`lib/main.dart`](lib/main.dart) (`main()`) | That there is nothing to install for Unicode NFC. The SDK folds every query through full NFC by default, so a non-Latin identifier produces the same key here as it does on the server. |
| [`lib/report_demo.dart`](lib/report_demo.dart) | The mock transaction detail and its `openReportForm` call, with the receipt drawn in code. |
| [`test/widget_test.dart`](test/widget_test.dart) | Widget tests asserting a cache hit does no network I/O, that invalid input never reaches the wire, and what the Report button hands over. |
