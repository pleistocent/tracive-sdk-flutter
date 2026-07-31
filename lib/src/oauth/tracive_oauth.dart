// Copyright (c) Tracive. Licensed under the Apache License, Version 2.0.
//
// The OAuth flow — the SDK specification §6, "phase 1 core".
//
// NO NETWORK IN TESTS: every request goes through the injected [HttpTransport],
// so `test/oauth_test.dart` drives the whole state machine against a fake. The
// Open API does not exist yet; nothing here has ever spoken to a real server,
// and it is written so that this stays true.

import 'dart:async';
import 'dart:math';

import '../client/clock.dart';
import '../client/error_envelope.dart';
import '../client/http_package_transport.dart';
import '../client/http_transport.dart';
import '../exception.dart';
import '../model/auth_result.dart';
import '../model/client_type.dart';
import '../model/tracive_environment.dart';
import '../model/tracive_mode.dart';
import 'auth_launcher.dart';
import 'authorize_url.dart';
import 'pkce.dart';
// Selects `platform_flutter.dart` under Flutter and `platform_default.dart`
// everywhere else. See `platform_default.dart` for why.
import 'platform_default.dart' if (dart.library.ui) 'platform_flutter.dart'
    as platform;
import 'token_store.dart';

/// Runs the §4.2 authorization-code + PKCE flow and owns the resulting tokens.
///
/// Normally reached as `client.oauth`; construct one directly only when you
/// want the flow without the API client.
///
/// ## The shape of the flow
///
/// It is deliberately **not** one awaitable call, because it is not one
/// process. [authorize] hands a URL to the operating system and returns; the
/// answer comes back minutes later as an App Link into the host app, which
/// routes it to [handleCallback]. An API that pretended otherwise would have to
/// keep a `Completer` alive across a browser trip and an Android process death,
/// and would silently fail whenever the OS collected the app.
///
/// ```dart
/// final start = await client.oauth!.authorize();
/// if (start is AuthAppNotInstalled) {
///   // The install link has already been opened. Ask the user to come back.
/// } else if (start is AuthFailed) {
///   // Nothing was opened; show start.error.
/// }
/// // start == null: the browser is open. Wait for the redirect, then:
///
/// // ... in your App Link handler:
/// final result = await client.oauth!.handleCallback(incomingUri);
/// ```
///
/// ## What it never does
///
/// * It never opens a WebView (§6 step 4, RFC 8252 §8.12).
/// * It never sends `code_challenge_method=plain` (§6 step 1).
/// * It never puts an OAuth parameter on the install link (§6 step 3).
/// * It never sends an API key. There is no API key anywhere in this SDK
///   (§2/§11.1).
class TraciveOAuth {
  /// Creates a flow for [mode].
  ///
  /// Everything after [environment] is a seam with a working default:
  /// [transport] defaults to the platform HTTP client, [tokenStore] to the
  /// Keystore/Keychain-backed store on Flutter, [launcher] to `url_launcher`.
  /// Tests replace all three; apps replace none of them.
  TraciveOAuth({
    required this.mode,
    this.environment = TraciveEnvironment.production,
    HttpTransport? transport,
    TokenStore? tokenStore,
    AuthLauncher? launcher,
    TraciveClock? clock,
    Random? random,
    String? installUrl,
    this.refreshSkew = const Duration(seconds: 60),
    this.pendingAuthorizationMaxAge = const Duration(minutes: 30),
  })  : _transport = transport ?? createDefaultHttpTransport(),
        _tokenStore = tokenStore ?? platform.createDefaultTokenStore(),
        _launcher = launcher ?? platform.createDefaultAuthLauncher(),
        _clock = clock ?? TraciveClock.system,
        _random = random,
        installUrl = installUrl ?? defaultInstallUrl;

  /// URL scheme the Tracive app registers. Used **only** as the presence probe.
  static const String traciveAppScheme = 'tracive';

  /// Android package id of the Tracive app, for the `<queries>` declaration
  /// that makes the presence probe answer truthfully on Android 11+.
  static const String traciveAndroidPackage = 'com.pleistocent.tracive';

  /// The URL probed to decide whether the Tracive app is installed (§6 step 2).
  ///
  /// A custom-scheme URL, not the authorize URL: `canOpen` on an `https://` URL
  /// is always `true` because a browser is always installed.
  static final Uri appPresenceProbe =
      Uri.parse('$traciveAppScheme://authorize');

  /// The clean install link opened when the Tracive app is missing.
  ///
  /// **Confirm this against the live chottu link before shipping.** It is the
  /// one constant in this SDK that cannot be derived from the frozen spec — §6
  /// names "the chottu install link" without giving its URL — and a wrong value
  /// sends every un-onboarded user to a 404. Override it with
  /// `TraciveOAuth(installUrl: …)` until it is confirmed.
  static const String defaultInstallUrl = 'https://tracive.chottu.link/app';

  /// The OAuth configuration this flow runs.
  final TraciveOAuthMode mode;

  /// Which deployment to talk to.
  final TraciveEnvironment environment;

  /// Where the user is sent when the Tracive app is not installed.
  final String installUrl;

  /// How long before expiry an access token is treated as already expired.
  final Duration refreshSkew;

  /// How long a started-but-unfinished authorization stays resumable.
  final Duration pendingAuthorizationMaxAge;

  final HttpTransport _transport;
  final TokenStore _tokenStore;
  final AuthLauncher _launcher;
  final TraciveClock _clock;
  final Random? _random;

  /// The single-flight latch (§6). Non-null exactly while a refresh is in
  /// flight; every other caller awaits this future instead of starting a
  /// second refresh.
  Future<TraciveTokens>? _refreshInFlight;

  /// The refresh token most recently handed to the server.
  ///
  /// A refresh token is single-use, and presenting one twice is precisely what
  /// reuse detection looks for — the server answers by revoking the whole
  /// grant. The latch alone cannot prevent that, because it is already clear by
  /// the time a late-resolving store read hands a second caller the token the
  /// first caller has just spent. This records what has been spent so such a
  /// caller can be turned away on the token's identity rather than on timing.
  ///
  /// Cleared whenever the stored tokens are, so a fresh authorization starts
  /// from a clean slate.
  String? _spentRefreshToken;

  /// Where tokens are kept. Exposed so a host app can clear it on log-out of
  /// its *own* account, which is not the same event as [signOut].
  TokenStore get tokenStore => _tokenStore;

  /// Whether a usable access token is stored.
  Future<bool> get isAuthorized async =>
      (await _tokenStore.read())?.hasAccessToken ?? false;

  /// Scopes the server granted, or `[]` when not authorized.
  Future<List<String>> grantedScopes() async =>
      (await _tokenStore.read())?.grantedScopes ?? const <String>[];

  /// Whether the Tracive app is installed — §6 step 2.
  ///
  /// Answers `false` when the manifest declaration is missing, which is
  /// indistinguishable from "not installed". See [AuthLauncher.canOpen] for the
  /// `<queries>` / `LSApplicationQueriesSchemes` entries this needs.
  Future<bool> isTraciveAppInstalled() => _launcher.canOpen(appPresenceProbe);

  /// Starts the flow — §6 steps 1-4.
  ///
  /// Returns:
  ///
  /// * `null` — the authorization page was opened. The outcome will arrive at
  ///   [handleCallback] when the OS routes the redirect back.
  /// * [AuthAppNotInstalled] — the Tracive app is missing. The **clean**
  ///   install link has been opened and **no OAuth flow was started**: no PKCE
  ///   pair was generated, no `state`, nothing persisted, nothing leaked into
  ///   the install-attribution chain. There is no deferred resume (§6 step 3);
  ///   the user retries here after installing.
  /// * [AuthFailed] — the OS refused to open the authorization page. The
  ///   pending record is rolled back, so a later stray redirect cannot be
  ///   matched against it.
  ///
  /// Order matters: the presence check runs **before** anything is generated or
  /// stored, which is what §6 step 2 means by "before any redirect".
  Future<AuthResult?> authorize() async {
    if (!await isTraciveAppInstalled()) {
      await _launcher.openExternally(
        buildInstallUrl(installUrl, clientId: mode.clientId),
      );
      return const AuthResult.appNotInstalled();
    }

    final pkce = PkcePair.generate(random: _random);
    final pending = PendingAuthorization(
      state: PkcePair.generateState(random: _random),
      codeVerifier: pkce.codeVerifier,
      redirectUri: mode.redirectUri,
      createdAt: _clock.now(),
    );
    // Persisted before the URL is opened, not after: on Android the host app
    // can be collected while the user is consenting, and a verifier that lived
    // only in a field would be gone when the App Link brings the app back.
    await _tokenStore.writePending(pending);

    final url = buildAuthorizeUrl(
      environment: environment,
      clientId: mode.clientId,
      redirectUri: mode.redirectUri,
      scopes: mode.scopes,
      state: pending.state,
      codeChallenge: pkce.codeChallenge,
      partnerUserId: mode.partnerUserId,
    );

    if (!await _launcher.openExternally(url)) {
      await _tokenStore.writePending(null);
      return const AuthResult.failed(
        TraciveInvalidRequestException(
          'The operating system refused to open the Tracive authorization page',
        ),
      );
    }
    return null;
  }

  /// Handles the redirect — §6 steps 5-6.
  ///
  /// Call this from the host app's App Link / Universal Link handler with the
  /// incoming URL.
  ///
  /// The `state` check runs **first**, before the `error` and `code`
  /// parameters are even read. That ordering is the point of `state`: a
  /// redirect this SDK did not start is a redirect from somebody else, and
  /// nothing else in it is worth interpreting. RFC 6749 §4.1.2.1 requires the
  /// server to echo `state` on error responses too, so a legitimate denial
  /// still carries it.
  ///
  /// A single-use guard is implicit: the pending record is erased on every
  /// terminal outcome, so replaying the same redirect a second time cannot
  /// re-exchange the code.
  Future<AuthResult> handleCallback(Uri url) async {
    final pending = await _tokenStore.readPending();
    if (pending == null) {
      return const AuthResult.failed(
        TraciveInvalidRequestException(
          'No authorization is in progress; call authorize() first',
        ),
      );
    }
    if (pending.isStaleAt(_clock.now(), maxAge: pendingAuthorizationMaxAge)) {
      await _tokenStore.writePending(null);
      return const AuthResult.failed(
        TraciveInvalidRequestException(
          'The authorization attempt expired; start it again',
        ),
      );
    }

    final parameters = _redirectParameters(url);
    final returnedState = parameters['state'];
    if (returnedState == null ||
        !_constantTimeEquals(returnedState, pending.state)) {
      // Do NOT clear the pending record here. A hostile or stray redirect must
      // not be able to cancel the flow the user is genuinely in the middle of.
      return const AuthResult.failed(TraciveStateMismatchException());
    }

    final error = parameters['error'];
    if (error != null && error.isNotEmpty) {
      await _tokenStore.writePending(null);
      if (error == 'access_denied') return const AuthResult.denied();
      final description = parameters['error_description'];
      return AuthResult.failed(
        TraciveInvalidRequestException(
          description == null || description.isEmpty
              ? 'Authorization failed: $error'
              : 'Authorization failed: $error ($description)',
          code: error,
        ),
      );
    }

    final code = parameters['code'];
    if (code == null || code.isEmpty) {
      await _tokenStore.writePending(null);
      return const AuthResult.failed(
        TraciveInvalidRequestException(
          'The redirect carried no authorization code',
        ),
      );
    }

    if (mode.clientType == ClientType.confidential) {
      // §6 step 6: no exchange. The code and verifier go to the partner's own
      // backend, which holds the client secret. Nothing is stored here —
      // this SDK never sees a token on this path.
      await _tokenStore.writePending(null);
      return AuthResult.codeReceived(
        code: code,
        codeVerifier: pending.codeVerifier,
        redirectUri: pending.redirectUri,
      );
    }

    try {
      final tokens = await _exchange(
        code: code,
        codeVerifier: pending.codeVerifier,
        redirectUri: pending.redirectUri,
      );
      await _tokenStore.write(tokens);
      await _tokenStore.writePending(null);
      return AuthResult.authorized(tokens.grantedScopes);
    } on TraciveException catch (error) {
      await _tokenStore.writePending(null);
      return AuthResult.failed(error);
    }
  }

  /// A bearer access token, refreshing first if the stored one is expired.
  ///
  /// PRIVACY: the return value is a credential. Do not log it, do not put it in
  /// an analytics event, do not attach it to a crash report.
  ///
  /// Throws [TraciveInvalidTokenException] when nothing is stored — that is
  /// "the user has not authorized", not an error worth retrying.
  Future<String> ensureAccessToken() async {
    final tokens = await _tokenStore.read();
    if (tokens == null || !tokens.hasAccessToken) {
      throw const TraciveInvalidTokenException(
        'Not authorized: no access token is stored. Call authorize() first.',
        code: 'invalid_token',
        statusCode: 401,
      );
    }
    if (!tokens.isExpiredAt(_clock.now(), skew: refreshSkew)) {
      return tokens.accessToken;
    }
    if (!tokens.canRefresh) {
      throw const TraciveExpiredTokenException(
        'The access token expired and there is no refresh token. '
        'The user must authorize again.',
        code: 'expired_token',
        statusCode: 401,
      );
    }
    final refreshed = await refreshTokens(staleAccessToken: tokens.accessToken);
    return refreshed.accessToken;
  }

  /// Refreshes the tokens, **single-flight** — §6.
  ///
  /// > "Auto-refresh on 401 `expired_token`, **single-flight**: concurrent 401s
  /// > must trigger exactly one refresh; the others await its result. Getting
  /// > this wrong trips the server's refresh-token **reuse detection**, which
  /// > revokes the whole grant."
  ///
  /// Three guards, and all three are needed:
  ///
  /// 1. **The latch.** While a refresh is in flight, every other caller awaits
  ///    that same future. N concurrent 401s produce one `POST /oauth/token`.
  /// 2. **The stale-token check.** A request whose 401 arrives *after* another
  ///    request already refreshed would otherwise start a second, pointless
  ///    refresh. Passing [staleAccessToken] — the token the failed request
  ///    actually used — lets this method notice that the stored token has moved
  ///    on and return it untouched.
  /// 3. **The spent-token check** ([_spentRefreshToken]).
  ///
  /// The third guard exists because the first two leave a real gap, and it is
  /// worth being precise about which one. It is true that the code between
  /// reading the latch and setting it contains no `await`, so no caller slips
  /// through *that* window. The unprotected window is earlier: the store read
  /// at the top of this method. A read that begins before another flight writes
  /// its new tokens, but whose future completes after that flight has finished
  /// and cleared the latch, returns a snapshot whose refresh token has already
  /// been spent. Such a caller then finds a null latch and spends it again —
  /// and [staleAccessToken] does not catch it, because the stale snapshot still
  /// carries the very access token the caller is reporting as stale.
  ///
  /// This is reachable in production, not just against a contrived fake: a
  /// secure-storage read runs over a platform channel, whose native side may
  /// read the keychain before another flight's write lands while its reply is
  /// delivered afterwards. Ordinary asynchronous interleaving is enough.
  ///
  /// Neither obvious repair closes it. Checking the latch *before* the read
  /// does not, and re-checking it *after* the read does not either, because in
  /// this ordering the earlier flight has already completed and cleared the
  /// latch — there is nothing left to observe. The guard has to be on the
  /// token's identity rather than on timing, which is what the third check is.
  /// Please do not "simplify" it back out.
  ///
  /// On `invalid_grant` / `grant_revoked` the stored tokens are cleared and
  /// [TraciveGrantRevokedException] is thrown. **Do not retry that** — retrying
  /// is what reuse detection is looking for.
  Future<TraciveTokens> refreshTokens({String? staleAccessToken}) async {
    final current = await _tokenStore.read();
    if (current == null || !current.canRefresh) {
      throw const TraciveInvalidTokenException(
        'No refresh token is stored; the user must authorize again',
        code: 'invalid_token',
        statusCode: 401,
      );
    }
    if (staleAccessToken != null && current.accessToken != staleAccessToken) {
      // Somebody else already refreshed while this caller was in flight.
      return current;
    }

    // Join an in-flight refresh FIRST. A caller arriving while a flight is
    // running is the ordinary concurrent-401 case, and joining is always the
    // right answer — it must be decided before the spent-token guard below,
    // which would otherwise turn those callers away for holding the very token
    // the running flight is spending.
    final inFlight = _refreshInFlight;
    if (inFlight != null) return inFlight;

    if (_spentRefreshToken != null &&
        current.refreshToken == _spentRefreshToken) {
      // No flight is running, yet this token has already been spent by one that
      // finished: `current` is a snapshot from before that flight's write. Do
      // not send it. Re-read and hand back whatever that flight stored.
      final latest = await _tokenStore.read();
      if (latest != null && latest.refreshToken != current.refreshToken) {
        return latest;
      }
      // The store still holds the spent token, so nothing replaced it — the
      // grant cannot be refreshed from here. Fail rather than present a token
      // the server will read as reuse.
      throw const TraciveInvalidTokenException(
        'The stored refresh token has already been used; '
        'the user must authorize again',
        code: 'invalid_token',
        statusCode: 401,
      );
    }

    return _startRefresh(current);
  }

  /// Erases the stored tokens without calling the server.
  ///
  /// Used on `grant_revoked` (§6): the grant is already gone server-side, so
  /// revoking it would be a wasted call, and *retrying* anything with the dead
  /// refresh token is exactly the pattern reuse detection punishes.
  Future<void> clearTokens() {
    _spentRefreshToken = null;
    return _tokenStore.clear();
  }

  /// Signs out — §6.
  ///
  /// > "`signOut()` calls `POST /oauth/revoke` best-effort, then clears local
  /// > tokens regardless of outcome."
  ///
  /// "Regardless of outcome" is the important half. A user who taps sign-out on
  /// a train with no signal must still be signed out on the device; leaving the
  /// tokens behind because a network call failed would leave their Tracive
  /// grant live on a phone they may be about to hand over.
  Future<void> signOut() async {
    final tokens = await _tokenStore.read();
    final refreshToken = tokens?.refreshToken;
    final token = (refreshToken != null && refreshToken.isNotEmpty)
        ? refreshToken
        : tokens?.accessToken;
    if (token != null && token.isNotEmpty) {
      try {
        await _postForm(
          environment.resolve(revokePath),
          buildRevokeForm(
            token: token,
            clientId: mode.clientId,
            tokenTypeHint: (refreshToken != null && refreshToken.isNotEmpty)
                ? 'refresh_token'
                : 'access_token',
          ),
        );
      } on TraciveException {
        // Best effort, by design. The local clear below is what the user asked
        // for; the server-side revocation is a courtesy that must never be able
        // to block it.
      }
    }
    _refreshInFlight = null;
    _spentRefreshToken = null;
    await _tokenStore.clear();
  }

  /// Releases the transport, if this flow created it.
  void close() => _transport.close();

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  Future<TraciveTokens> _startRefresh(TraciveTokens current) {
    final completer = Completer<TraciveTokens>();
    // Both set synchronously, before the first await inside `_performRefresh`
    // can yield: the latch is what makes the flight "single", and recording the
    // token as spent is what stops a later, stale snapshot of it being sent a
    // second time once the latch has cleared.
    _refreshInFlight = completer.future;
    _spentRefreshToken = current.refreshToken;
    _performRefresh(current).then(
      (tokens) {
        _refreshInFlight = null;
        completer.complete(tokens);
      },
      onError: (Object error, StackTrace stackTrace) {
        _refreshInFlight = null;
        // The flight failed, so this token was never exchanged for a new one:
        // release the spent marker or a retry would be refused forever. Only a
        // flight that SUCCEEDED leaves the marker standing, because only then
        // has the server actually consumed the token.
        if (_spentRefreshToken == current.refreshToken) {
          _spentRefreshToken = null;
        }
        completer.completeError(error, stackTrace);
      },
    );
    return completer.future;
  }

  Future<TraciveTokens> _performRefresh(TraciveTokens current) async {
    final response = await _postForm(
      environment.resolve(tokenPath),
      buildRefreshForm(
        refreshToken: current.refreshToken!,
        clientId: mode.clientId,
      ),
    );
    if (!response.isSuccess) {
      final error = mapTokenErrorResponse(response);
      if (error is TraciveGrantRevokedException) await _tokenStore.clear();
      throw error;
    }
    final tokens = _decodeTokenResponse(response, previous: current);
    // One write for the pair. The refresh token rotates (§6), so replacing them
    // separately could strand a new access token beside a spent refresh token.
    await _tokenStore.write(tokens);
    return tokens;
  }

  Future<TraciveTokens> _exchange({
    required String code,
    required String codeVerifier,
    required String redirectUri,
  }) async {
    final response = await _postForm(
      environment.resolve(tokenPath),
      buildTokenExchangeForm(
        code: code,
        codeVerifier: codeVerifier,
        redirectUri: redirectUri,
        clientId: mode.clientId,
      ),
    );
    if (!response.isSuccess) throw mapTokenErrorResponse(response);
    return _decodeTokenResponse(response);
  }

  TraciveTokens _decodeTokenResponse(
    TraciveHttpResponse response, {
    TraciveTokens? previous,
  }) {
    final json = decodeJsonObject(response.body);
    if (json == null) {
      throw TraciveServerException(
        statusCode: response.statusCode,
        message: 'The token endpoint returned a body that is not a JSON object',
      );
    }
    final tokens = TraciveTokens.fromTokenResponse(
      json,
      now: _clock.now(),
      previous: previous,
      fallbackScopes: mode.scopes,
    );
    if (!tokens.hasAccessToken) {
      throw TraciveServerException(
        statusCode: response.statusCode,
        message: 'The token endpoint returned no access_token',
      );
    }
    return tokens;
  }

  Future<TraciveHttpResponse> _postForm(
      Uri url, Map<String, String> form) async {
    final request = TraciveHttpRequest(
      method: 'POST',
      url: url,
      headers: const <String, String>{
        'accept': 'application/json',
        'content-type': 'application/x-www-form-urlencoded; charset=utf-8',
      },
      body: encodeForm(form),
    );
    try {
      return await _transport.send(request);
    } catch (error, stackTrace) {
      throw asTraciveException(error, stackTrace);
    }
  }

  /// Reads the redirect's parameters from the query **and** the fragment.
  ///
  /// The authorization-code flow puts them in the query. The fragment is read
  /// too because some App Link routers (and some Universal Link edge cases)
  /// deliver `…#code=…`, and a flow that silently ignored it would look like a
  /// server bug. Query wins on a collision.
  ///
  /// Decoding is guarded: `Uri.queryParameters` throws on a malformed
  /// percent-escape, and a hostile redirect is exactly where a malformed
  /// escape would come from. An undecodable redirect yields no parameters,
  /// hence no `state`, hence [TraciveStateMismatchException] — which is the
  /// correct verdict for a redirect this SDK cannot make sense of.
  Map<String, String> _redirectParameters(Uri url) {
    final parameters = <String, String>{};
    final fragment = url.fragment;
    if (fragment.isNotEmpty && fragment.contains('=')) {
      try {
        parameters.addAll(Uri.splitQueryString(fragment));
      } catch (_) {
        // A fragment that is not a decodable query string is not for us.
      }
    }
    try {
      parameters.addAll(url.queryParameters);
    } catch (_) {
      // Same: an undecodable query is treated as absent, not as fatal.
    }
    return parameters;
  }

  /// Length-independent-ish comparison for the `state` nonce.
  ///
  /// `state` is a CSRF nonce, not a MAC, so a timing side-channel here is not a
  /// realistic attack — but comparing every byte costs nothing and removes the
  /// question. Length is allowed to leak; it is fixed by construction.
  static bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var difference = 0;
    for (var i = 0; i < a.length; i++) {
      difference |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return difference == 0;
  }

  /// **Never** prints tokens, the verifier or the `state`.
  @override
  String toString() => 'TraciveOAuth(clientId: ${mode.clientId}, '
      'environment: ${environment.name}, '
      'clientType: ${mode.clientType.wireValue})';
}
