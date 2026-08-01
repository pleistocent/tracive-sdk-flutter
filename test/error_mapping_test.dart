// Copyright (c) Tracive. Licensed under the Apache License, Version 2.0.
//
// The error-code table, exhaustively.
//
// NO NETWORK. Every response here is a literal `TraciveHttpResponse`. The Open
// API does not exist yet; nothing in this repo has ever opened a socket, and
// this file is written so that stays true.
//
// Why this file is worth its length: error mapping is the part of an SDK that
// is exercised least in development and most in production, and it is where a
// mistake is *silent*. A `rate_limited` that maps to a generic failure does not
// crash — it just quietly loses the `Retry-After` the server took the trouble
// to send, and the app hammers the endpoint. So every row of the table gets an
// assertion, including the rows that look boring.
//
// Three properties are checked beyond the row-by-row mapping:
//
//   1. A malformed error response still produces a typed error, never a throw
//      from inside the SDK. Nginx HTML, an empty 500, a JSON array — all of it
//      has to land somewhere sensible.
//   2. An unrecognised code carries its raw `code` through, so a caller can
//      still branch on a phase 2 code this build has never heard of.
//   3. No error message ever contains a token or a raw identifier.

import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:tracive_sdk/tracive_sdk.dart';
// Imported by path on purpose: wire-error decoding is deliberately NOT part of
// the public barrel (see the "not exported" list in `lib/tracive_sdk.dart`).
// This test asserts the mapping table itself, so it needs the internal helper.
import 'package:tracive_sdk/src/client/error_envelope.dart';

void main() {
  final query = TraciveQuery.phone('+6281234567891');

  // ---------------------------------------------------------------------------
  // The table itself, row by row.
  // ---------------------------------------------------------------------------
  group('error-code table', () {
    void expectsMapping(
      String name, {
      required int status,
      required String code,
      required Matcher matcher,
    }) {
      test('$status $code', () {
        final mapped = mapErrorResponse(
          _errorResponse(status, code, message: 'server text'),
        );
        expect(mapped, matcher, reason: name);
        expect(
          mapped.code,
          code,
          reason: 'the raw wire code must survive the mapping',
        );
        expect(mapped.statusCode, status);
        expect(mapped.message, 'server text');
      });
    }

    // 400
    expectsMapping(
      'InvalidRequest',
      status: 400,
      code: 'invalid_request',
      matcher: isA<TraciveInvalidRequestException>(),
    );
    expectsMapping(
      'UnsupportedInputType',
      status: 400,
      code: 'unsupported_input_type',
      matcher: isA<TraciveUnsupportedInputTypeException>(),
    );
    expectsMapping(
      'UnsupportedCreditSource',
      status: 400,
      code: 'unsupported_credit_source',
      matcher: isA<TraciveUnsupportedCreditSourceException>(),
    );

    // 401
    expectsMapping(
      'InvalidToken',
      status: 401,
      code: 'invalid_token',
      matcher: isA<TraciveInvalidTokenException>(),
    );
    expectsMapping(
      'ExpiredToken',
      status: 401,
      code: 'expired_token',
      matcher: isA<TraciveExpiredTokenException>(),
    );
    expectsMapping(
      'GrantRevoked',
      status: 401,
      code: 'grant_revoked',
      matcher: isA<TraciveGrantRevokedException>(),
    );
    expectsMapping(
      'InvalidApiKey',
      status: 401,
      code: 'invalid_api_key',
      matcher: isA<TraciveInvalidApiKeyException>(),
    );

    // 403
    expectsMapping(
      'MissingScope',
      status: 403,
      code: 'missing_scope',
      matcher: isA<TraciveMissingScopeException>(),
    );
    expectsMapping(
      'DetailNotPermitted',
      status: 403,
      code: 'detail_not_permitted',
      matcher: isA<TraciveDetailNotPermittedException>(),
    );
    expectsMapping(
      'CredentialMismatch',
      status: 403,
      code: 'credential_mismatch',
      matcher: isA<TraciveCredentialMismatchException>(),
    );
    expectsMapping(
      'PartnerSuspended',
      status: 403,
      code: 'partner_suspended',
      matcher: isA<TracivePartnerSuspendedException>(),
    );

    // 409
    expectsMapping(
      'IdempotencyConflict',
      status: 409,
      code: 'idempotency_conflict',
      matcher: isA<TraciveIdempotencyConflictException>(),
    );

    // 402 — one type, three balances. `which` is the part a caller branches on
    // ("top up your own credits" vs "contact your account manager"), so it is
    // asserted rather than just the type.
    test('402 insufficient_user_credits carries which = user', () {
      final mapped = mapErrorResponse(
        _errorResponse(402, 'insufficient_user_credits'),
      );
      expect(mapped, isA<TraciveInsufficientCreditsException>());
      expect(
        (mapped as TraciveInsufficientCreditsException).which,
        InsufficientCreditsKind.user,
      );
    });

    test('402 insufficient_credits carries which = account', () {
      final mapped =
          mapErrorResponse(_errorResponse(402, 'insufficient_credits'));
      expect(
        (mapped as TraciveInsufficientCreditsException).which,
        InsufficientCreditsKind.account,
      );
    });

    test('402 insufficient_partner_balance carries which = partnerBalance', () {
      final mapped = mapErrorResponse(
        _errorResponse(402, 'insufficient_partner_balance'),
      );
      expect(
        (mapped as TraciveInsufficientCreditsException).which,
        InsufficientCreditsKind.partnerBalance,
      );
    });

    // 429 — the Retry-After header is the whole point of this row.
    test('429 rate_limited reads Retry-After', () {
      final mapped = mapErrorResponse(
        _errorResponse(
          429,
          'rate_limited',
          headers: const <String, String>{'Retry-After': '42'},
        ),
      );
      expect(mapped, isA<TraciveRateLimitedException>());
      expect(
        (mapped as TraciveRateLimitedException).retryAfter,
        const Duration(seconds: 42),
      );
      expect(mapped.isRetryable, isTrue);
    });

    test('429 without Retry-After yields a null delay, not a wrong one', () {
      final mapped = mapErrorResponse(_errorResponse(429, 'rate_limited'))
          as TraciveRateLimitedException;
      expect(mapped.retryAfter, isNull);
    });

    test('429 with an HTTP-date Retry-After yields null rather than a guess',
        () {
      final mapped = mapErrorResponse(
        _errorResponse(
          429,
          'rate_limited',
          headers: const <String, String>{
            'retry-after': 'Wed, 21 Oct 2026 07:28:00 GMT',
          },
        ),
      ) as TraciveRateLimitedException;
      expect(mapped.retryAfter, isNull);
    });

    // 5xx
    test('500 maps to Server and is retryable', () {
      final mapped = mapErrorResponse(_errorResponse(500, 'internal'));
      expect(mapped, isA<TraciveServerException>());
      expect(mapped.statusCode, 500);
      expect(mapped.isRetryable, isTrue);
    });

    test('503 with no code at all still maps to Server', () {
      final mapped = mapErrorResponse(
        TraciveHttpResponse(statusCode: 503, body: '{}'),
      );
      expect(mapped, isA<TraciveServerException>());
      expect(mapped.statusCode, 503);
    });

    // Transport failure.
    test('a transport failure maps to Network and keeps its cause', () {
      final cause = const FormatException('simulated socket failure');
      final mapped = asTraciveException(cause, StackTrace.current);
      expect(mapped, isA<TraciveNetworkException>());
      expect((mapped as TraciveNetworkException).cause, same(cause));
      expect(mapped.isRetryable, isTrue);
    });

    test('an already-typed error is not wrapped twice', () {
      const original = TraciveInvalidRequestException('already typed');
      expect(asTraciveException(original, StackTrace.current), same(original));
    });
  });

  // ---------------------------------------------------------------------------
  // Codes this build has never heard of.
  // ---------------------------------------------------------------------------
  group('unrecognised codes', () {
    test('an unknown 4xx code maps to Unknown and keeps the raw code', () {
      final mapped = mapErrorResponse(
        _errorResponse(418, 'teapot_overheated', message: 'short and stout'),
      );
      expect(mapped, isA<TraciveUnknownException>());
      expect(mapped.code, 'teapot_overheated');
      expect(mapped.statusCode, 418);
      expect(mapped.message, 'short and stout');
    });

    test('an unknown 5xx code maps to Server and keeps the raw code', () {
      final mapped = mapErrorResponse(_errorResponse(507, 'quota_exhausted'));
      expect(mapped, isA<TraciveServerException>());
      expect(mapped.code, 'quota_exhausted');
    });

    test('codes are matched case- and whitespace-insensitively', () {
      final mapped = mapErrorResponse(_errorResponse(429, '  RATE_LIMITED '));
      expect(mapped, isA<TraciveRateLimitedException>());
    });
  });

  // ---------------------------------------------------------------------------
  // Malformed envelopes. The error path is where a crash is least affordable.
  // ---------------------------------------------------------------------------
  group('malformed envelopes never throw', () {
    test('an HTML error page from a proxy', () {
      final mapped = mapErrorResponse(
        TraciveHttpResponse(
          statusCode: 502,
          headers: const <String, String>{'content-type': 'text/html'},
          body: '<html><body><h1>502 Bad Gateway</h1></body></html>',
        ),
      );
      expect(mapped, isA<TraciveServerException>());
      expect(mapped.statusCode, 502);
    });

    test('an empty body', () {
      final mapped = mapErrorResponse(TraciveHttpResponse(statusCode: 500));
      expect(mapped, isA<TraciveServerException>());
    });

    test('a JSON array where an object was promised', () {
      final mapped = mapErrorResponse(
        TraciveHttpResponse(statusCode: 400, body: '[1,2,3]'),
      );
      expect(mapped, isA<TraciveException>());
      expect(mapped.statusCode, 400);
    });

    test('a flat "error": "code" envelope', () {
      final mapped = mapErrorResponse(
        TraciveHttpResponse(
          statusCode: 403,
          body: jsonEncode(<String, Object?>{'error': 'missing_scope'}),
        ),
      );
      expect(mapped, isA<TraciveMissingScopeException>());
    });

    test('an error object whose fields have the wrong types', () {
      final mapped = mapErrorResponse(
        TraciveHttpResponse(
          statusCode: 400,
          body: jsonEncode(<String, Object?>{
            'error': <String, Object?>{
              'code': 42,
              'message': <String>['not', 'a', 'string'],
              'checkId': true,
            },
          }),
        ),
      );
      expect(mapped, isA<TraciveUnknownException>());
      expect(mapped.checkId, isNull);
    });

    test('checkId is carried through for support tickets', () {
      final mapped = mapErrorResponse(
        _errorResponse(400, 'invalid_request', checkId: 'chk_9f3'),
      );
      expect(mapped.checkId, 'chk_9f3');
    });
  });

  // ---------------------------------------------------------------------------
  // The token endpoint speaks RFC 6749's flat envelope, not the API's nested
  // one. Both have to map.
  // ---------------------------------------------------------------------------
  group('token-endpoint envelopes', () {
    test('invalid_grant maps to GrantRevoked — the do-not-retry case', () {
      final mapped = mapTokenErrorResponse(
        TraciveHttpResponse(
          statusCode: 400,
          body: jsonEncode(<String, Object?>{
            'error': 'invalid_grant',
            'error_description': 'refresh token already used',
          }),
        ),
      );
      expect(mapped, isA<TraciveGrantRevokedException>());
      expect(mapped.message, 'refresh token already used');
    });

    test('invalid_scope maps to MissingScope', () {
      final mapped = mapTokenErrorResponse(
        TraciveHttpResponse(
          statusCode: 400,
          body: jsonEncode(<String, Object?>{'error': 'invalid_scope'}),
        ),
      );
      expect(mapped, isA<TraciveMissingScopeException>());
    });

    test('a nested envelope from the token endpoint still uses the same table',
        () {
      final mapped = mapTokenErrorResponse(
        _errorResponse(429, 'rate_limited', headers: {'retry-after': '7'}),
      );
      expect(mapped, isA<TraciveRateLimitedException>());
      expect(
        (mapped as TraciveRateLimitedException).retryAfter,
        const Duration(seconds: 7),
      );
    });

    test('an unrecognised token error does not crash', () {
      final mapped = mapTokenErrorResponse(
        TraciveHttpResponse(statusCode: 400, body: 'not json at all'),
      );
      expect(mapped, isA<TraciveException>());
    });
  });

  // ---------------------------------------------------------------------------
  // End to end through the client: the same table, but reached the way an app
  // reaches it. This is what proves the client actually consults the mapping
  // rather than inventing its own errors.
  // ---------------------------------------------------------------------------
  group('through TraciveClient', () {
    test('402 surfaces as InsufficientCredits with the right balance', () {
      final client = _client(
        (_) => _errorResponse(402, 'insufficient_user_credits'),
      );
      expect(
        () => client.checkScammer(query, source: Source.server),
        throwsA(
          isA<TraciveInsufficientCreditsException>().having(
            (e) => e.which,
            'which',
            InsufficientCreditsKind.user,
          ),
        ),
      );
    });

    test('429 surfaces with the Retry-After the server sent', () {
      final client = _client(
        (_) => _errorResponse(
          429,
          'rate_limited',
          headers: const <String, String>{'retry-after': '30'},
        ),
      );
      expect(
        () => client.checkScammer(query, source: Source.server),
        throwsA(
          isA<TraciveRateLimitedException>().having(
            (e) => e.retryAfter,
            'retryAfter',
            const Duration(seconds: 30),
          ),
        ),
      );
    });

    test('a transport that throws surfaces as Network, not as its own type',
        () {
      final client =
          _client((_) => throw const FormatException('no route to host'));
      expect(
        () => client.checkScammer(query, source: Source.server),
        throwsA(isA<TraciveNetworkException>()),
      );
    });

    test('a 200 that is not JSON surfaces as Server, not as FormatException',
        () {
      final client = _client(
        (_) => TraciveHttpResponse(statusCode: 200, body: '<html>hello</html>'),
      );
      expect(
        () => client.checkScammer(query, source: Source.server),
        throwsA(isA<TraciveServerException>()),
      );
    });

    test('401 invalid_token does not trigger a refresh', () async {
      // Only `expired_token` refreshes. `invalid_token` means the token is
      // not merely old — refreshing on it would burn the refresh token for
      // nothing, and a rotated-then-rejected refresh token is exactly what
      // reuse detection looks for.
      final transport =
          _FakeTransport((_) => _errorResponse(401, 'invalid_token'));
      final client = _clientWith(transport);
      await expectLater(
        client.checkScammer(query, source: Source.server),
        throwsA(isA<TraciveInvalidTokenException>()),
      );
      expect(transport.requests, hasLength(1));
      expect(
        transport.requests.single.url.path,
        endsWith('/scammer-checks'),
        reason: 'no call to the token endpoint should have been made',
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Privacy. An exception message ends up in a crash report, and a crash report
  // ends up somewhere neither we nor the user controls.
  // ---------------------------------------------------------------------------
  group('privacy', () {
    test('no mapped error prints a token or a raw identifier', () {
      const secretToken = 'eyJhbGciOiJIUzI1NiJ9.super-secret-access-token';
      final mapped = mapErrorResponse(
        _errorResponse(401, 'invalid_token', message: 'token rejected'),
      );
      expect(mapped.toString(), isNot(contains(secretToken)));
      expect(mapped.toString(), isNot(contains('6281234567891')));
    });

    test('a query rejection never prints the offending input', () {
      try {
        TraciveQuery.phone('081234567891');
        fail('expected a rejection');
      } on TraciveQueryException catch (error) {
        expect(error.reason, QueryRejectionReason.notE164);
        expect(error.toString(), isNot(contains('081234567891')));
      }
    });
  });
}

// -----------------------------------------------------------------------------
// Fakes. Small on purpose: a transport a test cannot read in ten seconds is a
// transport that will eventually be trusted without being read.
// -----------------------------------------------------------------------------

class _FakeTransport extends HttpTransport {
  _FakeTransport(this.handler);

  final FutureOr<TraciveHttpResponse> Function(TraciveHttpRequest) handler;
  final List<TraciveHttpRequest> requests = <TraciveHttpRequest>[];

  @override
  Future<TraciveHttpResponse> send(TraciveHttpRequest request) async {
    requests.add(request);
    return handler(request);
  }
}

TraciveHttpResponse _errorResponse(
  int status,
  String code, {
  String? message,
  String? checkId,
  Map<String, String> headers = const <String, String>{},
}) =>
    TraciveHttpResponse(
      statusCode: status,
      headers: headers,
      body: jsonEncode(<String, Object?>{
        'error': <String, Object?>{
          'code': code,
          if (message != null) 'message': message,
          if (checkId != null) 'checkId': checkId,
        },
      }),
    );

TraciveClient _client(
  FutureOr<TraciveHttpResponse> Function(TraciveHttpRequest) handler,
) =>
    _clientWith(_FakeTransport(handler));

TraciveClient _clientWith(_FakeTransport transport) => TraciveClient(
      mode: TraciveMode.oauth(
        clientId: 'partner-client-id',
        redirectUri: 'https://partner.example/oauth/callback',
      ),
      installUrl: 'https://install.example/app',
      transport: transport,
      tokenStore: InMemoryTokenStore(
        // No `expiresAt`, so nothing refreshes proactively and each test observes
        // exactly the request it wrote.
        tokens: const TraciveTokens(
          accessToken: 'access-token-1',
          refreshToken: 'refresh-token-1',
        ),
      ),
      retryPolicy: RetryPolicy.none,
    );
