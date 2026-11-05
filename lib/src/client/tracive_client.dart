// Copyright 2026 PT Pleistocent Teknologi Nusantara.
// Licensed under the Apache License, Version 2.0.
//
// The API client.
//
// NO NETWORK IN TESTS. Every byte leaves through the injected [HttpTransport],
// so `test/client_test.dart` drives the whole thing against a fake. A suite
// that depends on a live environment fails whenever somebody else is
// mid-deploy.
//
// The cache lives in `lib/src/cache/`, not here. This file decides *whether* to
// consult it for a given `Source`; everything about TTL, the hashed key, the
// "never cache full detail" projection and the zero-TTL invalidation lever is
// `CheckCache`'s, and is tested there. Two owners for one rule is how the two
// halves drift apart.

import 'dart:convert';
import 'dart:math';

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
// Same split as `TraciveOAuth`'s: the Flutter implementations under Flutter,
// the inert ones under a bare Dart VM.
import '../oauth/platform_default.dart'
    if (dart.library.ui) '../oauth/platform_flutter.dart' as auth_platform;
import '../oauth/token_store.dart';
import '../oauth/tracive_oauth.dart';
import '../query/tracive_query.dart';
import '../report/report_attachment.dart';
import '../report/report_form_flow.dart';
import '../report/report_form_launcher.dart';
import '../report/report_form_result.dart';
import '../report/report_form_target.dart';
import '../report/report_platform_default.dart'
    if (dart.library.ui) '../report/report_platform_flutter.dart'
    as report_platform;
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

/// Randomness for the generated `Idempotency-Key`.
///
/// `Random.secure()` because the cost is one draw per check and it removes a
/// question that would otherwise need answering: a key only has to be unique,
/// but "unique enough" arguments about a seeded generator are not worth having
/// on a value that identifies a billable operation.
final Random _idempotencyKeyRandom = Random.secure();

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
  /// The first four parameters are the configuration. [installUrl] applies in
  /// OAuth mode only and defaults to [TraciveOAuth.defaultInstallUrl], so pass
  /// it only to override that link — and pass a real URL when you do. Only
  /// `null` means "use the default"; a blank or whitespace-only string is a
  /// configured value, it is not normalised away here, and it throws
  /// [ArgumentError] with the reason `blank_install_url` (see
  /// [TraciveOAuth.installUrl] for why). The rest are seams:
  /// [transport] and [clock] are named as such by the cross-SDK contract;
  /// [retryPolicy], [cache], [tokenStore], [launcher], [oauth] and
  /// [reportFormLauncher] are additive, and every one of them has a working
  /// default, so an app passes none of them.
  ///
  /// [installUrl] and [launcher] also serve [openReportForm], in every mode.
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
    ReportFormLauncher? reportFormLauncher,
  }) {
    final resolvedTransport = transport ?? createDefaultHttpTransport();
    final resolvedClock = clock ?? TraciveClock.system;
    final resolvedLauncher =
        launcher ?? auth_platform.createDefaultAuthLauncher();
    // Proxy mode builds no TraciveOAuth, so the blank-link rule it enforces is
    // applied here instead: openReportForm uses the link in every mode.
    if (mode is! TraciveOAuthMode &&
        installUrl != null &&
        installUrl.trim().isEmpty) {
      throw ArgumentError.value(
        installUrl,
        'installUrl',
        '${TraciveOAuth.blankInstallUrlReason}: pass a real URL or omit the '
            'parameter.',
      );
    }
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
              launcher: resolvedLauncher,
              clock: resolvedClock,
              // `??` fires on absence only. A blank string is a configured
              // value and travels through unchanged, so it meets the same
              // rejection in TraciveOAuth's constructor that it would have met
              // had the flow been built directly. Normalising it here — to the
              // default or to anything else — would make the client the one
              // place where a blank quietly works.
              installUrl: installUrl ?? TraciveOAuth.defaultInstallUrl,
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
      launcher: resolvedLauncher,
      installUrl: resolvedOAuth?.installUrl ??
          installUrl ??
          TraciveOAuth.defaultInstallUrl,
      reportFormLauncher: reportFormLauncher ??
          report_platform.createDefaultReportFormLauncher(),
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
    required AuthLauncher launcher,
    required String installUrl,
    required ReportFormLauncher reportFormLauncher,
  })  : _transport = transport,
        _clock = clock,
        _retryPolicy = retryPolicy,
        _launcher = launcher,
        _installUrl = installUrl,
        _reportFormLauncher = reportFormLauncher;

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
  final AuthLauncher _launcher;
  final String _installUrl;
  final ReportFormLauncher _reportFormLauncher;

  /// Checks currently on the wire, keyed by row key, detail level, locale and
  /// the caller's own idempotency key.
  ///
  /// The latch itself, and the reasoning for it, is on [_fetchCheckLatched].
  final Map<String, Future<CheckResult>> _inFlightChecks =
      <String, Future<CheckResult>>{};

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
  /// The request nonetheless always carries *some* `Idempotency-Key`: when you
  /// supply none, a per-call one is generated so that this client's own replay
  /// after a 401 refresh can be collapsed server-side. That does not give you a
  /// retry budget — only your own key does — and it is no substitute for a key
  /// derived from your transaction if you want retries or deduplication across
  /// processes.
  ///
  /// **Identical checks that overlap are one request and one charge.** A call
  /// for the same identifier, detail level and locale made while another is
  /// still on the wire joins that request rather than starting a second one, so
  /// a double-tapped button — or a list screen rendering one identifier in two
  /// cells — is billed once. Both callers get the same answer, stamped
  /// [Origin.server], because that is where it came from. Checks that do not
  /// overlap are the cache's business, not this one's.
  ///
  /// **Your [idempotencyKey] is part of what "identical" means.** Two
  /// overlapping checks that carry different keys of yours are two transactions
  /// you deliberately told this client apart, so they are two requests; a check
  /// carrying one of your keys never joins a flight started without it, which is
  /// what keeps its retry budget. Sharing still covers the case the latch exists
  /// for, because a double-tapped button and a list cell rendered twice go
  /// through one code path with one set of options.
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
      final result = await _fetchCheckLatched(
        query: query,
        detail: detail,
        locale: locale,
        idempotencyKey: idempotencyKey,
      );
      // The cache decides what to keep *within* a cacheable answer:
      // `cacheable()` on the way in, and a non-positive tier TTL deletes rather
      // than stores. None of that is re-implemented here.
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
  ///
  /// Returns `null` when [url] is not this client's redirect, or carries no
  /// OAuth parameter at all: "not mine", not an error, and nothing was touched.
  /// That is what makes it safe to route every incoming deep link through here.
  Future<AuthResult?> handleCallback(Uri url) async {
    _ensureOAuthMode();
    return oauth!.handleCallback(url);
  }

  /// Revokes the grant best-effort, clears the local tokens, and **empties the
  /// result cache**.
  ///
  /// The cache goes too, and that is not housekeeping. Its rows were fetched
  /// under the grant of the user who just signed out — they are that person's
  /// check history, which is to say a list of who they suspected of fraud — and
  /// the next person to use this device must not inherit it. Leaving them
  /// behind also means the SDK keeps serving verdicts obtained under consent
  /// that has just been withdrawn.
  ///
  /// ## Why the client owns this, when [close] deliberately does not
  ///
  /// [close] refuses to touch [cache] because a cache can be shared between
  /// clients and is often built and owned by the host app: closing something
  /// you did not open is how another client's next read fails.
  ///
  /// Sign-out is the opposite case, and sharing is the reason rather than the
  /// objection. The obligation attaches to the **data**, not to who holds the
  /// handle: a shared cache means the departing user's verdicts are visible to
  /// *more* clients, not fewer. Nor could a narrower clear be written even if
  /// one were wanted — the row key is `SHA-256(searchQueryIndex)` and carries
  /// no user, so a row cannot be attributed to whoever fetched it, and
  /// "everything" is the only set that certainly contains theirs.
  ///
  /// Closing is destructive and terminal; clearing is not. A cache that has
  /// been emptied still works — the next check for each identifier simply costs
  /// a credit, which is exactly the right price for the first check after a
  /// sign-out. That asymmetry is why one of these methods may act on a shared
  /// cache and the other may not.
  ///
  /// The tokens are discarded first, so a cache that refuses to empty surfaces
  /// its failure without having blocked the sign-out itself. If this throws,
  /// the grant is already gone and the verdicts are not — which is worth
  /// knowing, and is why the failure is not swallowed.
  Future<void> signOut() async {
    _ensureOAuthMode();
    await oauth!.signOut();
    await cache.clear();
  }

  /// Whether a grant is stored, by delegating to [oauth].
  ///
  /// False in proxy mode rather than throwing: a proxied client genuinely holds
  /// no grant, which is an answer to the question rather than a misuse of it.
  /// Swift, Kotlin and React Native all spell it this way.
  Future<bool> get isAuthorized async =>
      mode is TraciveOAuthMode ? await oauth!.isAuthorized : false;

  /// Empties the result cache, and nothing else.
  ///
  /// The same call as `client.cache.clear()`, named where a reader looks for
  /// it. [signOut] already does this; reach for this one when the user stays
  /// signed in and only the stored verdicts should go — a "clear data" button,
  /// or a privacy setting. The four SDKs all spell it this way.
  Future<void> clearCache() => cache.clear();

  /// Opens Tracive's report form with [query], [incidentDate] and
  /// [attachments] already filled in, for a user reporting the recipient of a
  /// transaction as a scammer.
  ///
  /// It needs no grant and no token, spends no credit and makes no request,
  /// so it works for a confidential client, before `authorize()`, and in proxy
  /// mode. Nothing leaves the phone: the files travel to the Tracive app on the
  /// device, and the user decides there whether to submit.
  ///
  /// [incidentDate] is the transaction's calendar date. Only its `year`,
  /// `month` and `day` are read, exactly as they are, with no time zone
  /// conversion — so pass the date as your user saw it (`DateTime(2026, 11, 3)`,
  /// or `.toLocal()` first if you hold a UTC instant). A date after the
  /// device's local today is refused.
  ///
  /// Every rule is checked before anything is written or opened, and a broken
  /// one returns [ReportFormFailed] naming it (see [ReportFormError] for the
  /// order). Then, against the build of the Tracive app for [environment] —
  /// sandbox for sandbox, production otherwise:
  ///
  /// * the app accepts the package → `ReportFormOpened(attachmentsDelivered:
  ///   true)`. On iOS the user first picks Tracive in the "Open in" sheet,
  ///   which is popped over [anchor] on iPad; dismissing it, or picking any
  ///   other app or "Save to Files", returns [ReportFormCancelled].
  /// * the app is installed but too old for packages → it is opened on the
  ///   identifier alone, `ReportFormOpened(attachmentsDelivered: false)`.
  /// * the app is not installed → the same install link [authorize] opens,
  ///   carrying neither the identifier nor the files,
  ///   [ReportFormInstallPageOpened].
  ///
  /// [target] overrides the build, for testing against a build the SDK does
  /// not know about; see [ReportFormTarget.new].
  ///
  /// iOS needs `<capabilityScheme>` and `<appScheme>` of each target in
  /// `LSApplicationQueriesSchemes` (`tracive-report`, `tracivesandbox-report`,
  /// `tracive`, `tracivesandbox`). Without the capability schemes every user
  /// gets the identifier-only form, never the attachments.
  ///
  /// **It does not throw.** A platform failure arrives as
  /// `ReportFormFailed(ReportFormPlatformFailure(reason))`.
  Future<ReportFormResult> openReportForm(
    TraciveQuery query, {
    DateTime? incidentDate,
    List<ReportAttachment> attachments = const <ReportAttachment>[],
    ReportFormAnchor? anchor,
    ReportFormTarget? target,
  }) {
    final mode = this.mode;
    return runReportForm(
      query: query.searchQueryIndex,
      incidentDate: incidentDate,
      attachments: attachments,
      today: _clock.now().toLocal(),
      target: target ?? ReportFormTarget.forEnvironment(environment),
      anchor: anchor,
      launcher: _reportFormLauncher,
      authLauncher: _launcher,
      installUrl: _installUrl,
      clientId: mode is TraciveOAuthMode ? mode.clientId : null,
    );
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
  /// Yes for **transport-shaped** failures only — the ones that say "the server
  /// could not answer right now": a network error, a 5xx, a 429. A slightly old
  /// verdict beats no verdict on a payment screen, and none of those three says
  /// anything about whether the caller is entitled to a fresh one.
  ///
  /// No for everything else, which is to say every failure that carries a
  /// verdict about the caller: a revoked grant, a missing scope, a rejected
  /// token — and an exhausted credit balance. Papering over those with a cached
  /// result hides a broken integration from the developer and keeps serving
  /// data the user may have just revoked consent for.
  ///
  /// **402 used to be in this set, and that was the expensive one.** A partner
  /// whose balance has run out would be handed a cached verdict that is
  /// indistinguishable from a normal answer: no exception, no flag on the
  /// result, nothing to log. They would carry on believing the integration was
  /// healthy until the cache emptied — at which point every check would start
  /// failing at once, on a payment screen, with no warning that the cause had
  /// been building for days. Surfacing
  /// [TraciveInsufficientCreditsException] the moment it happens is what gives
  /// them the chance to top up before that. An empty balance is not a transient
  /// server condition; it is a fact about the account that will not change on
  /// its own.
  bool _isWorthFallingBack(TraciveException error) =>
      error is TraciveNetworkException ||
      error is TraciveServerException ||
      error is TraciveRateLimitedException;

  /// [_fetchCheck], **single-flight**, because the unit here is currency.
  ///
  /// Two overlapping checks for the same identifier both read the cache, both
  /// missed, both POSTed and both were billed. The cache write is the only
  /// point where the two are serialised, and it happens *after* both requests
  /// have already gone out — so it cannot help. A double-tapped button, or a
  /// list screen rendering the same identifier in two cells, doubled the bill
  /// and nothing anywhere reported it. `TraciveOAuth.refreshTokens` has had the
  /// correct shape all along; this is the same latch in the one place where
  /// getting it wrong costs money rather than a round trip.
  ///
  /// The key is the row key **plus the detail level and the locale**, never the
  /// row key alone: a minimal result must never be handed back to a caller who
  /// asked for full. It carries the locale even for [Detail.minimal], where the
  /// request omits it — splitting a key too finely only costs a share that
  /// could have been made, while merging two keys that are not the same
  /// question hands somebody the wrong answer. Every Tracive SDK spells this
  /// key the same way.
  ///
  /// It carries the **caller's** idempotency key as well, when there is one,
  /// because that key is an explicit statement that this check is a transaction
  /// of the caller's own. Leaving it out overrode that statement twice over: a
  /// caller who supplied a key could join a flight started by one who did not,
  /// silently losing the retry budget that only a caller's key grants; and two
  /// overlapping checks carrying two different keys — the caller saying these
  /// are two billable transactions — were collapsed into one request under
  /// whichever key happened to arrive first. [_generatedIdempotencyKey] refuses
  /// to derive a key from the query for the same reason, "since that would
  /// collapse two deliberate re-checks of the same identifier into one"; the
  /// latch was doing exactly that through another door. What the latch exists
  /// for is untouched, because a double-tapped button and a list cell rendered
  /// twice reach this method through one code path with one set of options, and
  /// so still share a flight.
  ///
  /// The **generated** key must never go in here. It is unique per call, so
  /// including it would give every unkeyed check a latch of its own and turn the
  /// feature off entirely — which is why the key is read here, where a caller's
  /// key and no key are still distinguishable, rather than in [_fetchCheck]
  /// where one has already been substituted for the other. A blank key is no
  /// key, in the latch exactly as on the wire. The caller's key goes last, so a
  /// value containing the separator cannot be read as another segment.
  ///
  /// Nothing is awaited between reading the map and writing it — this method is
  /// not `async` for exactly that reason. An `await` in that gap is the whole
  /// bug back again, because both callers would observe an empty map and both
  /// would start a flight.
  ///
  /// **If per-request cancellation is ever added to [checkScammer], a call
  /// carrying it must neither join nor start a shared flight.** One caller's
  /// cancel would otherwise abandon another caller's check — or, if the signal
  /// were dropped on the way in, cancelling would stop cancelling anything and
  /// spend the credit it exists to save. There is no such parameter today (a
  /// Dart `Future` is not cancellable and this SDK exposes no token for it), so
  /// there is nothing to carve out yet; the React Native SDK, which does have
  /// one, carves it out there.
  Future<CheckResult> _fetchCheckLatched({
    required TraciveQuery query,
    required Detail detail,
    required String? locale,
    required String? idempotencyKey,
  }) {
    final latchKey = '${cacheKeyFor(query)}|${detail.wireValue}|'
        '${locale ?? ''}|${_callerIdempotencyKey(idempotencyKey) ?? ''}';
    final existing = _inFlightChecks[latchKey];
    if (existing != null) return existing;

    final flight = _fetchCheck(
      query: query,
      detail: detail,
      locale: locale,
      idempotencyKey: idempotencyKey,
    ).whenComplete(() {
      // A statement body, not an expression one. `Map.remove` answers the value
      // it removed — this very future — and a `whenComplete` callback that
      // returns a future is awaited before the result is delivered, so the
      // arrow form makes the flight wait on itself and every check hangs.
      _inFlightChecks.remove(latchKey);
    });
    _inFlightChecks[latchKey] = flight;
    return flight;
  }

  Future<CheckResult> _fetchCheck({
    required TraciveQuery query,
    required Detail detail,
    required String? locale,
    required String? idempotencyKey,
  }) async {
    final callerKey = _callerIdempotencyKey(idempotencyKey);
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
          // Every check carries an `Idempotency-Key`, whether the caller
          // supplied one or not.
          //
          // This client re-sends the identical POST after a 401 refresh (see
          // [_sendAuthorized]). Without a key the two attempts are
          // indistinguishable to the server, so any billing that happens before
          // or during authorisation is charged twice, with no way for the
          // caller to detect it. This code used to justify the replay with "a
          // 401 is rejected before billing" — an assumption about the server's
          // ordering that nothing on the client can verify, and the one premise
          // this SDK otherwise refuses to make anywhere. Generating a key
          // removes the need to assume anything.
          'idempotency-key': callerKey ?? _generatedIdempotencyKey(),
        },
        body: body,
      ),
      // A generated key is **not** a licence to retry. The retry budget keys
      // off the *caller's* key, so a 5xx, a 429 or a timeout on an unkeyed
      // check is still surfaced immediately, exactly as README and SECURITY.md
      // promise. A key the SDK invented would let the server collapse a
      // duplicate charge, but it cannot tell the caller whether the first
      // attempt landed, and that is the decision retrying takes away from them.
      safeToRepeat: callerKey != null,
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
  /// * **401 -> refresh -> replay, exactly once.** The replay is the identical
  ///   request, and it carries an `Idempotency-Key` — [_fetchCheck] attaches
  ///   one even when the caller supplied none — so if the first attempt was
  ///   billed after all, the server can collapse the two into a single charge.
  ///   It deliberately does not consume the retry budget: this is a
  ///   re-authentication, not a retry of a failed check. `refreshedOnce` bounds
  ///   it, because if the replay is rejected again, something is wrong that a
  ///   third attempt will not fix.
  /// * **401 `grant_revoked` -> clear and stop.** No refresh, no retry.
  ///   Retrying with a dead refresh token is what trips reuse detection.
  ///   `invalid_token` is terminal too, without the teardown: a credential the
  ///   server calls unusable is not made usable by minting another one.
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
        // Refresh on any 401 that is not terminal, rather than only on an exact
        // `expired_token` body.
        //
        // A bare `401 Unauthorized` — no body at all, or a `WWW-Authenticate`
        // header and nothing else — is what CDNs, API gateways and
        // misconfigured reverse proxies emit, and this SDK is explicitly
        // designed to sit behind a partner gateway (the proxy contract exists
        // for that). Requiring the code left the client permanently stuck in
        // that state: `errorCodeOf` answers `null`, the branch never fired, and
        // every subsequent call failed identically until the app happened to
        // call `authorize()` again. The user's grant was fine the whole time.
        //
        // `invalid_token` is excluded alongside `grant_revoked`, for the same
        // reason at one remove: the server is saying the credential is not
        // usable at all, so obtaining a fresh one earns nothing. It is the
        // answer to a malformed or empty bearer, and refreshing into it would
        // spend a rotation to be told the same thing again.
        if (code != 'invalid_token' && !refreshedOnce) {
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

  /// The caller's own idempotency key, or `null` when they supplied none.
  ///
  /// Trimmed, because a stray space would make this client's post-refresh
  /// replay a different key from the attempt it repeats — the one thing an
  /// idempotency key must never be. A value that is blank once trimmed is no
  /// key at all: it buys no retry budget, a generated key is sent in its place,
  /// and it does not split the latch either. One reading of "the caller
  /// supplied a key", used everywhere that answer decides anything.
  static String? _callerIdempotencyKey(String? idempotencyKey) {
    // Only the "is there a key here" reading trims. The value goes out exactly as the caller
    // wrote it, whitespace included, because it is what the server deduplicates on and what the
    // partner recorded against their transaction — trimming it would send a key that differs from
    // the one in their ledger. The sibling SDKs spell it the same way.
    if (idempotencyKey == null || idempotencyKey.trim().isEmpty) return null;
    return idempotencyKey;
  }

  /// A per-call key for a check the caller did not key itself.
  ///
  /// Prefixed so a key this SDK invented is distinguishable from a partner's
  /// own in a server-side log, which is what makes a disputed charge
  /// reconcilable. A v4 UUID is the right shape: the key only has to be unique,
  /// never guessable or reproducible, and it must **never** be derived from the
  /// query — that would collapse two deliberate re-checks of the same
  /// identifier into one answer and one charge, which is a different bug in the
  /// same family.
  static String _generatedIdempotencyKey() {
    final bytes = List<int>.generate(
      16,
      (_) => _idempotencyKeyRandom.nextInt(256),
    );
    bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant 1
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return 'sdk-${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
        '${hex.substring(20)}';
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
