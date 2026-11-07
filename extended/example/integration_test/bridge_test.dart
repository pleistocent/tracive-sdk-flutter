// Copyright 2026 PT Pleistocent Teknologi Nusantara.
// Licensed under the Apache License, Version 2.0.

import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:tracive_sdk/tracive_sdk.dart';
import 'package:tracive_sdk_extended/tracive_sdk_extended.dart';
import 'package:tracive_sdk_extended_example/local_backend.dart';

/// The real native core, over the real channel, against a real socket. What
/// the fake channel in the package's own tests cannot reach lives here.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late LocalBackend backend;
  late TraciveReports reports;

  Future<Uint8List> png() async {
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawColor(const Color(0xFFB2DFDB), ui.BlendMode.src);
    final image = await recorder.endRecording().toImage(600, 800);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    return bytes!.buffer.asUint8List();
  }

  ReportDraft draftWith(
    List<PreparedEvidence> evidence,
    List<RequiredTerm> terms,
  ) =>
      ReportDraft(
        identifiers: const <String>['BANK_IDN_BCA_0000000001'],
        title: 'Integration test',
        chronology: 'c' * 60,
        incidentDate: '2026-11-05',
        evidence: evidence,
        acceptedTerms: terms,
        language: 'en',
      );

  setUp(() async {
    backend = await LocalBackend.start();
    reports = TraciveReports.withTokens(
      environment: TraciveEnvironment.custom(backend.baseUrl),
      accessToken: (_) async => backend.acceptedToken,
    );
  });

  tearDown(() async {
    await reports.dispose();
    await backend.close();
  });

  testWidgets('requirements cross from the server to Dart', (_) async {
    final requirements = await reports.requirements();

    expect(requirements.enabled, isTrue);
    expect(requirements.limits.chronologyMinLength, 50);
    expect(requirements.terms.map((t) => t.id), contains('PRIVACY_POLICY'));
  });

  testWidgets('prepare compresses to AVIF, and only native holds it',
      (_) async {
    final evidence = await reports.prepare(await png(), mimeType: 'image/png');

    expect(evidence.mimeType, 'image/avif');
    expect(evidence.byteCount, greaterThan(0));
    expect(evidence.byteCount, lessThanOrEqualTo(200 * 1024));
  });

  testWidgets('a PDF of 1 MiB is refused and 1 MiB minus 1 passes', (_) async {
    final pdf = Uint8List(1024 * 1024 - 1);
    pdf.setAll(0, '%PDF-1.4'.codeUnits);
    final passed = await reports.prepare(pdf, mimeType: 'application/pdf');
    expect(passed.byteCount, 1024 * 1024 - 1);

    await expectLater(
      reports.prepare(Uint8List(1024 * 1024), mimeType: 'application/pdf'),
      throwsA(
        isA<TraciveReportException>().having(
          (e) => e.code,
          'code',
          ReportErrorCode.fileTooLarge,
        ),
      ),
    );
  });

  testWidgets('a file that is neither image nor PDF is refused', (_) async {
    await expectLater(
      reports.prepare(Uint8List(8), mimeType: 'text/plain'),
      throwsA(
        isA<TraciveReportException>().having(
          (e) => e.code,
          'code',
          ReportErrorCode.unsupportedFile,
        ),
      ),
    );
  });

  testWidgets('submit files once, reports progress, releases the evidence',
      (_) async {
    final requirements = await reports.requirements();
    final evidence = await reports.prepare(await png(), mimeType: 'image/png');
    final draft = draftWith(<PreparedEvidence>[evidence], requirements.terms);
    final fractions = <double>[];

    final result = await reports.submit(draft, onProgress: fractions.add);

    expect((result as ReportSubmitted).status, ReportStatus.submitted);
    expect(backend.filedKeys, <String>[draft.idempotencyKey]);
    expect(backend.uploadedSizes, <int>[evidence.byteCount]);
    expect(fractions.last, 1.0);
    expect(evidence.isReleased, isTrue);

    final body = backend.filedBodies.single;
    expect(body['identifiers'], draft.identifiers);
    expect(body['language'], 'en');
    expect(body['acceptedTerms'], <String, Object?>{
      'TERMS_OF_SERVICE': 'v1.1',
      'PRIVACY_POLICY': 'v1.1',
    });
    expect((body['device'] as Map<String, Object?>)['installId'], isNotEmpty);

    expect(await reports.status(result.reportId), ReportStatus.inReview);
  });

  testWidgets('an expired token refreshes, and a burst of 401s joins one',
      (_) async {
    await reports.requirements();

    var refreshes = 0;
    final refreshed = TraciveReports.withTokens(
      environment: TraciveEnvironment.custom(backend.baseUrl),
      accessToken: (stale) async {
        if (stale == null) return 'expired';
        refreshes++;
        expect(stale, 'expired');
        await Future<void>.delayed(const Duration(milliseconds: 200));
        return backend.acceptedToken;
      },
    );
    addTearDown(refreshed.dispose);

    final answers = await Future.wait(
      List<Future<ReportRequirements>>.generate(
        6,
        (_) => refreshed.requirements(),
      ),
    );

    expect(answers, hasLength(6));
    expect(refreshes, 1);
  });

  testWidgets('a revoked grant ends in needs consent, keeping the draft',
      (_) async {
    final requirements = await reports.requirements();
    final evidence = await reports.prepare(await png(), mimeType: 'image/png');
    final draft = draftWith(<PreparedEvidence>[evidence], requirements.terms);
    backend.revoked = true;

    expect(await reports.submit(draft), isA<ReportNeedsConsent>());
    expect(evidence.isReleased, isFalse);

    backend.revoked = false;
    expect(await reports.submit(draft), isA<ReportSubmitted>());
    expect(backend.filedKeys, hasLength(1));
  });

  testWidgets('a token callback that says no grant ends in needs consent',
      (_) async {
    final refused = TraciveReports.withTokens(
      environment: TraciveEnvironment.custom(backend.baseUrl),
      accessToken: (_) async => throw const TraciveGrantRevokedException(
        'gone',
        statusCode: 401,
      ),
    );
    addTearDown(refused.dispose);

    await expectLater(
      refused.requirements(),
      throwsA(
        isA<TraciveReportException>().having(
          (e) => e.code,
          'code',
          ReportErrorCode.needsConsent,
        ),
      ),
    );
    expect(backend.calls, isEmpty);
  });

  testWidgets('cancelling stops the native upload, and a retry files once',
      (_) async {
    final requirements = await reports.requirements();
    final evidence = await reports.prepare(await png(), mimeType: 'image/png');
    final draft = draftWith(<PreparedEvidence>[evidence], requirements.terms);
    backend.uploadDelay = const Duration(seconds: 20);

    final running = reports.submit(draft);
    while (!backend.calls.containsKey('PUT /upload/0')) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    final started = DateTime.now();
    await reports.cancelSubmit(draft);
    final result = await running;

    expect((result as ReportFailed).error.code, ReportErrorCode.cancelled);
    expect(DateTime.now().difference(started).inSeconds, lessThan(5));
    expect(backend.filedKeys, isEmpty);

    backend.uploadDelay = Duration.zero;
    expect(await reports.submit(draft), isA<ReportSubmitted>());
    expect(backend.filedKeys, <String>[draft.idempotencyKey]);
  });

  testWidgets('dispose cancels what is running', (_) async {
    final requirements = await reports.requirements();
    final evidence = await reports.prepare(await png(), mimeType: 'image/png');
    backend.uploadDelay = const Duration(seconds: 20);

    final running = reports.submit(
      draftWith(<PreparedEvidence>[evidence], requirements.terms),
    );
    while (!backend.calls.containsKey('PUT /upload/0')) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await reports.dispose();

    expect(
      ((await running.timeout(const Duration(seconds: 5))) as ReportFailed)
          .error
          .code,
      ReportErrorCode.cancelled,
    );
    expect(backend.filedKeys, isEmpty);
  });

  // Dart refuses a released handle before native sees it, so this goes around
  // it on the raw channel: the bytes must really be gone.
  testWidgets('released evidence is gone from the native side', (_) async {
    const channel = MethodChannel('tracive_sdk_extended/reports');
    final native = await channel.invokeMethod<int>('create', <String, Object?>{
      'baseUrl': backend.baseUrl,
      'appUrlScheme': 'tracive',
    });
    addTearDown(
      () => channel.invokeMethod<void>('dispose', <String, Object?>{
        'reports': native,
      }),
    );
    final prepared = await channel.invokeMapMethod<String, Object?>(
      'prepare',
      <String, Object?>{
        'reports': native,
        'bytes': await png(),
        'mimeType': 'image/png',
      },
    );
    final evidence = prepared!['evidence'];
    await channel.invokeMethod<void>('releaseEvidence', <String, Object?>{
      'reports': native,
      'evidence': evidence,
    });

    await expectLater(
      channel.invokeMethod<void>('submit', <String, Object?>{
        'reports': native,
        'key': 'released',
        'identifiers': <String>['BANK_IDN_BCA_0000000001'],
        'title': 'Integration test',
        'chronology': 'c' * 60,
        'incidentDate': '2026-11-05',
        'evidence': <Object?>[evidence],
        'terms': <Map<String, String>>[],
      }),
      throwsA(
        isA<PlatformException>().having(
          (e) => e.code,
          'code',
          'ATTACHMENT_INVALID',
        ),
      ),
    );
    expect(backend.filedKeys, isEmpty);
  });
}
