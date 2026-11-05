// Copyright 2026 PT Pleistocent Teknologi Nusantara.
// Licensed under the Apache License, Version 2.0.
//
// The report package and the fallback link against the shared fixture.
//
// `test/fixtures/report-package-vectors.json` is vendored byte-identically into
// every Tracive SDK, like the grammar vectors: if this implementation disagrees
// with a vector, this implementation is wrong. Every case goes through the
// public `openReportForm`, so what is checked is exactly what the platform was
// handed, and an error case is also checked to have opened nothing.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tracive_sdk/tracive_sdk.dart';
// By path on purpose: the encoder and the link builder are the wire contract,
// not public surface (see the "not exported" list in lib/tracive_sdk.dart).
import 'package:tracive_sdk/src/report/report_package.dart';

final Map<String, Object?> _vectors = jsonDecode(
        File('test/fixtures/report-package-vectors.json').readAsStringSync())
    as Map<String, Object?>;

/// The day every fixture case is evaluated on, so a case dated 2026-11-03
/// stays in the past whenever this runs.
final DateTime _today = DateTime(2026, 11, 4);

void main() {
  final cases =
      (_vectors['cases']! as List<Object?>).cast<Map<String, Object?>>();
  final links =
      (_vectors['reportLinks']! as List<Object?>).cast<Map<String, Object?>>();

  test('the fixture is the one the contract describes', () {
    // Guards against iterating an empty or truncated list and passing.
    expect(_vectors['version'], 1);
    expect(cases, hasLength(19));
    expect(links, hasLength(5));
  });

  group('report-package-vectors.json cases', () {
    for (final vector in cases) {
      test(vector['name'], () async {
        final query = _queryFor(vector['query']! as String);
        final attachments = <ReportAttachment>[
          for (final spec in (vector['attachments']! as List<Object?>)
              .cast<Map<String, Object?>>())
            _attachmentFor(spec),
        ];
        final platform = _RecordingPlatform();
        final auth = _RecordingAuthLauncher();
        final client = _client(platform, auth);

        final result = await client.openReportForm(
          query,
          incidentDate: _parseDate(vector['incidentDate'] as String?),
          attachments: attachments,
        );

        final expectation = vector['expect']! as Map<String, Object?>;
        final package = expectation['package'] as Map<String, Object?>?;
        if (package != null) {
          expect(result,
              const ReportFormResult.opened(attachmentsDelivered: true));
          expect(platform.packages, hasLength(1));
          _checkPackage(platform.packages.single, package, attachments);
        } else {
          expect(
            result,
            ReportFormResult.failed(_errorFor(expectation)),
          );
          expect(platform.calls, isEmpty,
              reason: 'a failed check opens nothing');
          expect(auth.opened, isEmpty, reason: 'a failed check opens nothing');
        }
      });
    }
  });

  group('report-package-vectors.json reportLinks', () {
    for (final vector in links) {
      test('${vector['scheme']} ${vector['query']}', () {
        final link = buildReportLink(
          vector['scheme']! as String,
          vector['query']! as String,
        );
        expect(link.toString(), vector['url']);
      });
    }

    test('a phone number keeps its plus sign through the link', () {
      final link = buildReportLink('tracive', 'PHONE_+6281234567890');
      expect(link.toString(), contains('PHONE_%2B6281234567890'));
      expect(link.queryParameters['media'], 'PHONE_+6281234567890');
    });
  });

  group('limits, at their exact boundary', () {
    test('a package of exactly 20 MiB is accepted, one byte more is refused',
        () {
      // 15,000,000 bytes encode to 20,000,000 characters of base64; the query
      // is padded until the whole package lands exactly on the cap.
      final attachment = ReportAttachment.image(
        _generated('89504e470d0a1a0a', 15000000),
        'image/png',
      );
      int sizeWith(String query) => buildReportPackage(
            query: query,
            incidentDate: null,
            attachments: <ReportAttachment>[attachment],
            today: _today,
          ).bytes!.length;

      final base = sizeWith('BANK_IDN_BCA_');
      final exact = 'BANK_IDN_BCA_${'1' * (reportPackageMaxBytes - base)}';
      expect(sizeWith(exact), reportPackageMaxBytes);

      final over = buildReportPackage(
        query: '${exact}1',
        incidentDate: null,
        attachments: <ReportAttachment>[attachment],
        today: _today,
      );
      expect(over.bytes, isNull);
      expect(
          over.error, const ReportFormPackageTooLarge(reportPackageMaxBytes));
    });

    test(
        "today is accepted and tomorrow is refused, by the device's local date",
        () {
      ReportFormError? errorFor(DateTime date) => buildReportPackage(
            query: 'BANK_IDN_BCA_1',
            incidentDate: date,
            attachments: const <ReportAttachment>[],
            today: DateTime(2026, 11, 4, 23, 59),
          ).error;

      expect(errorFor(DateTime(2026, 11, 4)), isNull);
      expect(errorFor(DateTime.utc(2026, 11, 4, 23)), isNull,
          reason: 'only year, month and day are read, with no conversion');
      expect(errorFor(DateTime(2026, 11, 5)),
          const ReportFormIncidentDateInFuture());
    });

    test('the date is written as YYYY-MM-DD from its own fields', () {
      final package = buildReportPackage(
        query: 'BANK_IDN_BCA_1',
        incidentDate: DateTime.utc(987, 3, 9, 23, 59),
        attachments: const <ReportAttachment>[],
        today: _today,
      );
      final json =
          jsonDecode(utf8.decode(package.bytes!)) as Map<String, Object?>;
      expect(json['incidentDate'], '0987-03-09');
    });

    test('a query is carried verbatim, slashes and non-ASCII included', () {
      const query = 'USERNAME_telegram_a/b_é';
      final package = buildReportPackage(
        query: query,
        incidentDate: null,
        attachments: const <ReportAttachment>[],
        today: _today,
      );
      final json =
          jsonDecode(utf8.decode(package.bytes!)) as Map<String, Object?>;
      expect(json['query'], query);
    });
  });
}

void _checkPackage(
  Uint8List bytes,
  Map<String, Object?> expected,
  List<ReportAttachment> sent,
) {
  final json = jsonDecode(utf8.decode(bytes)) as Map<String, Object?>;
  expect(json['v'], expected['v']);
  expect(json['query'], expected['query']);
  if (expected.containsKey('incidentDate')) {
    expect(json['incidentDate'], expected['incidentDate']);
  } else {
    expect(json.containsKey('incidentDate'), isFalse);
  }

  final expectedAttachments =
      (expected['attachments']! as List<Object?>).cast<Map<String, Object?>>();
  final actual =
      (json['attachments']! as List<Object?>).cast<Map<String, Object?>>();
  expect(actual, hasLength(expectedAttachments.length));
  for (var i = 0; i < actual.length; i++) {
    expect(actual[i]['name'], expectedAttachments[i]['name']);
    expect(actual[i]['mimeType'], expectedAttachments[i]['mimeType']);
    final data = actual[i]['data']! as String;
    expect(data, matches(RegExp(r'^[A-Za-z0-9+/]*={0,2}$')),
        reason: 'standard base64, no line breaks');
    expect(data.length % 4, 0, reason: 'padded');
    expect(base64Decode(data), sent[i].bytes);
  }
}

TraciveQuery _queryFor(String index) {
  final query = switch (index) {
    'BANK_IDN_BCA_1234567890' => TraciveQuery.bankAccount(
        countryAlpha3: 'IDN',
        bankCode: 'BCA',
        account: '1234567890',
      ),
    'PHONE_+6281234567890' => TraciveQuery.phone('+6281234567890'),
    _ => throw StateError('No builder for a fixture query; add one here'),
  };
  expect(query.searchQueryIndex, index);
  return query;
}

ReportAttachment _attachmentFor(Map<String, Object?> spec) {
  final mimeType = spec['mimeType']! as String;
  final bytes = _generated(spec['head']! as String, spec['sizeBytes']! as int);
  return mimeType == 'application/pdf'
      ? ReportAttachment.pdf(bytes)
      : ReportAttachment.image(bytes, mimeType);
}

/// Byte i is `head[i]` while i is inside the head, else `i % 251`.
Uint8List _generated(String headHex, int size) {
  final bytes = Uint8List(size);
  for (var i = 0; i < size; i++) {
    bytes[i] = i * 2 < headHex.length
        ? int.parse(headHex.substring(i * 2, i * 2 + 2), radix: 16)
        : i % 251;
  }
  return bytes;
}

DateTime? _parseDate(String? value) {
  if (value == null) return null;
  final parts = value.split('-').map(int.parse).toList();
  return DateTime(parts[0], parts[1], parts[2]);
}

ReportFormError _errorFor(Map<String, Object?> expectation) {
  final index = expectation['index'] as int?;
  final max = expectation['max'] as int?;
  return switch (expectation['error']) {
    'INCIDENT_DATE_IN_FUTURE' => const ReportFormIncidentDateInFuture(),
    'TOO_MANY_ATTACHMENTS' => ReportFormTooManyAttachments(max!),
    'UNSUPPORTED_TYPE' => ReportFormUnsupportedType(index!),
    'CONTENT_MISMATCH' => ReportFormContentMismatch(index!),
    'PDF_TOO_LARGE' => ReportFormPdfTooLarge(index!),
    'PACKAGE_TOO_LARGE' => ReportFormPackageTooLarge(max!),
    final other =>
      throw StateError('Unknown error code in the fixture: $other'),
  };
}

TraciveClient _client(ReportFormLauncher platform, AuthLauncher auth) =>
    TraciveClient(
      mode: TraciveMode.oauth(
        partnerUserId: 'partner-user-1',
        clientId: 'partner-client-id',
        redirectUri: 'https://partner.example/oauth/callback',
      ),
      environment: TraciveEnvironment.sandbox,
      transport: const _NoNetwork(),
      tokenStore: InMemoryTokenStore(),
      launcher: auth,
      reportFormLauncher: platform,
      // Late on the 4th in UTC is the 4th or the 5th locally, never the 3rd.
      clock: MutableClock(DateTime.utc(2026, 11, 4, 12)),
    );

class _RecordingPlatform extends ReportFormLauncher {
  final List<String> calls = <String>[];
  final List<Uint8List> packages = <Uint8List>[];

  @override
  Future<ReportHandoff> handOver(
    ReportFormTarget target,
    Uint8List package, {
    ReportFormAnchor? anchor,
  }) async {
    calls.add('handOver');
    packages.add(package);
    return const ReportHandoff.started();
  }

  @override
  Future<bool> isInstalled(ReportFormTarget target) async {
    calls.add('isInstalled');
    return true;
  }

  @override
  Future<bool> openLink(ReportFormTarget target, Uri link) async {
    calls.add('openLink');
    return true;
  }
}

class _RecordingAuthLauncher extends AuthLauncher {
  final List<Uri> opened = <Uri>[];

  @override
  Future<bool> canOpen(Uri url) async => true;

  @override
  Future<bool> openExternally(Uri url) async {
    opened.add(url);
    return true;
  }
}

class _NoNetwork extends HttpTransport {
  const _NoNetwork();

  @override
  Future<TraciveHttpResponse> send(TraciveHttpRequest request) =>
      throw StateError('openReportForm must not touch the network');
}
