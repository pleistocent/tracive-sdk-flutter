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
    scopes: const [TraciveScopes.scammerCheck],
  ),
  // `installUrl` — where a user without the Tracive app is sent — defaults to
  // the install page every Tracive SDK opens. Pass one only to override it, and
  // pass a real URL: omitting it means "use the default", while a blank or
  // whitespace-only string is a configured value and throws `ArgumentError`
  // (`blank_install_url`) right here. See `doc/oauth.md`.
  // environment: TraciveEnvironment.sandbox,  // while you are developing
);
```

**Name the scopes with `TraciveScopes`, do not type the strings.** A scope name
is only ever validated by the authorization server, which rejects the whole
consent request when it does not recognise one — so a typo is not a narrower
grant, it is an integration that cannot authorize at all, failing identically
whichever name is wrong. Ask for the narrowest set that works: an unused scope
on the consent screen is one more permission the user has to accept.

| Constant                     | Wire value      | Grants                                    |
| ---------------------------- | --------------- | ----------------------------------------- |
| `TraciveScopes.scammerCheck` | `scammer.check` | running a scammer check (`checkScammer`)  |
| `TraciveScopes.creditsRead`  | `credits.read`  | reading the remaining credits (`credits`) |
| `TraciveScopes.profileRead`  | `profile.read`  | reading the minimal profile (`profile`)   |

`scopes` defaults to `[TraciveScopes.scammerCheck]` alone. Check
`AuthAuthorized.grantedScopes` rather than assuming you were given what you
asked for.

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
} on TraciveInvalidTokenException {
  sendUserBackToConsent();            // no usable grant stored; nothing was sent
} on TraciveNetworkException {
  showOffline();
} on TraciveException catch (e) {
  report(e);                          // sealed base type; catch-all
}
```

### A damaged grant repairs itself, and costs one extra round trip

`TraciveInvalidTokenException` is what you get when there is no usable grant — but not every damaged
record is one. If the stored access token is blank while the refresh token beside it is still good,
the SDK renews it with a single `POST /oauth/token` and carries on. You will see one unexplained
refresh before the call you actually made, and nothing else.

That state is reachable from a partial write, a save interrupted by process death, or a restored
backup. The alternative would be to declare the grant lost and send the user back through consent to
replace a credential that never stopped working.

`TraciveInvalidTokenException` is reserved for the case where there is genuinely nothing to spend:
no access token and no refresh token. Nothing is sent to the server on that path, so nothing is
billed.

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
ships its own, and **you do not have to install anything**: the default is
`UnormNormalizer`, full Unicode NFC, backed by `unorm_dart`. That package is
already a declared dependency of this SDK, so it costs you nothing to add and
nothing to configure.

This matters because the folded key **is** the record key. A key that differs
from the server's by one code point resolves to a record that does not exist,
so the check misses — and a miss is billed, with nothing in the response to
notice it by. Full NFC by default is what keeps this SDK's keys identical to
the Kotlin, Swift and React Native SDKs', which get NFC from their platforms.

### Measured, not assumed

`UnormNormalizer` was checked against Python 3's `unicodedata` at Unicode
16.0.0 — the release the server's JavaScript engine folds against. It agrees on
63 487 of the 63 488 BMP code points fed in raw, and on all 20 000 randomly
generated multi-code-point sequences over a deliberately hostile alphabet
(combining marks, Hangul jamo, Indic and Tamil two-part vowels, Tibetan, Kana
voicing marks, Hebrew presentation forms, Arabic hamza carriers).

The single divergence is **U+D7A4**: `unorm_dart` treats it as a Hangul
syllable and decomposes it, but the Hangul Syllables block ends at U+D7A3 and
U+D7A4 is unassigned, so true NFC leaves it alone. It is left uncorrected
deliberately — no input method produces an unassigned code point, and owning a
patch around a third-party bug means re-verifying it on every release of that
package. Ordinary Hangul is unaffected: the composition direction is correct.

### The opt-out, and when it is worth taking

`DefaultNormalizer` is also shipped: dependency-free, implementing the
composition half of the algorithm only. It is **exact** for ASCII, Latin,
Greek, Cyrillic and Hangul, and for any input that is already decomposed (which
is what Apple platforms hand back). It diverges from full NFC in three narrow
cases: singleton decompositions (U+212B ANGSTROM SIGN), composition-excluded
characters (U+0958 DEVANAGARI QA, the Hebrew presentation forms), and
already-composed text followed by a lower-class combining mark. Measured the
same way: 565 of 63 488 BMP characters fed raw, and zero divergences over
16 467 already-decomposed inputs.

It is faster — roughly 25 ns per fold for an ASCII identifier against about
3 µs for full NFC. Read those as absolutes before reading them as a ratio: one
fold happens per query, which is one per check, which is one network round trip
of tens of milliseconds. Folding 10 000 identifiers costs about 30 ms in total.

So install it only if you have measured a problem *and* your identifiers stay
inside its documented scope:

```dart
import 'package:tracive_sdk/tracive_sdk.dart';

void main() {
  // Only with the trade above understood: 565 BMP code points then fold to a
  // key the server does not hold, and each resulting miss is billed.
  TraciveNormalization.normalizer = const DefaultNormalizer();
  runApp(const MyApp());
}
```

Whichever you install, install it once, before building any query. Changing it
afterwards throws `StateError`: the folded key is also the cache key, so a
mid-run swap orphans every row written before it.

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

