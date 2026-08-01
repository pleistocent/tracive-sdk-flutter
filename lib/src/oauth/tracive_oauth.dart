// Copyright (c) Tracive. Licensed under the Apache License, Version 2.0.
//
// The OAuth flow — "phase 1 core".
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

/// Runs the authorization-code + PKCE flow and owns the resulting tokens.
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
/// * It never opens a WebView (step 3, and "Never a WebView" in
///   `doc/oauth.md`; RFC 8252 §8.12).
/// * It never sends `code_challenge_method=plain`.
/// * It never puts an OAuth parameter on the install link.
/// * It never refreshes on a clock. A token it holds is refreshed when the
///   server rejects it, and at no other moment. The one refresh that does not
///   wait for a 401 is the repair of a stored grant whose access token is
///   blank, where there is no token to send and therefore no rejection to wait
///   for — see [ensureAccessToken].
/// * It never sends an API key. There is no API key anywhere in this SDK,
///   in any mode.
class TraciveOAuth {
  /// Creates a flow for [mode].
  ///
  /// [installUrl] defaults to [defaultInstallUrl] and is only worth passing if
  /// Tracive has issued you a different link. Pass a real URL or none at all: a
  /// blank one throws [ArgumentError] here — see [installUrl].
  ///
  /// Everything after [installUrl] is a seam with a working default:
  /// [transport] defaults to the platform HTTP client, [tokenStore] to the
  /// Keystore/Keychain-backed store on Flutter, [launcher] to `url_launcher`.
  /// Tests replace all three; apps replace none of them.
  TraciveOAuth({
    required this.mode,
    this.environment = TraciveEnvironment.production,
    this.installUrl = defaultInstallUrl,
    HttpTransport? transport,
    TokenStore? tokenStore,
    AuthLauncher? launcher,
    TraciveClock? clock,
    Random? random,
    this.pendingAuthorizationMaxAge = PendingAuthorization.defaultMaxAge,
  })  : _transport = transport ?? createDefaultHttpTransport(),
        _tokenStore = tokenStore ?? platform.createDefaultTokenStore(),
        _launcher = launcher ?? platform.createDefaultAuthLauncher(),
        _clock = clock ?? TraciveClock.system,
        _random = random {
    // Not an assert: asserts are compiled out of a release build, which is
    // exactly the build a partner ships. See [installUrl] for why this is a
    // rejection rather than a fallback to [defaultInstallUrl].
    if (installUrl.trim().isEmpty) {
      throw ArgumentError.value(
        installUrl,
        'installUrl',
        '$blankInstallUrlReason: pass a real URL or omit the parameter. '
            'A blank override is neither the default nor a link anyone '
            'configured — it builds a schemeless string no operating system '
            'can open.',
      );
    }
  }

  /// The cross-SDK reason token for a blank [installUrl].
  ///
  /// Spelled identically in every Tracive SDK, so that a partner reading one
  /// SDK's error can search for the same string in another. It travels inside
  /// the [ArgumentError]'s message; this package raises configuration mistakes
  /// as [ArgumentError] (as [TraciveEnvironment.custom] does), and that type
  /// carries no code field of its own.
  static const String blankInstallUrlReason = 'blank_install_url';

  /// URL scheme the Tracive app registers. Used **only** as the presence probe.
  static const String traciveAppScheme = 'tracive';

  /// The install page a device without the Tracive app is sent to.
  ///
  /// The same link in every Tracive SDK. The path is part of it — the bare host
  /// does not resolve to the install page.
  static const String defaultInstallUrl = 'https://tracive.chottu.link/install';

  /// Android package id of the Tracive app, for the `<queries>` declaration
  /// that makes the presence probe answer truthfully on Android 11+.
  static const String traciveAndroidPackage = 'com.pleistocent.tracive';

  /// The URL probed to decide whether the Tracive app is installed.
  ///
  /// A custom-scheme URL, not the authorize URL: `canOpen` on an `https://` URL
  /// is always `true` because a browser is always installed.
  static final Uri appPresenceProbe =
      Uri.parse('$traciveAppScheme://authorize');

  /// The OAuth configuration this flow runs.
  final TraciveOAuthMode mode;

  /// Which deployment to talk to.
  final TraciveEnvironment environment;

  /// Where the user is sent when the Tracive app is not installed.
  ///
  /// Defaults to [defaultInstallUrl], which is the link every Tracive SDK
  /// opens. Pass one only to override it.
  ///
  /// **A blank override is rejected: the constructor throws [ArgumentError],
  /// carrying the reason `blank_install_url`.** Whitespace-only counts as
  /// blank. Omitting the parameter is not blank — absence is a real answer, and
  /// it still means [defaultInstallUrl].
  ///
  /// A blank value here is almost always a build variable that did not expand,
  /// and there is no good way to carry on from one. Substituting
  /// [defaultInstallUrl] would send a partner's users to a link the partner
  /// never configured, and nobody could tell, because [authorize] returns
  /// [AuthAppNotInstalled] either way and this SDK logs nothing. Using the
  /// blank as given is no better, and that is the part that is easy to miss: it
  /// does not produce the partner's link either. It builds
  /// `?ref=…&utm_source=…` — a schemeless, hostless string no operating system
  /// will open — and it too says nothing, until some user without the Tracive
  /// app finds it. Both roads fail; only one of them can be made loud. So the
  /// blank is refused at construction, which is once, in host-app code, on
  /// every run, in development, before an end user is involved.
  ///
  /// This is **not** URL validation. Anything non-blank is used verbatim,
  /// untrimmed and unparsed, including a value that is plainly wrong: what
  /// links Tracive issues is not this SDK's to adjudicate.
  ///
  /// Whatever it is, it is opened **clean**: the only query parameters that
  /// travel on it are `ref` (your OAuth client id — the partner's identifier,
  /// never the end user's) and `utm_source`, both optional and both
  /// non-sensitive. No OAuth parameter is ever added, and any that is already
  /// present on the configured URL is stripped rather than trusted: `state`,
  /// `code_challenge`, `code_verifier`, `partner_user_id`, `redirect_uri` and
  /// `scope` must not travel here. This link transits a third-party link
  /// service, so anything on it lands in that service's logs, and there is
  /// nothing to gain by sending it — there is no deferred resume, so the user
  /// installs Tracive and retries here, against a freshly generated PKCE pair.
  final String installUrl;

  /// How long a started-but-unfinished authorization stays resumable.
  ///
  /// Defaults to [PendingAuthorization.defaultMaxAge] — ten minutes, the same
  /// in every Tracive SDK — because ten minutes is how long the authorization
  /// code itself lives. Holding the pending record any longer cannot rescue a
  /// flow the server has already given up on; it only leaves the PKCE verifier
  /// and a still-acceptable `state` on the device for longer. That reasoning,
  /// and why the value used to be thirty minutes, is on the constant.
  ///
  /// Overriding it is a real seam, not a knob to widen casually: a longer
  /// window here is a longer replay window for an unfinished redirect, and it
  /// puts this SDK out of step with its siblings.
  final Duration pendingAuthorizationMaxAge;

  final HttpTransport _transport;
  final TokenStore _tokenStore;
  final AuthLauncher _launcher;
  final TraciveClock _clock;
  final Random? _random;

  /// Names the authorization this process started, or `null` when it started
  /// none. Backs [pendingAuthorizationId]; see that member for why it is held
  /// in memory rather than beside the record on disk.
  String? _pendingAuthorizationId;

  /// Distinguishes one attempt from the next within this process. Not a
  /// secret and never sent anywhere — a counter is enough, and it is what the
  /// Kotlin SDK uses, so an id read in one is recognisable in the other.
  int _authorizationCounter = 0;

  /// The single-flight latch. Non-null exactly while a refresh is in
  /// flight; every other caller awaits this future instead of starting a
  /// second refresh.
  Future<TraciveTokens>? _refreshInFlight;

  /// The refresh tokens this flow has actually handed to the server, oldest
  /// first.
  ///
  /// A refresh token is single-use, and presenting one twice is precisely what
  /// reuse detection looks for — the server answers by revoking the whole
  /// grant. The latch alone cannot prevent that, because it is already clear by
  /// the time a late-resolving store read hands a second caller the token the
  /// first caller has just spent. This records what has been spent so such a
  /// caller can be turned away on the token's identity rather than on timing.
  ///
  /// It is a short history rather than a single slot because a store read can
  /// outlive more than one rotation. With one slot, a snapshot taken before the
  /// first of two rotations was no longer recognised by the time it arrived —
  /// the slot had moved on to the second token — and went straight back on the
  /// wire. How far back this reaches is not safety-critical, though: the flight
  /// itself re-reads the store and sends what it finds there, so a snapshot
  /// older than this history causes at worst one redundant refresh, never a
  /// reuse. See [_performRefresh].
  ///
  /// Cleared whenever the stored tokens are, so a fresh authorization starts
  /// from a clean slate.
  final List<String> _spentRefreshTokens = <String>[];

  /// How many spent refresh tokens to remember. Comfortably more rotations than
  /// a single store read can realistically span; see [_spentRefreshTokens] for
  /// why an under-estimate here is not a correctness problem.
  static const int _spentRefreshTokenHistory = 8;

  /// Which generation of credentials this flow is currently working with.
  ///
  /// Bumped by [signOut] and [clearTokens]. Every code path that is about to
  /// write tokens captures it before its network call and compares afterwards,
  /// and writes only if it has not moved.
  ///
  /// The problem it solves is that discarding credentials is instantaneous
  /// while acquiring them is not. A refresh or an exchange that was already on
  /// the wire when the user signed out will still complete, and its `write`
  /// would refill the store the user just emptied — leaving their grant live on
  /// a device they may be about to hand over, which is precisely what
  /// [signOut]'s contract says must not happen.
  ///
  /// Awaiting the in-flight work inside [signOut] would not fix this: it would
  /// make signing out wait on the network, which [signOut] deliberately
  /// refuses to do. Gating the write is what makes sign-out both immediate and
  /// final.
  int _credentialEpoch = 0;

  /// Where tokens are kept. Exposed so a host app can clear it on log-out of
  /// its *own* account, which is not the same event as [signOut].
  TokenStore get tokenStore => _tokenStore;

  /// Whether a grant the SDK can still use is stored.
  ///
  /// True when there is an access token, and also when there is only a refresh
  /// token — [ensureAccessToken] repairs that record rather than failing on it,
  /// so answering `false` would send a host app to consent for a grant that is
  /// still good. Matches the sibling SDKs, which all define this as "a usable
  /// record exists" rather than "an access token exists".
  Future<bool> get isAuthorized async {
    final tokens = await _tokenStore.read();
    return tokens?.isUsable ?? false;
  }

  /// Scopes the server granted, or `[]` when not authorized.
  Future<List<String>> grantedScopes() async =>
      (await _tokenStore.read())?.grantedScopes ?? const <String>[];

  /// Whether the Tracive app is installed.
  ///
  /// Answers `false` when the manifest declaration is missing, which is
  /// indistinguishable from "not installed". See [AuthLauncher.canOpen] for the
  /// `<queries>` / `LSApplicationQueriesSchemes` entries this needs.
  Future<bool> isTraciveAppInstalled() => _launcher.canOpen(appPresenceProbe);

  /// Starts the flow — steps 1 to 3 in `doc/oauth.md`.
  ///
  /// Returns:
  ///
  /// * `null` — the authorization page was opened. The outcome will arrive at
  ///   [handleCallback] when the OS routes the redirect back.
  /// * [AuthAppNotInstalled] — the Tracive app is missing. The **clean**
  ///   install link has been opened and **no OAuth flow was started**: no PKCE
  ///   pair was generated, no `state`, nothing persisted, nothing leaked into
  ///   the install-attribution chain. There is no deferred resume;
  ///   the user retries here after installing.
  /// * [AuthFailed] — the OS refused to open the authorization page. The
  ///   pending record is rolled back, so a later stray redirect cannot be
  ///   matched against it.
  ///
  /// Order matters: the presence check runs **before** anything is generated or
  /// stored, which is what "before any redirect" means.
  ///
  /// **It does not throw.** Everything it touches outside this process — the
  /// app-presence probe, the secure store, the browser launch — can fail, and
  /// each of those failures arrives as [AuthFailed] rather than as an exception.
  /// See [handleCallback], which is where that rule earns its keep; this method
  /// follows it so that both halves of the flow report failure the same way.
  Future<AuthResult?> authorize() async {
    try {
      return await _authorize();
    } on TraciveException catch (error) {
      return AuthResult.failed(error);
    } catch (_) {
      // Best effort: a store that refused the write above may equally refuse
      // this one, and there is nothing further to do about it either way.
      await _forgetPendingQuietly();
      return const AuthResult.failed(_localStorageFailure);
    }
  }

  Future<AuthResult?> _authorize() async {
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
    // The id is taken only once the record is safely stored, so a store that
    // refused leaves nothing for a later cancel to claim it cancelled.
    _pendingAuthorizationId = 'authorization-${++_authorizationCounter}';

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
      await _forgetPending();
      return const AuthResult.failed(
        TraciveInvalidRequestException(
          'The operating system refused to open the Tracive authorization page',
        ),
      );
    }
    return null;
  }

  /// Handles the redirect — steps 5 and 6 in `doc/oauth.md`.
  ///
  /// Call this from the host app's App Link / Universal Link handler with the
  /// incoming URL. Routing **every** incoming link through it is fine, and is
  /// what the next paragraph exists to make safe.
  ///
  /// ## `null` means "this link was not addressed here"
  ///
  /// Before anything else — before the store is read, before a pending record
  /// is judged — the URL is checked against this client's own `redirectUri`,
  /// and it must carry at least one of `state`, `code` or `error`. A URL that
  /// fails either check returns `null` with nothing touched, because it is not
  /// this SDK's to interpret.
  ///
  /// That gate is not decoration. Any app on the device can register a custom
  /// scheme and fire a URL at yours, and a host is encouraged to funnel its
  /// whole deep-link surface through here. Without it, one unrelated link —
  /// your own marketing link, a share intent, a stray redirect from another
  /// app — would be judged as an OAuth redirect, and the honest verdict on a
  /// link carrying no `state` is [TraciveStateMismatchException]: an error
  /// raised at the user, about a consent that is still perfectly fine, for a
  /// link that had nothing to do with it. `null` says the true thing instead.
  ///
  /// It narrows what is accepted and nothing else. Everything past the gate is
  /// unchanged: `state` is still what decides whether a code may be redeemed,
  /// and being generous here costs nothing because of it. The comparison is
  /// therefore deliberately loose — scheme, authority and path, case-insensitive
  /// and ignoring trailing slashes — so that a browser that normalises the URL
  /// on the way back cannot drop a genuine redirect.
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
  ///
  /// ## It does not throw
  ///
  /// Every failure comes back as [AuthFailed], including the ones that are not
  /// about OAuth at all: a secure store that refuses to read or write, a token
  /// endpoint that answers with something undecodable, a platform channel that
  /// is not there.
  ///
  /// That is a property of *where this method is called from*, not a general
  /// preference for return values over exceptions. Its caller is the host app's
  /// App Link / Universal Link handler — a platform callback, usually a couple
  /// of lines long, almost never wrapped in a `try`. An exception escaping into
  /// it is an unhandled exception in somebody else's app, raised on a code path
  /// they did not write and cannot see, for a reason (the Keychain was locked)
  /// that has nothing to do with the deep link they were routing. The three
  /// sibling SDKs all return their failure here for the same reason.
  ///
  /// One `switch` over the result therefore covers every outcome, and there is
  /// nothing to catch alongside it.
  Future<AuthResult?> handleCallback(Uri url) async {
    try {
      return await _handleCallback(url);
    } on TraciveException catch (error) {
      return AuthResult.failed(error);
    } catch (_) {
      return const AuthResult.failed(_localStorageFailure);
    }
  }

  Future<AuthResult?> _handleCallback(Uri url) async {
    // Both "not mine" gates run before the store is touched, so a link that was
    // never addressed here really does leave everything as it found it.
    // Both "not mine" gates run before the store is touched, so a link that was
    // never addressed here really does leave everything as it found it.
    if (!_isOurRedirect(url)) return null;
    final parameters = _redirectParameters(url);
    if (!_oauthRedirectParameters.any(parameters.containsKey)) return null;

    final pending = await _tokenStore.readPending();
    if (pending == null) {
      return const AuthResult.failed(
        TraciveInvalidRequestException(
          'No authorization is in progress; call authorize() first',
        ),
      );
    }
    if (pending.isStaleAt(_clock.now(), maxAge: pendingAuthorizationMaxAge)) {
      await _forgetPending();
      return const AuthResult.failed(
        TraciveInvalidRequestException(
          'The authorization attempt expired; start it again',
        ),
      );
    }

    final returnedState = parameters['state'];
    if (returnedState == null ||
        !_constantTimeEquals(returnedState, pending.state)) {
      // Do NOT clear the pending record here. A hostile or stray redirect must
      // not be able to cancel the flow the user is genuinely in the middle of.
      return const AuthResult.failed(TraciveStateMismatchException());
    }

    final error = parameters['error'];
    if (error != null && error.isNotEmpty) {
      await _forgetPending();
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
      await _forgetPending();
      return const AuthResult.failed(
        TraciveInvalidRequestException(
          'The redirect carried no authorization code',
        ),
      );
    }

    if (mode.clientType == ClientType.confidential) {
      // No exchange here. The code and verifier go to the partner's own
      // backend, which holds the client secret. Nothing is stored here —
      // this SDK never sees a token on this path.
      await _forgetPending();
      return AuthResult.codeReceived(
        code: code,
        codeVerifier: pending.codeVerifier,
        redirectUri: pending.redirectUri,
      );
    }

    // Captured before the exchange goes out, for the same reason the refresh
    // path captures it: a sign-out that lands while the code is being exchanged
    // must win over the tokens that come back.
    final epoch = _credentialEpoch;
    try {
      final tokens = await _exchange(
        code: code,
        codeVerifier: pending.codeVerifier,
        redirectUri: pending.redirectUri,
      );
      if (epoch != _credentialEpoch) throw _discardedMidFlight;
      await _tokenStore.write(tokens);
      await _forgetPending();
      return AuthResult.authorized(tokens.grantedScopes);
    } on TraciveException catch (error) {
      await _forgetPending();
      return AuthResult.failed(error);
    }
  }

  /// The id of the authorization this process is waiting on, or `null` when it
  /// started none.
  ///
  /// Read it once [authorize] has returned and hand it back to
  /// [cancelPendingAuthorization] later. That is the only way a cancel can be
  /// sure of what it is cancelling.
  ///
  /// It lives in memory, deliberately, and is therefore `null` after a process
  /// death even when a record is still on disk. A cancel is a *this process saw
  /// the browser close* signal, and a process that did not open a browser has no
  /// such signal to disambiguate — so a cancel naming an id from an earlier
  /// process is refused rather than guessed at. It is **not** `state`: `state`
  /// travels to the authorization server and comes back on the redirect, and
  /// this never leaves the device.
  String? get pendingAuthorizationId => _pendingAuthorizationId;

  /// Abandons the pending authorization, so nothing can complete it later.
  ///
  /// Call this when the browser closes without a redirect — the user pressed
  /// back, or dismissed the Custom Tab. Nothing will ever arrive in that case,
  /// and without this the record sits on the device with a live PKCE verifier
  /// beside the `state` it answers to until it ages out, which is ten minutes
  /// by default ([pendingAuthorizationMaxAge]).
  ///
  /// **Pass [authorizationId] whenever you can.** A browser-closed signal
  /// arrives from the widget or the platform lifecycle, not from the code that
  /// started the flow, and it can arrive late. Consider the double tap:
  /// [authorize] runs twice, the second call supersedes the first, and *then*
  /// the first browser's close event turns up. Cancelling unconditionally at
  /// that point kills the second attempt — the one the user is looking at.
  /// With the id, a stale signal is recognised and ignored.
  ///
  /// Returns whether a pending authorization was abandoned. `false` means there
  /// was nothing pending, or that what is pending is not what [authorizationId]
  /// named.
  ///
  /// It does not throw, on the same terms as [handleCallback]: it is called
  /// from a lifecycle callback, and a store that refuses is reported as "there
  /// was nothing to cancel" rather than as an exception the caller has no move
  /// against.
  Future<bool> cancelPendingAuthorization({String? authorizationId}) async {
    final current = _pendingAuthorizationId;
    if (authorizationId != null && authorizationId != current) return false;
    // The store is consulted only when this process is holding nothing of its
    // own, which is the one case where the answer cannot be known without
    // looking: a record left behind by an earlier process.
    if (current == null && await _readPendingQuietly() == null) return false;
    await _forgetPendingQuietly();
    return true;
  }

  /// The stored bearer access token.
  ///
  /// PRIVACY: the return value is a credential. Do not log it, do not put it in
  /// an analytics event, do not attach it to a crash report.
  ///
  /// Throws [TraciveInvalidTokenException] when there is nothing to send and
  /// nothing to refresh with — that is "the user has not authorized", not an
  /// error worth retrying.
  ///
  /// ## A blank access token beside a refresh token is repaired, not rejected
  ///
  /// A stored grant whose access token is blank is **not** the same case as no
  /// grant at all. The refresh token beside it is a perfectly good credential,
  /// so it is spent and the token that comes back is returned. The user is not
  /// sent through consent again for a grant that never stopped working. That is
  /// the branch every Tracive SDK is standardising on.
  ///
  /// The state is reachable from a damaged storage record — a partial write, a
  /// save interrupted by process death, a restored backup — because
  /// [TraciveTokens.fromStorageJson] defaults a missing `accessToken` to `''`.
  /// It never arrives from the token endpoint, whose answer is rejected when it
  /// carries no `access_token`.
  ///
  /// Nothing downstream of here can recover it, which is why the branch has to
  /// be here rather than on the 401 path. An empty bearer is not answered with
  /// `401 expired_token`: a malformed one is `invalid_token`, which this SDK —
  /// and every sibling — treats as terminal, so the request would not be
  /// refreshed and retried. The damaged record would simply fail on every call
  /// from then on, and fail by telling the user to authorize again.
  ///
  /// With no refresh token beside it there is nothing to spend, and the typed
  /// error above is the honest answer.
  ///
  /// ## Refresh is reactive, and only reactive
  ///
  /// This method does **not** consult [TraciveTokens.expiresAt], and it never
  /// refreshes a token it actually holds. The stored token is sent; if the
  /// server answers `401 expired_token`, `TraciveClient` refreshes once —
  /// single-flight, via [refreshTokens] — and replays the request. Every
  /// Tracive SDK is standardising on exactly that path, and only that path.
  ///
  /// Refreshing ahead of the timestamp was tried and removed, for three
  /// reasons:
  ///
  /// * **The reactive path is mandatory anyway.** A token can be revoked, and a
  ///   token can expire between the check and the send, so the 401 has to be
  ///   handled whatever else is true. A pre-check cannot replace it, only run in
  ///   front of it — a second mechanism for one job. The redundant one hides
  ///   bugs in the mandatory one: while the pre-check always wins first, the 401
  ///   path is the one that rarely runs in production.
  /// * **The timestamp is compared against the device clock, which this SDK
  ///   does not own.** A phone running ten minutes fast declares every token
  ///   expired and refreshes on every single call. With rotating refresh tokens
  ///   and server-side reuse detection, that is not merely wasteful traffic: it
  ///   is a stream of rotations, and each one is another chance to trip a
  ///   revocation and sign the user out.
  /// * **The cost of getting it wrong is one round trip per token lifetime**,
  ///   paid by a single caller because the refresh is single-flight — and that
  ///   round trip is not billed. Authentication precedes billing, and a request
  ///   with an unusable bearer token is answered with a 401 rather than a check.
  ///
  /// [TraciveTokens.expiresAt] is still stored and still readable. An
  /// integrator who wants to warm a session before a user-visible action can
  /// read it through [tokenStore] and call [refreshTokens] — a deliberate
  /// choice, made by code that knows whether its clock can be trusted, rather
  /// than a default this SDK applies to every call on every device.
  Future<String> ensureAccessToken() async {
    final tokens = await _tokenStore.read();
    // The common path, first and unchanged: a stored access token is handed
    // over as it is, with no expiry check and no extra work of any kind.
    if (tokens != null && tokens.hasAccessToken) return tokens.accessToken;
    if (tokens != null && tokens.canRefresh) {
      // The blank-token repair. `staleAccessToken: ''` is the token this caller
      // would otherwise have sent, and passing it is what lets [refreshTokens]
      // notice that somebody else has already repaired the record and hand back
      // what they stored instead of spending a second rotation on it.
      final refreshed = await refreshTokens(staleAccessToken: '');
      return refreshed.accessToken;
    }
    throw const TraciveInvalidTokenException(
      'Not authorized: no access token is stored. Call authorize() first.',
      code: 'invalid_token',
      statusCode: 401,
    );
  }

  /// Refreshes the tokens, **single-flight**.
  ///
  /// Concurrent 401s must trigger exactly one refresh and the others must await
  /// its result. Getting this wrong presents a rotated refresh token twice,
  /// which trips the server's reuse detection and revokes the whole grant.
  ///
  /// Four guards, and all four are needed:
  ///
  /// 1. **The latch.** While a refresh is in flight, every other caller awaits
  ///    that same future. N concurrent 401s produce one token request.
  /// 2. **The stale-token check.** A request whose 401 arrives *after* another
  ///    request already refreshed would otherwise start a second, pointless
  ///    refresh. Passing [staleAccessToken] — the token the failed request
  ///    actually used — lets this method notice that the stored token has moved
  ///    on and return it untouched.
  /// 3. **The spent-token check** ([_spentRefreshTokens]).
  /// 4. **The flight's own store re-read** ([_performRefresh]), which decides
  ///    what actually goes on the wire.
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
  /// The fourth guard is what makes the third one's memory an optimisation
  /// rather than a security boundary. A snapshot can be several rotations old,
  /// and no bounded history recognises all of them; so a flight never sends the
  /// snapshot it was started from. It re-reads the store and sends whatever is
  /// live there, which means the worst a snapshot too old to be recognised can
  /// cause is one redundant refresh.
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

    if (_spentRefreshTokens.contains(current.refreshToken)) {
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

    return _startRefresh();
  }

  /// Erases the stored tokens without calling the server.
  ///
  /// Used on `grant_revoked`: the grant is already gone server-side, so
  /// revoking it would be a wasted call, and *retrying* anything with the dead
  /// refresh token is exactly the pattern reuse detection punishes.
  Future<void> clearTokens() => _discardCredentials();

  /// Signs out.
  ///
  /// Calls the revocation endpoint best-effort, and clears the local tokens
  /// regardless of the outcome. "Regardless of outcome" is the important half:
  /// a user who taps sign-out on a train with no signal must still be signed
  /// out on the device. Leaving the tokens behind because a network call failed
  /// would leave their Tracive grant live on a phone they may be about to hand
  /// over.
  ///
  /// The local discard happens **before** the revocation call, not after. That
  /// ordering closes the window the network call opens: once the store is empty
  /// and the epoch has moved, a refresh that starts during the call finds
  /// nothing to spend, and one that was already on the wire has its write
  /// rejected when it lands. Doing it the other way round meant a sign-out
  /// could be silently undone by a response that arrived a moment later.
  Future<void> signOut() async {
    final tokens = await _tokenStore.read();
    final refreshToken = tokens?.refreshToken;
    final token = (refreshToken != null && refreshToken.isNotEmpty)
        ? refreshToken
        : tokens?.accessToken;

    await _discardCredentials();

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
        // Best effort, by design. The local discard above is what the user
        // asked for; the server-side revocation is a courtesy that must never
        // be able to block it, or to undo it.
      }
    }
  }

  /// Releases the transport, if this flow created it.
  void close() => _transport.close();

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  /// Throws away every credential this flow is holding, and moves the epoch so
  /// that anything already on the wire cannot put them back.
  Future<void> _discardCredentials() async {
    _credentialEpoch++;
    _refreshInFlight = null;
    _spentRefreshTokens.clear();
    // The shipped store erases the pending record along with the tokens, so
    // holding on to the id would let a later cancel report that it abandoned an
    // attempt that is no longer there.
    _pendingAuthorizationId = null;
    await _tokenStore.clear();
  }

  /// Records [token] as handed to the server, evicting the oldest entry once
  /// the history is full.
  void _markSpent(String token) {
    if (_spentRefreshTokens.contains(token)) return;
    _spentRefreshTokens.add(token);
    if (_spentRefreshTokens.length > _spentRefreshTokenHistory) {
      _spentRefreshTokens.removeAt(0);
    }
  }

  /// The failure [authorize] and [handleCallback] report when something outside
  /// this SDK's own logic refused — almost always the device's secure store.
  ///
  /// The underlying error is deliberately **not** carried into the message. It
  /// is produced by whichever store the host installed, and this SDK does not
  /// put text it did not write into a value that travels to a crash reporter
  /// from a code path whose neighbouring variables are a PKCE verifier and a
  /// refresh token. The sibling SDKs report the same situation the same way.
  ///
  /// [TraciveInvalidRequestException] rather than a new type: from the caller's
  /// side this is the same class of outcome as "no authorization is in
  /// progress" — nothing was completed, and the move is to start the flow
  /// again.
  static const TraciveInvalidRequestException _localStorageFailure =
      TraciveInvalidRequestException(
    'The authorization could not be completed because this device refused to '
    'read or write the secure store the SDK keeps the pending authorization '
    'in. Nothing was authorized. Check that secure storage is available on '
    'this device — a locked Keychain and a missing Keystore entry both look '
    'like this — and start the flow again.',
  );

  /// Erases the pending record and forgets which attempt this process was
  /// waiting on.
  ///
  /// The two always move together. Leaving the id behind after the record is
  /// gone would let a later [cancelPendingAuthorization] report `true` for an
  /// attempt that was already spent.
  Future<void> _forgetPending() async {
    _pendingAuthorizationId = null;
    await _tokenStore.writePending(null);
  }

  /// [_forgetPending], swallowing a store that refuses.
  ///
  /// Used on paths that are already reporting an outcome, where a second error
  /// from the same broken store would replace an accurate answer with a less
  /// accurate one.
  Future<void> _forgetPendingQuietly() async {
    try {
      await _forgetPending();
    } catch (_) {
      // Nothing to do, and nothing that can be done.
    }
  }

  /// The stored pending record, reporting a store that refuses as absence.
  ///
  /// The caller could do nothing with the distinction: either way there is no
  /// record this process can act on.
  Future<PendingAuthorization?> _readPendingQuietly() async {
    try {
      return await _tokenStore.readPending();
    } catch (_) {
      return null;
    }
  }

  /// The error a caller gets when its tokens arrived after the credentials they
  /// belong to were discarded. Deliberately the same typed error as "nothing is
  /// stored", because that is now the truth: whatever the server issued is gone
  /// and the user has to authorize again.
  static const TraciveInvalidTokenException _discardedMidFlight =
      TraciveInvalidTokenException(
    'The session was signed out while this request was in flight, so the '
    'tokens it returned were discarded. Authorize again.',
    code: 'invalid_token',
    statusCode: 401,
  );

  Future<TraciveTokens> _startRefresh() {
    final completer = Completer<TraciveTokens>();
    // Set synchronously, before the first await inside `_performRefresh` can
    // yield: the latch is what makes the flight "single", and every caller that
    // arrives while it is up joins this future instead of starting a second
    // flight.
    _refreshInFlight = completer.future;
    _performRefresh(_credentialEpoch).then(
      (tokens) {
        _refreshInFlight = null;
        completer.complete(tokens);
      },
      onError: (Object error, StackTrace stackTrace) {
        _refreshInFlight = null;
        completer.completeError(error, stackTrace);
      },
    );
    return completer.future;
  }

  Future<TraciveTokens> _performRefresh(int epoch) async {
    // Read the store again rather than trusting the caller's snapshot. The
    // caller read before the latch was taken, so its record may be any number
    // of rotations old; the store is the only authority on which refresh token
    // is live. This is what keeps a snapshot older than the spent history from
    // ever reaching the wire — it just causes a redundant refresh instead.
    final current = await _tokenStore.read();
    if (epoch != _credentialEpoch) throw _discardedMidFlight;
    if (current == null || !current.canRefresh) {
      throw const TraciveInvalidTokenException(
        'No refresh token is stored; the user must authorize again',
        code: 'invalid_token',
        statusCode: 401,
      );
    }
    final refreshToken = current.refreshToken!;
    if (_spentRefreshTokens.contains(refreshToken)) {
      throw const TraciveInvalidTokenException(
        'The stored refresh token has already been used; '
        'the user must authorize again',
        code: 'invalid_token',
        statusCode: 401,
      );
    }

    _markSpent(refreshToken);

    // Whether the marker may be released again depends entirely on what kind of
    // failure this is, and there are only two kinds worth telling apart.
    //
    // A complete HTTP response, whatever its status, settles the question: an
    // OAuth token endpoint that answers with an error has issued no tokens
    // (RFC 6749 §5.2), so the refresh token was not consumed and the marker
    // must come off — otherwise one 500 would end the grant for good.
    //
    // No response at all does not settle it. A socket timeout or a dropped
    // connection is indistinguishable from a success whose reply was lost: the
    // server may have rotated the token and be waiting to see the new one. The
    // marker stays, and the caller is told to re-authorize. That is the
    // strictly better trade, not merely the cautious one — if the token really
    // was consumed, the grant already needs re-authorization and this avoids a
    // revocation event on top; if it was not, the cost is one consent the user
    // did not strictly need. Retrying loses in the first case and only ties in
    // the second.
    //
    // In principle a connect-phase or DNS failure proves the request never
    // arrived and could be released. It is not detected here: the transport is
    // injectable, so the underlying error is whatever some other package chose
    // to throw, and guessing at its shape would be a guess about the
    // ambiguous-versus-safe distinction that this whole rule turns on.
    final TraciveHttpResponse response;
    try {
      response = await _postForm(
        environment.resolve(tokenPath),
        buildRefreshForm(refreshToken: refreshToken, clientId: mode.clientId),
      );
    } on TraciveException {
      // The transport error itself is deliberately not carried through: it is
      // produced by whichever transport the host installed, and this SDK does
      // not put text it did not write into an exception that ends up in a crash
      // report next to a token refresh.
      throw const TraciveInvalidTokenException(
        'The refresh request failed before an answer arrived, so it is not '
        'known whether the refresh token was consumed. It will not be '
        'presented again; the user must authorize again.',
        code: 'invalid_token',
        statusCode: 401,
      );
    }

    if (!response.isSuccess) {
      _spentRefreshTokens.remove(refreshToken);
      final error = mapTokenErrorResponse(response);
      if (error is TraciveGrantRevokedException) await _discardCredentials();
      throw error;
    }

    // Past this point the server has issued a new pair, so the old refresh
    // token is spent no matter what happens next — including a body this SDK
    // cannot decode.
    final tokens = _decodeTokenResponse(response, previous: current);
    if (epoch != _credentialEpoch) {
      // Signed out (or the grant was revoked) while this was on the wire. The
      // server has issued a fresh pair, but nobody asked for it any more —
      // writing it would undo the sign-out.
      throw _discardedMidFlight;
    }
    // One write for the pair. The refresh token rotates, so replacing them
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

  /// The parameters an authorization redirect must carry at least one of.
  ///
  /// A URL on this client's own redirect that has none of them did not come
  /// from the authorization server, so it is left alone rather than allowed to
  /// resolve — or to fail — a pending request. Spelled the same in the Kotlin
  /// SDK.
  static const List<String> _oauthRedirectParameters = <String>[
    'state',
    'code',
    'error',
  ];

  /// Whether [url] is addressed to this client's own redirect URI.
  ///
  /// Compared as everything before the query and the fragment — scheme,
  /// authority and path, the parts a redirect registration fixes.
  /// Case-insensitively, because scheme and host are (RFC 3986 §3.1 and
  /// §3.2.2), and with trailing slashes ignored, because a browser adds one to
  /// a bare-authority URL and a registration usually does not carry it.
  ///
  /// Getting this wrong in the permissive direction costs nothing: `state` is
  /// still checked afterwards, and that is what actually decides whether a code
  /// may be redeemed. Getting it wrong in the restrictive direction would drop
  /// a real redirect, so it errs towards accepting.
  bool _isOurRedirect(Uri url) =>
      _redirectTarget(url.toString()).toLowerCase() ==
      _redirectTarget(mode.redirectUri).toLowerCase();

  static String _redirectTarget(String url) {
    var target = url;
    final fragment = target.indexOf('#');
    if (fragment >= 0) target = target.substring(0, fragment);
    final query = target.indexOf('?');
    if (query >= 0) target = target.substring(0, query);
    while (target.endsWith('/')) {
      target = target.substring(0, target.length - 1);
    }
    return target;
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
