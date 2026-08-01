# OAuth

> Contract: the Tracive OAuth specification
> **The backend is not live yet** — no `/oauth/authorize`,
> `/oauth/token` or `/oauth/revoke` endpoint exists. Everything here is
> implemented against the frozen contract and tested without a network.

phase 1 authenticates with **OAuth 2.0 Authorization Code + PKCE (S256)**. The
end user consents inside the Tracive app; your app receives a short-lived token
on their behalf. There is **no API key** in this SDK, in any mode — a long-lived
secret shipped inside a mobile binary is a published secret.

---

## The flow, in order

```
1. Generate code_verifier + code_challenge (S256) and a random state
2. Is the Tracive app installed?            <- BEFORE any redirect
      no  -> open the clean install link, return AuthResult.appNotInstalled
      yes -> continue
3. Open the authorize URL in a Custom Tab (Android) / Universal Link (iOS)
4. OS routes the redirect back              -> client.handleCallback(url)
5. Verify state; mismatch -> AuthFailed(TraciveStateMismatchException)
6. public client       -> exchange code + verifier -> AuthResult.authorized
   confidential client -> AuthResult.codeReceived  (your backend exchanges it)
```

Steps 1 and 2 are in that order for a reason. The presence check runs **before**
anything is generated or persisted, so a user who does not have the app never
has a PKCE pair minted, never has a `state` stored, and never has an OAuth
parameter leak into an install-attribution chain.

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

The SDK detects the Tracive app with `canLaunchUrl(Uri.parse('tracive://authorize'))`.
On Android 11+ (API 30) that returns `false` for **any** app you have not
declared, whether it is installed or not — package visibility. Without this
block every user looks un-onboarded and is sent to the install link.

`android/app/src/main/AndroidManifest.xml`, as a direct child of `<manifest>`:

```xml
<queries>
    <package android:name="com.pleistocent.tracive" />
    <intent>
        <action android:name="android.intent.action.VIEW" />
        <data android:scheme="tracive" />
    </intent>
    <!-- url_launcher needs this to open the Custom Tab and the install link. -->
    <intent>
        <action android:name="android.intent.action.VIEW" />
        <data android:scheme="https" />
    </intent>
</queries>
```

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
</array>
```

`canOpenURL` returns `false` for any scheme not in that array, so the same
"everyone looks un-onboarded" failure applies.

Then add the Associated Domains capability with
`applinks:your.app`, and serve
`/.well-known/apple-app-site-association` naming your team and bundle id.

### Both

Route incoming links to `client.handleCallback(url)`. Any deep-link package
works (`app_links`, `uni_links`, `go_router`'s deep-link handling); the SDK does
not care which, and deliberately does not depend on one.

---

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
- **Auto-refresh on `401 expired_token`, single-flight.** Concurrent 401s
  trigger exactly one refresh; the others await its result. This is not an
  optimisation — sending the same refresh token twice is what trips the
  server's refresh-token **reuse detection**, which revokes the whole grant.
- **`401 grant_revoked`** clears the stored tokens and surfaces
  `TraciveGrantRevokedException`. It is not retried; retrying with a dead
  refresh token is precisely what reuse detection is looking for.
- **`signOut()`** calls `POST /oauth/revoke` best-effort and then clears local
  tokens **regardless of the outcome**. A user who signs out on a plane must
  still be signed out.

If one app holds grants for more than one Tracive client id, give each its own
`SecureStorageTokenStore(namespace: …)` — otherwise the second silently
overwrites the first's tokens.

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
