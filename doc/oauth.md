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

### In code

```dart
final client = TraciveClient(
  mode: TraciveMode.oauth(
    clientId: 'your-client-id',
    redirectUri: 'https://your.app/oauth/callback',
    scopes: const ['scammer.check'],
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
      if (!grantedScopes.contains('scammer.check')) showDegradedUi();
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

When the Tracive app is missing, the SDK opens a **clean** install link: no
OAuth parameters whatsoever, only an attribution tag naming your client
(`utm_source=<clientId>`, `utm_medium=tracive_sdk_flutter`). Any OAuth-looking
query parameter on the configured URL is stripped before it is opened.

There is **no deferred resume**. The user installs Tracive, comes back to your
app, and taps again. Resuming an OAuth flow across an install would mean parking
a verifier and a `state` in an attribution service, which is a credential in a
third party's logs.

> ⚠️ `TraciveOAuth.defaultInstallUrl` is `https://tracive.chottu.link/app`,
> which is a **placeholder**. It is the one constant in this SDK that cannot be
> derived from the frozen spec. Confirm it against the live chottu link before
> shipping, and until then pass your own:
> `TraciveClient(mode: …, installUrl: 'https://…')`.

---

## Testing it without a backend

Every part of the flow above is unit-tested with no network and no device:
`AuthLauncher` and `TokenStore` are injectable, and so is the HTTP transport.

```dart
final client = TraciveClient(
  mode: TraciveMode.oauth(clientId: 'test', redirectUri: 'https://x.test/cb'),
  transport: FakeTransport(),         // your fake
  launcher: FakeLauncher(installed: true),
  tokenStore: InMemoryTokenStore(),
  clock: MutableClock(DateTime.utc(2026)),
);
```

No test in this repository reaches for a real host, and none can — see
`.github/workflows/ci.yml`, which runs the suite with no credentials.
