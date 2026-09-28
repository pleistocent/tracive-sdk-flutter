// Copyright 2026 PT Pleistocent Teknologi Nusantara.
// Licensed under the Apache License, Version 2.0.
//
// Model, error-mapping and cache-policy tests.
//
// NO NETWORK: every response body here is a literal Map. The Open API does not
// exist yet, so a test that reached for it could only ever be aspirational.
//
// The three things worth failing a build over, and which this file exists to
// pin down:
//   1. Decoding never throws on an unexpected payload (forward compatibility).
//   2. Nothing that must not be logged is printable (identifiers, tokens,
//      proxy header values, the end user's name).
//   3. No API key can enter the public surface.

import 'dart:io';

import 'package:test/test.dart';
import 'package:tracive_sdk/tracive_sdk.dart';

void main() {
  group('CheckResult.fromJson', () {
    final fetchedAt = DateTime.utc(2026, 7, 30, 12);

    test('decodes a full-detail response', () {
      final result = CheckResult.fromJson(<String, Object?>{
        'checkId': 'chk_123',
        'found': true,
        'riskTier': 'HIGH',
        'reportTotal': 12,
        'credibleReports': 9,
        'ambiguousReports': 3,
        'firstReportOn': '2025-01',
        'lastReportOn': '2026-07',
        'fraudAmount': <String, Object?>{'IDR': 4500000, 'USD': 290.5},
        'tags': <Object?>['investment', 'telegram'],
        'relatedScammerCount': 4,
        'topChronologies': <Object?>[
          <String, Object?>{
            'chronology': 'Promised 30% monthly returns.',
            'riskLevel': 3,
            'incidentDate': '2026-05',
          },
        ],
        'comments': <Object?>[
          <String, Object?>{
            'date': '2026-06',
            'text': 'Same story here.',
            'fromCredibleReport': true,
          },
        ],
        'billing': <String, Object?>{
          'creditSource': 'USER',
          'unitsCharged': 1,
          'partnerBalanceRemaining': 998,
        },
        'cacheTtlSeconds': 3600,
        'disclaimer': 'User-submitted reports, not a legal finding.',
      }, fetchedAt: fetchedAt);

      expect(result.checkId, 'chk_123');
      expect(result.found, isTrue);
      expect(result.riskTier, RiskTier.high);
      expect(result.reportTotal, 12);
      expect(result.credibleReports, 9);
      expect(result.ambiguousReports, 3);
      expect(result.firstReportOn, '2025-01');
      expect(result.lastReportOn, '2026-07');
      expect(result.fraudAmount, <String, double>{
        'IDR': 4500000,
        'USD': 290.5,
      });
      expect(result.tags, <String>['investment', 'telegram']);
      expect(result.relatedScammerCount, 4);
      expect(result.topChronologies, hasLength(1));
      expect(result.topChronologies!.single.incidentDate, '2026-05');
      expect(result.comments!.single.fromCredibleReport, isTrue);
      expect(result.billing!.unitsCharged, 1);
      expect(result.billing!.partnerBalanceRemaining, 998);
      // `cacheTtlSeconds` is in the payload above but is no longer modelled. It
      // must be skipped, not fatal — `fromJson` would have thrown otherwise.
      expect(result.disclaimer, isNotNull);
      expect(result.origin, Origin.server);
      expect(result.fetchedAt, fetchedAt);
      expect(result.hasFullDetail, isTrue);
    });

    test('decodes a minimal, not-found response', () {
      final result = CheckResult.fromJson(<String, Object?>{
        'found': false,
        'riskTier': 'NONE',
      }, fetchedAt: fetchedAt);

      expect(result.found, isFalse);
      expect(result.riskTier, RiskTier.none);
      expect(result.reportTotal, 0);
      expect(result.fraudAmount, isEmpty);
      expect(result.tags, isEmpty);
      expect(result.checkId, isNull);
      expect(result.billing, isNull);
      expect(
        result.hasFullDetail,
        isFalse,
        reason: 'absent means "not requested", and must stay distinct from []',
      );
      expect(result.topChronologies, isNull);
      expect(result.comments, isNull);
    });

    test('an empty list is "requested, none found" - not "not requested"', () {
      final result = CheckResult.fromJson(<String, Object?>{
        'found': true,
        'riskTier': 'CAUTION',
        'topChronologies': <Object?>[],
        'comments': <Object?>[],
      }, fetchedAt: fetchedAt);
      expect(result.topChronologies, isEmpty);
      expect(result.comments, isEmpty);
      expect(result.hasFullDetail, isTrue);
    });

    test('ignores unknown fields instead of failing', () {
      // phase 2 will add fields. A build from phase 1 must survive them.
      final result = CheckResult.fromJson(<String, Object?>{
        'found': true,
        'riskTier': 'ELEVATED',
        'somethingNew': <String, Object?>{'nested': true},
        'anotherList': <Object?>[1, 2, 3],
      }, fetchedAt: fetchedAt);
      expect(result.riskTier, RiskTier.elevated);
    });

    test('degrades on wrong types instead of throwing', () {
      final result = CheckResult.fromJson(<String, Object?>{
        'checkId': 42,
        'found': 'true',
        'riskTier': <String, Object?>{'unexpected': 'shape'},
        'reportTotal': '7',
        'credibleReports': 2.9,
        'firstReportOn': 'not a date',
        'fraudAmount': <String, Object?>{'IDR': 'nope', 'USD': '12.5'},
        'tags': <Object?>['ok', 7, null],
        'topChronologies': 'not a list',
        'billing': 'not an object',
      }, fetchedAt: fetchedAt);

      expect(result.checkId, isNull);
      expect(result.found, isTrue, reason: '"true" is decoded leniently');
      expect(
        result.riskTier,
        RiskTier.none,
        reason: 'a non-string tier is not a tier at all',
      );
      expect(result.reportTotal, 7);
      expect(result.credibleReports, 2);
      expect(result.firstReportOn, isNull);
      expect(result.fraudAmount, <String, double>{'USD': 12.5});
      expect(result.tags, <String>['ok']);
      expect(result.topChronologies, isNull);
      expect(result.billing, isNull);
    });

    test('an unknown risk tier fails safe to HIGH, not to NONE', () {
      // If the server invents a tier this build has never heard of,
      // over-warning is recoverable; silently reporting "clean" is not.
      final result = CheckResult.fromJson(<String, Object?>{
        'found': true,
        'riskTier': 'CRITICAL',
      }, fetchedAt: fetchedAt);
      expect(result.riskTier, RiskTier.high);
      expect(RiskTier.fromWire('critical'), RiskTier.high);
      expect(RiskTier.fromWire(null), RiskTier.none);
      expect(RiskTier.fromWire(''), RiskTier.none);
      expect(RiskTier.fromWire(' high '), RiskTier.high);
      expect(RiskTier.none.isRisky, isFalse);
      expect(RiskTier.caution.isRisky, isTrue);
    });

    test('a legacy ISO date-time report date keeps only its month', () {
      final result = CheckResult.fromJson(<String, Object?>{
        'found': true,
        'riskTier': 'HIGH',
        'firstReportOn': '2025-01-15T12:00:00Z',
        'lastReportOn': '2026-07-15T12:00:00.000Z',
      }, fetchedAt: fetchedAt);
      expect(result.firstReportOn, '2025-01');
      expect(result.lastReportOn, '2026-07');
    });

    test('a report date that is not a month decodes to null', () {
      for (final value in <Object?>['garbage', '2026-13', '26-07', '', 5]) {
        final result = CheckResult.fromJson(<String, Object?>{
          'found': true,
          'riskTier': 'HIGH',
          'lastReportOn': value,
        }, fetchedAt: fetchedAt);
        expect(result.lastReportOn, isNull, reason: '$value');
      }
    });

    test('round-trips through toJson', () {
      final original = CheckResult.fromJson(<String, Object?>{
        'checkId': 'chk_1',
        'found': true,
        'riskTier': 'ELEVATED',
        'reportTotal': 3,
        'firstReportOn': '2026-01',
        'fraudAmount': <String, Object?>{'IDR': 1000.0},
        'tags': <Object?>['a'],
        'billing': <String, Object?>{'creditSource': 'USER', 'unitsCharged': 1},
        'cacheTtlSeconds': 60,
        'disclaimer': 'd',
      }, fetchedAt: fetchedAt);
      expect(CheckResult.fromJson(original.toJson()), original);
    });

    test('the explicit origin wins over anything in the payload', () {
      final result = CheckResult.fromJson(
        <String, Object?>{'found': true, 'riskTier': 'HIGH', 'origin': 'CACHE'},
        origin: Origin.server,
        fetchedAt: fetchedAt,
      );
      expect(result.origin, Origin.server);
      expect(result.isFromCache, isFalse);
    });
  });

  group('CheckResult.cacheable', () {
    test('drops everything that varies with detail or locale', () {
      // Section 5: only the invariant fields may be cached, which is what lets
      // the cache key be the query alone rather than (query, detail, locale).
      final result = CheckResult(
        checkId: 'chk_1',
        found: true,
        riskTier: RiskTier.high,
        reportTotal: 5,
        fraudAmount: const <String, double>{'IDR': 1.0},
        tags: const <String>['x'],
        topChronologies: const <Chronology>[
          Chronology(chronology: 'text', riskLevel: 1),
        ],
        comments: const <Comment>[
          Comment(date: 'd', text: 't', fromCredibleReport: true),
        ],
        billing: const Billing(creditSource: 'USER', unitsCharged: 1),
        disclaimer: 'd',
        origin: Origin.server,
        fetchedAt: DateTime.utc(2026, 7, 30),
      );

      final cached = result.cacheable();

      expect(cached.checkId, isNull, reason: 'a cache hit checked nothing');
      expect(cached.topChronologies, isNull);
      expect(cached.comments, isNull);
      expect(cached.billing, isNull, reason: 'a cache hit costs nothing');
      expect(cached.origin, Origin.cache);
      expect(cached.riskTier, RiskTier.high);
      expect(cached.reportTotal, 5);
      expect(cached.disclaimer, 'd');
      expect(
        cached.fetchedAt,
        result.fetchedAt,
        reason: 'TTL is measured from the original fetch, not the read',
      );
    });

    test('survives a JSON round trip, as the cache needs it to', () {
      final cached = CheckResult(
        found: true,
        riskTier: RiskTier.caution,
        origin: Origin.server,
        fetchedAt: DateTime.utc(2026, 7, 30),
        tags: const <String>['a', 'b'],
        fraudAmount: const <String, double>{'IDR': 2.5},
      ).cacheable();

      expect(CheckResult.fromJson(cached.toJson()), cached);
      expect(CheckResult.fromJson(cached.toJson()).origin, Origin.cache);
    });

    test('exposes unmodifiable collections', () {
      final result = CheckResult(
        found: true,
        riskTier: RiskTier.none,
        origin: Origin.server,
        fetchedAt: DateTime.utc(2026),
        tags: <String>['a'],
        fraudAmount: <String, double>{'IDR': 1},
      );
      expect(() => result.tags.add('b'), throwsUnsupportedError);
      expect(() => result.fraudAmount['USD'] = 2, throwsUnsupportedError);
    });
  });

  group('CachePolicy', () {
    CheckResult resultFor(RiskTier tier) => CheckResult(
          found: tier != RiskTier.none,
          riskTier: tier,
          origin: Origin.server,
          fetchedAt: DateTime.utc(2026, 7, 30, 12),
        );

    test('uses the section 5 defaults per tier', () {
      const policy = CachePolicy.defaultPolicy;
      expect(policy.defaultTtlFor(RiskTier.high), const Duration(days: 30));
      expect(policy.defaultTtlFor(RiskTier.elevated), const Duration(days: 7));
      expect(policy.defaultTtlFor(RiskTier.caution), const Duration(hours: 24));
      expect(policy.defaultTtlFor(RiskTier.none), const Duration(hours: 1));
    });

    test('a tier TTL can be zero, so a host can refuse to cache that tier', () {
      // Zero is not merely a short TTL: the cache stores nothing and drops what
      // is there. It is the only lifetime with a second meaning.
      const policy = CachePolicy(noneTtl: Duration.zero);
      expect(policy.defaultTtlFor(RiskTier.none), Duration.zero);
      expect(policy.defaultTtlFor(RiskTier.high), const Duration(days: 30));
      expect(
        policy.isFresh(resultFor(RiskTier.none), DateTime.utc(2026, 7, 30, 12)),
        isFalse,
        reason: 'a zero TTL is stale even at the instant of the fetch',
      );
    });

    test('freshness is measured from fetchedAt', () {
      const policy = CachePolicy.defaultPolicy;
      final result = resultFor(RiskTier.caution);
      final justInside = result.fetchedAt.add(
        const Duration(hours: 23, minutes: 59),
      );
      final justOutside = result.fetchedAt.add(
        const Duration(hours: 24, seconds: 1),
      );
      expect(policy.isFresh(result, justInside), isTrue);
      expect(policy.isFresh(result, justOutside), isFalse);
      expect(
        policy.isFresh(result, policy.expiryFor(result)),
        isFalse,
        reason: 'the expiry instant itself is already stale',
      );
    });

    test('a disabled policy is never fresh', () {
      expect(
        CachePolicy.disabled.isFresh(
          resultFor(RiskTier.high),
          DateTime.utc(2026, 7, 30, 12),
        ),
        isFalse,
      );
    });

    test('compares by value and copies with replacements', () {
      expect(const CachePolicy(), CachePolicy.defaultPolicy);
      expect(CachePolicy.defaultPolicy.copyWith(maxEntries: 10).maxEntries, 10);
      expect(
        CachePolicy.defaultPolicy.copyWith(maxEntries: 10),
        isNot(CachePolicy.defaultPolicy),
      );
    });
  });

  group('error mapping (section 7)', () {
    TraciveException map(int status, String? code, {Duration? retryAfter}) =>
        TraciveException.fromApiError(
          statusCode: status,
          code: code,
          message: 'boom',
          checkId: 'chk_9',
          retryAfter: retryAfter,
        );

    test('maps every documented code to its own type', () {
      expect(
        map(400, 'invalid_request'),
        isA<TraciveInvalidRequestException>(),
      );
      expect(
        map(400, 'unsupported_input_type'),
        isA<TraciveUnsupportedInputTypeException>(),
      );
      expect(
        map(400, 'unsupported_credit_source'),
        isA<TraciveUnsupportedCreditSourceException>(),
      );
      expect(map(401, 'invalid_token'), isA<TraciveInvalidTokenException>());
      expect(map(401, 'expired_token'), isA<TraciveExpiredTokenException>());
      expect(map(401, 'grant_revoked'), isA<TraciveGrantRevokedException>());
      expect(map(401, 'invalid_api_key'), isA<TraciveInvalidApiKeyException>());
      expect(map(403, 'missing_scope'), isA<TraciveMissingScopeException>());
      expect(
        map(403, 'detail_not_permitted'),
        isA<TraciveDetailNotPermittedException>(),
      );
      expect(
        map(403, 'credential_mismatch'),
        isA<TraciveCredentialMismatchException>(),
      );
      expect(
        map(403, 'partner_suspended'),
        isA<TracivePartnerSuspendedException>(),
      );
      expect(
        map(403, 'user_credit_not_permitted'),
        isA<TraciveUserCreditNotPermittedException>(),
      );
      expect(
        map(403, 'translation_not_permitted'),
        isA<TraciveTranslationNotPermittedException>(),
      );
      expect(
        map(409, 'idempotency_conflict'),
        isA<TraciveIdempotencyConflictException>(),
      );
      expect(map(429, 'rate_limited'), isA<TraciveRateLimitedException>());
      expect(
        map(429, 'daily_quota_exceeded'),
        isA<TraciveRateLimitedException>(),
      );
    });

    test('distinguishes the three 402s by which balance ran out', () {
      expect(
        map(402, 'insufficient_user_credits'),
        isA<TraciveInsufficientCreditsException>().having(
          (e) => e.which,
          'which',
          InsufficientCreditsKind.user,
        ),
      );
      expect(
        map(402, 'insufficient_credits'),
        isA<TraciveInsufficientCreditsException>().having(
          (e) => e.which,
          'which',
          InsufficientCreditsKind.account,
        ),
      );
      expect(
        map(402, 'insufficient_partner_balance'),
        isA<TraciveInsufficientCreditsException>().having(
          (e) => e.which,
          'which',
          InsufficientCreditsKind.partnerBalance,
        ),
      );
    });

    test('an unrecognised code never crashes and keeps the raw code', () {
      final unknown = map(400, 'some_future_code');
      expect(unknown, isA<TraciveUnknownException>());
      expect(unknown.code, 'some_future_code');

      final serverSide = map(503, 'some_future_code');
      expect(serverSide, isA<TraciveServerException>());
      expect(serverSide.code, 'some_future_code');
      expect(serverSide.statusCode, 503);
    });

    test('falls back on the status class when there is no code at all', () {
      expect(map(500, null), isA<TraciveServerException>());
      expect(map(429, null), isA<TraciveRateLimitedException>());
      expect(map(418, null), isA<TraciveUnknownException>());
      expect(
        TraciveException.fromApiError(statusCode: 418).message,
        contains('418'),
        reason: 'with no server message at all, the status is what is left',
      );
    });

    test('codes are matched case-insensitively and trimmed', () {
      expect(map(401, ' Expired_Token '), isA<TraciveExpiredTokenException>());
    });

    test('carries checkId through for support tickets', () {
      expect(map(409, 'idempotency_conflict').checkId, 'chk_9');
    });

    test('reads a malformed or missing error envelope without throwing', () {
      expect(
        TraciveException.fromErrorBody(500, null),
        isA<TraciveServerException>(),
      );
      expect(
        TraciveException.fromErrorBody(500, '<html>502 Bad Gateway</html>'),
        isA<TraciveServerException>(),
      );
      expect(
        TraciveException.fromErrorBody(401, <String, Object?>{
          'error': <String, Object?>{
            'code': 'grant_revoked',
            'message': 'Consent withdrawn',
            'checkId': 'chk_2',
          },
        }),
        isA<TraciveGrantRevokedException>()
            .having((e) => e.checkId, 'checkId', 'chk_2')
            .having((e) => e.message, 'message', 'Consent withdrawn'),
      );
    });

    test('marks transient failures retryable and permanent ones not', () {
      // Note section 7: retryable means "the failure is transient", not
      // "retrying is free" - a checkScammer retry still needs an
      // Idempotency-Key or it risks a double charge.
      expect(map(500, null).isRetryable, isTrue);
      expect(map(429, 'rate_limited').isRetryable, isTrue);
      expect(map(401, 'expired_token').isRetryable, isTrue);
      expect(
        TraciveNetworkException(const SocketException('down')).isRetryable,
        isTrue,
      );
      expect(
        map(401, 'grant_revoked').isRetryable,
        isFalse,
        reason: 'retrying a revoked grant trips reuse detection',
      );
      expect(map(402, 'insufficient_user_credits').isRetryable, isFalse);
    });

    test('parses Retry-After only in its delta-seconds form', () {
      expect(
        TraciveRateLimitedException.parseRetryAfter('120'),
        const Duration(seconds: 120),
      );
      expect(
        TraciveRateLimitedException.parseRetryAfter(' 5 '),
        const Duration(seconds: 5),
      );
      expect(TraciveRateLimitedException.parseRetryAfter(null), isNull);
      expect(TraciveRateLimitedException.parseRetryAfter('-1'), isNull);
      expect(
        TraciveRateLimitedException.parseRetryAfter(
          'Wed, 21 Oct 2026 07:28:00 GMT',
        ),
        isNull,
        reason:
            'the HTTP-date form is not parsed; callers fall back on backoff',
      );
      expect(
        map(429, 'rate_limited', retryAfter: const Duration(seconds: 30)),
        isA<TraciveRateLimitedException>().having(
          (e) => e.retryAfter,
          'retryAfter',
          const Duration(seconds: 30),
        ),
      );
    });

    test('every error is a TraciveException and an Exception', () {
      expect(map(500, null), isA<TraciveException>());
      expect(map(500, null), isA<Exception>());
      expect(
        const TraciveQueryException(QueryRejectionReason.notE164),
        isA<TraciveException>(),
      );
    });

    test('Proxy mode has a typed "not yet" error to throw', () {
      const error = TraciveException.notImplemented(
        'Proxy mode arrives in phase 2',
      );
      expect(error, isA<TraciveNotImplementedException>());
      expect(error.message, contains('phase 2'));
    });
  });

  group('privacy: what may never be logged', () {
    test('an authorization code and PKCE verifier are not printable', () {
      const result = AuthResult.codeReceived(
        code: 'super-secret-code',
        codeVerifier: 'super-secret-verifier',
        redirectUri: 'https://partner.example/callback',
      );
      final rendered = result.toString();
      expect(rendered, isNot(contains('super-secret-code')));
      expect(rendered, isNot(contains('super-secret-verifier')));
      expect(rendered, contains('redacted'));
      expect(rendered, contains('https://partner.example/callback'));
    });

    test('proxy auth header values are not printable', () {
      final mode = TraciveMode.proxy(
        baseUrl: 'https://proxy.example/v1',
        authHeaders: <String, String>{'X-Partner-Token': 'shhh'},
      );
      final rendered = mode.toString();
      expect(rendered, isNot(contains('shhh')));
      expect(rendered, contains('X-Partner-Token'));
      expect(rendered, contains('redacted'));
    });

    test('the auth headers are copied, not captured', () {
      // A mode is a value, and this one holds credentials. A caller that kept
      // the map it passed could otherwise change what this object claims to
      // hold after it was built — and a proxy mode whose headers changed
      // underneath it is a request signed with something nobody chose.
      final supplied = <String, String>{'x-partner-key': 'first'};
      final mode = TraciveProxyMode(
        baseUrl: 'https://partner.example/tracive',
        authHeaders: supplied,
      );

      supplied['x-partner-key'] = 'second';
      supplied['x-extra'] = 'added later';

      expect(mode.authHeaders['x-partner-key'], 'first');
      expect(mode.authHeaders.containsKey('x-extra'), isFalse);
      expect(
        () => mode.authHeaders['x-partner-key'] = 'third',
        throwsUnsupportedError,
        reason: 'and the copy itself is not writable either',
      );
    });

    test('a user name is not printable', () {
      const profile = ProfileInfo(sub: 'user_1', name: 'Budi Santoso');
      expect(profile.toString(), isNot(contains('Budi')));
      expect(profile.toString(), contains('user_1'));
    });

    test('comment and chronology text is summarised, not printed', () {
      const comment = Comment(
        date: '2026-01',
        text: 'he took my bank account 123',
        fromCredibleReport: true,
      );
      expect(comment.toString(), isNot(contains('123')));
      const chronology = Chronology(
        chronology: 'called from +6281234567891',
        riskLevel: 2,
      );
      expect(chronology.toString(), isNot(contains('+62')));
    });

    test('no API key parameter exists anywhere in lib/', () {
      // A hard design invariant (section 11.1): authentication is OAuth+PKCE
      // precisely so that no long-lived secret ships inside the binary. This
      // scans the source rather than the surface, because the point is that the
      // parameter must never be added in the first place.
      final libDirectory = Directory('lib');
      if (!libDirectory.existsSync()) {
        fail('run `dart test` from the package root');
      }
      final offenders = <String>[];
      final apiKeyIdentifier = RegExp(r'\bapi[_]?[Kk]ey\b');
      for (final entity in libDirectory.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        for (final line in entity.readAsLinesSync()) {
          final code = line.split('//').first;
          if (apiKeyIdentifier.hasMatch(code)) {
            offenders.add('${entity.path}: ${line.trim()}');
          }
        }
      }
      expect(
        offenders,
        isEmpty,
        reason: 'no API-key parameter may enter the public surface',
      );
    });
  });

  group('TraciveEnvironment', () {
    test('carries the documented base URLs, including /v1', () {
      expect(
        TraciveEnvironment.production.baseUrl,
        'https://api.tracive.id/v1',
      );
      expect(
        TraciveEnvironment.sandbox.baseUrl,
        'https://api-sandbox.tracive.id/v1',
      );
    });

    test('resolves paths without doubling or dropping slashes', () {
      expect(
        TraciveEnvironment.production.resolve('scammer-checks').toString(),
        'https://api.tracive.id/v1/scammer-checks',
      );
      expect(
        TraciveEnvironment.production.resolve('/credits').toString(),
        'https://api.tracive.id/v1/credits',
      );
      expect(
        TraciveEnvironment.custom(
          'https://proxy.example/v1/',
        ).resolve('profile').toString(),
        'https://proxy.example/v1/profile',
      );
    });

    test('rejects a non-absolute custom URL at construction time', () {
      expect(() => TraciveEnvironment.custom(''), throwsArgumentError);
      expect(() => TraciveEnvironment.custom('   '), throwsArgumentError);
      expect(() => TraciveEnvironment.custom('/v1'), throwsArgumentError);
      expect(
        () => TraciveEnvironment.custom('proxy.example/v1'),
        throwsArgumentError,
      );
    });

    test('rejects a cleartext custom URL', () {
      // Every authorized request carries `Authorization: Bearer <token>`. Over
      // plaintext HTTP that token is readable by anything on the path, and
      // nothing about the failure is visible to the integrator or the user.
      // Phase 2's proxy mode makes this a URL people will actually type.
      expect(
        () => TraciveEnvironment.custom('http://proxy.internal/v1'),
        throwsArgumentError,
      );
      expect(
        () => TraciveEnvironment.custom('http://192.168.1.10:8080/v1'),
        throwsArgumentError,
        reason: 'a LAN address is still a network path',
      );
      expect(
        () => TraciveEnvironment.custom('ftp://proxy.example/v1'),
        throwsArgumentError,
      );
    });

    test('allows http on loopback, where there is no path to listen on', () {
      // A local test server with no certificate is the ordinary way to exercise
      // proxy mode, and traffic to loopback never leaves the machine.
      for (final host in TraciveEnvironment.loopbackHosts) {
        final url =
            host == '::1' ? 'http://[$host]:8080/v1' : 'http://$host:8080/v1';
        expect(
          TraciveEnvironment.custom(url).baseUrl,
          url,
          reason: 'http://$host must stay usable for local testing',
        );
      }
      expect(
        TraciveEnvironment.custom('https://proxy.example/v1').baseUrl,
        'https://proxy.example/v1',
      );
    });
  });

  group('TraciveScopes', () {
    test('are the exact wire strings', () {
      // Spelled out as literals rather than compared to the constants
      // themselves. A test written the other way round would pass no matter
      // what the constants held, so renaming one would quietly redefine the
      // contract instead of failing here.
      //
      // A scope name is only ever validated by the authorization server, and it
      // rejects the whole consent request when it does not recognise one — so a
      // wrong name is not a narrower grant, it is an integration that cannot
      // authorize at all, and only a live consent screen would show it.
      expect(TraciveScopes.scammerCheck, 'scammer.check');
      expect(TraciveScopes.creditsRead, 'credits.read');
      expect(TraciveScopes.profileRead, 'profile.read');
    });

    test('are dot-separated, never colon-separated', () {
      // Both halves of the shape are easy to get wrong, and both have been
      // wrong in a Tracive SDK before: a colon separator, and a resource named
      // after neither the endpoint nor the thing acted on.
      for (final scope in <String>[
        TraciveScopes.scammerCheck,
        TraciveScopes.creditsRead,
        TraciveScopes.profileRead,
      ]) {
        expect(scope, contains('.'), reason: '"$scope" must be dot-separated');
        expect(
          scope,
          isNot(contains(':')),
          reason: '"$scope" must not be colon-separated',
        );
      }
    });

    test('are what an OAuth mode asks for by default', () {
      // The default is the one scope every integration needs. Asking for more
      // by default would put permissions on the consent screen that the caller
      // never uses.
      final mode = TraciveMode.oauth(
        partnerUserId: 'partner-user-1',
        clientId: 'partner-app',
        redirectUri: 'https://partner.example/callback',
      );
      expect((mode as TraciveOAuthMode).scopes, <String>['scammer.check']);
    });
  });

  group('TraciveMode', () {
    test('OAuth mode defaults to a public client and needs no secret', () {
      final mode = TraciveMode.oauth(
        partnerUserId: 'partner-user-1',
        clientId: 'partner-app',
        redirectUri: 'https://partner.example/callback',
      );
      expect(mode, isA<TraciveOAuthMode>());
      final oauth = mode as TraciveOAuthMode;
      expect(oauth.clientType, ClientType.public);
      expect(oauth.scopes, isNotEmpty);
      expect(oauth.partnerUserId, 'partner-user-1');
    });

    // SDK-2: the rest of the server's partner_user_id rule.
    test('rejects a partnerUserId the server would refuse', () {
      for (final bad in <String>[
        'budi@bca.co.id',
        '08123456789',
        '628123456789',
        '+62 812-3456-7890',
        '+6591234567',
        'x' * 201,
      ]) {
        expect(
          () => TraciveMode.oauth(
            clientId: 'cli_1',
            redirectUri: 'https://partner.test/cb',
            partnerUserId: bad,
          ),
          throwsArgumentError,
          reason: bad,
        );
      }
      for (final ok in <String>[
        '0012345678',
        '1234567890123456',
        '3f2b9c1e-uuid',
        'pelanggan-ñandú',
        'x' * 200,
      ]) {
        TraciveMode.oauth(
          clientId: 'cli_1',
          redirectUri: 'https://partner.test/cb',
          partnerUserId: ok,
        );
      }
    });

    test('rejects a blank partnerUserId in every build', () {
      // A plain throw, not an assert: the AOT compiler strips asserts, so the
      // earlier version of this guard let a release build send
      // `partner_user_id=` while debug refused it — the worst shape a check can
      // have, because the difference appears only in production.
      for (final blank in <String>['', '   ', '\t\n']) {
        expect(
          () => TraciveMode.oauth(
            clientId: 'c',
            redirectUri: 'https://partner.example/cb',
            partnerUserId: blank,
          ),
          throwsA(isA<ArgumentError>()),
          reason: 'a blank id of length ${blank.length} must be refused here',
        );
      }
    });

    test('is exhaustively switchable', () {
      String describe(TraciveMode mode) => switch (mode) {
            TraciveOAuthMode() => 'oauth',
            TraciveProxyMode() => 'proxy',
          };
      expect(
        describe(
          TraciveMode.oauth(
            partnerUserId: 'partner-user-1',
            clientId: 'a',
            redirectUri: 'https://b.example/c',
          ),
        ),
        'oauth',
      );
      expect(
        describe(TraciveMode.proxy(baseUrl: 'https://p.example')),
        'proxy',
      );
    });

    test('compares by value', () {
      final a = TraciveMode.oauth(
        partnerUserId: 'partner-user-1',
        clientId: 'a',
        redirectUri: 'https://b.example/c',
      );
      final b = TraciveMode.oauth(
        partnerUserId: 'partner-user-1',
        clientId: 'a',
        redirectUri: 'https://b.example/c',
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });
  });

  group('AuthResult', () {
    test('is exhaustively switchable over the five section 6 cases', () {
      String describe(AuthResult result) => switch (result) {
            AuthAuthorized(:final grantedScopes) => 'authorized:$grantedScopes',
            AuthCodeReceived(:final redirectUri) => 'code:$redirectUri',
            AuthDenied() => 'denied',
            AuthAppNotInstalled() => 'appNotInstalled',
            AuthFailed(:final error) => 'failed:${error.runtimeType}',
          };

      expect(
        describe(const AuthResult.authorized(<String>['scammer.check'])),
        'authorized:[scammer.check]',
      );
      expect(
        describe(
          const AuthResult.codeReceived(
            code: 'c',
            codeVerifier: 'v',
            redirectUri: 'https://r.example',
          ),
        ),
        'code:https://r.example',
      );
      expect(describe(const AuthResult.denied()), 'denied');
      expect(describe(const AuthResult.appNotInstalled()), 'appNotInstalled');
      expect(
        describe(const AuthResult.failed(TraciveStateMismatchException())),
        'failed:TraciveStateMismatchException',
      );
    });

    test('value cases compare by value', () {
      expect(const AuthResult.denied(), const AuthResult.denied());
      expect(
        const AuthResult.appNotInstalled(),
        const AuthResult.appNotInstalled(),
      );
      expect(
        const AuthResult.authorized(<String>['a']),
        const AuthResult.authorized(<String>['a']),
      );
      expect(
        const AuthResult.denied(),
        isNot(const AuthResult.appNotInstalled()),
      );
    });
  });

  group('small models', () {
    test('CreditsInfo decodes and round-trips', () {
      final credits = CreditsInfo.fromJson(<String, Object?>{
        'subscriptionCredits': 25,
        'tier': 'PRO',
        'nextResetAt': '2026-08-01T00:00:00.000Z',
        'unexpected': true,
      });
      expect(credits.subscriptionCredits, 25);
      expect(credits.tier, 'PRO');
      expect(credits.nextResetAt, DateTime.utc(2026, 8));
      expect(CreditsInfo.fromJson(credits.toJson()), credits);
    });

    test('ProfileInfo decodes and round-trips', () {
      final profile = ProfileInfo.fromJson(<String, Object?>{
        'sub': 'user_1',
        'name': 'Budi',
        'country': 'ID',
        'tier': 'FREE',
        'memberSince': '2025-03-04T05:06:07.000Z',
      });
      expect(profile.sub, 'user_1');
      expect(profile.memberSince, DateTime.utc(2025, 3, 4, 5, 6, 7));
      expect(ProfileInfo.fromJson(profile.toJson()), profile);
    });

    test('Billing defaults creditSource to USER', () {
      final billing = Billing.fromJson(<String, Object?>{'unitsCharged': 2});
      expect(billing.creditSource, 'USER');
      expect(billing.unitsCharged, 2);
      expect(billing.partnerBalanceRemaining, isNull);
    });

    test('enums decode leniently and expose their wire values', () {
      expect(Detail.minimal.wireValue, 'minimal');
      expect(Detail.full.wireValue, 'full');
      expect(
        Detail.minimal.supportsLocale,
        isFalse,
        reason: 'the server ignores locale at minimal detail',
      );
      expect(Detail.fromWire('FULL'), Detail.full);
      expect(Detail.fromWire('nonsense'), Detail.minimal);

      expect(Origin.fromWire('cache'), Origin.cache);
      expect(Origin.fromWire(null), Origin.server);

      expect(ClientType.fromWire('CONFIDENTIAL'), ClientType.confidential);
      expect(ClientType.fromWire(null), ClientType.public);

      expect(QueryType.fromWire('username'), QueryType.username);
      expect(QueryType.fromWire('DOMAIN'), isNull);
    });

    test('Source says what it is allowed to touch', () {
      expect(Source.cacheFirst.readsCache, isTrue);
      expect(Source.cacheFirst.readsNetwork, isTrue);
      expect(Source.server.readsCache, isFalse);
      expect(
        Source.cache.readsNetwork,
        isFalse,
        reason: 'a cache-only lookup must never open a socket',
      );
    });
  });
}
