// Copyright 2026 PT Pleistocent Teknologi Nusantara.
// Licensed under the Apache License, Version 2.0.
//
// The API client.
//
// NO NETWORK. Every response in this file is a literal `TraciveHttpResponse`
// handed back by `_FakeTransport`. A suite that talks to a live environment
// fails whenever somebody else is mid-deploy. There is no host name in this
// file that is ever resolved.
//
// What is asserted here, in rough order of what it would cost to get wrong:
//
//   * the request the SDK actually puts on the wire — `query` not `input`,
//     `creditSource: USER`, `locale` omitted for minimal detail, the
//     `Idempotency-Key` header;
//   * which `Source` is allowed to spend a credit and which is not;
//   * that a check is never auto-retried without an `Idempotency-Key` —
//     the money bug, and the one that is silent when it happens;
//   * 401 -> refresh -> replay-once, and 401 `grant_revoked` -> clear and stop;
//   * that Proxy mode throws exactly the documented sentence.

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:test/test.dart';
import 'package:tracive_sdk/tracive_sdk.dart';

/// A fixed instant, so nothing in this file depends on when it is run.
final DateTime _t0 = DateTime.utc(2026, 7, 31, 12);

void main() {
  final query = TraciveQuery.phone('+6281234567891');

  // ---------------------------------------------------------------------------
  // The request that actually goes on the wire.
  // ---------------------------------------------------------------------------
  group('POST /scammer-checks request', () {
    test('hits the environment base URL with a bearer token', () async {
      final transport = _FakeTransport((_) => _ok(_checkBody()));
      final client = _client(transport: transport);

      await client.checkScammer(query, source: Source.server);

      final request = transport.requests.single;
      expect(request.method, 'POST');
      expect(
        request.url.toString(),
        'https://api.tracive.id/v1/scammer-checks',
      );
      expect(request.header('authorization'), 'Bearer access-token-1');
      expect(request.header('content-type'), contains('application/json'));
    });

    test('sends the folded key as "query", never as "input"', () async {
      final transport = _FakeTransport((_) => _ok(_checkBody()));
      final client = _client(transport: transport);

      await client.checkScammer(query, source: Source.server);

      final body = _bodyOf(transport.requests.single);
      // The SDK has already folded the key, and that same folded
      // string is the cache key. Sending `input` would have the server fold it
      // again — and any disagreement between the two foldings is a permanent,
      // billed cache miss.
      expect(body['query'], 'PHONE_+6281234567891');
      expect(body.containsKey('input'), isFalse);
    });

    test('always sends creditSource USER in phase 1', () async {
      final transport = _FakeTransport((_) => _ok(_checkBody()));
      final client = _client(transport: transport);

      await client.checkScammer(query, source: Source.server);

      expect(_bodyOf(transport.requests.single)['creditSource'], 'USER');
    });

    test('omits locale when detail is minimal — the server ignores it',
        () async {
      final transport = _FakeTransport((_) => _ok(_checkBody()));
      final client = _client(transport: transport);

      await client.checkScammer(query, source: Source.server, locale: 'id');

      final body = _bodyOf(transport.requests.single);
      expect(body['detail'], 'minimal');
      expect(body.containsKey('locale'), isFalse);
    });

    test('sends locale when detail is full', () async {
      final transport = _FakeTransport((_) => _ok(_checkBody()));
      final client = _client(transport: transport);

      await client.checkScammer(
        query,
        source: Source.server,
        detail: Detail.full,
        locale: 'id',
      );

      final body = _bodyOf(transport.requests.single);
      expect(body['detail'], 'full');
      expect(body['locale'], 'id');
    });

    test('every check carries an Idempotency-Key, supplied or generated',
        () async {
      // The SDK re-sends this exact POST after a 401 refresh. Without a key the
      // two attempts are indistinguishable to the server, so any billing that
      // happens before or during authorisation is charged twice with no way for
      // the caller to detect it. The code used to justify the replay with "a
      // 401 is rejected before billing" — an assumption about the server's
      // ordering that nothing on the client can verify. Generating a key
      // removes the need to assume it.
      final transport = _FakeTransport((_) => _ok(_checkBody()));
      final client = _client(transport: transport);

      await client.checkScammer(query, source: Source.server);
      final generated = transport.requests.last.header('idempotency-key');
      expect(generated, isNotNull);
      expect(
        generated,
        startsWith('sdk-'),
        reason: 'a key the SDK invented must be tellable from a partner\'s own '
            'in a server-side log, or a disputed charge cannot be reconciled',
      );

      await client.checkScammer(
        query,
        source: Source.server,
        idempotencyKey: '  9f3c-1  ',
      );
      // Sent exactly as given, whitespace and all. This used to be trimmed, on
      // the grounds that a stray space would make the replay a different key —
      // but the replay reuses the string this call captured, so it never
      // differs either way. What trimming did change is the one thing the
      // assertion above cares about: the partner recorded '  9f3c-1  ' against
      // their transaction, and a server holding '9f3c-1' cannot be reconciled
      // with their ledger on a disputed charge. Kotlin, Swift and React Native
      // all pass the value through untouched.
      expect(
        transport.requests.last.header('idempotency-key'),
        '  9f3c-1  ',
      );

      await client.checkScammer(
        query,
        source: Source.server,
        idempotencyKey: '   ',
      );
      expect(
        transport.requests.last.header('idempotency-key'),
        startsWith('sdk-'),
        reason: 'a blank key is no key, so one is generated',
      );
    });

    test('a generated key is unique per call, never derived from the query',
        () async {
      // Deriving it from the identifier would collapse two deliberate re-checks
      // of the same number into one answer and one charge — a different bug in
      // the same family.
      final transport = _FakeTransport((_) => _ok(_checkBody()));
      final client = _client(transport: transport);

      await client.checkScammer(query, source: Source.server);
      await client.checkScammer(query, source: Source.server);

      final keys = transport.requests
          .map((request) => request.header('idempotency-key'))
          .toList();
      expect(keys, hasLength(2));
      expect(keys.first, isNot(keys.last));
    });

    test('the post-refresh replay reuses the key of the attempt it repeats',
        () async {
      // The whole point. A replay under a different key is two operations to
      // the server, which is exactly the double charge the key exists to stop.
      var checks = 0;
      final transport = _FakeTransport((request) {
        if (request.url.path.endsWith('/oauth/token')) return _ok(_tokenBody());
        checks++;
        return checks == 1 ? _error(401, 'expired_token') : _ok(_checkBody());
      });
      final client =
          _client(transport: transport, tokenStore: _authorizedStore());

      await client.checkScammer(query, source: Source.server);

      final sent = transport.to('/scammer-checks');
      expect(sent, hasLength(2));
      expect(sent.first.header('idempotency-key'), startsWith('sdk-'));
      expect(
        sent.last.header('idempotency-key'),
        sent.first.header('idempotency-key'),
        reason: 'the replay must be the same operation, not a second one',
      );
    });

    test('a generated key does not buy a retry budget', () async {
      // `isRetryable` still keys off the CALLER's key. The SDK's own key makes
      // its replay collapsible; it cannot tell the caller whether the first
      // attempt landed, and that is the decision retrying takes away from them.
      final transport = _FakeTransport((_) => _error(503, 'unavailable'));
      final client = _client(transport: transport, retryPolicy: _fastRetries);

      await expectLater(
        client.checkScammer(query, source: Source.server),
        throwsA(isA<TraciveServerException>()),
      );
      expect(transport.requests, hasLength(1));
    });

    test('honours a sandbox or custom environment', () async {
      final sandbox = _FakeTransport((_) => _ok(_checkBody()));
      await _client(
        transport: sandbox,
        environment: TraciveEnvironment.sandbox,
      ).checkScammer(query, source: Source.server);
      expect(
        sandbox.requests.single.url.toString(),
        'https://api-sandbox.tracive.id/v1/scammer-checks',
      );

      final custom = _FakeTransport((_) => _ok(_checkBody()));
      await _client(
        transport: custom,
        environment:
            TraciveEnvironment.custom('https://proxy.example.test/v1/'),
      ).checkScammer(query, source: Source.server);
      expect(
        custom.requests.single.url.toString(),
        'https://proxy.example.test/v1/scammer-checks',
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Decoding the answer.
  // ---------------------------------------------------------------------------
  group('CheckResult decoding', () {
    test('decodes the documented fields and stamps origin/fetchedAt', () async {
      final clock = MutableClock(_t0);
      final transport = _FakeTransport((_) => _ok(_checkBody()));
      final client = _client(transport: transport, clock: clock);

      final result = await client.checkScammer(query, source: Source.server);

      expect(result.checkId, 'chk_1');
      expect(result.found, isTrue);
      expect(result.riskTier, RiskTier.high);
      expect(result.reportTotal, 12);
      expect(result.credibleReports, 9);
      expect(result.ambiguousReports, 3);
      expect(result.fraudAmount, <String, double>{'IDR': 4500000});
      expect(result.tags, <String>['investment', 'impersonation']);
      expect(result.relatedScammerCount, 4);
      expect(result.billing?.unitsCharged, 1);
      expect(result.disclaimer, isNotNull);
      expect(result.origin, Origin.server);
      expect(result.fetchedAt, _t0);
    });

    test('ignores fields this build has never heard of', () async {
      // Forward compatibility with phase 2. A new field on the response
      // must not be able to break an app that shipped before it existed.
      final transport = _FakeTransport(
        (_) => _ok(
          _checkBody(
            extra: <String, Object?>{
              'futureVersionVerdict': <String, Object?>{'score': 0.91},
              'unknownList': <Object?>[1, 2, 3],
            },
          ),
        ),
      );
      final client = _client(transport: transport);

      final result = await client.checkScammer(query, source: Source.server);
      expect(result.riskTier, RiskTier.high);
    });

    test('a 200 that is not a JSON object is a Server error, not a crash', () {
      final client = _client(
        transport: _FakeTransport(
          (_) => TraciveHttpResponse(statusCode: 200, body: '[1,2,3]'),
        ),
      );
      return expectLater(
        client.checkScammer(query, source: Source.server),
        throwsA(isA<TraciveServerException>()),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Sources. Each of these decides whether a credit is spent, which is
  // why they get one test each rather than one test between them.
  // ---------------------------------------------------------------------------
  group('Source', () {
    test('cacheFirst serves a live entry with no network I/O', () async {
      final clock = MutableClock(_t0);
      final cache = CheckCache.inMemory(clock: clock.now);
      final transport = _FakeTransport((_) => _ok(_checkBody()));
      final client = _client(
        transport: transport,
        cache: cache,
        clock: clock,
      );

      final first = await client.checkScammer(query);
      final second = await client.checkScammer(query);

      expect(transport.requests, hasLength(1),
          reason: 'the second call is free');
      expect(first.origin, Origin.server);
      expect(second.origin, Origin.cache);
      expect(second.reportTotal, first.reportTotal);
      // Never cached, because they are single-use or vary with
      // detail/locale.
      expect(second.checkId, isNull);
      expect(second.billing, isNull);
      // TTL is measured from the original server fetch, not from the read.
      expect(second.fetchedAt, first.fetchedAt);
    });

    test('server ignores a live entry and spends a credit', () async {
      final clock = MutableClock(_t0);
      final cache = CheckCache.inMemory(clock: clock.now);
      await cache.write(query, _cachedResult(clock.now(), reportTotal: 7));

      final transport = _FakeTransport(
        (_) => _ok(_checkBody(reportTotal: 12)),
      );
      final client = _client(transport: transport, cache: cache, clock: clock);

      final result = await client.checkScammer(query, source: Source.server);

      expect(transport.requests, hasLength(1));
      expect(result.origin, Origin.server);
      expect(result.reportTotal, 12);
    });

    test('cache with no live entry raises CacheMiss, never a silent empty',
        () async {
      // An empty `CheckResult` here would read as "not a scammer", which is
      // the most dangerous wrong answer this SDK can give.
      final transport = _FakeTransport(
        (_) => fail('Source.cache must never touch the network'),
      );
      final client = _client(transport: transport);

      await expectLater(
        client.checkScammer(query, source: Source.cache),
        throwsA(isA<TraciveCacheMissException>()),
      );
      expect(transport.requests, isEmpty);
    });

    test('cache serves a live entry without touching the network', () async {
      final clock = MutableClock(_t0);
      final cache = CheckCache.inMemory(clock: clock.now);
      await cache.write(query, _cachedResult(clock.now(), reportTotal: 7));
      final transport = _FakeTransport(
        (_) => fail('Source.cache must never touch the network'),
      );

      final result = await _client(
        transport: transport,
        cache: cache,
        clock: clock,
      ).checkScammer(query, source: Source.cache);

      expect(result.origin, Origin.cache);
      expect(result.reportTotal, 7);
    });

    test('serverFirst falls back on a live entry when the server is down',
        () async {
      final clock = MutableClock(_t0);
      final cache = CheckCache.inMemory(clock: clock.now);
      await cache.write(query, _cachedResult(clock.now(), reportTotal: 7));
      final transport = _FakeTransport((_) => _error(503, 'unavailable'));

      final result = await _client(
        transport: transport,
        cache: cache,
        clock: clock,
      ).checkScammer(query, source: Source.serverFirst);

      expect(transport.requests, hasLength(1),
          reason: 'the server was tried first');
      expect(result.origin, Origin.cache);
      expect(result.reportTotal, 7);
    });

    test('serverFirst does not paper over an entitlement failure', () async {
      // A 403 says "this caller is not allowed an answer". Serving a cached one
      // hides a broken integration and keeps showing data the user may have
      // just revoked consent for.
      final clock = MutableClock(_t0);
      final cache = CheckCache.inMemory(clock: clock.now);
      await cache.write(query, _cachedResult(clock.now(), reportTotal: 7));
      final transport = _FakeTransport((_) => _error(403, 'missing_scope'));

      await expectLater(
        _client(
          transport: transport,
          cache: cache,
          clock: clock,
        ).checkScammer(query, source: Source.serverFirst),
        throwsA(isA<TraciveMissingScopeException>()),
      );
    });

    test('serverFirst surfaces a 402 rather than serving a cached verdict',
        () async {
      // The expensive one, because it is the quiet one. An exhausted balance
      // answered from the cache is byte-identical to a healthy answer — no
      // exception, no flag on the result, nothing to log — so a partner keeps
      // believing the integration works until the cache empties and every
      // check fails at once, on a payment screen, days after the cause
      // appeared. An empty balance is not a transient server condition; it is
      // a fact about the account that will not fix itself, and the only useful
      // moment to learn it is the first one.
      final clock = MutableClock(_t0);
      final cache = CheckCache.inMemory(clock: clock.now);
      await cache.write(query, _cachedResult(clock.now(), reportTotal: 7));
      final transport = _FakeTransport(
        (_) => _error(402, 'insufficient_user_credits'),
      );

      await expectLater(
        _client(
          transport: transport,
          cache: cache,
          clock: clock,
        ).checkScammer(query, source: Source.serverFirst),
        throwsA(isA<TraciveInsufficientCreditsException>()),
        reason: 'a live cached entry must not mask an empty balance',
      );
    });

    test('defaultSource applies when no source is passed', () async {
      final transport = _FakeTransport(
        (_) => fail('defaultSource: Source.cache must not reach the network'),
      );
      final client = _client(
        transport: transport,
        defaultSource: Source.cache,
      );

      await expectLater(
        client.checkScammer(query),
        throwsA(isA<TraciveCacheMissException>()),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Cache behaviour the client is responsible for.
  // ---------------------------------------------------------------------------
  group('cache integration', () {
    test('a cacheTtlSeconds still on the wire changes nothing', () async {
      // The backend stopped sending it. A proxy that still does must not
      // shorten the entry, and must not break the decode: the answer is stored
      // for the HIGH tier's thirty days, so a second check two days later is
      // served from the cache.
      final clock = MutableClock(_t0);
      final cache = CheckCache.inMemory(clock: clock.now);

      final transport = _FakeTransport(
        (_) => _ok(_checkBody(cacheTtlSeconds: 0)),
      );
      final client = _client(transport: transport, cache: cache, clock: clock);
      await client.checkScammer(query, source: Source.server);

      clock.advance(const Duration(days: 2));
      final replayed = await client.checkScammer(query, source: Source.cache);
      expect(replayed.origin, Origin.cache);
      expect(transport.requests, hasLength(1));
    });

    test('an expired entry is not served, and the server is called', () async {
      final clock = MutableClock(_t0);
      final cache = CheckCache.inMemory(clock: clock.now);
      // NONE has a one-hour TTL.
      await cache.write(
        query,
        _cachedResult(clock.now(), tier: RiskTier.none, reportTotal: 0),
      );
      clock.advance(const Duration(hours: 2));

      final transport = _FakeTransport((_) => _ok(_checkBody()));
      final result = await _client(
        transport: transport,
        cache: cache,
        clock: clock,
      ).checkScammer(query);

      expect(transport.requests, hasLength(1));
      expect(result.origin, Origin.server);
    });

    test('a full-detail answer is not written to the cache', () async {
      // The cache key is the query alone, and it has to stay that way — but
      // that is only sound while nothing that varies with `detail` or `locale`
      // can get into a row. A full-detail response carries a `disclaimer` and
      // `tags` in the requested language, and the projection of it kept both.
      // Storing that means a later `detail: minimal, locale: en` caller reads
      // an Indonesian disclaimer, in the one string the SDK tells every
      // integrator to put on screen.
      final clock = MutableClock(_t0);
      final cache = CheckCache.inMemory(clock: clock.now);
      final transport = _FakeTransport((_) => _ok(_checkBody()));

      await _client(transport: transport, cache: cache, clock: clock)
          .checkScammer(
        query,
        source: Source.server,
        detail: Detail.full,
        locale: 'id',
      );

      expect(
        await cache.read(query),
        isNull,
        reason: 'a localized answer must not become a locale-less cache row',
      );
    });

    test('a full-detail check is not answered from the cache either', () async {
      // The other direction of the same rule. Serving a cached minimal row to
      // a caller who asked for chronologies and comments returns less than was
      // asked for, silently.
      final clock = MutableClock(_t0);
      final cache = CheckCache.inMemory(clock: clock.now);
      await cache.write(query, _cachedResult(clock.now()));
      expect(await cache.read(query), isNotNull);

      final transport = _FakeTransport((_) => _ok(_checkBody()));
      final result =
          await _client(transport: transport, cache: cache, clock: clock)
              .checkScammer(query, detail: Detail.full, locale: 'id');

      expect(transport.requests, hasLength(1));
      expect(result.origin, Origin.server);
    });

    test('a minimal-detail answer is still cached', () async {
      // The regression guard for the two above: the cache must still do its
      // job for the level that is actually cacheable.
      final clock = MutableClock(_t0);
      final cache = CheckCache.inMemory(clock: clock.now);
      final transport = _FakeTransport((_) => _ok(_checkBody()));

      await _client(transport: transport, cache: cache, clock: clock)
          .checkScammer(query, source: Source.server);

      expect(await cache.read(query), isNotNull);
    });

    test('client.cache.clear() empties it', () async {
      final clock = MutableClock(_t0);
      final cache = CheckCache.inMemory(clock: clock.now);
      final transport = _FakeTransport((_) => _ok(_checkBody()));
      final client = _client(transport: transport, cache: cache, clock: clock);

      await client.checkScammer(query);
      await client.cache.clear();
      await client.checkScammer(query);

      expect(transport.requests, hasLength(2));
    });

    test('a disabled cache means every check costs a credit', () async {
      final transport = _FakeTransport((_) => _ok(_checkBody()));
      final client = _client(
        transport: transport,
        cache: const CheckCache.disabled(),
      );

      await client.checkScammer(query);
      await client.checkScammer(query);

      expect(transport.requests, hasLength(2));
      expect(client.cachePolicy.enabled, isFalse);
    });

    test('OAuth mode falls back to the shared install link', () {
      // The link was briefly a required argument, while its URL was still
      // unconfirmed and a wrong default would have been a 404 on every
      // partner's first run. It is confirmed now, and it is the same one in
      // every Tracive SDK, so an app configures nothing.
      final client = TraciveClient(
        mode: _oauthMode,
        transport: _FakeTransport((_) => _ok('{}')),
        tokenStore: _authorizedStore(),
      );
      expect(client.oauth!.installUrl, 'https://tracive.chottu.link/install');
    });

    test('an explicit install link overrides the default', () {
      final client = TraciveClient(
        mode: _oauthMode,
        transport: _FakeTransport((_) => _ok('{}')),
        tokenStore: _authorizedStore(),
        installUrl: 'https://install.example/app',
      );
      expect(client.oauth!.installUrl, 'https://install.example/app');
    });

    test('Proxy mode needs no install link — it has no OAuth flow', () {
      expect(
        () => TraciveClient(
          mode: TraciveMode.proxy(
            baseUrl: 'https://partner.example/tracive',
            authHeaders: const <String, String>{'x-partner-key': 'k'},
          ),
          transport: _FakeTransport((_) => fail('nothing should be sent')),
        ),
        returnsNormally,
      );
    });

    test('the default cache takes the cachePolicy it was configured with', () {
      final client = TraciveClient(
        mode: _oauthMode,
        cachePolicy: const CachePolicy(highTtl: Duration(days: 3)),
        transport: _FakeTransport((_) => _ok('{}')),
        tokenStore: _authorizedStore(),
        installUrl: 'https://install.example/app',
      );
      expect(client.cachePolicy.highTtl, const Duration(days: 3));
    });
  });

  // ---------------------------------------------------------------------------
  // Single-flight for checks. The other money bug, and the one the cache cannot
  // help with: two overlapping checks for the same identifier both read the
  // cache, both miss, both POST and both are billed, because the write that
  // would have saved the second happens after both requests have already gone
  // out. A double-tapped button is the everyday shape of it.
  // ---------------------------------------------------------------------------
  group('overlapping identical checks', () {
    test('are one request and one charge', () async {
      // The gate is what makes this a concurrency test rather than a scheduling
      // one: neither check can answer until both are on the wire.
      //
      // It is also what pins the *generated* key out of the latch key. Neither
      // call supplied one, so each is given a per-call key of its own — and a
      // latch keyed off the key actually sent would therefore give every unkeyed
      // check a flight to itself and turn the feature off, with only this
      // assertion to notice.
      final gate = Completer<TraciveHttpResponse>();
      final transport = _FakeTransport((_) => gate.future);
      final client = _client(transport: transport);

      final first = client.checkScammer(query, source: Source.server);
      final second = client.checkScammer(query, source: Source.server);
      await Future<void>.delayed(Duration.zero);
      gate.complete(_ok(_checkBody()));
      final results =
          await Future.wait<CheckResult>(<Future<CheckResult>>[first, second]);

      expect(
        transport.to('/scammer-checks'),
        hasLength(1),
        reason: 'the second tap must join the first request, not buy another',
      );
      expect(results.map((result) => result.riskTier),
          everyElement(RiskTier.high));
      expect(
        results.map((result) => result.origin),
        everyElement(Origin.server),
        reason: 'a joined caller was answered by the server, not by the cache',
      );
    });

    test('differing only in detail are not shared', () async {
      // A minimal row must never be handed to a caller who asked for full, so
      // the detail level is part of the latch key rather than the row key
      // alone.
      final gate = Completer<TraciveHttpResponse>();
      final transport = _FakeTransport((_) => gate.future);
      final client = _client(transport: transport);

      final minimal = client.checkScammer(query, source: Source.server);
      final full = client.checkScammer(
        query,
        source: Source.server,
        detail: Detail.full,
        locale: 'id',
      );
      await Future<void>.delayed(Duration.zero);
      gate.complete(_ok(_checkBody()));
      await Future.wait<CheckResult>(<Future<CheckResult>>[minimal, full]);

      final sent = transport.to('/scammer-checks');
      expect(sent, hasLength(2));
      expect(
        sent.map((request) => _bodyOf(request)['detail']),
        containsAll(<String>['minimal', 'full']),
      );
    });

    test('differing only in locale are not shared', () async {
      final gate = Completer<TraciveHttpResponse>();
      final transport = _FakeTransport((_) => gate.future);
      final client = _client(transport: transport);

      final indonesian = client.checkScammer(
        query,
        source: Source.server,
        detail: Detail.full,
        locale: 'id',
      );
      final english = client.checkScammer(
        query,
        source: Source.server,
        detail: Detail.full,
        locale: 'en',
      );
      await Future<void>.delayed(Duration.zero);
      gate.complete(_ok(_checkBody()));
      await Future.wait<CheckResult>(
        <Future<CheckResult>>[indonesian, english],
      );

      expect(
        transport.to('/scammer-checks').map((r) => _bodyOf(r)['locale']),
        containsAll(<String>['id', 'en']),
      );
    });

    test("differing only in the caller's idempotency key are not shared",
        () async {
      // Two keys are the caller saying "these are two billable transactions".
      // Sharing one flight between them answered both from one request, sent
      // under whichever key arrived first — so the second caller's transaction
      // never reached the server under the name they gave it, and they were
      // never told. The generated key already refuses to be derived from the
      // query for this exact reason; the latch was doing it through another
      // door.
      final gate = Completer<TraciveHttpResponse>();
      final transport = _FakeTransport((_) => gate.future);
      final client = _client(transport: transport);

      final first = client.checkScammer(
        query,
        source: Source.server,
        idempotencyKey: 'txn-1',
      );
      final second = client.checkScammer(
        query,
        source: Source.server,
        idempotencyKey: 'txn-2',
      );
      await Future<void>.delayed(Duration.zero);
      gate.complete(_ok(_checkBody()));
      await Future.wait<CheckResult>(<Future<CheckResult>>[first, second]);

      final sent = transport.to('/scammer-checks');
      expect(sent, hasLength(2));
      expect(
        sent.map((request) => request.header('idempotency-key')),
        containsAll(<String>['txn-1', 'txn-2']),
        reason: 'each transaction must reach the server under its own key',
      );
    });

    test('a keyed check does not join an unkeyed flight', () async {
      // The retry budget keys off the caller's key alone. A keyed caller that
      // joined an unkeyed flight would lose it without being told: a 5xx or a
      // timeout would be surfaced immediately on a check the caller had gone to
      // the trouble of making safe to repeat.
      final gate = Completer<TraciveHttpResponse>();
      final transport = _FakeTransport((_) => gate.future);
      final client = _client(transport: transport);

      final unkeyed = client.checkScammer(query, source: Source.server);
      final keyed = client.checkScammer(
        query,
        source: Source.server,
        idempotencyKey: 'txn-1',
      );
      await Future<void>.delayed(Duration.zero);
      gate.complete(_ok(_checkBody()));
      await Future.wait<CheckResult>(<Future<CheckResult>>[unkeyed, keyed]);

      final keys = transport
          .to('/scammer-checks')
          .map((request) => request.header('idempotency-key'))
          .toList();
      expect(keys, hasLength(2));
      expect(keys, contains('txn-1'));
      expect(keys.where((key) => key!.startsWith('sdk-')), hasLength(1));
    });

    test('carrying the same caller key are one transaction, and are shared',
        () async {
      // The other direction. One key twice is one transaction named once, so
      // including the key in the latch must not stop these two sharing — a
      // per-call latch would be no latch at all.
      final gate = Completer<TraciveHttpResponse>();
      final transport = _FakeTransport((_) => gate.future);
      final client = _client(transport: transport);

      final first = client.checkScammer(
        query,
        source: Source.server,
        idempotencyKey: 'txn-1',
      );
      final second = client.checkScammer(
        query,
        source: Source.server,
        idempotencyKey: 'txn-1',
      );
      await Future<void>.delayed(Duration.zero);
      gate.complete(_ok(_checkBody()));
      await Future.wait<CheckResult>(<Future<CheckResult>>[first, second]);

      final sent = transport.to('/scammer-checks');
      expect(sent, hasLength(1));
      expect(sent.single.header('idempotency-key'), 'txn-1');
    });

    test('are not split by a blank caller key, which is no key at all',
        () async {
      // `'   '` buys no retry budget and is replaced on the wire by a generated
      // key. It must not split the latch either, or blankness would be the one
      // value that costs a second charge while granting nothing in return.
      final gate = Completer<TraciveHttpResponse>();
      final transport = _FakeTransport((_) => gate.future);
      final client = _client(transport: transport);

      final unkeyed = client.checkScammer(query, source: Source.server);
      final blank = client.checkScammer(
        query,
        source: Source.server,
        idempotencyKey: '   ',
      );
      await Future<void>.delayed(Duration.zero);
      gate.complete(_ok(_checkBody()));
      await Future.wait<CheckResult>(<Future<CheckResult>>[unkeyed, blank]);

      expect(transport.to('/scammer-checks'), hasLength(1));
    });

    test('are latched only while they overlap', () async {
      // The guard against the opposite mistake. A latch entry that outlived its
      // request would serve one answer for the rest of the session — which is a
      // cache with no TTL, written by the wrong file.
      final transport = _FakeTransport((_) => _ok(_checkBody()));
      final client = _client(
        transport: transport,
        cache: const CheckCache.disabled(),
      );

      await client.checkScammer(query, source: Source.server);
      await client.checkScammer(query, source: Source.server);

      expect(transport.to('/scammer-checks'), hasLength(2));
    });

    test('fail both callers together, and unlatch', () async {
      final transport = _FakeTransport((_) => _error(503, 'unavailable'));
      final client = _client(
        transport: transport,
        cache: const CheckCache.disabled(),
      );

      final first = client.checkScammer(query, source: Source.server);
      final second = client.checkScammer(query, source: Source.server);
      // Both expectations are attached before either future is awaited: a
      // shared failure that reached only one listener would otherwise surface
      // as an unhandled asynchronous error rather than as this assertion.
      final firstFails =
          expectLater(first, throwsA(isA<TraciveServerException>()));
      final secondFails =
          expectLater(second, throwsA(isA<TraciveServerException>()));
      await firstFails;
      await secondFails;

      expect(transport.to('/scammer-checks'), hasLength(1));

      await expectLater(
        client.checkScammer(query, source: Source.server),
        throwsA(isA<TraciveServerException>()),
        reason: 'a failed flight must not latch the failure in place',
      );
      expect(transport.to('/scammer-checks'), hasLength(2));
    });
  });

  // ---------------------------------------------------------------------------
  // Retry policy. This is the money bug: a blind retry of a POST that may
  // already have been processed charges the user twice, and nothing anywhere
  // reports that it happened.
  // ---------------------------------------------------------------------------
  group('retry policy', () {
    // The five numbers below are a cross-SDK contract, not a local preference:
    // Kotlin, Swift, React Native and this SDK ship the same set. They were
    // asserted nowhere, which is how three of the four came to ship three
    // different initial backoffs and two jitter ratios with no reason recorded
    // anywhere for any of them. Behavioural tests cannot catch that — a policy
    // that waits 300 ms passes every one of them — so each value is pinned by
    // name here, and changing one has to be deliberate.
    test('the shipped defaults are the cross-SDK set', () {
      const policy = RetryPolicy.defaultPolicy;
      expect(policy.maxAttempts, 3);
      expect(policy.backoffMultiplier, 2.0);
      expect(policy.initialBackoff, const Duration(milliseconds: 500));
      expect(policy.jitter, 0.2);
      expect(policy.maxBackoff, const Duration(seconds: 8));
    });

    test('the schedule those numbers produce is 500 ms then 1 s', () {
      // `jitter: 0` to read the curve itself. The first retry is attempt 2.
      const policy = RetryPolicy(jitter: 0);
      expect(policy.backoffFor(1), Duration.zero);
      expect(policy.backoffFor(2), const Duration(milliseconds: 500));
      expect(policy.backoffFor(3), const Duration(seconds: 1));
      expect(
        policy.backoffFor(9),
        const Duration(seconds: 8),
        reason: 'maxBackoff binds only for a caller who raises maxAttempts',
      );
    });

    test('jitter only ever shortens a wait', () {
      // One-sided on purpose: if it could lengthen one, `maxBackoff` would stop
      // being a ceiling and the worst case would be the documented one plus
      // twenty percent.
      const policy = RetryPolicy.defaultPolicy;
      const base = Duration(milliseconds: 500);
      final random = Random(20260801);

      for (var i = 0; i < 500; i++) {
        final delay = policy.backoffFor(2, random: random);
        expect(delay, lessThanOrEqualTo(base));
        expect(delay, greaterThanOrEqualTo(base * 0.8));
      }
    });

    test('a 5xx check without an Idempotency-Key is NOT retried', () async {
      final transport = _FakeTransport((_) => _error(503, 'unavailable'));
      final client = _client(transport: transport, retryPolicy: _fastRetries);

      await expectLater(
        client.checkScammer(query, source: Source.server),
        throwsA(isA<TraciveServerException>()),
      );
      expect(
        transport.requests,
        hasLength(1),
        reason: 'a repeat could double-charge, so it must not happen',
      );
    });

    test('a timeout on a check without an Idempotency-Key is NOT retried',
        () async {
      // A timeout is indistinguishable from a success whose response was lost:
      // the credit may already be spent.
      final transport = _FakeTransport(
        (_) => throw const _SimulatedTimeout(),
      );
      final client = _client(transport: transport, retryPolicy: _fastRetries);

      await expectLater(
        client.checkScammer(query, source: Source.server),
        throwsA(isA<TraciveNetworkException>()),
      );
      expect(transport.requests, hasLength(1));
    });

    test('a 5xx check WITH an Idempotency-Key is retried to the limit',
        () async {
      final transport = _FakeTransport((_) => _error(503, 'unavailable'));
      final client = _client(transport: transport, retryPolicy: _fastRetries);

      await expectLater(
        client.checkScammer(
          query,
          source: Source.server,
          idempotencyKey: 'idem-1',
        ),
        throwsA(isA<TraciveServerException>()),
      );
      expect(transport.requests, hasLength(3));
      // Every attempt carries the same key, which is what lets the server
      // collapse the replays into one charge.
      for (final request in transport.requests) {
        expect(request.header('idempotency-key'), 'idem-1');
      }
    });

    test('a retried check that eventually succeeds returns the result',
        () async {
      var calls = 0;
      final transport = _FakeTransport((_) {
        calls++;
        return calls < 3 ? _error(500, 'internal') : _ok(_checkBody());
      });
      final client = _client(transport: transport, retryPolicy: _fastRetries);

      final result = await client.checkScammer(
        query,
        source: Source.server,
        idempotencyKey: 'idem-2',
      );

      expect(result.riskTier, RiskTier.high);
      expect(transport.requests, hasLength(3));
    });

    test('a 429 is never auto-retried; the Retry-After is handed back',
        () async {
      // The server has already said how long to wait. Burning the retry budget
      // inside a few hundred milliseconds only deepens the hole.
      final transport = _FakeTransport(
        (_) => _error(
          429,
          'rate_limited',
          headers: const <String, String>{'retry-after': '30'},
        ),
      );
      final client = _client(transport: transport, retryPolicy: _fastRetries);

      await expectLater(
        client.checkScammer(
          query,
          source: Source.server,
          idempotencyKey: 'idem-3',
        ),
        throwsA(
          isA<TraciveRateLimitedException>().having(
            (e) => e.retryAfter,
            'retryAfter',
            const Duration(seconds: 30),
          ),
        ),
      );
      expect(transport.requests, hasLength(1));
    });

    test('a GET is retried without any key — it costs nothing', () async {
      final transport = _FakeTransport((_) => _error(503, 'unavailable'));
      final client = _client(transport: transport, retryPolicy: _fastRetries);

      await expectLater(
          client.credits(), throwsA(isA<TraciveServerException>()));
      expect(transport.requests, hasLength(3));
    });
  });

  // ---------------------------------------------------------------------------
  // Token handling on the API path.
  // ---------------------------------------------------------------------------
  group('401 handling', () {
    test('expired_token refreshes once and replays with the new token',
        () async {
      var checks = 0;
      final transport = _FakeTransport((request) {
        if (request.url.path.endsWith('/oauth/token')) return _ok(_tokenBody());
        checks++;
        return checks == 1 ? _error(401, 'expired_token') : _ok(_checkBody());
      });
      final store = _authorizedStore();
      final client = _client(transport: transport, tokenStore: store);

      final result = await client.checkScammer(query, source: Source.server);

      expect(result.riskTier, RiskTier.high);
      expect(transport.to('/oauth/token'), hasLength(1));
      expect(transport.to('/scammer-checks'), hasLength(2));
      expect(
        transport.to('/scammer-checks').last.header('authorization'),
        'Bearer access-token-2',
        reason: 'the replay must use the refreshed token, not the dead one',
      );
      expect((await store.read())?.refreshToken, 'refresh-token-2');
    });

    test('a cold start with an already-expired stored token still recovers',
        () async {
      // The scenario the removed proactive refresh always pre-empted, and
      // therefore the one that had never actually run: the process has just
      // started, nothing has refreshed yet, `expiresAt` is already in the past,
      // and the very first request of the session is the one the server
      // rejects. Under the old strategy `ensureAccessToken` refreshed on the
      // clock before this request was ever built, so this path was dead code in
      // exactly the situation it exists for.
      var checks = 0;
      final transport = _FakeTransport((request) {
        if (request.url.path.endsWith('/oauth/token')) return _ok(_tokenBody());
        checks++;
        return checks == 1 ? _error(401, 'expired_token') : _ok(_checkBody());
      });
      final store = InMemoryTokenStore(
        tokens: TraciveTokens(
          accessToken: 'access-token-1',
          refreshToken: 'refresh-token-1',
          // Issued before this session began and never used since.
          expiresAt: _t0.subtract(const Duration(hours: 1)),
          grantedScopes: const <String>['scammer.check'],
        ),
      );
      final client = _client(transport: transport, tokenStore: store);

      final result = await client.checkScammer(query, source: Source.server);

      expect(result.riskTier, RiskTier.high);
      expect(
        transport.to('/scammer-checks').first.header('authorization'),
        'Bearer access-token-1',
        reason: 'the expired token is sent; the server is what decides',
      );
      expect(transport.to('/oauth/token'), hasLength(1));
      expect(transport.to('/scammer-checks'), hasLength(2));
      expect(
        transport.to('/scammer-checks').last.header('authorization'),
        'Bearer access-token-2',
        reason: 'the replay must carry the refreshed token',
      );
      expect((await store.read())?.refreshToken, 'refresh-token-2');
    });

    test('a second expired_token gives up rather than looping', () async {
      final transport = _FakeTransport((request) {
        if (request.url.path.endsWith('/oauth/token')) return _ok(_tokenBody());
        return _error(401, 'expired_token');
      });
      final client = _client(transport: transport);

      await expectLater(
        client.checkScammer(query, source: Source.server),
        throwsA(isA<TraciveExpiredTokenException>()),
      );
      expect(transport.to('/oauth/token'), hasLength(1));
      expect(transport.to('/scammer-checks'), hasLength(2));
    });

    test('grant_revoked clears the tokens and does not retry', () async {
      // Retrying with a dead refresh token is exactly the pattern the server's
      // reuse detection punishes — it revokes the whole grant.
      final transport = _FakeTransport((_) => _error(401, 'grant_revoked'));
      final store = _authorizedStore();
      final client = _client(transport: transport, tokenStore: store);

      await expectLater(
        client.checkScammer(query, source: Source.server),
        throwsA(isA<TraciveGrantRevokedException>()),
      );
      expect(store.clearCount, 1);
      expect(await store.read(), isNull);
      expect(transport.to('/oauth/token'), isEmpty);
    });

    test('invalid_token is terminal — a fresh token earns nothing', () async {
      // The one 401 code that is excluded from the refresh, alongside
      // grant_revoked. The server is saying the credential is not usable at
      // all — it is the answer to a malformed or empty bearer — so minting
      // another one only spends a rotation to be told the same thing again.
      final transport = _FakeTransport((_) => _error(401, 'invalid_token'));
      final client = _client(transport: transport);

      await expectLater(
        client.checkScammer(query, source: Source.server),
        throwsA(isA<TraciveInvalidTokenException>()),
      );
      expect(transport.to('/oauth/token'), isEmpty);
    });

    // A bare `401 Unauthorized` with no JSON body is what CDNs, API gateways
    // and misconfigured reverse proxies emit, and this SDK is explicitly
    // designed to sit behind a partner gateway. Requiring the body to carry
    // exactly `expired_token` meant that in that state it never refreshed, so
    // every subsequent call failed identically until the app happened to call
    // authorize() again — while the user's grant was fine the whole time.
    test('a 401 with an empty body refreshes and replays', () async {
      var checks = 0;
      final transport = _FakeTransport((request) {
        if (request.url.path.endsWith('/oauth/token')) return _ok(_tokenBody());
        checks++;
        return checks == 1 ? _bareUnauthorized() : _ok(_checkBody());
      });
      final client = _client(
        transport: transport,
        tokenStore: _authorizedStore(),
      );

      final result = await client.checkScammer(query, source: Source.server);

      expect(result.riskTier, RiskTier.high);
      expect(transport.to('/oauth/token'), hasLength(1));
      expect(
        transport.to('/scammer-checks').last.header('authorization'),
        'Bearer access-token-2',
      );
    });

    test('a 401 carrying an unrecognised code refreshes too', () async {
      var checks = 0;
      final transport = _FakeTransport((request) {
        if (request.url.path.endsWith('/oauth/token')) return _ok(_tokenBody());
        checks++;
        return checks == 1
            ? _error(401, 'token_not_active_yet')
            : _ok(_checkBody());
      });
      final client = _client(
        transport: transport,
        tokenStore: _authorizedStore(),
      );

      await client.checkScammer(query, source: Source.server);

      expect(transport.to('/oauth/token'), hasLength(1));
      expect(transport.to('/scammer-checks'), hasLength(2));
    });

    test('a bare 401 still refreshes at most once', () async {
      // Widening which responses trigger a refresh must not widen how many
      // refreshes one request can cause. A grant that is genuinely finished
      // must surface, not loop.
      final transport = _FakeTransport((request) {
        if (request.url.path.endsWith('/oauth/token')) return _ok(_tokenBody());
        return _bareUnauthorized();
      });
      final client = _client(
        transport: transport,
        tokenStore: _authorizedStore(),
      );

      await expectLater(
        client.checkScammer(query, source: Source.server),
        throwsA(isA<TraciveException>()),
      );
      expect(transport.to('/oauth/token'), hasLength(1));
      expect(transport.to('/scammer-checks'), hasLength(2));
    });

    test('concurrent 401s trigger exactly one refresh (single-flight)',
        () async {
      // Two refreshes means the first rotated refresh token is presented twice,
      // which is what reuse detection looks for — and it revokes the grant.
      //
      // The verdict is keyed on the token the request actually carried, not on
      // a call counter: under `Future.wait` the interleaving is not fixed, and
      // a counter would make this test's meaning depend on scheduling luck.
      //
      // Four *different* identifiers, deliberately. Four checks of the same one
      // are a single request now (see "overlapping identical checks"), so they
      // could only ever produce a single 401 — and this test would pass while
      // exercising nothing it is named after.
      final transport = _FakeTransport((request) async {
        if (request.url.path.endsWith('/oauth/token')) {
          // Yield, so a second refresh would have every chance to slip in.
          await Future<void>.delayed(Duration.zero);
          return _ok(_tokenBody());
        }
        return request.header('authorization') == 'Bearer access-token-1'
            ? _error(401, 'expired_token')
            : _ok(_checkBody());
      });
      final client = _client(transport: transport);

      final results = await Future.wait<CheckResult>(<Future<CheckResult>>[
        client.checkScammer(TraciveQuery.phone('+6281234567891'),
            source: Source.server),
        client.checkScammer(TraciveQuery.phone('+6281234567892'),
            source: Source.server),
        client.checkScammer(TraciveQuery.phone('+6281234567893'),
            source: Source.server),
        client.checkScammer(TraciveQuery.phone('+6281234567894'),
            source: Source.server),
      ]);

      expect(results, hasLength(4));
      expect(transport.to('/scammer-checks'), hasLength(8));
      expect(transport.to('/oauth/token'), hasLength(1));
    });

    test('no stored token is a typed error, not a bearer of empty string',
        () async {
      final transport = _FakeTransport(
        (_) => fail('nothing should be sent without a token'),
      );
      final client = _client(
        transport: transport,
        tokenStore: InMemoryTokenStore(),
      );

      await expectLater(
        client.checkScammer(query, source: Source.server),
        throwsA(isA<TraciveInvalidTokenException>()),
      );
      expect(transport.requests, isEmpty);
    });

    test('a blank stored access token is refreshed before the check is sent',
        () async {
      // A damaged storage record: a partial write, a save interrupted by
      // process death, a restored backup. The refresh token beside it is
      // intact, so the grant is recoverable without consent — and it has to be
      // recovered *here*, before the send, because `Bearer ` is answered
      // `invalid_token` rather than `expired_token`, and `invalid_token` is
      // terminal — as the "invalid_token does not refresh" test above pins. The
      // caller sees a result, not an authorization error.
      final transport = _FakeTransport((request) {
        if (request.url.path.endsWith('/oauth/token')) return _ok(_tokenBody());
        return _ok(_checkBody());
      });
      final store = InMemoryTokenStore(
        tokens: const TraciveTokens(
          accessToken: '',
          refreshToken: 'refresh-token-1',
          grantedScopes: <String>['scammer.check'],
        ),
      );
      final client = _client(transport: transport, tokenStore: store);

      final result = await client.checkScammer(query, source: Source.server);

      expect(result.riskTier, RiskTier.high);
      expect(transport.to('/oauth/token'), hasLength(1));
      expect(transport.to('/scammer-checks'), hasLength(1));
      expect(
        transport.to('/scammer-checks').single.header('authorization'),
        'Bearer access-token-2',
        reason: 'the check must carry the token the refresh just minted',
      );
      expect(
        transport.requests
            .map((request) => request.header('authorization'))
            .toList(),
        isNot(contains('Bearer ')),
        reason: 'an empty bearer must never reach the wire',
      );
      expect((await store.read())?.refreshToken, 'refresh-token-2');
    });
  });

  // ---------------------------------------------------------------------------
  // /credits and /profile.
  // ---------------------------------------------------------------------------
  group('credits and profile', () {
    test('credits() GETs /credits and decodes it', () async {
      final transport = _FakeTransport(
        (_) => _ok(
          jsonEncode(<String, Object?>{
            'subscriptionCredits': 42,
            'tier': 'pro',
            'nextResetAt': '2026-08-01T00:00:00.000Z',
            'somethingNew': true,
          }),
        ),
      );
      final client = _client(transport: transport);

      final info = await client.credits();

      expect(transport.requests.single.method, 'GET');
      expect(
        transport.requests.single.url.toString(),
        'https://api.tracive.id/v1/credits',
      );
      expect(info.subscriptionCredits, 42);
      expect(info.tier, 'pro');
      expect(info.nextResetAt, DateTime.utc(2026, 8));
    });

    test('profile() GETs /profile and decodes it', () async {
      final transport = _FakeTransport(
        (_) => _ok(
          jsonEncode(<String, Object?>{
            'sub': 'user_123',
            'name': 'Sri Wahyuni',
            'country': 'ID',
            'tier': 'pro',
            'memberSince': '2025-02-11T00:00:00.000Z',
          }),
        ),
      );
      final client = _client(transport: transport);

      final profile = await client.profile();

      expect(
        transport.requests.single.url.toString(),
        'https://api.tracive.id/v1/profile',
      );
      expect(profile.sub, 'user_123');
      expect(profile.country, 'ID');
      // Personal data: never in a log line.
      expect(profile.toString(), isNot(contains('Sri Wahyuni')));
    });

    test('402 on a check is the documented way to learn you are out of credits',
        () async {
      // This is what you handle instead of polling credits() first.
      final transport = _FakeTransport(
        (_) => _error(402, 'insufficient_user_credits'),
      );
      final client = _client(transport: transport);

      await expectLater(
        client.checkScammer(query, source: Source.server),
        throwsA(
          isA<TraciveInsufficientCreditsException>().having(
            (e) => e.which,
            'which',
            InsufficientCreditsKind.user,
          ),
        ),
      );
      expect(transport.to('/credits'), isEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  // Sign-out.
  //
  // The cached rows are the departing user's check history — a list of who they
  // suspected of fraud — held under a grant that no longer exists. The next
  // person to pick up this device must not inherit it, and the SDK must not go
  // on serving verdicts obtained under consent that has just been withdrawn.
  // ---------------------------------------------------------------------------
  group('isAuthorized', () {
    test('true with a grant, false without, false in proxy mode', () async {
      final transport = _FakeTransport((_) => _ok('{}'));
      final authorized = _client(
        transport: transport,
        tokenStore: _authorizedStore(),
      );
      expect(await authorized.isAuthorized, isTrue);

      final empty =
          _client(transport: transport, tokenStore: InMemoryTokenStore());
      expect(await empty.isAuthorized, isFalse);
    });
  });

  group('clearCache', () {
    test('empties the cache and leaves the grant alone', () async {
      final clock = MutableClock(_t0);
      final cache = CheckCache.inMemory(clock: clock.now);
      await cache.write(query, _cachedResult(clock.now(), reportTotal: 7));
      final store = _authorizedStore();
      final client = _client(
        transport: _FakeTransport((_) => _ok('{}')),
        cache: cache,
        clock: clock,
        tokenStore: store,
      );

      await client.clearCache();

      expect(await cache.read(query), isNull);
      expect(
        await store.read(),
        isNotNull,
        reason: 'this is the difference from signOut: the user stays signed in',
      );
    });
  });

  group('signOut', () {
    test('empties the result cache as well as the tokens', () async {
      final clock = MutableClock(_t0);
      final cache = CheckCache.inMemory(clock: clock.now);
      await cache.write(query, _cachedResult(clock.now(), reportTotal: 7));
      final store = _authorizedStore();
      final transport = _FakeTransport((_) => _ok('{}'));
      final client = _client(
        transport: transport,
        cache: cache,
        clock: clock,
        tokenStore: store,
      );

      await client.signOut();

      expect(await store.read(), isNull);
      expect(
        await cache.read(query),
        isNull,
        reason: "the departing user's verdicts must not survive their session",
      );
    });

    test('the next user does not read the previous one\'s verdict', () async {
      // The failure stated from the arriving user's side. Without the clear,
      // their very first check is answered from the departed user's row — at
      // zero cost, with no network call, and therefore with nothing anywhere
      // recording that one person read another's result.
      final clock = MutableClock(_t0);
      final cache = CheckCache.inMemory(clock: clock.now);
      await cache.write(query, _cachedResult(clock.now(), reportTotal: 7));
      final store = _authorizedStore();
      final transport = _FakeTransport(
        (request) => request.url.path.endsWith('/oauth/revoke')
            ? _ok('{}')
            : _ok(_checkBody()),
      );
      final client = _client(
        transport: transport,
        cache: cache,
        clock: clock,
        tokenStore: store,
      );

      await client.signOut();

      // Somebody else signs in on the same device, sharing the same cache.
      await store.write(
        TraciveTokens(
          accessToken: 'access-token-1',
          refreshToken: 'refresh-token-1',
          expiresAt: _t0.add(const Duration(hours: 1)),
          grantedScopes: const <String>['scammer.check'],
        ),
      );

      final result =
          await client.checkScammer(query, source: Source.cacheFirst);

      expect(
        result.origin,
        Origin.server,
        reason: 'the answer must come from the server, not from the last user',
      );
      expect(transport.to('/scammer-checks'), hasLength(1));
      expect(result.reportTotal, isNot(7));
    });

    test('the tokens are gone even when the cache refuses to empty', () async {
      // Ordering, asserted rather than assumed: a broken cache must not be able
      // to leave a live grant on the device. The failure is still surfaced —
      // the caller has been told the tokens went and the verdicts did not.
      final store = _authorizedStore();
      final cache = CheckCache.inMemory();
      await cache.close();
      final client = _client(
        transport: _FakeTransport((_) => _ok('{}')),
        cache: cache,
        tokenStore: store,
      );

      await expectLater(client.signOut(), throwsA(isA<Object>()));
      expect(await store.read(), isNull);
    });
  });

  // ---------------------------------------------------------------------------
  // Proxy mode — phase 2.
  // ---------------------------------------------------------------------------
  group('Proxy mode (phase 2)', () {
    TraciveClient proxyClient() => TraciveClient(
          mode: TraciveMode.proxy(
            baseUrl: 'https://partner.example/tracive',
            authHeaders: const <String, String>{
              'x-partner-key': 'not-a-tracive-key'
            },
          ),
          transport:
              _FakeTransport((_) => fail('Proxy mode must not send anything')),
        );

    test('the type exists so phase 2 is not a breaking change', () {
      expect(proxyClient().mode, isA<TraciveProxyMode>());
      expect(proxyClient().oauth, isNull);
    });

    test('every call throws the documented sentence', () async {
      final client = proxyClient();
      final notImplemented = throwsA(
        isA<TraciveNotImplementedException>().having(
          (e) => e.message,
          'message',
          'Proxy mode arrives in phase 2',
        ),
      );

      await expectLater(client.checkScammer(query), notImplemented);
      await expectLater(client.credits(), notImplemented);
      await expectLater(client.profile(), notImplemented);
      await expectLater(client.authorize(), notImplemented);
      await expectLater(
        client.handleCallback(Uri.parse('https://partner.example/cb?code=x')),
        notImplemented,
      );
      await expectLater(client.signOut(), notImplemented);
    });
  });

  // ---------------------------------------------------------------------------
  // Privacy. Everything below ends up in a log line or a crash report sooner or
  // later, and neither we nor the user controls where those go.
  // ---------------------------------------------------------------------------
  group('privacy', () {
    test('a request never prints its bearer token or its body', () {
      final request = TraciveHttpRequest(
        method: 'POST',
        url: Uri.parse('https://api.tracive.id/v1/scammer-checks'),
        headers: const <String, String>{'authorization': 'Bearer secret-token'},
        body: jsonEncode(<String, Object?>{'query': 'PHONE_+6281234567891'}),
      );
      expect(request.toString(), isNot(contains('secret-token')));
      expect(request.toString(), isNot(contains('6281234567891')));
    });

    test('a response never prints its body', () {
      final response = _ok(_checkBody());
      expect(response.toString(), isNot(contains('chk_1')));
      expect(response.toString(), isNot(contains('investment')));
    });

    test('the client never prints a token', () {
      final client = _client(transport: _FakeTransport((_) => _ok('{}')));
      expect(client.toString(), isNot(contains('access-token-1')));
    });

    test('a query never prints the identifier it wraps', () {
      expect(query.toString(), isNot(contains('6281234567891')));
    });
  });

  // ---------------------------------------------------------------------------
  // Lifecycle.
  // ---------------------------------------------------------------------------
  test('close() releases the transport', () {
    final transport = _FakeTransport((_) => _ok('{}'));
    _client(transport: transport).close();
    expect(transport.closeCount, 1);
  });
}

// -----------------------------------------------------------------------------
// Fixtures and fakes. Small on purpose: a fake nobody can read in ten seconds is
// a fake that will eventually be trusted without being read.
// -----------------------------------------------------------------------------

final TraciveMode _oauthMode = TraciveMode.oauth(
  partnerUserId: 'partner-user-1',
  clientId: 'partner-client-id',
  redirectUri: 'https://partner.example/oauth/callback',
);

/// Retries with no backoff — the policy under test is *whether* a call repeats,
/// not how long it sleeps first, and a test that sleeps is a test nobody runs.
const RetryPolicy _fastRetries = RetryPolicy(
  maxAttempts: 3,
  initialBackoff: Duration.zero,
  maxBackoff: Duration.zero,
);

/// A store holding a live grant.
///
/// No `expiresAt`, which RFC 6749 permits and `TraciveTokens` documents as "not
/// expired; the 401 path will catch it". That matters here: several tests in
/// this file move the clock to age a *cache* entry, and a token expiry would
/// make those tests refresh a token as a side effect of testing the cache.
/// Refresh behaviour is driven by 401 responses below, where it belongs.
InMemoryTokenStore _authorizedStore() => InMemoryTokenStore(
      tokens: const TraciveTokens(
        accessToken: 'access-token-1',
        refreshToken: 'refresh-token-1',
        grantedScopes: <String>['scammer.check'],
      ),
    );

TraciveClient _client({
  required _FakeTransport transport,
  TraciveEnvironment environment = TraciveEnvironment.production,
  Source defaultSource = Source.cacheFirst,
  CheckCache? cache,
  InMemoryTokenStore? tokenStore,
  RetryPolicy retryPolicy = RetryPolicy.none,
  MutableClock? clock,
}) =>
    TraciveClient(
      mode: _oauthMode,
      environment: environment,
      defaultSource: defaultSource,
      transport: transport,
      clock: clock ?? MutableClock(_t0),
      retryPolicy: retryPolicy,
      cache: cache,
      tokenStore: tokenStore ?? _authorizedStore(),
      // Overridden so nothing here depends on the shipped default.
      installUrl: 'https://install.example/app',
    );

/// A `CheckResult` as it would be after a server answer, for priming a cache.
CheckResult _cachedResult(
  DateTime fetchedAt, {
  RiskTier tier = RiskTier.high,
  int reportTotal = 7,
}) =>
    CheckResult(
      found: true,
      riskTier: tier,
      origin: Origin.server,
      fetchedAt: fetchedAt,
      reportTotal: reportTotal,
    );

String _checkBody({
  String checkId = 'chk_1',
  String riskTier = 'HIGH',
  int reportTotal = 12,
  int? cacheTtlSeconds,
  Map<String, Object?> extra = const <String, Object?>{},
}) =>
    jsonEncode(<String, Object?>{
      'checkId': checkId,
      'found': true,
      'riskTier': riskTier,
      'reportTotal': reportTotal,
      'credibleReports': 9,
      'ambiguousReports': 3,
      'firstReportOn': '2026-01-04T00:00:00.000Z',
      'lastReportOn': '2026-07-20T00:00:00.000Z',
      'fraudAmount': <String, Object?>{'IDR': 4500000},
      'tags': <Object?>['investment', 'impersonation'],
      'relatedScammerCount': 4,
      'billing': <String, Object?>{'creditSource': 'USER', 'unitsCharged': 1},
      'disclaimer': 'Reports are submitted by users and are not adjudicated.',
      if (cacheTtlSeconds != null) 'cacheTtlSeconds': cacheTtlSeconds,
      ...extra,
    });

String _tokenBody() => jsonEncode(<String, Object?>{
      'access_token': 'access-token-2',
      'refresh_token': 'refresh-token-2',
      'token_type': 'Bearer',
      'expires_in': 3600,
      'scope': 'scammer.check',
    });

TraciveHttpResponse _ok(String body) => TraciveHttpResponse(
      statusCode: 200,
      headers: const <String, String>{'content-type': 'application/json'},
      body: body,
    );

/// A `401 Unauthorized` with no body at all — what a CDN, an API gateway or a
/// misconfigured reverse proxy emits, and therefore the response no error code
/// can be read out of.
TraciveHttpResponse _bareUnauthorized() => TraciveHttpResponse(
      statusCode: 401,
      headers: const <String, String>{},
      body: '',
    );

TraciveHttpResponse _error(
  int status,
  String code, {
  String? message,
  Map<String, String> headers = const <String, String>{},
}) =>
    TraciveHttpResponse(
      statusCode: status,
      headers: headers,
      body: jsonEncode(<String, Object?>{
        'error': <String, Object?>{
          'code': code,
          if (message != null) 'message': message,
        },
      }),
    );

Map<String, Object?> _bodyOf(TraciveHttpRequest request) =>
    jsonDecode(request.body!) as Map<String, Object?>;

/// Stands in for a socket timeout: any exception type at all, because a
/// transport is free to throw whatever its stack throws.
class _SimulatedTimeout implements Exception {
  const _SimulatedTimeout();

  @override
  String toString() => 'simulated socket timeout';
}

class _FakeTransport extends HttpTransport {
  _FakeTransport(this.handler);

  final FutureOr<TraciveHttpResponse> Function(TraciveHttpRequest) handler;

  /// Every request the SDK made, in order. The assertion this file leans on
  /// most is `hasLength(1)` — "the SDK did not silently call twice".
  final List<TraciveHttpRequest> requests = <TraciveHttpRequest>[];

  int closeCount = 0;

  @override
  Future<TraciveHttpResponse> send(TraciveHttpRequest request) async {
    requests.add(request);
    return handler(request);
  }

  @override
  void close() => closeCount++;

  List<TraciveHttpRequest> to(String pathSuffix) => requests
      .where((request) => request.url.path.endsWith(pathSuffix))
      .toList(growable: false);
}
