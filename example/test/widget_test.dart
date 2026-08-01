// Copyright (c) Tracive. Licensed under the Apache License, Version 2.0.
//
// Widget tests for the example app.
//
// NO NETWORK. The app injects `DemoBackend` as the client's transport, so these
// tests exercise the real SDK decode path with nothing listening on a socket.
// That is the same seam a host app would use for its own widget tests, which is
// half of why the example is written this way.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tracive_sdk_example/main.dart';

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
  testWidgets('states up front that the backend is not live', (tester) async {
    await _pumpApp(tester);

    expect(find.textContaining('phase 1'), findsOneWidget);
    expect(find.textContaining('not live'), findsOneWidget);
    expect(find.text('Backend calls this session: 0'), findsOneWidget);
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
}
