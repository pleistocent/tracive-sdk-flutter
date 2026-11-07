// Copyright 2026 PT Pleistocent Teknologi Nusantara.
// Licensed under the Apache License, Version 2.0.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tracive_sdk/tracive_sdk.dart';
import 'package:tracive_sdk_extended/tracive_sdk_extended.dart';

import 'fake_native.dart';

// Long enough for a real answer, short enough that a hang fails here rather
// than at the runner's ten-minute limit.
const Duration _noHang = Duration(seconds: 2);

final Uint8List _bytes = Uint8List.fromList(<int>[1, 2, 3]);

const Map<String, Object?> _requirements = <String, Object?>{
  'enabled': true,
  'remainingToday': 2,
  'limits': <String, Object?>{
    'titleMaxLength': 50,
    'chronologyMinLength': 50,
    'chronologyMaxLength': 2000,
    'commentMaxLength': 150,
    'maxIdentifiers': 10,
    'attachmentsPerIdentifier': 5,
    'extraAttachmentsWithPhone': 5,
    'maxAttachmentBytes': 1048575,
    'attachmentTypes': <String>['image/avif'],
  },
  'terms': <Map<String, String>>[
    <String, String>{
      'id': 'TERMS_OF_SERVICE',
      'version': 'v1.1',
      'url': 'https://tracive.id/terms',
    },
  ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeNative native;

  setUp(() => native = FakeNative());
  tearDown(() => native.close());

  TraciveReports reportsWith(ReportAccessToken tokens) =>
      TraciveReports.withTokens(
        environment: TraciveEnvironment.sandbox,
        accessToken: tokens,
      );

  Future<String> ask(String? stale, {int reports = 1}) async =>
      await native.callDart('accessToken', <String, Object?>{
        'reports': reports,
        'stale': stale,
      }).timeout(_noHang) as String;

  Future<int> start(TraciveReports reports) async {
    native.answers['requirements'] = (_) => _requirements;
    await reports.requirements();
    final created = native.named('create').length;
    return created;
  }

  ReportDraft draftWith(List<PreparedEvidence> evidence) => ReportDraft(
        identifiers: const <String>['BANK_IDN_BCA_1'],
        title: 'Title',
        chronology: 'c' * 50,
        incidentDate: '2026-11-05',
        evidence: evidence,
        acceptedTerms: const <RequiredTerm>[
          RequiredTerm(id: 'TERMS_OF_SERVICE', version: 'v1.1', url: 'u'),
        ],
      );

  Map<Object?, Object?> submitted(String id) => <Object?, Object?>{
        'outcome': 'submitted',
        'reportId': id,
        'status': 'SUBMITTED',
      };

  group('tokens', () {
    test('native gets the token, and stale reaches the callback', () async {
      final seen = <String?>[];
      final reports = reportsWith((stale) async {
        seen.add(stale);
        return stale == null ? 'first' : 'fresh';
      });
      await start(reports);

      expect(await ask(null), 'first');
      expect(await ask('first'), 'fresh');
      expect(seen, <String?>[null, 'first']);
    });

    test('a client refreshes through its single flight', () async {
      var refreshes = 0;
      final gate = Completer<void>();
      final client = TraciveClient(
        mode: TraciveMode.oauth(
          clientId: 'client',
          redirectUri: 'scheme://oauth/callback',
          partnerUserId: 'user',
        ),
        environment: TraciveEnvironment.sandbox,
        tokenStore: InMemoryTokenStore(
          tokens: const TraciveTokens(
            accessToken: 'stale',
            refreshToken: 'refresh',
          ),
        ),
        transport: _TokenEndpoint(() async {
          refreshes++;
          await gate.future;
        }),
      );
      final reports = TraciveReports(client: client);
      await start(reports);

      final first = ask('stale');
      final second = ask('stale');
      final third = ask('stale');
      await pumpEventQueue();
      gate.complete();

      expect(await Future.wait(<Future<String>>[first, second, third]),
          <String>['new', 'new', 'new']);
      expect(refreshes, 1);
      client.close();
    });

    test('a partner callback is joined while it runs', () async {
      var asked = 0;
      final gate = Completer<String>();
      final reports = reportsWith((_) {
        asked++;
        return gate.future;
      });
      await start(reports);

      final first = ask('stale');
      final second = ask('stale');
      await pumpEventQueue();
      gate.complete('fresh');

      expect(await first, 'fresh');
      expect(await second, 'fresh');
      expect(asked, 1);
    });

    test('a flight that ended does not answer the next request', () async {
      var asked = 0;
      final reports = reportsWith((_) async => 'token-${++asked}');
      await start(reports);

      expect(await ask('stale'), 'token-1');
      expect(await ask('stale'), 'token-2');
    });

    for (final (name, failure) in <(String, Object)>[
      ('no grant', const TraciveInvalidTokenException('x', statusCode: 401)),
      ('expired', const TraciveExpiredTokenException('x', statusCode: 401)),
      ('revoked', const TraciveGrantRevokedException('x', statusCode: 401)),
      ('missing scope', const TraciveMissingScopeException('x')),
      (
        'a partner saying so',
        const TraciveReportException(ReportErrorCode.needsConsent, 'x'),
      ),
    ]) {
      test('$name becomes needs-consent on the native side', () async {
        final reports = reportsWith((_) async => throw failure);
        await start(reports);

        await expectLater(
          ask('stale'),
          throwsA(
            isA<PlatformException>().having(
              (e) => e.code,
              'code',
              'NEEDS_CONSENT',
            ),
          ),
        );
      });
    }

    test('a refused client grant reaches native as needs-consent', () async {
      final client = TraciveClient(
        mode: TraciveMode.oauth(
          clientId: 'client',
          redirectUri: 'scheme://oauth/callback',
          partnerUserId: 'user',
        ),
        environment: TraciveEnvironment.sandbox,
        tokenStore: InMemoryTokenStore(),
      );
      final reports = TraciveReports(client: client);
      await start(reports);

      await expectLater(
        ask(null),
        throwsA(
          isA<PlatformException>().having(
            (e) => e.code,
            'code',
            'NEEDS_CONSENT',
          ),
        ),
      );
      client.close();
    });

    test('a network failure stays a network failure', () async {
      final reports = reportsWith(
        (_) async => throw TraciveNetworkException(StateError('offline')),
      );
      await start(reports);

      await expectLater(
        ask('stale'),
        throwsA(
          isA<PlatformException>().having((e) => e.code, 'code', 'NETWORK'),
        ),
      );
    });

    test('anything else is a server failure, with no text of its own',
        () async {
      final reports = reportsWith(
        (_) async => throw StateError('account 1234567890'),
      );
      await start(reports);

      await expectLater(
        ask('stale'),
        throwsA(
          isA<PlatformException>()
              .having((e) => e.code, 'code', 'SERVER')
              .having((e) => e.message, 'message', isNot(contains('1234'))),
        ),
      );
    });

    test('a client without OAuth is refused', () {
      final client = TraciveClient(
        mode: TraciveMode.proxy(baseUrl: 'https://proxy.example.com'),
      );
      expect(() => TraciveReports(client: client), throwsArgumentError);
      client.close();
    });
  });

  group('errors', () {
    for (final code in ReportErrorCode.values) {
      test('${code.wire} maps to its code', () async {
        final reports = reportsWith((_) async => 'token');
        native.answers['status'] = (_) => throw PlatformException(
              code: code.wire,
              message: 'message',
              details: <String, Object?>{
                'httpStatus': 429,
                'retryAfterSeconds': 3600,
              },
            );

        await expectLater(
          reports.status('r'),
          throwsA(
            isA<TraciveReportException>()
                .having((e) => e.code, 'code', code)
                .having((e) => e.message, 'message', 'message')
                .having((e) => e.httpStatus, 'httpStatus', 429)
                .having((e) => e.retryAfterSeconds, 'retryAfter', 3600),
          ),
        );
      });
    }

    test('an unknown code is a server failure', () {
      expect(ReportErrorCode.fromWire('NEW_ONE'), ReportErrorCode.server);
      expect(ReportStatus.fromWire('NEW_ONE'), ReportStatus.inReview);
    });
  });

  test('requirements cross whole', () async {
    final reports = reportsWith((_) async => 'token');
    native.answers['requirements'] = (_) => _requirements;

    final requirements = await reports.requirements();

    expect(requirements.enabled, isTrue);
    expect(requirements.remainingToday, 2);
    expect(requirements.limits.chronologyMaxLength, 2000);
    expect(requirements.limits.maxAttachmentBytes, 1048575);
    expect(requirements.limits.attachmentTypes, <String>['image/avif']);
    expect(requirements.terms.single.version, 'v1.1');
  });

  test('status and the native core are shared across calls', () async {
    final reports = reportsWith((_) async => 'token');
    native.answers['status'] = (_) => 'NEED_REVISION';

    expect(await reports.status('r'), ReportStatus.needRevision);
    expect(await reports.status('r'), ReportStatus.needRevision);
    expect(native.named('create'), hasLength(1));
    expect(native.named('create').single.arguments, <String, Object?>{
      'baseUrl': TraciveEnvironment.sandbox.baseUrl,
      'appUrlScheme': 'tracivesandbox',
    });
  });

  group('submit', () {
    test('sends the draft, and its key, once', () async {
      final reports = reportsWith((_) async => 'token');
      final evidence = await reports.prepare(_bytes, mimeType: 'image/png');
      final draft = draftWith(<PreparedEvidence>[evidence]);
      native.answers['submit'] = (_) => submitted('r1');

      final result = await reports.submit(draft).timeout(_noHang);

      expect(result, isA<ReportSubmitted>());
      expect((result as ReportSubmitted).reportId, 'r1');
      expect(result.status, ReportStatus.submitted);
      final sent = native.named('submit').single.arguments as Map;
      expect(sent['key'], draft.idempotencyKey);
      expect(sent['evidence'], <int>[evidence.handle]);
      expect(sent['incidentDate'], '2026-11-05');
    });

    test('a double tap makes one native call', () async {
      final reports = reportsWith((_) async => 'token');
      final evidence = await reports.prepare(_bytes, mimeType: 'image/png');
      final draft = draftWith(<PreparedEvidence>[evidence]);
      final gate = Completer<Object?>();
      native.answers['submit'] = (_) => gate.future;

      final first = reports.submit(draft);
      final second = reports.submit(draft);
      await pumpEventQueue();
      gate.complete(submitted('r1'));

      expect(await first.timeout(_noHang), isA<ReportSubmitted>());
      expect(await second.timeout(_noHang), isA<ReportSubmitted>());
      expect(native.named('submit'), hasLength(1));
    });

    test('a retry after a failure keeps the key and the evidence', () async {
      final reports = reportsWith((_) async => 'token');
      final evidence = await reports.prepare(_bytes, mimeType: 'image/png');
      final draft = draftWith(<PreparedEvidence>[evidence]);
      native.answers['submit'] =
          (_) => throw PlatformException(code: 'NETWORK', message: 'offline');

      final failed = await reports.submit(draft).timeout(_noHang);

      expect(
        (failed as ReportFailed).error.code,
        ReportErrorCode.network,
      );
      expect(evidence.isReleased, isFalse);

      native.answers['submit'] = (_) => submitted('r1');
      expect(await reports.submit(draft), isA<ReportSubmitted>());
      final keys = native
          .named('submit')
          .map((call) => (call.arguments as Map)['key'])
          .toSet();
      expect(keys, <Object?>{draft.idempotencyKey});
    });

    test('a draft already filed answers without native', () async {
      final reports = reportsWith((_) async => 'token');
      final draft = draftWith(<PreparedEvidence>[
        await reports.prepare(_bytes, mimeType: 'image/png'),
      ]);
      native.answers['submit'] = (_) => submitted('r1');

      await reports.submit(draft);
      final again = await reports.submit(draft);

      expect((again as ReportSubmitted).reportId, 'r1');
      expect(native.named('submit'), hasLength(1));
    });

    test('needs-consent keeps the evidence for the retry', () async {
      final reports = reportsWith((_) async => 'token');
      final evidence = await reports.prepare(_bytes, mimeType: 'image/png');
      native.answers['submit'] = (_) => <Object?, Object?>{
            'outcome': 'needsConsent',
          };

      final result = await reports.submit(draftWith(<PreparedEvidence>[
        evidence,
      ]));

      expect(result, isA<ReportNeedsConsent>());
      expect(evidence.isReleased, isFalse);
      expect(native.named('releaseEvidence'), isEmpty);
    });

    test('a thrown needs-consent is the same outcome', () async {
      final reports = reportsWith((_) async => 'token');
      final draft = draftWith(<PreparedEvidence>[
        await reports.prepare(_bytes, mimeType: 'image/png'),
      ]);
      native.answers['submit'] =
          (_) => throw PlatformException(code: 'NEEDS_CONSENT');

      expect(await reports.submit(draft), isA<ReportNeedsConsent>());
    });

    test('progress reaches the caller for its own draft only', () async {
      final reports = reportsWith((_) async => 'token');
      final draft = draftWith(<PreparedEvidence>[
        await reports.prepare(_bytes, mimeType: 'image/png'),
      ]);
      final gate = Completer<Object?>();
      native.answers['submit'] = (_) => gate.future;
      final fractions = <double>[];

      final result = reports.submit(draft, onProgress: fractions.add);
      await pumpEventQueue();
      await native.callDart('progress', <String, Object?>{
        'key': draft.idempotencyKey,
        'fraction': 0.5,
      });
      await native.callDart('progress', <String, Object?>{
        'key': 'another draft',
        'fraction': 0.9,
      });
      gate.complete(submitted('r1'));
      await result;
      await native.callDart('progress', <String, Object?>{
        'key': draft.idempotencyKey,
        'fraction': 1.0,
      });

      expect(fractions, <double>[0.5]);
    });

    test('cancelling stops the native job, and the draft can resend', () async {
      final reports = reportsWith((_) async => 'token');
      final draft = draftWith(<PreparedEvidence>[
        await reports.prepare(_bytes, mimeType: 'image/png'),
      ]);
      final gate = Completer<Object?>();
      native.answers['submit'] = (_) => gate.future;
      native.answers['cancelSubmit'] = (_) {
        gate.completeError(
          PlatformException(code: 'CANCELLED', message: 'cancelled'),
        );
        return null;
      };

      final result = reports.submit(draft);
      await pumpEventQueue();
      await reports.cancelSubmit(draft);

      expect(
        ((await result.timeout(_noHang)) as ReportFailed).error.code,
        ReportErrorCode.cancelled,
      );
      expect(
        (native.named('cancelSubmit').single.arguments as Map)['key'],
        draft.idempotencyKey,
      );

      native.answers['submit'] = (_) => submitted('r1');
      expect(await reports.submit(draft), isA<ReportSubmitted>());
    });

    test('cancelling with nothing running asks native nothing', () async {
      final reports = reportsWith((_) async => 'token');
      final draft = draftWith(<PreparedEvidence>[
        await reports.prepare(_bytes, mimeType: 'image/png'),
      ]);

      await reports.cancelSubmit(draft);

      expect(native.named('cancelSubmit'), isEmpty);
    });
  });

  group('evidence handles', () {
    test('bytes cross once, and only on prepare', () async {
      final reports = reportsWith((_) async => 'token');
      final evidence = await reports.prepare(_bytes, mimeType: 'image/png');
      native.answers['submit'] = (_) => submitted('r1');

      await reports.submit(draftWith(<PreparedEvidence>[evidence]));

      expect(evidence.mimeType, 'image/avif');
      expect(evidence.byteCount, 1234);
      expect(
          (native.named('prepare').single.arguments as Map)['bytes'], _bytes);
      expect(
        (native.named('submit').single.arguments as Map).values,
        isNot(contains(_bytes)),
      );
    });

    test('a filed report releases its evidence', () async {
      final reports = reportsWith((_) async => 'token');
      final evidence = await reports.prepare(_bytes, mimeType: 'image/png');
      native.answers['submit'] = (_) => submitted('r1');

      await reports.submit(draftWith(<PreparedEvidence>[evidence]));

      expect(evidence.isReleased, isTrue);
      expect(
        (native.named('releaseEvidence').single.arguments as Map)['evidence'],
        evidence.handle,
      );
    });

    test('dispose on a file releases it once', () async {
      final reports = reportsWith((_) async => 'token');
      final evidence = await reports.prepare(_bytes, mimeType: 'image/png');

      await evidence.dispose();
      await evidence.dispose();

      expect(native.named('releaseEvidence'), hasLength(1));
    });

    test('a draft holding released evidence is refused', () async {
      final reports = reportsWith((_) async => 'token');
      final evidence = await reports.prepare(_bytes, mimeType: 'image/png');
      await evidence.dispose();

      await expectLater(
        reports.submit(draftWith(<PreparedEvidence>[evidence])),
        throwsStateError,
      );
      expect(native.named('submit'), isEmpty);
    });

    test('dispose releases the native core and its evidence', () async {
      final reports = reportsWith((_) async => 'token');
      final evidence = await reports.prepare(_bytes, mimeType: 'image/png');

      await reports.dispose();
      await reports.dispose();

      expect(evidence.isReleased, isTrue);
      expect(native.named('dispose'), hasLength(1));
      expect(() => reports.requirements(), throwsStateError);
    });
  });

  group('screens', () {
    final prefill = ReportPrefill.forQuery(
      TraciveQuery.bankAccount(
        countryAlpha3: 'IDN',
        bankCode: 'BCA',
        account: '1234567890',
      ),
      incidentDate: DateTime(2026, 11, 5),
      title: 'Title',
      attachments: <ReportAttachment>[
        ReportAttachment.image(_bytes, 'image/png'),
      ],
    );

    test('the form sends the prefill and the theme', () async {
      final reports = reportsWith((_) async => 'token');
      native.answers['presentForm'] = (_) => <Object?, Object?>{
            'outcome': 'submitted',
            'reportId': 'r1',
            'status': 'IN_REVIEW',
          };

      final outcome = await TraciveReportForm.present(
        reports,
        prefill: prefill,
        theme: const TraciveReportTheme(
          primaryColor: Color(0xFF00695C),
          cornerRadius: 16,
        ),
      );

      final sent = native.named('presentForm').single.arguments as Map;
      expect(sent['identifiers'], prefill.identifiers);
      expect(sent['incidentDate'], '2026-11-05');
      expect(sent['title'], 'Title');
      expect(sent['primaryColor'], 0xFF00695C);
      expect(sent['cornerRadius'], 16);
      expect(((sent['attachments'] as List).single as Map)['mimeType'],
          'image/png');
      expect((outcome as ReportFormSubmitted).reportId, 'r1');
      expect(outcome.status, ReportStatus.inReview);
    });

    test('each form outcome maps', () async {
      final reports = reportsWith((_) async => 'token');
      native.answers['presentForm'] = (_) => <Object?, Object?>{
            'outcome': 'needsConsent',
          };
      expect(
        await TraciveReportForm.present(reports, prefill: prefill),
        isA<ReportFormNeedsConsent>(),
      );

      native.answers['presentForm'] = (_) => <Object?, Object?>{
            'outcome': 'cancelled',
          };
      expect(
        await TraciveReportForm.present(reports, prefill: prefill),
        isA<ReportFormUserCancelled>(),
      );
    });

    test('a double tap opens one form', () async {
      final reports = reportsWith((_) async => 'token');
      final gate = Completer<Object?>();
      native.answers['presentForm'] = (_) => gate.future;

      final first = TraciveReportForm.present(reports, prefill: prefill);
      final second = TraciveReportForm.present(reports, prefill: prefill);
      await pumpEventQueue();
      gate.complete(<Object?, Object?>{'outcome': 'cancelled'});
      await first;
      await second;

      expect(native.named('presentForm'), hasLength(1));
    });

    test('the status screen says how it ended', () async {
      final reports = reportsWith((_) async => 'token');
      native.answers['presentStatus'] = (_) => 'needsConsent';
      expect(
        await TraciveReportStatus.present(reports, 'r1'),
        ReportStatusOutcome.needsConsent,
      );
      native.answers['presentStatus'] = (_) => 'closed';
      expect(
        await TraciveReportStatus.present(reports, 'r1'),
        ReportStatusOutcome.closed,
      );
    });

    test('a prefill with no identifier is refused', () {
      expect(
        () => ReportPrefill(identifiers: const <String>[]),
        throwsArgumentError,
      );
    });
  });
}

/// Answers the refresh with one new token pair.
final class _TokenEndpoint extends HttpTransport {
  _TokenEndpoint(this._onRefresh);

  final Future<void> Function() _onRefresh;

  @override
  Future<TraciveHttpResponse> send(TraciveHttpRequest request) async {
    await _onRefresh();
    return TraciveHttpResponse(
      statusCode: 200,
      body: '{"access_token":"new","refresh_token":"rotated",'
          '"token_type":"Bearer","expires_in":3600}',
    );
  }
}
