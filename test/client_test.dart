// Copyright (c) Tracive. Licensed under the Apache License, Version 2.0.
//
// The API client.
//
// NO NETWORK. Every response in this file is a literal `TraciveHttpResponse`
// handed back by `_FakeTransport`. The Open API does not exist yet (spec
// preamble), so a test that opened a socket could only be aspirational — and
// once the API is live, a suite that talks to it fails whenever somebody else
// is mid-deploy. There is no host name in this file that is ever resolved.
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

    test('sends Idempotency-Key only when one is given', () async {
      final transport = _FakeTransport((_) => _ok(_checkBody()));
      final client = _client(transport: transport);

      await client.checkScammer(query, source: Source.server);
      expect(transport.requests.last.header('idempotency-key'), isNull);

      await client.checkScammer(
        query,
        source: Source.server,
        idempotencyKey: '  9f3c-1  ',
      );
      // Trimmed: a stray space would make the replay a different key, which is
      // the one thing an idempotency key must never be.
      expect(transport.requests.last.header('idempotency-key'), '9f3c-1');

      await client.checkScammer(
        query,
        source: Source.server,
        idempotencyKey: '   ',
      );
      expect(transport.requests.last.header('idempotency-key'), isNull);
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
    test('a zero cacheTtlSeconds evicts what is already stored', () async {
      // The fleet-wide invalidation lever. Honouring it only for new writes
      // would leave the wrong verdict sitting on the device — which is the
      // exact situation the lever exists for.
      final clock = MutableClock(_t0);
      final cache = CheckCache.inMemory(clock: clock.now);
      await cache.write(query, _cachedResult(clock.now(), reportTotal: 7));
      expect(await cache.read(query), isNotNull);

      final transport = _FakeTransport(
        (_) => _ok(_checkBody(cacheTtlSeconds: 0)),
      );
      await _client(
        transport: transport,
        cache: cache,
        clock: clock,
      ).checkScammer(query, source: Source.server);

      expect(await cache.read(query), isNull);
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
  // Retry policy. This is the money bug: a blind retry of a POST that may
  // already have been processed charges the user twice, and nothing anywhere
  // reports that it happened.
  // ---------------------------------------------------------------------------
  group('retry policy', () {
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

    test('invalid_token does not refresh — only expired_token does', () async {
      final transport = _FakeTransport((_) => _error(401, 'invalid_token'));
      final client = _client(transport: transport);

      await expectLater(
        client.checkScammer(query, source: Source.server),
        throwsA(isA<TraciveInvalidTokenException>()),
      );
      expect(transport.to('/oauth/token'), isEmpty);
    });

    test('concurrent 401s trigger exactly one refresh (single-flight)',
        () async {
      // Two refreshes means the first rotated refresh token is presented twice,
      // which is what reuse detection looks for — and it revokes the grant.
      //
      // The verdict is keyed on the token the request actually carried, not on
      // a call counter: under `Future.wait` the interleaving is not fixed, and
      // a counter would make this test's meaning depend on scheduling luck.
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
        client.checkScammer(query, source: Source.server),
        client.checkScammer(query, source: Source.server),
        client.checkScammer(query, source: Source.server),
        client.checkScammer(query, source: Source.server),
      ]);

      expect(results, hasLength(4));
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

const TraciveMode _oauthMode = TraciveMode.oauth(
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
