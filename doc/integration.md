# Integration guide

> **Status: phase 1 — OAuth mode only, and the backend Open API is not live
> yet.** You can integrate, compile and unit-test against this SDK today. You
> cannot get a real answer from it, because there is no server to answer.
> Proxy mode arrives in phase 2 (`doc/proxy-contract.md`).

---

## 1. Add the dependency

```yaml
dependencies:
  tracive_sdk: ^0.1.0
```

Requires Dart `^3.5.0` and Flutter `>=3.24.0`. It pulls in `http`, `crypto`,
`flutter_secure_storage`, `sqflite_sqlcipher`, `url_launcher`, `path` and
`unorm_dart`.

Android and iOS only. On web and desktop the query builders, models and error
types all work, but `sqflite_sqlcipher` has no implementation there — use
`CheckCache.inMemory()` (see step 5) — and there is no Tracive app to authorize
against.

## 2. Platform setup

The OAuth flow needs four lines of Android manifest and three of `Info.plist`
before it can even detect whether the Tracive app is installed. **Do this
first**; without it every user looks un-onboarded.

→ [`doc/oauth.md` § Platform setup](oauth.md#platform-setup)

## 3. Build a client

```dart
import 'package:tracive_sdk/tracive_sdk.dart';

final client = TraciveClient(
  mode: TraciveMode.oauth(
    clientId: 'your-client-id',
    redirectUri: 'https://your.app/oauth/callback',
    scopes: const ['scammer.check'],
  ),
  // `installUrl` — where a user without the Tracive app is sent — defaults to
  // the install page every Tracive SDK opens. Pass one only to override it.
  // environment: TraciveEnvironment.sandbox,  // while you are developing
);
```

**There is no API-key parameter here, in any mode.** That is a hard design
invariant, not an omission. A long-lived key shipped inside a mobile binary is a
published key; PKCE exists so there is nothing long-lived to ship.

## 4. Authorize

→ [`doc/oauth.md`](oauth.md). In short: `await client.authorize()`, route your
deep link to `client.handleCallback(url)`, `switch` on the sealed `AuthResult`.

## 5. Open the persistent cache (recommended)

```dart
final client = TraciveClient(
  mode: mode,
  cache: await openTraciveCache(),   // SQLCipher + Keystore/Keychain
);
```

Without this the client uses `CheckCache.inMemory()`: a real cache with the same
rules, which just does not survive a restart. Every cache hit is a credit you do
not spend, so the persistent one usually pays for itself on day one. A
constructor must not silently open a database file and a Keystore entry, which
is why it is opt-in rather than the default.

→ [`doc/caching.md`](caching.md)

## 6. Check something

```dart
final query = TraciveQuery.phone('+62 812-3456-7891');
// query.searchQueryIndex == 'PHONE_+6281234567891'

final result = await client.checkScammer(query);

if (result.riskTier.isRisky) {
  showWarning(
    tier: result.riskTier,          // HIGH | ELEVATED | CAUTION
    reports: result.reportTotal,
    disclaimer: result.disclaimer,  // surface this — see below
  );
}
```

Builders, all of which fold their input to the exact key the backend indexes:

```dart
TraciveQuery.phone('+6281234567891');
TraciveQuery.email('Budi@Example.COM');                  // -> EMAIL_budi@example.com
TraciveQuery.bankAccount(countryAlpha3: 'IDN', bankCode: 'BCA', account: '3242-4242-422');
TraciveQuery.iban('DE89 3704 0044 0532 0130 00');
TraciveQuery.crypto(chain: 'ETH', address: '0xAbC…');    // EVM addresses lowercased
TraciveQuery.username(platform: 'INSTAGRAM', handle: '@budi_scam');
```

There is deliberately **no `domain()` builder.** The plan listed a DOMAIN input
type; the backend dropped it. Building such a key would guarantee a miss, and a
miss is billed.

### Validate early, because a miss is billed

Every builder throws `TraciveQueryException` **before any network call** if the
input cannot produce a key the backend could match:

```dart
try {
  final query = TraciveQuery.phone(userInput);
  ...
} on TraciveQueryException catch (e) {
  // e.reason is a stable, cross-SDK string: 'not_e164', 'not_an_email',
  // 'country_not_alpha3', 'empty_account_id', 'empty_bank_code',
  // 'empty_value', 'empty_handle', 'empty_chain', 'empty_address',
  // 'empty_platform', 'invalid_document_id'.
  showFieldError(messageFor(e.reason));
}
```

A local-format number (`081234567891`) is **rejected, not up-converted**: the
server cannot infer the dial code either, so the SDK would silently be asking
about a different entity — and you would still be charged for the miss.

An e-mail address with no `@` (`not_an_email`) is rejected for the same reason.
The server applies no shape validation to an e-mail, so `EMAIL_budi` is a
perfectly legal record key: it is looked up, missed, and billed. The check is
`@`-presence only and is **not** an address grammar — `budi@localhost` and
`budi@[192.168.0.1]` are accepted, because the server would match them and a
stricter client would lock you out of a lookup that works.

Every empty field names itself, so you can put the message next to the right
input: `empty_chain` and `empty_address` for `crypto()`, `empty_platform` and
`empty_handle` for `username()`, `empty_bank_code` and `empty_account_id` for
`bankAccount()`. `empty_value` is the empty-e-mail case and nothing else.

## 7. Handle the errors that matter

```dart
try {
  final result = await client.checkScammer(query);
} on TraciveInsufficientCreditsException {
  offerTopUp();                       // the 402 — see below
} on TraciveRateLimitedException catch (e) {
  backOff(e.retryAfter);
} on TraciveGrantRevokedException {
  sendUserBackToConsent();            // tokens already cleared; do not retry
} on TraciveNetworkException {
  showOffline();
} on TraciveException catch (e) {
  report(e);                          // sealed base type; catch-all
}
```

### Do **not** poll `credits()` before every check

Make the check and handle the 402. Calling `credits()` first is two round trips
per transaction instead of one, and it is *wrong* under concurrency anyway — the
balance can change between the two calls, so the pre-check tells you nothing you
can rely on. Use `credits()` for a balance display, not as a gate.

### Retrying a check

This SDK will **not** auto-retry `checkScammer` on a 5xx or a timeout unless you
pass an `idempotencyKey`. A blind retry of a POST that may already have been
processed risks charging the user twice.

```dart
final key = const Uuid().v4();   // one per logical check, stable across retries
await client.checkScammer(query, idempotencyKey: key);
```

If you implement your own retry loop, pass one there too.

## 8. Surface the disclaimer

`CheckResult.disclaimer` is not decoration. These are **user-submitted reports,
not adjudicated findings**, and presenting them as the latter is how a false
positive becomes someone's problem — a real person locked out of a payment, on
the strength of a report nobody verified. Show it wherever you show the verdict.

---

## Choosing a `Source`

| `Source` | Behaviour | Use it when |
|---|---|---|
| `cacheFirst` *(default)* | Cache, then network | Almost always |
| `serverFirst` | Network, falling back to the cache when the server cannot answer | You want the freshest answer but a stale one beats none |
| `server` | Network only; never reads the cache | An explicit "refresh" button |
| `cache` | Cache only; **throws `TraciveCacheMissException` on a miss** | Offline mode |

`Source.cache` never returns a silent empty result — that would read as "not a
scammer", which is the most expensive wrong answer this SDK could give.

`serverFirst` falls back to the cache only for failures that mean *the server
could not answer right now* (transport, 5xx, 429, exhausted credits). It does
**not** fall back for `grant_revoked`, `missing_scope` or a rejected token:
papering over those hides a broken integration and keeps serving data the user
may have just revoked consent for.

---

## Unicode normalisation

The query grammar folds e-mail addresses, bank codes, chains, platforms and
handles through **Unicode NFC** — and Dart's core library has no NFC. The SDK
therefore ships `DefaultNormalizer`, a dependency-free implementation of the
composition half of the algorithm.

It is **exact** for ASCII, Latin, Greek, Cyrillic and Hangul, and for any input
that is already decomposed (which is what Apple platforms hand back). It
diverges from full NFC in three narrow cases: singleton decompositions
(U+212B ANGSTROM SIGN), composition-excluded characters (U+0958 DEVANAGARI QA,
the Hebrew presentation forms), and already-composed text followed by a
lower-class combining mark. Measured, not assumed: 565 of 63 488 BMP characters
fed raw, and zero divergences over 16 467 already-decomposed inputs.

Every divergence produces a **different key from the server's**, and a miss is
billed. If your app accepts identifiers where those characters are plausible,
install the full implementation at start-up. The SDK ships it as
`UnormNormalizer`, so this is the whole change — one line, no adapter to write:

```dart
import 'package:tracive_sdk/tracive_sdk.dart';

void main() {
  TraciveNormalization.normalizer = const UnormNormalizer();
  runApp(const MyApp());
}
```

Set it once, before building any query. (`example/lib/main.dart` does exactly
this.)

`UnormNormalizer` is backed by `unorm_dart`, which is already a declared
dependency of this SDK — you do not add anything to your `pubspec.yaml`. It is
**not** the default: switching the default would change every existing
integrator's folded keys, and therefore their cache keys, in a patch release.
Opting in is a decision your app makes knowingly.

---

## Testing your integration

Everything is injectable, and **no test in this SDK touches a network**:

```dart
TraciveClient(
  mode: mode,
  transport: myFakeTransport,           // HttpTransport
  clock: MutableClock(DateTime.utc(2026)),
  cache: CheckCache.inMemory(),
  tokenStore: InMemoryTokenStore(),
  launcher: myFakeLauncher,             // AuthLauncher
);
```

Write your tests the same way. A test that reaches for `api.tracive.id` cannot
pass today (there is no server) and will be flaky the day there is one.

