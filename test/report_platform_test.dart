// Copyright 2026 PT Pleistocent Teknologi Nusantara.
// Licensed under the Apache License, Version 2.0.
//
// The report form's native boundary, from the Dart side.
//
// No device can run here, so the native halves are not executed. What can be
// checked is that Dart and native agree: the method channel's arguments and
// answers against a mocked messenger, the names the Kotlin and Swift sources
// read, and the Android manifest every host app inherits — the file banks audit.
//
// This file needs `dart:ui`, so it runs under `flutter test`.
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tracive_sdk/tracive_sdk.dart';
// ignore: implementation_imports
import 'package:tracive_sdk/src/report/report_platform_flutter.dart';

final String _kotlin = File(
  'android/src/main/kotlin/id/tracive/sdk/flutter/TraciveSdkPlugin.kt',
).readAsStringSync();
final String _kotlinStore = File(
  'android/src/main/kotlin/id/tracive/sdk/flutter/ReportPackageStore.kt',
).readAsStringSync();
final String _swift = File(
  'ios/tracive_sdk/Sources/tracive_sdk/TraciveSdkPlugin.swift',
).readAsStringSync();
final String _manifest =
    File('android/src/main/AndroidManifest.xml').readAsStringSync();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const launcher = MethodChannelReportFormLauncher();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  void answer(Object? Function(MethodCall call) handler) =>
      messenger.setMockMethodCallHandler(
        MethodChannelReportFormLauncher.channel,
        (call) async => handler(call),
      );

  tearDown(() => messenger.setMockMethodCallHandler(
        MethodChannelReportFormLauncher.channel,
        null,
      ));

  group('method channel', () {
    test('handOver sends the target, the bytes and the anchor', () async {
      MethodCall? seen;
      answer((call) {
        seen = call;
        return <String, Object?>{'outcome': 'started'};
      });

      final outcome = await launcher.handOver(
        ReportFormTarget.sandbox,
        Uint8List.fromList(<int>[1, 2, 3]),
        anchor: const ReportFormAnchor(left: 1, top: 2, width: 3, height: 4),
      );

      expect(outcome, const ReportHandoff.started());
      expect(seen!.method, 'handOver');
      expect(seen!.arguments, <String, Object?>{
        'androidPackage': 'com.pleistocent.tracive.sandbox',
        'capabilityScheme': 'tracivesandbox-report',
        'fileExtension': 'tracivesandboxreport',
        'mimeType': 'application/vnd.tracive.report+json',
        'package': Uint8List.fromList(<int>[1, 2, 3]),
        'anchor': <String, double>{
          'left': 1,
          'top': 2,
          'width': 3,
          'height': 4,
        },
      });
    });

    test('every native outcome maps to its handoff', () async {
      Future<ReportHandoff> outcomeFor(Map<String, Object?> reply) {
        answer((_) => reply);
        return launcher.handOver(ReportFormTarget.production, Uint8List(1));
      }

      expect(await outcomeFor(<String, Object?>{'outcome': 'started'}),
          const ReportHandoff.started());
      expect(
        await outcomeFor(
            <String, Object?>{'outcome': 'sentTo', 'bundleId': 'com.x.y'}),
        const ReportHandoff.sentTo('com.x.y'),
      );
      expect(await outcomeFor(<String, Object?>{'outcome': 'dismissed'}),
          const ReportHandoff.dismissed());
      expect(await outcomeFor(<String, Object?>{'outcome': 'notAccepted'}),
          const ReportHandoff.notAccepted());
    });

    test('isInstalled and openLink send what native reads', () async {
      final calls = <MethodCall>[];
      answer((call) {
        calls.add(call);
        return true;
      });

      expect(await launcher.isInstalled(ReportFormTarget.production), isTrue);
      expect(
        await launcher.openLink(
          ReportFormTarget.production,
          Uri.parse('tracive://report/create?media=PHONE_%2B62811'),
        ),
        isTrue,
      );

      expect(calls[0].arguments, <String, Object?>{
        'androidPackage': 'com.pleistocent.tracive',
        'appScheme': 'tracive',
      });
      expect(calls[1].arguments, <String, Object?>{
        'androidPackage': 'com.pleistocent.tracive',
        'link': 'tracive://report/create?media=PHONE_%2B62811',
      });
    });

    test('a native reason token reaches the caller; platform text does not',
        () async {
      answer((_) => throw PlatformException(code: 'busy', message: 'raw text'));
      final client = TraciveClient(
        mode: TraciveMode.proxy(baseUrl: 'https://proxy.example/v1'),
        transport: const _NoNetwork(),
        reportFormLauncher: launcher,
      );

      final result =
          await client.openReportForm(TraciveQuery.phone('+6281234567890'));

      expect(result,
          const ReportFormResult.failed(ReportFormPlatformFailure('busy')));
    });

    test('a build without the native half reports missing_plugin', () async {
      final client = TraciveClient(
        mode: TraciveMode.proxy(baseUrl: 'https://proxy.example/v1'),
        transport: const _NoNetwork(),
        reportFormLauncher: launcher,
      );

      final result =
          await client.openReportForm(TraciveQuery.phone('+6281234567890'));

      expect(
        result,
        const ReportFormResult.failed(
          ReportFormPlatformFailure('missing_plugin'),
        ),
      );
    });
  });

  group('native sources agree with Dart', () {
    test('both read every argument Dart sends, on the same channel', () {
      for (final source in <String>[_kotlin, _swift]) {
        expect(source, contains('"tracive_sdk/report_form"'));
        for (final method in <String>['handOver', 'isInstalled', 'openLink']) {
          expect(source, contains('"$method"'));
        }
      }
      for (final key in <String>[
        'androidPackage',
        'fileExtension',
        'mimeType',
        'package',
        'link',
      ]) {
        expect(_kotlin, contains('"$key"'), reason: 'Kotlin reads $key');
      }
      for (final key in <String>[
        'capabilityScheme',
        'fileExtension',
        'package',
        'anchor',
        'appScheme',
        'link',
        'left',
        'top',
        'width',
        'height',
      ]) {
        expect(_swift, contains('"$key"'), reason: 'Swift reads $key');
      }
    });

    test('both answer only with outcomes Dart maps', () {
      expect(_kotlin, contains('"outcome" to "started"'));
      expect(_kotlin, contains('"outcome" to "notAccepted"'));
      expect(_swift, contains('"outcome": "sentTo"'));
      expect(_swift, contains('"outcome": "dismissed"'));
      expect(_swift, contains('"outcome": "notAccepted"'));
    });
  });

  group('the Android manifest every host app inherits', () {
    final provider =
        RegExp(r'<provider\b[^>]*>', dotAll: true).firstMatch(_manifest)![0]!;

    test('the provider is the SDK subclass, never exported, granting per URI',
        () {
      expect(
          provider,
          contains(
              'android:name="id.tracive.sdk.flutter.TraciveFlutterFileProvider"'));
      expect(provider, contains('android:exported="false"'));
      expect(provider, contains('android:grantUriPermissions="true"'));
      expect(_manifest,
          isNot(contains('android:name="androidx.core.content.FileProvider"')));
    });

    test('its authority is the Flutter SDK\'s own, and the code uses it', () {
      expect(
          provider,
          contains(
              r'android:authorities="${applicationId}.tracive-flutter-files"'));
      expect(_kotlin, contains('AUTHORITY_SUFFIX = ".tracive-flutter-files"'));
    });

    test('it serves one cache folder, the one the plugin writes to', () {
      final paths = File(
        'android/src/main/res/xml/tracive_sdk_flutter_report_paths.xml',
      ).readAsStringSync();
      final entries = RegExp(r'<(\w+-path)\b[^>]*>').allMatches(paths).toList();

      expect(entries, hasLength(1));
      expect(entries.single[1], 'cache-path');
      expect(entries.single[0], contains('path="tracive-sdk/report/"'));
      expect(_kotlinStore, contains('DIRECTORY = "tracive-sdk/report"'));
    });

    test('no Tracive application id is written into a host manifest', () {
      expect(_manifest, isNot(matches(RegExp(r'<package\s'))));
    });
  });
}

class _NoNetwork extends HttpTransport {
  const _NoNetwork();

  @override
  Future<TraciveHttpResponse> send(TraciveHttpRequest request) =>
      throw StateError('openReportForm must not touch the network');
}
