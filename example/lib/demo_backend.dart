// Copyright 2026 PT Pleistocent Teknologi Nusantara.
// Licensed under the Apache License, Version 2.0.
//
// A fake Tracive backend, in-process.
//
// WHY THIS EXISTS. It is what the `demo` flavor talks to, so the example runs
// on a fresh clone with no credentials, nothing to reach and nothing to bill.
//
// It is also the honest way to show the SDK's headline testability property.
// `HttpTransport` is a one-method interface precisely so that a fake is short
// enough to read — this file is the fake a host app would write for its own
// widget tests, and the same trick works in yours.
//
// Nothing here claims to be the real API's behaviour. It answers the shapes in
// the check and error contracts, and it is deliberately crude about everything
// else.

import 'dart:convert';

// ignore_for_file: implementation_imports — see analysis_options.yaml.
import 'package:tracive_sdk/tracive_sdk.dart';

/// An in-process stand-in for the Tracive Open API.
///
/// Answers `POST /scammer-checks`, `GET /credits`, `GET /profile` and
/// `POST /oauth/token`. Every response is built from the request, so the
/// example exercises the real decode path in `CheckResult.fromJson` rather
/// than a hand-built object.
class DemoBackend extends HttpTransport {
  /// Creates a fake backend.
  ///
  /// [latency] makes the loading state visible; [failNextCall] arms a single
  /// failure so the error path can be demonstrated on demand.
  DemoBackend({this.latency = const Duration(milliseconds: 450)});

  /// Simulated round-trip time.
  final Duration latency;

  /// When set, the next call fails with this status and `error.code`, once.
  ({int status, String code})? failNextCall;

  /// How many calls have actually reached this fake. The example shows it, so
  /// a cache hit is visibly *not* a call.
  int callCount = 0;

  @override
  Future<TraciveHttpResponse> send(TraciveHttpRequest request) async {
    await Future<void>.delayed(latency);
    callCount++;

    final failure = failNextCall;
    if (failure != null) {
      failNextCall = null;
      return _json(failure.status, <String, Object?>{
        'error': <String, Object?>{
          'code': failure.code,
          'message': 'Simulated ${failure.code}',
          'checkId': 'chk_demo_error',
        },
      });
    }

    final path = request.url.path;
    if (path.endsWith('/oauth/token')) return _token();
    if (path.endsWith('/oauth/revoke')) return _json(200, <String, Object?>{});
    if (path.endsWith('/scammer-checks')) return _check(request);
    if (path.endsWith('/credits')) return _credits();
    if (path.endsWith('/profile')) return _profile();

    return _json(404, <String, Object?>{
      'error': <String, Object?>{
        'code': 'invalid_request',
        'message': 'The demo backend has no route for $path',
      },
    });
  }

  // ---------------------------------------------------------------------------

  /// A verdict derived from the folded key, so the same input always gives the
  /// same answer and different inputs give different ones.
  ///
  /// The rule is arbitrary on purpose — it is a demo, not a model. What it does
  /// preserve is the response field *shape*, including the `disclaimer` a host
  /// app is required to surface.
  TraciveHttpResponse _check(TraciveHttpRequest request) {
    final body = _decodeObject(request.body) ?? const <String, Object?>{};
    final query = body['query'];
    final wantsFullDetail = body['detail'] == 'full';
    final key = query is String ? query : '';

    // A stable pseudo-random bucket. `hashCode` is not stable across runs for
    // every type, but it is for String within a process, which is enough here.
    final bucket =
        key.isEmpty ? 0 : key.codeUnits.fold<int>(7, (a, b) => a + b) % 10;
    final (tier, reports) = switch (bucket) {
      0 || 1 => ('HIGH', 27),
      2 || 3 => ('ELEVATED', 9),
      4 || 5 => ('CAUTION', 3),
      _ => ('NONE', 0),
    };

    return _json(200, <String, Object?>{
      // `${bucket}` keeps its braces on purpose: `$bucket_` would parse the
      // trailing underscore as part of the identifier.
      'checkId': 'chk_demo_${bucket}_$callCount',
      'found': tier != 'NONE',
      'riskTier': tier,
      'reportTotal': reports,
      'credibleReports': (reports * 0.7).round(),
      'ambiguousReports': reports - (reports * 0.7).round(),
      if (reports > 0) 'firstReportOn': '2025-11',
      if (reports > 0) 'lastReportOn': '2026-07',
      'fraudAmount': reports > 0
          ? <String, Object?>{'IDR': reports * 1500000.0}
          : <String, Object?>{},
      'tags': reports > 0
          ? <Object?>['investment', 'social_engineering']
          : <Object?>[],
      'relatedScammerCount': reports > 0 ? 4 : 0,
      if (wantsFullDetail)
        'topChronologies': <Object?>[
          <String, Object?>{
            'chronology':
                'Promised 30% monthly returns, then stopped replying once '
                    'the transfer cleared.',
            'riskLevel': 3,
            'incidentDate': '2026-06',
          },
        ],
      if (wantsFullDetail)
        'comments': <Object?>[
          <String, Object?>{
            'date': '2026-06',
            'text': 'Took my deposit and blocked me.',
            'fromCredibleReport': true,
          },
        ],
      'billing': <String, Object?>{'creditSource': 'USER', 'unitsCharged': 1},
      'disclaimer':
          'These are user-submitted reports, not adjudicated findings. '
              'Verify independently before acting on them.',
      // A field this build has never heard of. It must be ignored,
      // not to be fatal — this is that requirement, exercised.
      'somethingFutureVersionAdded': <String, Object?>{'x': 1},
    });
  }

  TraciveHttpResponse _credits() => _json(200, <String, Object?>{
        'subscriptionCredits': 42,
        'tier': 'PRO',
        'nextResetAt': '2026-08-01T00:00:00Z',
      });

  TraciveHttpResponse _profile() => _json(200, <String, Object?>{
        'sub': 'usr_demo_0001',
        'name': 'Demo User',
        'country': 'IDN',
        'tier': 'PRO',
        'memberSince': '2025-03-11T00:00:00Z',
      });

  TraciveHttpResponse _token() => _json(200, <String, Object?>{
        'access_token': 'demo-access-token',
        'refresh_token': 'demo-refresh-token',
        'token_type': 'Bearer',
        'expires_in': 3600,
        'scope': 'scammer.check',
      });

  static Map<String, Object?>? _decodeObject(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, Object?> ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  static TraciveHttpResponse _json(int status, Map<String, Object?> body) =>
      TraciveHttpResponse(
        statusCode: status,
        headers: const <String, String>{
          'content-type': 'application/json; charset=utf-8',
        },
        body: jsonEncode(body),
      );
}
