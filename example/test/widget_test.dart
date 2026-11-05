// Copyright 2026 PT Pleistocent Teknologi Nusantara.
// Licensed under the Apache License, Version 2.0.
//
// Widget tests for the example app.
//
// NO NETWORK. With no `--flavor` the app is the demo flavor, which injects
// `DemoBackend` as the client's transport, so these tests exercise the real SDK
// decode path with nothing listening on a socket.
// That is the same seam a host app would use for its own widget tests, which is
// half of why the example is written this way.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tracive_sdk/tracive_sdk.dart';
import 'package:tracive_sdk_example/main.dart';
import 'package:tracive_sdk_example/report_demo.dart';

/// Mounts the app on a viewport tall enough to render the whole screen.
///
/// The screen is a `ListView`, which builds lazily: on the default 800x600 test
/// surface the result card is never laid out, so a finder would report "not
/// found" for content the app renders perfectly well. Enlarging the surface is
/// what makes these assertions test the app rather than the scroll position.
Future<void> _pumpApp(WidgetTester tester) async {
  tester.view
    ..physicalSize = const Size(1200, 3200)
    ..devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(const TraciveExampleApp());
}

/// Taps Check and waits out `DemoBackend`'s simulated latency.
Future<void> _tapCheck(WidgetTester tester) async {
  await tester.tap(find.text('Check'));
  await tester.pump(); // start the future
  await tester.pump(const Duration(seconds: 1)); // clear the fake's latency
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('states up front that the demo answers from a fake', (
    tester,
  ) async {
    await _pumpApp(tester);

    expect(find.textContaining('Demo flavor'), findsOneWidget);
    expect(find.textContaining('DemoBackend'), findsOneWidget);
    expect(find.text('Backend calls this session: 0'), findsOneWidget);
    // The live flavors' OAuth controls are not the demo's: it is pre-seeded.
    expect(find.text('Authorize'), findsNothing);
  });

  testWidgets('a check shows a verdict, the folded key and the disclaimer', (
    tester,
  ) async {
    await _pumpApp(tester);
    await _tapCheck(tester);

    // The grammar folded '+62 812-3456-7891' before anything was sent.
    expect(
      find.textContaining('PHONE_+6281234567891'),
      findsOneWidget,
      reason: 'the folded key is what goes on the wire and into the cache',
    );

    // Any UI built on the SDK is required to surface the disclaimer.
    expect(find.textContaining('user-submitted reports'), findsOneWidget);

    expect(find.text('Backend calls this session: 1'), findsOneWidget);
  });

  testWidgets('a second identical check is served from cache, not the network',
      (
    tester,
  ) async {
    await _pumpApp(tester);
    await _tapCheck(tester);
    await _tapCheck(tester);

    expect(
      find.text('Backend calls this session: 1'),
      findsOneWidget,
      reason: 'the cache hit cost zero credits and did no network I/O',
    );
    expect(find.widgetWithText(Chip, 'CACHE'), findsOneWidget);
  });

  testWidgets('an invalid number is rejected before any call is made', (
    tester,
  ) async {
    await _pumpApp(tester);

    await tester.enterText(find.byType(TextField), 'not-a-phone-number');
    await tester.tap(find.text('Check'));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text('Invalid input'), findsOneWidget);
    expect(find.textContaining('not_e164'), findsOneWidget);
    expect(
      find.text('Backend calls this session: 0'),
      findsOneWidget,
      reason: 'validation runs before the network — a miss is billed',
    );
  });

  testWidgets('source: cache with an empty cache is an error, not "safe"', (
    tester,
  ) async {
    await _pumpApp(tester);

    await tester.tap(find.text('cache'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Check'));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text('Cache miss'), findsOneWidget);
    expect(find.text('Backend calls this session: 0'), findsOneWidget);
  });

  group('the mock transaction detail', () {
    final transaction = MockTransaction(
      amount: 'Rp 2.500.000',
      date: DateTime(2026, 11, 3),
      bankCode: 'BCA',
      account: '1234567890',
      recipientName: 'Toko Gadget Murah',
    );

    Future<_RecordingPlatform> report(
      WidgetTester tester, {
      String? target,
    }) async {
      final platform = _RecordingPlatform();
      final client = TraciveClient(
        mode: TraciveMode.oauth(
          partnerUserId: 'partner-user-1',
          clientId: 'demo-client',
          redirectUri: 'tracive-flutter-demo://oauth/callback',
        ),
        cache: CheckCache.inMemory(),
        tokenStore: InMemoryTokenStore(),
        reportFormLauncher: platform,
      );
      tester.view
        ..physicalSize = const Size(1200, 2400)
        ..devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(
        home: TransactionDetailScreen(client: client, transaction: transaction),
      ));
      if (target != null) {
        await tester.tap(find.text(target));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text('Report'));
      // The receipt PNG is rendered by the engine, which answers in real time,
      // not on the test's fake clock: give it real time, then flush.
      for (var i = 0; i < 200 && !platform.handedOver.isCompleted; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      await tester.pumpAndSettle();
      return platform;
    }

    testWidgets(
        'Report hands the account, the date and two receipts to the '
        'sandbox build by default', (tester) async {
      final platform = await report(tester);

      expect(platform.target, ReportFormTarget.sandbox);
      final package =
          jsonDecode(utf8.decode(platform.package!)) as Map<String, Object?>;
      expect(package['query'], 'BANK_IDN_BCA_1234567890');
      expect(package['incidentDate'], '2026-11-03');
      expect(
        (package['attachments']! as List<Object?>)
            .map((a) => (a! as Map<String, Object?>)['mimeType']),
        <String>['image/png', 'application/pdf'],
      );
      expect(find.textContaining('the date and the receipt'), findsOneWidget);
    });

    testWidgets('the QA target reaches the dev build', (tester) async {
      final platform = await report(tester, target: 'Dev build (QA)');

      expect(platform.target?.androidPackage, 'com.pleistocent.tracive.dev');
      expect(platform.target?.fileExtension, 'tracivedevreport');
    });

    test('the generated PDF is one the report form accepts', () {
      final pdf = receiptPdf(transaction.receiptLines);
      expect(ascii.decode(pdf.sublist(0, 5)), '%PDF-');
      expect(pdf.length, lessThan(1048576));
      final text = ascii.decode(pdf);
      final xref = int.parse(
        RegExp(r'startxref\n(\d+)').firstMatch(text)!.group(1)!,
      );
      expect(text.substring(xref, xref + 4), 'xref',
          reason: 'startxref must point at the table');
    });
  });
}

class _RecordingPlatform extends ReportFormLauncher {
  final Completer<void> handedOver = Completer<void>();
  ReportFormTarget? target;
  Uint8List? package;

  @override
  Future<ReportHandoff> handOver(
    ReportFormTarget target,
    Uint8List package, {
    ReportFormAnchor? anchor,
  }) async {
    this.target = target;
    this.package = package;
    handedOver.complete();
    return const ReportHandoff.started();
  }

  @override
  Future<bool> isInstalled(ReportFormTarget target) async => true;

  @override
  Future<bool> openLink(ReportFormTarget target, Uri link) async => true;
}
