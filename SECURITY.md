# Security Policy

## Reporting a vulnerability

**Do not open a public GitHub issue for a security problem.**

Report it privately, either way:

- **E-mail** — `developer@pleistocent.com`. If the report contains user data or
  a working exploit and you want it encrypted, say so in a first message with no
  details and we will send you a key.
- **GitHub** — *Security* → *Report a vulnerability* on
  <https://github.com/pleistocent/tracive-sdk-flutter> (GitHub Private
  Vulnerability Reporting). This is the preferred channel: it keeps the report,
  the fix and the advisory in one place.

Please include: the SDK version, the platform and OS version, what an attacker
gains, and the smallest reproduction you have. A proof-of-concept app or a
failing test is worth more than a description.

### What to expect

| Stage | Target |
|---|---|
| Acknowledgement of your report | 2 working days |
| Initial assessment and severity | 7 calendar days |
| Fix released, or a dated plan if it is not that simple | 90 calendar days |

We will credit you in the advisory and the changelog unless you ask us not to.
We do not currently run a paid bug-bounty programme.

**Coordinated disclosure.** Please give us the 90 days above before publishing.
If the issue is being exploited in the wild, tell us that in the first message —
that changes the timeline, and we would rather hear it from you than from a user.

## Supported versions

| Version | Supported |
|---|---|
| `0.1.x` | Yes |
| `< 0.1.0` | No — there is nothing earlier |

While the package is `0.x`, security fixes land on the latest minor version
only. There are no long-term support branches yet.

## Scope

**In scope:** anything in this repository — the SDK's Dart code, the example
app, the CI configuration, and the documentation where it tells an integrator to
do something unsafe.

**Out of scope here, but still wanted:** vulnerabilities in the Tracive backend,
the Tracive mobile app, or `tracive.id` itself. Report those to the same
address; they are simply not fixed by a change in this repo.

Also out of scope: findings in this SDK's third-party dependencies that have
already been published upstream (report those to the package's own maintainers),
and reports that amount to "the device is rooted / jailbroken", where the
attacker already has more privilege than any client-side control can withstand.

## Design invariants — treat a violation as a vulnerability

These properties are what this SDK is *for*. If you can break one, that is a
security bug even if nothing crashes.

1. **There is no API-key parameter anywhere in the public surface, in any
   mode.** A long-lived key shipped inside a mobile binary is a published key.
   Authentication is OAuth 2.0 with PKCE (S256 only), so the device holds only
   a short-lived access token and a rotating refresh token. A pull request that
   adds an API-key parameter will be rejected on sight.
2. **The raw identifier is never stored.** The cache key is
   `SHA-256(searchQueryIndex)`; the row payload holds counts, tiers, dates and
   tags, and nothing that names a person. Hashing is not encryption — someone
   holding the database and a list of candidate phone numbers can confirm a
   guess — which is why the database is *also* encrypted at rest.
3. **Nothing is logged.** No `print`, no `debugPrint`, no analytics hook
   anywhere in `lib/`. Every `toString()` on a type that holds an identifier, a
   token or an authorization code is redacted, and this is enforced by the
   `avoid_print` lint plus tests that assert redaction.
4. **Tokens live in the Android Keystore / iOS Keychain** — never in
   `SharedPreferences`, `UserDefaults` or a plain file.
5. **The authorization page never opens in a WebView.** Custom Tabs on Android,
   `UIApplication.open` / Universal Link on iOS. RFC 8252 forbids the WebView,
   and App Links do not fire from one anyway.
6. **Refresh is single-flight.** Concurrent `401 expired_token` responses
   trigger exactly one refresh. Getting this wrong trips the server's
   refresh-token reuse detection, which revokes the entire grant.
7. **A `checkScammer` is never auto-retried on a 5xx or a timeout without an
   `Idempotency-Key`.** A blind retry of a POST that may already have been
   processed risks charging the user twice.

## What this SDK cannot protect you from

Said plainly, so nobody relies on a guarantee that is not there:

- **A compromised device.** On a rooted or jailbroken device an attacker can
  read the Keystore-backed material and the decrypted cache. Client-side storage
  raises the cost of an attack; it does not stop one.
- **Your own logging.** The SDK does not log, but it hands you `CheckResult`
  and `TraciveQuery` objects. `TraciveQuery.searchQueryIndex` **is** the raw
  identifier — do not put it in a log line, a crash report or an analytics
  event.
- **A hostile redirect.** `state` is verified and a mismatch discards the code,
  but the redirect URI must be an App Link / Universal Link your app actually
  owns. A custom scheme any app can claim is not equivalent, whatever the
  registration screen accepts.
- **Storing the authorization code.** For a `confidential` client the SDK hands
  back `AuthResult.codeReceived`. That code and its verifier are bearer
  credentials until they are exchanged: forward them to your backend over TLS
  and hold them nowhere else.
