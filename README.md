# Tracive SDK for Flutter

Check a phone number, e-mail address, bank account, crypto address or social
handle against Tracive's scam reports, from a Flutter app.

[![CI](https://github.com/pleistocent/tracive-sdk-flutter/actions/workflows/ci.yml/badge.svg)](https://github.com/pleistocent/tracive-sdk-flutter/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)

---

## Read this before you start

Three things, stated plainly, because finding them out later is expensive:

1. **The backend Open API is not live yet.** No `/v1/*` route, no
   `/oauth/token`, nothing. This SDK is built against a frozen contract, and
   every one of its tests runs **with no network, by design**. You can
   integrate, compile and unit-test today. You cannot get a real answer.
2. **phase 1 is OAuth mode only.** `TraciveMode.proxy(...)` exists in the type
   system so that adding it later is not a breaking change — and every call made
   in that mode throws `TraciveNotImplementedException('Proxy mode arrives in
   phase 2')`. See [`doc/proxy-contract.md`](doc/proxy-contract.md).
3. **There is no API-key parameter anywhere in this SDK, in any mode.** That is
   a design invariant, not an oversight. An API key shipped inside a mobile
   binary is an API key that has been published. Authentication is OAuth 2.0
   with PKCE, so nothing long-lived and secret ever ships in your app.

This is `0.1.0`. The surface may still change in a minor release until `1.0.0`.

---

## Install

```yaml
dependencies:
  tracive_sdk: ^0.1.0
```

Dart `^3.5.0`, Flutter `>=3.24.0`, Android and iOS.

Then add the platform bits the OAuth flow needs — four lines of
`AndroidManifest.xml` and three of `Info.plist`. Without them the SDK cannot
tell whether the Tracive app is installed and every user looks un-onboarded:
[`doc/oauth.md` § Platform setup](doc/oauth.md#platform-setup).

## Use

```dart
import 'package:flutter/material.dart';
import 'package:tracive_sdk/tracive_sdk.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final client = TraciveClient(
    mode: TraciveMode.oauth(
      clientId: 'your-client-id',
      redirectUri: 'https://your.app/oauth/callback', // an App Link you own
    ),
    cache: await openTraciveCache(),                  // encrypted, on device
  );

  // 1. The user consents in the Tracive app (Custom Tab / Universal Link).
  await client.authorize();
  // ... and in your deep-link handler:
  //     await client.handleCallback(incomingUrl);

  // 2. Check something.
  final result = await client.checkScammer(
    TraciveQuery.phone('+62 812-3456-7891'),
  );

  if (result.riskTier.isRisky) {
    // Show these; do not log them. `disclaimer` is not decoration — these are
    // user-submitted reports, not adjudicated findings, and this SDK never
    // logs anything itself.
    showWarning(
      title: '${result.riskTier.wireValue}: ${result.reportTotal} reports',
      body: result.disclaimer,
    );
  }
}

/// Your own UI. This SDK has none, and logs nothing — a risk verdict and a
/// disclaimer belong on screen, not in a log line that ends up in a crash
/// report.
void showWarning({required String title, required String? body}) {
  // ...
}
```

A runnable app is in [`example/`](example).

## What you get

| | |
|---|---|
| **Query builders** | phone, e-mail, bank account, IBAN, crypto, social handle — each folded to the exact key the backend indexes |
| **OAuth 2.0 + PKCE** | S256 only, app-presence pre-check, Custom Tabs / Universal Link, single-flight refresh, rotating refresh tokens |
| **Encrypted cache** | SQLCipher, key in Keystore/Keychain, per-tier TTL, server-driven invalidation |
| **Typed errors** | every documented `error.code` maps to a `TraciveException` subclass |
| **Testable offline** | the HTTP transport, the clock, the cache, the token store and the browser launcher are all injectable |

---

## Five things that will bite you if you skip them

### A miss is billed

Every query builder validates **before** anything leaves the device and throws
`TraciveQueryException` rather than send a key that could not possibly match.
A local-format phone number is rejected, not up-converted, and there is
deliberately **no `domain()` builder** — the backend dropped that input type, so
such a key could only ever miss.

### Do not poll `credits()` before every check

Make the check and handle the `402` (`TraciveInsufficientCreditsException`).
That is one round trip per transaction instead of two, and it is correct under
concurrency where a pre-check is not — the balance can change between the two
calls. Use `credits()` to *display* a balance, not to gate a call.

### Retrying a check needs an `Idempotency-Key`

This SDK will **not** auto-retry `checkScammer` on a 5xx or a timeout unless you
pass `idempotencyKey:`. A blind retry of a POST that may already have been
processed risks charging the user twice. Pass a UUID per logical check, stable
across your own retries.

### The authorization page never opens in a WebView

Custom Tabs on Android, `UIApplication.open` on iOS. This is not a style
preference: **App Links do not fire from an in-app WebView**, so the redirect
would never come back — and RFC 8252 forbids it, because a WebView is a browser
the host app can read the user's password out of.

### Surface `CheckResult.disclaimer`

These are user-submitted reports, not adjudicated findings. Presenting them as
the latter is how a false positive becomes a real person's problem.

---

## Privacy

- **No raw identifier is ever stored.** The cache key is
  `SHA-256(searchQueryIndex)`; the stored payload is counts, tiers, dates and
  tags. There is no column for the query.
- **Nothing is logged.** No `print`, no `debugPrint`, no analytics hook anywhere
  in `lib/`. Every `toString()` on a type holding an identifier, a token or an
  authorization code is redacted.
- **Tokens live in the Android Keystore / iOS Keychain**, never in
  `SharedPreferences`, `UserDefaults` or a plain file.
- `relatedScammerCount` is a **count, never a list** — returning the linked
  identifiers would leak third parties' data.

One thing the SDK cannot do for you: `TraciveQuery.searchQueryIndex` **is** the
raw identifier. Do not put it in a log line, a crash report or an analytics
event.

See [`SECURITY.md`](SECURITY.md) for the full invariant list and how to report a
vulnerability.

---

## Documentation

| | |
|---|---|
| [`doc/integration.md`](doc/integration.md) | Getting started, sources, errors, Unicode normalisation |
| [`doc/oauth.md`](doc/oauth.md) | The flow, platform setup, tokens, public vs confidential clients |
| [`doc/caching.md`](doc/caching.md) | TTLs, the invalidation lever, what is never cached, what is not unit-tested |
| [`doc/proxy-contract.md`](doc/proxy-contract.md) | phase 2: what a partner proxy must implement |
| [`SECURITY.md`](SECURITY.md) | Design invariants, reporting a vulnerability |
| [`CHANGELOG.md`](CHANGELOG.md) | Including the known limitations of `0.1.0` |

---

## Cross-SDK consistency

Kotlin, Flutter and Swift SDKs share one frozen surface, and the string-folding
grammar is pinned by a fixture vendored verbatim into all three:
`test/fixtures/query-grammar-vectors.json`. `test/query_grammar_test.dart` loads
it and asserts every vector, so a fold that drifts from the backend's fails the
build here rather than costing a customer a billed miss in production.

If you change a fold, you are changing the contract — the fixture, the other two
SDKs and the backend all move together.

## Development

```bash
flutter pub get
flutter analyze
flutter test
```

The suite needs no credentials, no emulator and no network. If a change makes a
test require any of those, the change is wrong.

## Licence

Apache-2.0 — see [`LICENSE`](LICENSE).
