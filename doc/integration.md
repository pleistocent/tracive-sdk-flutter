# Integration guide

> **Status: phase 1 — OAuth mode only.** Build against sandbox first. Sandbox
> and production are separate registrations: each needs a client id issued for
> it, with your redirect registered on that client, and a sandbox client id is
> unknown to production. Proxy mode arrives in phase 2
> (`doc/proxy-contract.md`).

---

## 1. Add the dependency

```yaml
dependencies:
  tracive_sdk: ^0.2.1
```

Requires Dart `^3.5.0` and Flutter `>=3.24.0`. It pulls in `http`, `crypto`,
`flutter_secure_storage`, `sqflite_sqlcipher`, `url_launcher`, `path` and
`unorm_dart`, and carries a small Android and iOS module of its own for
[step 9](#9-report-a-scammer). Rebuild the app after adding or upgrading it; a
hot restart does not load native code.

Android and iOS only. On web and desktop the query builders, models and error
types all work, but `sqflite_sqlcipher` has no implementation there — use
`CheckCache.inMemory()` (see step 5) — and there is no Tracive app to authorize
against.

## 2. Platform setup

The OAuth flow needs a few lines of Android manifest and `Info.plist` before it
can even detect whether the Tracive app is installed. **Do this first**; without
it every user looks un-onboarded. The report form adds two iOS schemes, in
[step 9](#9-report-a-scammer).

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
deep link to `client.handleCallback(url)`, `switch` on the sealed `AuthResult`
— and on `null`, which means the link was not this SDK's to interpret.

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

A bank can also be named the way your own records may already hold it — by its
national bank code or its BIC:

```dart
TraciveQuery.bankAccountByShortCode(countryAlpha3: 'IDN', bankShortCode: '014', account: '3242-4242-422');
TraciveQuery.bankAccountByBic(countryAlpha3: 'IDN', bic: 'CENAIDJA', account: '3242-4242-422');
```

Both translate the code to Tracive's bank code through a table shipped inside
the SDK, offline, so each builds exactly the key `bankCode: 'BCA'` builds and
shares its cache entries. Leading zeros are optional (`14` finds `014`), and an
11-character BIC is looked up by its first 8. A code the table does not list for
that country throws `unknown_bank_code` before any request, so it is never
billed.

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
  // 'unknown_bank_code', 'empty_value', 'empty_handle', 'empty_chain',
  // 'empty_address', 'empty_platform', 'invalid_document_id'.
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
  if (e.isDailyQuotaExceeded) {
    tryAgainTomorrow();               // retryAfter runs to 00:00 UTC
  } else {
    backOff(e.retryAfter);            // never auto-retried
  }
} on TraciveTranslationNotPermittedException {
  checkAgainInEnglish();              // same query, no locale
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

Three more are about your contract or quota rather than your code:

| Type | When | What to do |
|---|---|---|
| `TraciveUserCreditNotPermittedException` | 403 on a check: your contract does not let you charge the user's subscription credits | contact Tracive; retrying will not help |
| `TraciveTranslationNotPermittedException` | 403 on a `Detail.full` check with a non-English `locale`: your contract withholds translation, or the user has no premium subscription | check again without `locale` for the English result |
| `TraciveRateLimitedException` with `isDailyQuotaExceeded` | 429: a daily allowance is spent (the connection's daily quota, its account reads, or the sandbox org cap), and `retryAfter` points at 00:00 UTC | tell the user to try later; the SDK never retries a 429 |

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

Every check nonetheless leaves with an `Idempotency-Key`: when you supply none,
the SDK generates a per-call one (prefixed `sdk-`, so a server-side log can tell
it from yours) purely so that its **own** replay after a 401 refresh can be
collapsed into a single charge. It is not a retry budget — that still keys off
*your* key — and it is not deduplication across processes, because it is
regenerated on every call.

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

### Keep the check on the transaction it belongs to

A verdict is worth showing twice: once while the user can still stop, and once
afterwards, on the record of what they did. The second one is not a second check
— record the first and read it back.

```dart
// After the transfer is created and has its own reference.
await client.cache.writeTransactionCheck(transaction.reference, result);

// On the transaction detail, however much later.
final shown = await client.cache.readTransactionCheck(transaction.reference);
if (shown != null) {
  renderSecurityCheckCard(shown);   // tier, counts, shown.fetchedAt, shown.disclaimer
}
```

**When to run the check**

- **On the confirmation screen, before the PIN.** The user has seen the payee's
  name and the amount, so they have a reason to care, and they have not
  authorised anything yet, so a warning can still save the money for free.
- **Not while they are typing the account number.** There is no payee name on
  screen yet, so the answer means nothing to them — and every typo costs a
  credit.
- **Not on the receipt.** A warning after the money has gone is not protection,
  it is bad news. The receipt is the right place to *record* that a check
  happened, never to run one.
- **On the first transfer to a given account, plus a manual "check this payee"
  action.** Re-checking a payee the user pays every month spends their credits
  and teaches them to swipe past the result.

**When to record it**

- **Whenever a transaction exists and a check was run for it** — including, and
  especially, one where the user was warned and chose to continue. That is the
  transfer whose history someone will ask about.
- **Once per transaction, not once per check.** Two transfers to one account
  share one billed check; call `writeTransactionCheck` twice, with each
  transfer's own id.
- **Never when the user declined the check.** `null` means no card, which is the
  truth. Rendering an empty result as "no reports found" invents a reassurance
  nobody gave.
- **Do not send any of it to your own servers.** The partner terms forbid
  uploading Tracive results, including derived values like a tier or a report
  count. What may leave the device is the user's decision — `riskAccepted`,
  `riskAcceptedAt` — and that is enough to defend the transfer in a dispute.

Full rules in [caching.md](caching.md#recording-what-a-transaction-was-shown).

## 9. Report a scammer

A transaction detail screen is also where a user who has just been scammed
looks for help. `openReportForm` opens Tracive's report form with the
recipient's account, the transaction date and the receipt already filled in;
the user reviews and submits it in the Tracive app.

```dart
Future<void> report(BuildContext buttonContext, Transaction transaction) async {
  final box = buttonContext.findRenderObject()! as RenderBox;
  final origin = box.localToGlobal(Offset.zero);

  final result = await client.openReportForm(
    TraciveQuery.bankAccount(
      countryAlpha3: 'IDN',
      bankCode: transaction.bankCode,
      account: transaction.account,
    ),
    incidentDate: transaction.localDate,
    attachments: [ReportAttachment.image(transaction.receiptPng, 'image/png')],
    anchor: ReportFormAnchor(
      left: origin.dx, top: origin.dy,
      width: box.size.width, height: box.size.height,
    ),
  );

  switch (result) {
    case ReportFormOpened():            break; // Tracive is in front now
    case ReportFormCancelled():         break; // iOS: user backed out; nothing sent
    case ReportFormInstallPageOpened(): showSnack('Install Tracive, then tap Report again');
    case ReportFormFailed(:final error): showSnack('Could not open the report form (${error.code})');
  }
}
```

**What it does not need.** No grant, no token, no credit, no request: it works
for a confidential client, before `authorize()`, and in proxy mode. The receipt
goes from your app to the Tracive app on the same phone and nowhere else.

**`incidentDate` is a calendar date.** Only `year`, `month` and `day` are read,
exactly as they are; there is no time zone conversion. Pass the date your user
saw on the transaction. If you hold a UTC timestamp, call `.toLocal()` first,
or a transfer made at 06:00 in Jakarta is reported as the day before. A date
after the device's local today is refused.

**What is checked, in this order, before anything is opened:**

| `error.code` | Rule |
|---|---|
| `INCIDENT_DATE_IN_FUTURE` | the date is after the device's local today |
| `TOO_MANY_ATTACHMENTS` | more than 5, or more than 10 when the query is a phone number (`max`) |
| `UNSUPPORTED_TYPE` | not `image/jpeg` (`image/jpg` accepted), `image/png`, `image/webp`, `image/heic`, `image/heif`, `image/bmp` or `application/pdf`; GIF is refused (`index`) |
| `CONTENT_MISMATCH` | the bytes are not the declared type, or are empty (`index`) |
| `PDF_TOO_LARGE` | a PDF of 1,048,576 bytes or more (`index`) |
| `PACKAGE_TOO_LARGE` | the encoded package is over 20 MiB, about 15 MiB of attachments (`max`) |
| `PLATFORM_FAILURE` | the platform refused the hand-off; `reason` says which step |

The Tracive app checks all of it again on receipt, since any app on the phone
can send it a package. Checking here first means nothing the SDK accepts is
silently dropped there.

**What happens next**, against the Tracive build for your `environment`
(sandbox for sandbox, production for production and for a custom base URL):

| On the device | Android | iOS | Result |
|---|---|---|---|
| Tracive, a version that takes attachments | the report form opens | the "Open in" sheet; the user taps Tracive | `ReportFormOpened(attachmentsDelivered: true)` |
| … and the user closes the sheet, or picks "Save to Files" or another app | — | nothing is sent to Tracive | `ReportFormCancelled()` |
| … and the iPad is rotated with the sheet open, which closes it | — | nothing is sent to Tracive | `ReportFormCancelled()`, about a second later |
| Tracive, an older version | opened on the account alone | the same, once the user allows iOS's "open Tracive?" prompt (cancelling it gives `ReportFormCancelled()`) | `ReportFormOpened(attachmentsDelivered: false)` |
| No Tracive | the install link | the install link | `ReportFormInstallPageOpened()` |

The install link is the one `authorize()` opens, and carries neither the
account nor the files: it goes through a third-party link service. The account
link of the older-app row is sent to the Tracive package alone on Android, and
to the Tracive scheme on iOS.

### iOS: two more queried schemes

```xml
<key>LSApplicationQueriesSchemes</key>
<array>
    <string>tracive</string>
    <string>tracivesandbox</string>
    <string>tracive-report</string>
    <string>tracivesandbox-report</string>
</array>
```

The `-report` schemes are registered only by Tracive versions that take
attachments; the "Open in" sheet cannot tell an old version from a new one.
**If you leave them out**, `canOpenURL` says no and every user gets the
older-app row: the form opens on the account alone, without the date and the
receipt. That is the safe direction, but it is easy to miss, so test it once
with a current Tracive build.

Pass `anchor`, the button's rectangle in the Flutter view's logical
coordinates. On iPad the sheet is a popover and points at it; without one it
points at the middle of the screen. iPhone and Android ignore it.

### Android: what lands in your merged manifest

Banks audit the merged manifest, so here is everything this package adds:

```xml
<queries>
  <intent>
    <action android:name="android.intent.action.VIEW" />
    <data android:scheme="tracive" />
  </intent>
  <intent>
    <action android:name="android.intent.action.VIEW" />
    <data android:scheme="tracivesandbox" />
  </intent>
</queries>

<provider
  android:name="id.tracive.sdk.flutter.TraciveFlutterFileProvider"
  android:authorities="${applicationId}.tracive-flutter-files"
  android:exported="false"
  android:grantUriPermissions="true">
  <meta-data
    android:name="android.support.FILE_PROVIDER_PATHS"
    android:resource="@xml/tracive_sdk_flutter_report_paths" />
</provider>
```

- The **provider** serves one folder, `cache/tracive-sdk/report/`, which holds
  at most one package; the previous one is deleted on the next call. It is
  never exported. Read access is granted per intent, to an explicit
  `ACTION_VIEW` addressed to the Tracive package alone, so no other app can
  receive or open the file. It is a subclass of androidx's `FileProvider`, so it
  does not collide with yours, and its authority is not the one the other
  Tracive SDKs use.
- The **queries** make the production and sandbox Tracive apps visible on
  Android 11+, which both the presence check and the hand-off need. They name
  schemes, not packages: no Tracive application id is written into your
  manifest.

### Testing against another build

`target:` aims the call at a build the SDK does not know about — for testing
against it, never in production:

```dart
await client.openReportForm(
  query,
  target: ReportFormTarget(
    androidPackage: 'com.example.qa',
    iosBundleId: 'com.example.qa',
    appScheme: 'exampleqa',
    capabilityScheme: 'exampleqa-report',
    fileExtension: 'exampleqareport',
  ),
);
```

That build needs a `<queries><package android:name="…"/>` entry in your own
manifest and its two schemes in `LSApplicationQueriesSchemes`; the SDK's
manifest only makes production and sandbox visible.

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

`serverFirst` falls back to the cache only for **transport-shaped** failures —
a network error, a 5xx, a 429. Those mean *the server could not answer right
now*, and none of them says anything about whether you were entitled to an
answer.

It does **not** fall back for anything that carries a verdict about the caller:
`grant_revoked`, `missing_scope`, a rejected token, or a **402**. The 402 is the
one worth being explicit about. An exhausted balance served from the cache is
indistinguishable from a normal answer — no exception, no flag on the result —
so you would keep believing the integration was healthy until the cache emptied
and every check started failing at once, on a payment screen, with no warning
that it had been building for days. `TraciveInsufficientCreditsException` is
raised the moment it happens instead, which is what gives you the chance to top
up. An empty balance is not a transient server condition.

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
  reportFormLauncher: myFakeReportForm, // ReportFormLauncher
);
```

Write your tests the same way. A test that reaches for either environment
fails whenever that environment is down or mid-deploy.

