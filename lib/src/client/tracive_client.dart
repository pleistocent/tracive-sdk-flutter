// Copyright (c) Tracive. Licensed under the Apache License, Version 2.0.
//
// The API client.
//
// NO NETWORK IN TESTS. Every byte leaves through the injected [HttpTransport],
// so `test/client_test.dart` drives the whole thing against a fake. The Open
// API does not exist yet (spec preamble); a test that reached for it could only
// be aspirational, and once the API is live, a suite that depends on it fails
// whenever somebody else is mid-deploy.
//
// The cache lives in `lib/src/cache/`, not here. This file decides *whether* to
// consult it for a given `Source`; everything about TTL, the hashed key, the
// "never cache full detail" projection and the zero-TTL invalidation lever is
// `CheckCache`'s, and is tested there. Two owners for one rule is how the two
// halves drift apart.

import 'dart:convert';

import '../cache/check_cache.dart';
import '../exception.dart';
import '../model/auth_result.dart';
import '../model/billing.dart';
import '../model/cache_policy.dart';
import '../model/check_result.dart';
import '../model/credits_info.dart';
import '../model/detail.dart';
import '../model/origin.dart';
import '../model/profile_info.dart';
import '../model/source.dart';
import '../model/tracive_environment.dart';
import '../model/tracive_mode.dart';
import '../oauth/auth_launcher.dart';
import '../oauth/token_store.dart';
import '../oauth/tracive_oauth.dart';
import '../query/tracive_query.dart';
import 'clock.dart';
import 'error_envelope.dart';
import 'http_package_transport.dart';
import 'http_transport.dart';
import 'retry_policy.dart';

/// Path of the check endpoint, relative to the environment base URL.
const String scammerChecksPath = 'scammer-checks';

/// Path of the credits endpoint.
const String creditsPath = 'credits';

/// Path of the profile endpoint.
const String profilePath = 'profile';

/// The entry point of the SDK.
///
/// ```dart
/// final client = TraciveClient(
///   mode: TraciveMode.oauth(
///     clientId: 'your-client-id',
///     redirectUri: 'https://your.app/oauth/callback',
///   ),
/// );
///
/// final result = await client.checkScammer(TraciveQuery.phone('+6281234567891'));
/// if (result.riskTier.isRisky) showWarning(result.disclaimer);
/// ```
///
/// ## Two things that are not optional
///
/// * **There is no API-key parameter here, in any mode.** That is a hard design
///   invariant, not an omission. Authentication is OAuth with PKCE, so
///   nothing long-lived and secret ever ships inside your binary.
/// * **Surface `CheckResult.disclaimer` in your UI.** These are user-submitted
///   reports, not adjudicated findings, and presenting them as the latter is
///   how a false positive becomes someone's problem.
///
/// ## Do not poll `credits()`
///
/// Do **not** call [credits] before each check to see whether you can
/// afford it. Make the check and handle
/// [TraciveInsufficientCreditsException] — that is one round trip per
/// transaction instead of two, and it is correct under concurrency where a
/// pre-check is not.
class TraciveClient {
  /// Creates a client.
  ///
  /// The first four parameters are the configuration. The rest are seams:
  /// [transport] and [clock] are named as such by the cross-SDK contract;
  /// [retryPolicy], [cache], [tokenStore], [launcher], [oauth] and
  /// [installUrl] are additive, and every one of them has a working
  /// default, so an app passes none of them.
  ///
  /// **The default [cache] is in memory**, which is deliberate: a constructor
  /// must not silently open a database file and a Keystore entry. For the
  /// persistent encrypted cache, build it explicitly and pass it in — that call
  /// is `await openTraciveCache()` and it is the one place in this SDK that
  /// touches a platform plugin:
  ///
  /// ```dart
  /// final client = TraciveClient(mode: mode, cache: await openTraciveCache());
  /// ```
  ///
  /// When you supply a [cache], **its** [CheckCache.policy] is the policy in
  /// force and [cachePolicy] here is only the seed for the default cache. There
  /// is exactly one owner of the TTL rules, and it is the cache.
  factory TraciveClient({
    required TraciveMode mode,
    TraciveEnvironment environment = TraciveEnvironment.production,
    CachePolicy cachePolicy = CachePolicy.defaultPolicy,
    Source defaultSource = Source.cacheFirst,
    HttpTransport? transport,
    TraciveClock? clock,
    RetryPolicy retryPolicy = RetryPolicy.defaultPolicy,
    CheckCache? cache,
    TokenStore? tokenStore,
    AuthLauncher? launcher,
    TraciveOAuth? oauth,
    String? installUrl,
  }) {
    final resolvedTransport = transport ?? createDefaultHttpTransport();
    final resolvedClock = clock ?? TraciveClock.system;
    // Proxy mode has no OAuth flow: it authenticates with the partner's own
    // headers against the partner's own endpoint. Every call throws anyway
    // (phase 2), so there is nothing to build.
    final resolvedOAuth = mode is TraciveOAuthMode
        ? (oauth ??
            TraciveOAuth(
              mode: mode,
              environment: environment,
              transport: resolvedTransport,
              tokenStore: tokenStore,
              launcher: launcher,
              clock: resolvedClock,
              installUrl: installUrl,
            ))
        : null;
    return TraciveClient._(
      mode: mode,
      environment: environment,
      defaultSource: defaultSource,
      cache: cache ??
          CheckCache.inMemory(policy: cachePolicy, clock: resolvedClock.now),
      oauth: resolvedOAuth,
      transport: resolvedTransport,
      clock: resolvedClock,
      retryPolicy: retryPolicy,
    );
  }

  TraciveClient._({
    required this.mode,
    required this.environment,
    required this.defaultSource,
    required this.cache,
    required this.oauth,
    required HttpTransport transport,
    required TraciveClock clock,
    required RetryPolicy retryPolicy,
  })  : _transport = transport,
        _clock = clock,
        _retryPolicy = retryPolicy;

  /// How this client authenticates.
  final TraciveMode mode;

  /// Which deployment it talks to.
  final TraciveEnvironment environment;

  /// The [Source] used when [checkScammer] is called without one.
  final Source defaultSource;

  /// The local result cache, whose `client.cache.clear()` this is.
  ///
  /// Never `null`: "no cache" is spelled `CheckCache.disabled()`, so no caller
  /// has to null-check, and the difference between "not caching" and "cache
  /// broken" stays visible in [CheckCache.lastStoreError] instead of collapsing
  /// into a null.
  final CheckCache cache;

  /// The OAuth flow, or `null` in Proxy mode.
  final TraciveOAuth? oauth;

  final HttpTransport _transport;
  final TraciveClock _clock;
  final RetryPolicy _retryPolicy;

  /// The TTL rules in force — always [cache]'s own policy.
  CachePolicy get cachePolicy => cache.policy;

  /// Checks one identifier.
  ///
  /// [query] is already folded and already validated: `TraciveQuery`'s builders
  /// throw before construction if the input could not produce a matching key,
  /// because a miss is billed. Nothing further is validated here.
  ///
  /// [source] defaults to [defaultSource]. [detail] defaults to
  /// [Detail.minimal]; [locale] is **omitted from the request** when
  /// `detail == minimal`, because the server ignores it there.
  ///
  /// [idempotencyKey] is worth more than it looks. This client will
  /// **not** auto-retry a check on a 5xx or a timeout unless you pass one — a
  /// blind retry of a POST that may already have been processed risks charging
  /// the user twice. Pass a key (a UUID per logical check, stable across your
  /// own retries) and retrying becomes safe, both here and in your code.
  ///
  /// Throws a [TraciveException] subtype from the error-code table, or
  /// [TraciveCacheMissException] when `source: Source.cache` finds no live
  /// entry — never a silent empty result that would read as "not a scammer".
  Future<CheckResult> checkScammer(
    TraciveQuery query, {
    Source? source,
    Detail detail = Detail.minimal,
    String? locale,
    String? idempotencyKey,
  }) async {
    _ensureOAuthMode();
    final effectiveSource = source ?? defaultSource;

    // Full detail never touches the cache, in either direction, and this is
    // where that is decided because this is the only place that knows what was
    // *asked for* — a response alone cannot tell you, since a full-detail
    // answer for an identifier with no reports looks exactly like a minimal
    // one.
    //
    // Writing is unsound because the row key is the query alone: a full-detail
    // response carries `disclaimer` and `tags` in the requested language, so
    // storing its projection means a later `detail: minimal` caller, whose
    // request carried no locale at all, reads back a disclaimer in somebody
    // else's language — in the one string this SDK tells every integrator to
    // put on screen.
    //
    // Reading is unsound for a plainer reason: a cached row has no
    // chronologies and no comments, so answering a full-detail check from it
    // silently returns less than was asked for.
    //
    // The alternative would be to key rows by `(query, detail, locale)`. That
    // is a larger contract change for no gain, because a full-detail row could
    // only ever be served to a caller who wanted the content it is not allowed
    // to keep. `Detail.minimal` being "the only form that is cached" is what
    // both enum members already document; this makes the code agree.
    final cacheApplies = detail == Detail.minimal;

    // `cacheFirst` and `cache` consult the cache before the network;
    // `serverFirst` consults it only after the network has failed; `server`
    // never reads it at all.
    final readsCacheFirst = cacheApplies &&
        (effectiveSource == Source.cacheFirst ||
            effectiveSource == Source.cache);
    if (readsCacheFirst) {
      // A hit is already stamped `Origin.cache`, already checked against the
      // TTL, and cost zero credits and zero network I/O.
      final hit = await cache.read(query);
      if (hit != null) return hit;
    }

    if (!effectiveSource.readsNetwork) {
      throw const TraciveCacheMissException(
        'No live cached result for this query, and source was Source.cache',
      );
    }

    try {
      final result = await _fetchCheck(
        query: query,
        detail: detail,
        locale: locale,
        idempotencyKey: idempotencyKey,
      );
      // The cache decides what to keep *within* a cacheable answer:
      // `cacheable()` on the way in, and a non-positive `cacheTtlSeconds`
      // deletes rather than stores (the fleet-wide invalidation lever). None of
      // that is re-implemented here.
      if (cacheApplies) await cache.write(query, result);
      return result;
    } on TraciveException catch (error) {
      if (cacheApplies &&
          effectiveSource == Source.serverFirst &&
          _isWorthFallingBack(error)) {
        final fallback = await cache.read(query);
        if (fallback != null) return fallback;
      }
      rethrow;
    }
  }

  /// `GET /credits`.
  ///
  /// **Do not call this before every check.** Handle the 402
  /// ([TraciveInsufficientCreditsException]) instead; it saves one call per
  /// transaction, and a pre-check is racy anyway — the balance can change
  /// between the two requests.
  Future<CreditsInfo> credits() async {
    _ensureOAuthMode();
    final response = await _sendAuthorized(
      TraciveHttpRequest(
        method: 'GET',
        url: environment.resolve(creditsPath),
        headers: const <String, String>{'accept': 'application/json'},
      ),
      // A GET changes nothing and costs nothing, so repeating it is free.
      safeToRepeat: true,
    );
    return CreditsInfo.fromJson(_requireJsonObject(response));
  }

  /// `GET /profile`.
  ///
  /// PRIVACY: the result is personal data about the authenticated Tracive user.
  /// [ProfileInfo.toString] already omits the name; do not log the object's
  /// fields individually either.
  Future<ProfileInfo> profile() async {
    _ensureOAuthMode();
    final response = await _sendAuthorized(
      TraciveHttpRequest(
        method: 'GET',
        url: environment.resolve(profilePath),
        headers: const <String, String>{'accept': 'application/json'},
      ),
      safeToRepeat: true,
    );
    return ProfileInfo.fromJson(_requireJsonObject(response));
  }

  /// Starts the OAuth flow — see [TraciveOAuth.authorize] for the return
  /// contract (`null` means "the browser is open; wait for the redirect").
  ///
  /// `async` on purpose, as are the two below: in Proxy mode these throw
  /// [TraciveNotImplementedException], and a method that sometimes throws
  /// synchronously and sometimes returns a rejected future is a method whose
  /// `.catchError` silently does not catch. Every failure on this class arrives
  /// the same way.
  Future<AuthResult?> authorize() async {
    _ensureOAuthMode();
    return oauth!.authorize();
  }

  /// Handles the OAuth redirect — see [TraciveOAuth.handleCallback].
  Future<AuthResult> handleCallback(Uri url) async {
    _ensureOAuthMode();
    return oauth!.handleCallback(url);
  }

  /// Revokes the grant best-effort and clears local tokens.
  Future<void> signOut() async {
    _ensureOAuthMode();
    return oauth!.signOut();
  }

  /// Releases the HTTP transport. Call it when the client is done with.
  ///
  /// Deliberately does **not** close [cache]: a cache can be shared between
  /// clients and is often owned by the host app. Close the one you opened.
  void close() => _transport.close();

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  void _ensureOAuthMode() {
    if (mode is! TraciveOAuthMode) {
      // Spelled exactly as the contract spells it, so the three SDKs say the
      // same thing.
      throw const TraciveNotImplementedException(
        'Proxy mode arrives in phase 2',
      );
    }
  }

  /// Whether a failed `serverFirst` call may be answered from the cache.
  ///
  /// Yes for the failures that say "the server could not answer right now":
  /// transport, 5xx, 429, and an exhausted credit balance. A slightly old
  /// verdict beats no verdict on a payment screen.
  ///
  /// No for the failures that say "this caller is not entitled to an answer" —
  /// a revoked grant, a missing scope, a rejected token. Papering over those
  /// with a cached result hides a broken integration from the developer and
  /// keeps serving data the user may have just revoked consent for.
  bool _isWorthFallingBack(TraciveException error) =>
      error is TraciveNetworkException ||
      error is TraciveServerException ||
      error is TraciveRateLimitedException ||
      error is TraciveInsufficientCreditsException;

  Future<CheckResult> _fetchCheck({
    required TraciveQuery query,
    required Detail detail,
    required String? locale,
    required String? idempotencyKey,
  }) async {
    final hasIdempotencyKey =
        idempotencyKey != null && idempotencyKey.trim().isNotEmpty;
    final body = jsonEncode(<String, Object?>{
      // phase 1 always sends USER.
      'creditSource': Billing.userCreditSource,
      'detail': detail.wireValue,
      // Omitted for minimal: the server ignores it there.
      if (detail.supportsLocale && locale != null && locale.isNotEmpty)
        'locale': locale,
      // `query`, not `input`: the key is already folded, and that same folded
      // string is what the cache key is derived from.
      'query': query.searchQueryIndex,
    });

    final response = await _sendAuthorized(
      TraciveHttpRequest(
        method: 'POST',
        url: environment.resolve(scammerChecksPath),
        headers: <String, String>{
          'accept': 'application/json',
          'content-type': 'application/json; charset=utf-8',
          if (hasIdempotencyKey) 'idempotency-key': idempotencyKey.trim(),
        },
        body: body,
      ),
      // Without an Idempotency-Key a repeat could double-charge, so the
      // retry policy is not allowed to fire.
      safeToRepeat: hasIdempotencyKey,
    );

    return CheckResult.fromJson(
      _requireJsonObject(response),
      origin: Origin.server,
      fetchedAt: _clock.now(),
    );
  }

  /// Sends [request] with a bearer token, handling the refresh and the retry.
  ///
  /// Three distinct behaviours, deliberately not merged:
  ///
  /// * **401 `expired_token` -> refresh -> replay, exactly once.** The rejected
  ///   request was never processed, so replaying it cannot double-charge; that
  ///   is why this replay is allowed even without an `Idempotency-Key`, and why
  ///   it does not consume the retry budget. `refreshedOnce` bounds it: if the
  ///   replay is rejected again, something is wrong that a third attempt will
  ///   not fix.
  /// * **401 `grant_revoked` -> clear and stop.** No refresh, no retry.
  ///   Retrying with a dead refresh token is what trips reuse detection.
  /// * **5xx / transport -> retry only if [safeToRepeat].**
  Future<TraciveHttpResponse> _sendAuthorized(
    TraciveHttpRequest request, {
    required bool safeToRepeat,
  }) async {
    // Counts only the failures that are candidates for the retry budget. The
    // token replay above is not one of them.
    var failedAttempts = 0;
    var refreshedOnce = false;

    while (true) {
      final token = await oauth!.ensureAccessToken();
      TraciveHttpResponse response;
      try {
        response = await _transport.send(
          request.withHeader('authorization', 'Bearer $token'),
        );
      } catch (error, stackTrace) {
        final failure = asTraciveException(error, stackTrace);
        failedAttempts++;
        if (_retryPolicy.shouldRetry(
          failure,
          safeToRepeat: safeToRepeat,
          attemptsSoFar: failedAttempts,
        )) {
          await _wait(_retryPolicy.backoffFor(failedAttempts + 1));
          continue;
        }
        throw failure;
      }

      if (response.isSuccess) return response;

      if (response.statusCode == 401) {
        final code = errorCodeOf(response);
        if (code == 'grant_revoked') {
          await oauth!.clearTokens();
          throw mapErrorResponse(response);
        }
        if (code == 'expired_token' && !refreshedOnce) {
          refreshedOnce = true;
          await oauth!.refreshTokens(staleAccessToken: token);
          continue;
        }
      }

      final failure = mapErrorResponse(response);
      failedAttempts++;
      if (_retryPolicy.shouldRetry(
        failure,
        safeToRepeat: safeToRepeat,
        attemptsSoFar: failedAttempts,
      )) {
        await _wait(_retryPolicy.backoffFor(failedAttempts + 1));
        continue;
      }
      throw failure;
    }
  }

  Map<String, Object?> _requireJsonObject(TraciveHttpResponse response) {
    final json = decodeJsonObject(response.body);
    if (json == null) {
      throw TraciveServerException(
        statusCode: response.statusCode,
        message: 'The API returned a body that is not a JSON object',
      );
    }
    return json;
  }

  static Future<void> _wait(Duration amount) => amount <= Duration.zero
      ? Future<void>.value()
      : Future<void>.delayed(amount);

  @override
  String toString() =>
      'TraciveClient(mode: $mode, environment: ${environment.name}, '
      'defaultSource: ${defaultSource.name})';
}
