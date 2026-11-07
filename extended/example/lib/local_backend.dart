// Copyright 2026 PT Pleistocent Teknologi Nusantara.
// Licensed under the Apache License, Version 2.0.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A stand-in for the Tracive API, in this process, on 127.0.0.1.
///
/// It answers the shapes of the report routes and checks nothing else. The
/// native core reaches it over a real socket, which also proves Dart keeps
/// running while a native screen covers the app.
final class LocalBackend {
  LocalBackend._(this._server);

  /// Starts the server.
  static Future<LocalBackend> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final backend = LocalBackend._(server);
    server.listen(backend._handle);
    return backend;
  }

  final HttpServer _server;

  /// The only token the routes accept.
  String acceptedToken = 'local-token-1';

  /// Answers every route with a 401 `grant_revoked` while true.
  bool revoked = false;

  /// How long each upload is held before it answers.
  Duration uploadDelay = Duration.zero;

  /// How many requests each route took, by `METHOD /path`.
  final Map<String, int> calls = <String, int>{};

  /// The `Idempotency-Key` of every report filed.
  final List<String> filedKeys = <String>[];

  /// The body of every report filed.
  final List<Map<String, Object?>> filedBodies = <Map<String, Object?>>[];

  /// The size of every file uploaded.
  final List<int> uploadedSizes = <int>[];

  /// The answer of `GET /reports/{id}`.
  String reportStatus = 'IN_REVIEW';

  /// The base URL, with `/v1`.
  String get baseUrl => 'http://127.0.0.1:${_server.port}/v1';

  /// Stops the server.
  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;
    calls.update('${request.method} $path', (n) => n + 1, ifAbsent: () => 1);
    try {
      if (path.startsWith('/upload/')) return await _upload(request);
      final authorization = request.headers.value('authorization');
      if (revoked) return await _error(request, 401, 'grant_revoked');
      if (authorization != 'Bearer $acceptedToken') {
        return await _error(request, 401, 'expired_token');
      }
      switch ((request.method, path)) {
        case ('GET', '/v1/report-requirements'):
          return await _json(request, 200, _requirements);
        case ('POST', '/v1/report-uploads'):
          return await _openUploads(request);
        case ('POST', '/v1/reports'):
          return await _file(request);
      }
      if (request.method == 'GET' && path.startsWith('/v1/reports/')) {
        return await _json(request, 200, <String, Object?>{
          'reportId': path.split('/').last,
          'status': reportStatus,
        });
      }
      await _error(request, 404, 'report_not_found');
    } on Object {
      request.response.statusCode = 500;
      await request.response.close();
    }
  }

  Future<void> _openUploads(HttpRequest request) async {
    final body = await _body(request);
    final files = body['attachments']! as List<Object?>;
    await _json(request, 200, <String, Object?>{
      'uploadId': 'upl_local',
      'attachments': <Map<String, Object?>>[
        for (var i = 0; i < files.length; i++)
          <String, Object?>{
            'attachmentId': 'att_$i',
            'url': 'http://127.0.0.1:${_server.port}/upload/$i',
          },
      ],
    });
  }

  Future<void> _upload(HttpRequest request) async {
    final size = await request.fold<int>(0, (sum, part) => sum + part.length);
    await Future<void>.delayed(uploadDelay);
    uploadedSizes.add(size);
    request.response.statusCode = 200;
    await request.response.close();
  }

  Future<void> _file(HttpRequest request) async {
    final key = request.headers.value('idempotency-key') ?? '';
    final body = await _body(request);
    if (!filedKeys.contains(key)) {
      filedKeys.add(key);
      filedBodies.add(body);
    }
    final id = 'local_${filedKeys.indexOf(key) + 1}';
    await _json(request, 202, <String, Object?>{
      'reportId': id,
      'status': 'SUBMITTED',
    });
  }

  Future<Map<String, Object?>> _body(HttpRequest request) async {
    final text = await utf8.decoder.bind(request).join();
    return (jsonDecode(text) as Map<String, Object?>);
  }

  Future<void> _json(
    HttpRequest request,
    int status,
    Map<String, Object?> body,
  ) async {
    request.response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body));
    await request.response.close();
  }

  Future<void> _error(HttpRequest request, int status, String code) async {
    await request.drain<void>();
    await _json(request, status, <String, Object?>{
      'error': <String, Object?>{'code': code, 'message': code},
    });
  }
}

const Map<String, Object?> _requirements = <String, Object?>{
  'enabled': true,
  'remainingToday': 3,
  'limits': <String, Object?>{
    'titleMaxLength': 50,
    'chronologyMinLength': 50,
    'chronologyMaxLength': 2000,
    'commentMaxLength': 150,
    'maxIdentifiers': 10,
    'attachmentsPerIdentifier': 5,
    'extraAttachmentsWithPhone': 5,
    'maxAttachmentBytes': 1048575,
    'attachmentTypes': <String>[
      'image/avif',
      'image/webp',
      'image/jpeg',
      'application/pdf',
    ],
  },
  'terms': <Map<String, String>>[
    <String, String>{
      'id': 'TERMS_OF_SERVICE',
      'version': 'v1.1',
      'url': 'https://tracive.id/terms',
    },
    <String, String>{
      'id': 'PRIVACY_POLICY',
      'version': 'v1.1',
      'url': 'https://tracive.id/privacy',
    },
  ],
};
