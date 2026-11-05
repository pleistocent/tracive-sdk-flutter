// Copyright 2026 PT Pleistocent Teknologi Nusantara.
// Licensed under the Apache License, Version 2.0.
//
// `openReportForm`'s fallback chain, with the platform faked.
//
// NO DEVICE. Every native step goes to `_FakePlatform`, which records rather
// than opens, and the install link goes to `_FakeAuthLauncher`. The Android and
// iOS outcomes are both reachable here because the decisions are made in Dart;
// the native halves only report what happened.

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tracive_sdk/tracive_sdk.dart';
import 'package:tracive_sdk/src/report/report_form_flow.dart';

final TraciveQuery _phone = TraciveQuery.phone('+6281234567890');

final ReportAttachment _png = ReportAttachment.image(
  Uint8List.fromList(<int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1]),
  'image/png',
);

void main() {
  group('the target follows the environment', () {
    Future<ReportFormTarget> targetFor(TraciveEnvironment environment) async {
      final platform = _FakePlatform();
      await _client(platform, environment: environment).openReportForm(_phone);
      return platform.handedTo.single;
    }

    test('sandbox opens the sandbox build', () async {
      expect(await targetFor(TraciveEnvironment.sandbox),
          ReportFormTarget.sandbox);
    });

    test('production opens the production build', () async {
      expect(
        await targetFor(TraciveEnvironment.production),
        ReportFormTarget.production,
      );
    });

    test('a custom base URL opens the production build', () async {
      expect(
        await targetFor(TraciveEnvironment.custom('https://proxy.example/v1')),
        ReportFormTarget.production,
      );
    });

    test('an explicit target overrides it, link included', () async {
      final dev = ReportFormTarget(
        androidPackage: 'com.example.tracive.qa',
        iosBundleId: 'com.example.tracive.qa',
        appScheme: 'traciveqa',
        capabilityScheme: 'traciveqa-report',
        fileExtension: 'traciveqareport',
      );
      final platform =
          _FakePlatform(handoff: const ReportHandoff.notAccepted());

      final result =
          await _client(platform).openReportForm(_phone, target: dev);

      expect(
          result, const ReportFormResult.opened(attachmentsDelivered: false));
      expect(platform.handedTo.single, dev);
      expect(platform.linksOpened.single.toString(),
          'traciveqa://report/create?media=PHONE_%2B6281234567890');
    });
  });

  group('the fallback chain', () {
    test('a build that takes the package gets it, and nothing else is opened',
        () async {
      final platform = _FakePlatform();
      final auth = _FakeAuthLauncher();

      final result = await _client(platform, auth: auth).openReportForm(
        _phone,
        attachments: <ReportAttachment>[_png],
      );

      expect(result, const ReportFormResult.opened(attachmentsDelivered: true));
      expect(platform.calls, <String>['handOver']);
      expect(auth.opened, isEmpty);
    });

    test('an older build is opened on the link, in that build only', () async {
      final platform =
          _FakePlatform(handoff: const ReportHandoff.notAccepted());
      final auth = _FakeAuthLauncher();

      final result = await _client(platform, auth: auth).openReportForm(_phone);

      expect(
          result, const ReportFormResult.opened(attachmentsDelivered: false));
      expect(platform.calls, <String>['handOver', 'isInstalled', 'openLink']);
      expect(platform.linksOpened.single.toString(),
          'tracivesandbox://report/create?media=PHONE_%2B6281234567890');
      expect(platform.linkTargets.single, ReportFormTarget.sandbox);
      expect(auth.opened, isEmpty);
    });

    test('no app opens the clean install link and nothing else', () async {
      final platform = _FakePlatform(
        handoff: const ReportHandoff.notAccepted(),
        installed: false,
      );
      final auth = _FakeAuthLauncher();

      final result = await _client(platform, auth: auth).openReportForm(
        _phone,
        attachments: <ReportAttachment>[_png],
      );

      expect(result, const ReportFormResult.installPageOpened());
      expect(platform.calls, <String>['handOver', 'isInstalled']);
      final link = auth.opened.single;
      expect(link.replace(query: '').toString(),
          '${TraciveOAuth.defaultInstallUrl}?');
      expect(link.queryParameters, <String, String>{
        'ref': 'partner-client-id',
        'utm_source': 'tracive-sdk-flutter',
      });
      expect(link.toString(), isNot(contains('6281234567890')));
    });

    test('the install link override is the one opened', () async {
      final auth = _FakeAuthLauncher();
      await _client(
        _FakePlatform(
            handoff: const ReportHandoff.notAccepted(), installed: false),
        auth: auth,
        installUrl: 'https://install.example/app',
      ).openReportForm(_phone);

      expect(auth.opened.single.host, 'install.example');
    });

    test('an install link the OS refuses is a failure, not a claim it opened',
        () async {
      final result = await _client(
        _FakePlatform(
            handoff: const ReportHandoff.notAccepted(), installed: false),
        auth: _FakeAuthLauncher(opens: false),
      ).openReportForm(_phone);

      expect(
        result,
        const ReportFormResult.failed(
          ReportFormPlatformFailure('install_link_refused'),
        ),
      );
    });
  });

  group('iOS sheet resolution', () {
    test('the target build picked in the sheet means delivered', () async {
      final result = await _client(
        _FakePlatform(
          handoff:
              const ReportHandoff.sentTo('com.pleistocent.tracive.sandbox'),
        ),
      ).openReportForm(_phone);

      expect(result, const ReportFormResult.opened(attachmentsDelivered: true));
    });

    test('any other app picked in the sheet is a cancel', () async {
      final platform = _FakePlatform(
        // Production's id against a sandbox client: also the wrong build.
        handoff: const ReportHandoff.sentTo('com.pleistocent.tracive'),
      );
      final result = await _client(platform).openReportForm(_phone);

      expect(result, const ReportFormResult.cancelled());
      expect(platform.calls, <String>['handOver']);
    });

    test('a dismissed sheet is a cancel, and nothing else is opened', () async {
      final platform = _FakePlatform(handoff: const ReportHandoff.dismissed());
      final auth = _FakeAuthLauncher();

      final result = await _client(platform, auth: auth).openReportForm(_phone);

      expect(result, const ReportFormResult.cancelled());
      expect(platform.calls, <String>['handOver']);
      expect(auth.opened, isEmpty);
    });

    test(
        'no capability scheme but the app scheme answers: the link, and a '
        'cancelled system prompt is a cancel', () async {
      final opened = await _client(
        _FakePlatform(handoff: const ReportHandoff.notAccepted()),
      ).openReportForm(_phone);
      final refused = await _client(
        _FakePlatform(
            handoff: const ReportHandoff.notAccepted(), linkOpens: false),
      ).openReportForm(_phone);

      expect(
          opened, const ReportFormResult.opened(attachmentsDelivered: false));
      expect(refused, const ReportFormResult.cancelled());
    });

    test('the anchor reaches the platform', () async {
      const anchor = ReportFormAnchor(left: 10, top: 20, width: 30, height: 40);
      final platform = _FakePlatform();

      await _client(platform).openReportForm(_phone, anchor: anchor);

      expect(platform.anchors.single, anchor);
    });
  });

  group('platform failures', () {
    test('a reason token from the platform reaches the caller', () async {
      final result = await _client(
        _FakePlatform(throws: const ReportFormPlatformException('busy')),
      ).openReportForm(_phone);

      expect(result,
          const ReportFormResult.failed(ReportFormPlatformFailure('busy')));
    });

    test('anything else thrown is "unexpected", and never escapes', () async {
      final result = await _client(
        _FakePlatform(
            throws: StateError('PlatformException(raw platform text)')),
      ).openReportForm(_phone);

      expect(
          result,
          const ReportFormResult.failed(
              ReportFormPlatformFailure('unexpected')));
      expect(result.toString(), isNot(contains('raw platform text')));
    });

    test('outside Flutter nothing is installed and the install link is tried',
        () async {
      final auth = _FakeAuthLauncher();
      final result = await _client(
        const UnsupportedReportFormLauncher(),
        auth: auth,
      ).openReportForm(_phone);

      expect(result, const ReportFormResult.installPageOpened());
      expect(auth.opened, hasLength(1));
    });
  });

  group('no grant, no token, no network', () {
    test('a confidential client opens the form without reading a token',
        () async {
      final platform = _FakePlatform();
      final client = TraciveClient(
        mode: TraciveMode.oauth(
          partnerUserId: 'partner-user-1',
          clientId: 'partner-client-id',
          redirectUri: 'https://partner.example/oauth/callback',
          clientType: ClientType.confidential,
        ),
        transport: const _NoNetwork(),
        tokenStore: _UnreadableStore(),
        launcher: _FakeAuthLauncher(),
        reportFormLauncher: platform,
      );

      expect(
        await client.openReportForm(_phone),
        const ReportFormResult.opened(attachmentsDelivered: true),
      );
    });

    test('proxy mode opens it too, and the install link names no client',
        () async {
      final auth = _FakeAuthLauncher();
      final client = TraciveClient(
        mode: TraciveMode.proxy(baseUrl: 'https://proxy.example/v1'),
        transport: const _NoNetwork(),
        launcher: auth,
        reportFormLauncher: _FakePlatform(
          handoff: const ReportHandoff.notAccepted(),
          installed: false,
        ),
      );

      expect(
        await client.openReportForm(_phone),
        const ReportFormResult.installPageOpened(),
      );
      expect(auth.opened.single.queryParameters.containsKey('ref'), isFalse);
    });

    test('proxy mode refuses a blank install link, as OAuth mode does', () {
      expect(
        () => TraciveClient(
          mode: TraciveMode.proxy(baseUrl: 'https://proxy.example/v1'),
          installUrl: '  ',
        ),
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.message,
            'message',
            contains(TraciveOAuth.blankInstallUrlReason),
          ),
        ),
      );
    });

    test('the date check uses the client clock, read as a local date',
        () async {
      final now = DateTime.utc(2026, 11, 4, 12);
      final local = now.toLocal();
      final today = DateTime(local.year, local.month, local.day);
      final client = _client(_FakePlatform(), clock: MutableClock(now));

      expect(
        await client.openReportForm(_phone, incidentDate: today),
        const ReportFormResult.opened(attachmentsDelivered: true),
      );
      expect(
        await client.openReportForm(
          _phone,
          incidentDate: today.add(const Duration(days: 1)),
        ),
        const ReportFormResult.failed(ReportFormIncidentDateInFuture()),
      );
    });
  });

  group('types', () {
    test('an attachment prints its type and size, never its bytes', () {
      expect(_png.toString(), 'ReportAttachment(image/png, 9 bytes)');
    });

    test(
        'a target refuses values that cannot be an id, a scheme or an extension',
        () {
      ReportFormTarget build({
        String androidPackage = 'com.example.app',
        String appScheme = 'example',
        String fileExtension = 'examplereport',
      }) =>
          ReportFormTarget(
            androidPackage: androidPackage,
            iosBundleId: 'com.example.app',
            appScheme: appScheme,
            capabilityScheme: 'example-report',
            fileExtension: fileExtension,
          );

      expect(build, returnsNormally);
      expect(() => build(androidPackage: 'noDots'), throwsArgumentError);
      expect(() => build(appScheme: 'has space'), throwsArgumentError);
      expect(() => build(fileExtension: '../x'), throwsArgumentError);
    });

    test('every error carries the cross-SDK code', () {
      expect(
        <String>[
          const ReportFormIncidentDateInFuture().code,
          const ReportFormTooManyAttachments(5).code,
          const ReportFormUnsupportedType(0).code,
          const ReportFormContentMismatch(0).code,
          const ReportFormPdfTooLarge(0).code,
          const ReportFormPackageTooLarge(1).code,
          const ReportFormPlatformFailure('busy').code,
        ],
        <String>[
          'INCIDENT_DATE_IN_FUTURE',
          'TOO_MANY_ATTACHMENTS',
          'UNSUPPORTED_TYPE',
          'CONTENT_MISMATCH',
          'PDF_TOO_LARGE',
          'PACKAGE_TOO_LARGE',
          'PLATFORM_FAILURE',
        ],
      );
    });
  });
}

TraciveClient _client(
  ReportFormLauncher platform, {
  TraciveEnvironment environment = TraciveEnvironment.sandbox,
  AuthLauncher? auth,
  String? installUrl,
  TraciveClock? clock,
}) =>
    TraciveClient(
      mode: TraciveMode.oauth(
        partnerUserId: 'partner-user-1',
        clientId: 'partner-client-id',
        redirectUri: 'https://partner.example/oauth/callback',
      ),
      environment: environment,
      transport: const _NoNetwork(),
      tokenStore: _UnreadableStore(),
      launcher: auth ?? _FakeAuthLauncher(),
      reportFormLauncher: platform,
      installUrl: installUrl,
      clock: clock,
    );

class _FakePlatform extends ReportFormLauncher {
  _FakePlatform({
    this.handoff = const ReportHandoff.started(),
    this.installed = true,
    this.linkOpens = true,
    this.throws,
  });

  final ReportHandoff handoff;
  final bool installed;
  final bool linkOpens;
  final Object? throws;

  final List<String> calls = <String>[];
  final List<ReportFormTarget> handedTo = <ReportFormTarget>[];
  final List<ReportFormAnchor?> anchors = <ReportFormAnchor?>[];
  final List<ReportFormTarget> linkTargets = <ReportFormTarget>[];
  final List<Uri> linksOpened = <Uri>[];

  @override
  Future<ReportHandoff> handOver(
    ReportFormTarget target,
    Uint8List package, {
    ReportFormAnchor? anchor,
  }) async {
    calls.add('handOver');
    handedTo.add(target);
    anchors.add(anchor);
    if (throws case final error?) throw error;
    return handoff;
  }

  @override
  Future<bool> isInstalled(ReportFormTarget target) async {
    calls.add('isInstalled');
    return installed;
  }

  @override
  Future<bool> openLink(ReportFormTarget target, Uri link) async {
    calls.add('openLink');
    linkTargets.add(target);
    linksOpened.add(link);
    return linkOpens;
  }
}

class _FakeAuthLauncher extends AuthLauncher {
  _FakeAuthLauncher({this.opens = true});

  final bool opens;
  final List<Uri> opened = <Uri>[];

  @override
  Future<bool> canOpen(Uri url) async => true;

  @override
  Future<bool> openExternally(Uri url) async {
    opened.add(url);
    return opens;
  }
}

/// A store that fails the test if anything reads a credential.
class _UnreadableStore extends InMemoryTokenStore {
  @override
  Future<TraciveTokens?> read() =>
      throw StateError('openReportForm must not read a token');
}

class _NoNetwork extends HttpTransport {
  const _NoNetwork();

  @override
  Future<TraciveHttpResponse> send(TraciveHttpRequest request) =>
      throw StateError('openReportForm must not touch the network');
}
