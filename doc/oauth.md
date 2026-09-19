# OAuth

> Contract: the Tracive OAuth specification
> Consent happens in the build of the Tracive app that matches your
> environment — the sandbox build for `TraciveEnvironment.sandbox` — and the
> redirect must be registered on the client id issued in that environment.
> Everything here is tested without a network.

phase 1 authenticates with **OAuth 2.0 Authorization Code + PKCE (S256)**. The
end user consents inside the Tracive app; your app receives a short-lived token
on their behalf. There is **no API key** in this SDK, in any mode — a long-lived
secret shipped inside a mobile binary is a published secret.

---

## The flow, in order

```
1. Is the Tracive app installed?            <- BEFORE anything is generated
      no  -> open the clean install link, return AuthResult.appNotInstalled
      yes -> continue
2. Generate code_verifier + code_challenge (S256) and a random state
3. Open the authorize URL in a Custom Tab (Android) / Universal Link (iOS)
4. OS routes the redirect back              -> client.handleCallback(url)
5. Verify state; mismatch -> AuthFailed(TraciveStateMismatchException)
6. public client       -> exchange code + verifier -> AuthResult.authorized
   confidential client -> AuthResult.codeReceived  (your backend exchanges it)
```

The presence check comes first for a reason, and the order is load-bearing
rather than incidental. It runs **before** anything is generated or persisted,
so a user who does not have the app never has a PKCE pair minted, never has a
`state` stored, and never has an OAuth parameter leak into an
install-attribution chain.

The `state` and the verifier are then persisted, before the authorize URL is
opened, rather than held in a field — Android may collect your app while the
user is consenting. That pending record expires **ten minutes** after
`authorize()`, the same window in every Tracive SDK. Ten is the lifetime of the
authorization code the record exists to redeem (RFC 6749 §4.1.2 recommends at
most ten minutes), so once that code is dead nothing on the device can complete
the exchange. A longer window therefore recovers nothing, and it keeps the
verifier and a still-acceptable `state` on the device for longer — a wider
replay window for a redirect the user never finished.

A redirect that arrives after the window fails with
`TraciveInvalidRequestException` and the record is erased; the user starts
again. `TraciveOAuth(pendingAuthorizationMaxAge: …)` overrides the window, and
widening it widens that replay window, so treat it as a seam rather than a
knob.

### Cancelling a flow the user walked away from

Ten minutes is the ceiling, not the target. If the user dismisses the Custom Tab
or presses back, no redirect will ever arrive and there is nothing to wait for —
but the SDK cannot see that, because the OS does not report it. Your app can, so
tell it:

```dart
final oauth = client.oauth!;
await oauth.authorize();
final attempt = oauth.pendingAuthorizationId;

// ... later, when your app is resumed with no redirect having arrived:
await oauth.cancelPendingAuthorization(authorizationId: attempt);
```

That erases the record, and with it the live verifier sitting beside a `state`
the SDK would still accept.

**Pass the id whenever you can.** The browser-closed signal reaches you from a
lifecycle callback, not from the code that started the flow, and it can arrive
late — consider a double tap, where `authorize()` runs twice and only then does
the *first* browser's close event turn up. An unconditional cancel there kills
the attempt the user is actually looking at; a cancel naming the first id is
recognised as stale and ignored.

The id lives in memory, so it is `null` after a process death even when a record
is still on disk, and an id from an earlier process is refused. Calling
`cancelPendingAuthorization()` with no id still erases whatever is stored, which
is how you clean up after one. It returns whether anything was abandoned, and
like `handleCallback` it does not throw.

### In code

```dart
final client = TraciveClient(
  mode: TraciveMode.oauth(
    clientId: 'your-client-id',
    redirectUri: 'https://your.app/oauth/callback',
    scopes: const [TraciveScopes.scammerCheck],
  ),
);

switch (await client.authorize()) {
  case null:
    // The authorization page is open. Nothing to do here — the outcome
    // arrives at handleCallback() when the OS routes the redirect back.
    break;
  case AuthAppNotInstalled():
    showSnack('Install Tracive to continue, then try again.');
  case AuthFailed(:final error):
    showError(error);
  case final other:
    // authorize() cannot return the remaining cases; handleCallback() does.
    throw StateError('unexpected $other');
}
```

and, wherever your app receives its deep links:

```dart
Future<void> onDeepLink(Uri url) async {
  switch (await client.handleCallback(url)) {
    case null:
      // Not this SDK's redirect, or no OAuth parameter on it. Nothing was
      // touched — route the link onward to whatever else your app does with
      // deep links.
      await myRouter.handle(url);
    case AuthAuthorized(:final grantedScopes):
      // Check what was actually granted; do not assume you got what you asked
      // for.
      if (!grantedScopes.contains(TraciveScopes.scammerCheck)) {
        showDegradedUi();
      }
    case AuthCodeReceived(:final code, :final codeVerifier, :final redirectUri):
      // ClientType.confidential only. Forward these to YOUR backend over TLS
      // and hold them nowhere else — they are bearer credentials until they
      // are exchanged.
      await myBackend.completeTraciveAuth(code, codeVerifier, redirectUri);
    case AuthDenied():
      showSnack('You declined.');
    case AuthAppNotInstalled():
      showSnack('Install Tracive to continue.');
    case AuthFailed(:final error):
      showError(error);
  }
}
```

`AuthResult` is sealed, so a `switch` over it is exhaustive and a case added in
a later version becomes a compile error rather than a silently unhandled path.

---

## Never a WebView

The authorize URL opens in a **Custom Tab** on Android and via
`UIApplication.open` (Universal Link) on iOS. This SDK will not open it in a
`WebView`, and neither should you:

- **App Links do not fire from an in-app WebView.** The redirect would never
  reach your app; the flow simply hangs.
- RFC 8252 §8.12 forbids it. An in-app WebView is a browser the app controls,
  which means the app can read the user's Tracive credentials as they type them
  — exactly what OAuth exists to prevent.
- Users have no address bar to check, so a phishing implementation is
  indistinguishable from a real one.

---

## Platform setup

This package is intentionally **not** a Flutter plugin: it is pure Dart on top
of other people's plugins, so it has no Android or iOS module of its own and
therefore cannot merge a manifest fragment into your build. Shipping an empty
plugin module just to own a manifest would make every integrator's build depend
on native code that does nothing. The cost is the few lines below.

### Android

The SDK detects the Tracive app with `canLaunchUrl(Uri.parse('tracive://'))` —
the bare scheme, and `tracivedev://` against sandbox. It carries no host on
purpose: Android resolves such a probe by intent-filter matching, and a filter
that declares a host requires the URI to carry a matching one, so a probe
naming a host the app does not register answers `false` for an app that is
installed.
On Android 11+ (API 30) that returns `false` for **any** app you have not
declared, whether it is installed or not — package visibility. Without this
block every user looks un-onboarded and is sent to the install link.

`android/app/src/main/AndroidManifest.xml`, as a direct child of `<manifest>`:

```xml
<queries>
    <!-- The presence probe. One entry per scheme it may use: `tracive` is the
         production app, `tracivedev` the sandbox build. The probe follows
         `environment`, so a missing entry here means switching to sandbox
         answers "not installed" for everyone. -->
    <intent>
        <action android:name="android.intent.action.VIEW" />
        <data android:scheme="tracive" />
    </intent>
    <intent>
        <action android:name="android.intent.action.VIEW" />
        <data android:scheme="tracivedev" />
    </intent>
    <!-- url_launcher needs this to open the Custom Tab and the install link. -->
    <intent>
        <action android:name="android.intent.action.VIEW" />
        <data android:scheme="https" />
    </intent>
</queries>
```

**No `<package>` entry is needed, and one would not help.** The probe resolves
an intent, which a scheme query answers; a `<package>` entry names a single
build, so it cannot follow `environment` the way the probe does.

Then declare your redirect URI as an App Link, inside your `<activity>`:

```xml
<intent-filter android:autoVerify="true">
    <action android:name="android.intent.action.VIEW" />
    <category android:name="android.intent.category.DEFAULT" />
    <category android:name="android.intent.category.BROWSABLE" />
    <data android:scheme="https"
          android:host="your.app"
          android:pathPrefix="/oauth/callback" />
</intent-filter>
```

`autoVerify="true"` requires a `/.well-known/assetlinks.json` on `your.app`
naming your package and signing-certificate fingerprint. Without it the link is
not verified, Android shows a disambiguation dialog, and any other app may claim
it.

### iOS

`ios/Runner/Info.plist`:

```xml
<key>LSApplicationQueriesSchemes</key>
<array>
    <string>tracive</string>
    <string>tracivedev</string>
</array>
```

`canOpenURL` returns `false` for any scheme not in that array, so the same
"everyone looks un-onboarded" failure applies — and it applies per scheme, so
omitting `tracivedev` breaks sandbox only, which is the harder one to notice.

Then add the Associated Domains capability with
`applinks:your.app`, and serve
`/.well-known/apple-app-site-association` naming your team and bundle id.

### Both

Route incoming links to `client.handleCallback(url)`. Any deep-link package
works (`app_links`, `uni_links`, `go_router`'s deep-link handling); the SDK does
not care which, and deliberately does not depend on one.

**Routing every link through it is safe, and is the intended use.**
`handleCallback` returns `null` for a URL that is not this client's redirect, or
that carries none of `state`, `code` or `error` — "not mine", not an error, and
nothing touched, not even a read of the store. Treat `null` as "carry on with
your own routing".

---

## `access_denied` is not the only refusal

`error=access_denied` is the user saying no, and it is the only code with a typed outcome. Every
other code reaches you as a failure carrying the raw code:

```dart
if (result is AuthFailed) {
  if (result.error.code == 'temporarily_unavailable') {
    // Not a refusal by this user. Say "try again later", never "you declined".
    showRetryLater(result.error.message);
  } else {
    report(result.error);
  }
}
```

**Branch on the code, not on the error type.** The type is not the same across the Tracive SDKs —
Kotlin and Swift surface these as their "unknown" error, Flutter and React Native as their
invalid-request one — and an unrecognised code is deliberately data to pass through rather than a
case each SDK grows a class for. The code string is identical in all four, and it is the contract.

`temporarily_unavailable` is the one you will actually see. The server sends it for two situations
that are the same to your app and different to the user:

- **The partner organisation has not accepted the current terms.** Existing grants keep working;
  only new ones are refused, so this appears to new users and not to the ones you already have.
- **This device has reached its daily connection limit to your app.** A cap on successful
  authorizations per device per partner per UTC day, which exists because a free Tracive account
  gets a monthly credit allowance and one phone could otherwise cycle accounts to farm it.

`error_description` carries the server's own wording, including the reset time where there is one,
so show that rather than a string of your own. Both cases resolve without you doing anything; the
user retries later. The attempt is spent either way, so authorizing again starts a fresh one rather
than resuming.

## Redirect URI

**Use an App Link / Universal Link (`https://`) you actually own.** A custom
scheme (`yourapp://callback`) is registered on a first-come basis: any other
app on the device can claim the same scheme and receive the authorization code.

The SDK's defence against that is the `state` parameter, which is verified on
every callback and discards the code on mismatch. That is real, and it is not
sufficient on its own — it prevents a *forged* callback, not an *intercepted*
one. Own the domain.

---

## Public vs confidential clients

| | `ClientType.public` (default) | `ClientType.confidential` |
|---|---|---|
| Who exchanges the code | This SDK | Your backend |
| `client_secret` | None — PKCE replaces it | Held by your backend, never on the device |
| Result of `handleCallback` | `AuthAuthorized` | `AuthCodeReceived` |
| Where tokens live | Keystore / Keychain, on device | Your backend |

Choose `confidential` when your backend already brokers the user's session and
you would rather it hold the Tracive grant. The SDK then stops at the
authorization code and never sees a token. Note that in that mode
`checkScammer()` from the device has no token to send — the backend makes the
calls.

---

## Tokens

- **Access token** — JWT, one hour, held in the Android Keystore / iOS Keychain
  via `flutter_secure_storage`. **Never** in `SharedPreferences`,
  `UserDefaults` or a plain file.
- **Refresh token** — opaque and **rotating**: every refresh returns a new one,
  and the stored value is replaced atomically.
- **Auto-refresh on any non-terminal `401`, single-flight.** A bare 401 with no
  body is what a gateway emits, and requiring an exact `expired_token` code left
  the client stuck against one. Concurrent 401s
  trigger exactly one refresh; the others await its result. This is not an
  optimisation — sending the same refresh token twice is what trips the
  server's refresh-token **reuse detection**, which revokes the whole grant.
- **Nothing refreshes on a timer.** `ensureAccessToken()` hands over the stored
  access token without looking at its expiry: a token the SDK actually holds is
  refreshed when the server rejects it, and at no other moment. That is the one
  strategy every Tracive SDK is standardising on — see "Why there is no
  proactive refresh" below.
- **A stored grant whose access token is blank is repaired, not refused.**
  `ensureAccessToken()` spends the refresh token beside it and returns the token
  that comes back, instead of raising `TraciveInvalidTokenException` and sending
  the user back through consent. Such a record comes from damaged storage — a
  partial write, a save interrupted by process death, a restored backup — and
  the grant behind it never stopped working; one field of the local copy is
  missing, which is not the same thing. It cannot be left to the 401 above,
  because an empty bearer is answered `invalid_token`, the one 401 code excluded
  from the refresh — so the record would fail on every call from then on. With **no** refresh token beside it there is nothing to spend,
  and `TraciveInvalidTokenException` is still the answer.

  The shipped `SecureStorageTokenStore` keeps such a record, and `isAuthorized`
  answers `true` for it — both ask `TraciveTokens.isUsable`, which is true when
  either credential is live. That matters together: a store that dropped the
  record, or an `isAuthorized` that ignored it, would each on their own route
  the user back through consent before the repair could run. If you implement
  your own `TokenStore`, hand back what you stored rather than dropping a record
  whose access token is blank.
- **`401 grant_revoked`** clears the stored tokens and surfaces
  `TraciveGrantRevokedException`. It is not retried; retrying with a dead
  refresh token is precisely what reuse detection is looking for.
- **`signOut()`** calls `POST /oauth/revoke` best-effort and then clears local
  tokens **regardless of the outcome**. A user who signs out on a plane must
  still be signed out.

If one app holds grants for more than one Tracive client id, give each its own
`SecureStorageTokenStore(namespace: …)` — otherwise the second silently
overwrites the first's tokens.

### Why there is no proactive refresh

This SDK used to do both: refresh ahead of `expiresAt` (with a 60-second
margin), *and* refresh on the 401. It now does only the second. `refreshSkew` is
gone from `TraciveOAuth`'s constructor, and `ensureAccessToken()` no longer
reads the expiry at all.

Three reasons, in the order they matter:

1. **The reactive path is mandatory whatever else is true.** A token can be
   revoked, and a token can expire in the milliseconds between the check and the
   send. The 401 has to be handled regardless, so a pre-check cannot replace it —
   it can only run in front of it. That makes two mechanisms for one job, and the
   redundant one hides bugs in the mandatory one: the pre-check always won first,
   so the 401 path was the one that almost never ran in production.
2. **The comparison is against the device's clock, which the SDK does not own.**
   A phone running ten minutes fast declares every token expired and refreshes on
   every single call. With rotating refresh tokens and server-side reuse
   detection, that is not merely wasted traffic — it is a stream of rotations,
   and each one is another chance to trip a revocation and sign the user out of
   your integration.
3. **The cost of the trade is one wasted round trip per token lifetime**, paid by
   one caller because the refresh is single-flight. That round trip is **not
   billed**: authentication runs before billing, and a request carrying an
   unusable bearer token is answered with a 401 rather than with a check.

**What you must do if you passed `refreshSkew`:** delete the argument. Nothing
replaces it, and no other behaviour changed.

`expiresAt` is still stored, still serialised, and still readable through
`TokenStore`. `TraciveTokens.isExpiredAt(now)` is still there too — it just no
longer takes a `skew`, and nothing in the SDK calls it. Read them if you want to
warm a session before a user-visible action, or to show "signed in until", and
call `refreshTokens()` yourself. That is a decision for code that knows whether
its clock can be trusted; it is not a default worth applying to every call on
every device.

---

## The install link

When the Tracive app is missing, the SDK opens a **clean** install link:

```
https://tracive.chottu.link/install?ref=<clientId>&utm_source=tracive-sdk-flutter
```

Both query parameters are optional and non-sensitive. `ref` is your OAuth
client id — the *partner's* identifier, never the end user's, and it ships in
your app binary already; it is omitted when there is none. `utm_source` names
this SDK.

Nothing else travels on that link. No OAuth parameter is added — not `state`,
`code_challenge`, `code_verifier`, `partner_user_id`, `redirect_uri` or
`scope` — and any that is already present on the configured URL is stripped
before it is opened. This is a privacy requirement rather than tidiness: the
link transits a third-party link service, so whatever rides on it lands in that
service's logs.

There is **no deferred resume**. The user installs Tracive, comes back to your
app, and taps again. Resuming an OAuth flow across an install would mean parking
a verifier and a `state` in an attribution service, which is a credential in a
third party's logs — and there is nothing to gain, because the retry generates a
fresh PKCE pair anyway.

> `installUrl` is optional and defaults to the link above, which is the same one
> in every Tracive SDK. Pass it only if Tracive has issued you a different link.
> It was briefly a required argument, at a point when the URL was not yet
> confirmed and a wrong default would have been invisible in development and a
> 404 for every partner's first user without the app. The URL is confirmed now,
> so the argument is back to being an override.

**A blank `installUrl` throws.** Omitting the parameter is fine and means "use
the link above" — absence is a real answer. A blank or whitespace-only string is
not absence, and `TraciveOAuth` (and `TraciveClient`, which forwards it
unchanged) raises `ArgumentError` from the constructor, with the cross-SDK
reason `blank_install_url` in its message. Pass a real URL, or pass nothing.

The reason it throws rather than falling back is worth stating, because falling
back looks like the kind thing to do. A blank value is nearly always a build
variable that did not expand, and neither of the quiet options is actually
quiet-and-correct:

- **Substituting the default** sends your users to a link you never configured,
  and neither you nor they can tell — `authorize()` returns
  `AuthAppNotInstalled` either way and this SDK logs nothing.
- **Using the blank as given**, which this SDK used to do, does not send them to
  your link either. It builds `?ref=…&utm_source=…`: no scheme, no host, nothing
  an operating system can open. It reports nothing either, and it only ever
  shows up for a user who does not have the Tracive app, long after the build
  that caused it.

Both are wrong; only one failure can be made loud. The constructor is the
loudest point available — it runs once, in your own code, on every run,
in development, before any end user is involved.

This is **not** URL validation. Any non-blank value is used exactly as given,
untrimmed and unparsed, including one that is plainly wrong: which links Tracive
issues is not something this SDK can adjudicate, and a check clever enough to
try would reject link formats that do not exist yet.

---

## Testing it without a backend

Every part of the flow above is unit-tested with no network and no device:
`AuthLauncher` and `TokenStore` are injectable, and so is the HTTP transport.

```dart
final client = TraciveClient(
  mode: TraciveMode.oauth(clientId: 'test', redirectUri: 'https://x.test/cb'),
  installUrl: 'https://install.test/app',   // optional; overrides the default
  transport: FakeTransport(),         // your fake
  launcher: FakeLauncher(installed: true),
  tokenStore: InMemoryTokenStore(),
  clock: MutableClock(DateTime.utc(2026)),
);
```

No test in this repository reaches for a real host, and none can — see
`.github/workflows/ci.yml`, which runs the suite with no credentials.
