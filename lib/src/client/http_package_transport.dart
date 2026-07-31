// Copyright (c) Tracive. Licensed under the Apache License, Version 2.0.
//
// The default [HttpTransport], on `package:http` — the SDK specification §2 ("default =
// platform HTTP client").
//
// `package:http` is pure Dart (no Flutter plugin, no platform channel), which
// is what lets the whole client layer be exercised by a plain `dart test` run
// against a fake transport.

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'http_transport.dart';

/// The default transport. Wraps a `package:http` [http.Client].
///
/// Two decisions worth knowing about:
///
/// * **Redirects are not followed by default.** A 3xx that this client
///   followed would replay the `Authorization: Bearer …` header at whatever
///   origin the response named — which is a token-exfiltration primitive if
///   anything upstream is compromised or misconfigured. The Tracive API does
///   not redirect; a redirect therefore surfaces as an error rather than being
///   silently obeyed. Pass `followRedirects: true` only if a partner proxy
///   (`TraciveEnvironment.custom`) genuinely needs it.
/// * **Bodies are decoded as UTF-8, explicitly.** `http.Response.body` falls
///   back to latin-1 when the server sends no `charset`, which corrupts every
///   non-ASCII byte in a report.
class HttpPackageTransport extends HttpTransport {
  /// Creates a transport.
  ///
  /// Pass [client] to share one connection pool with the rest of your app. If
  /// you do, you own its lifetime: [close] will not shut down a client it did
  /// not create.
  HttpPackageTransport({
    http.Client? client,
    this.timeout = const Duration(seconds: 30),
    this.followRedirects = false,
  })  : _client = client ?? http.Client(),
        _ownsClient = client == null;

  final http.Client _client;
  final bool _ownsClient;

  /// Per-request timeout. A hung socket otherwise hangs the caller's UI.
  final Duration timeout;

  /// Whether to follow 3xx responses. Off by default — see the class docs.
  final bool followRedirects;

  @override
  Future<TraciveHttpResponse> send(TraciveHttpRequest request) async {
    final outbound = http.Request(request.method, request.url)
      ..followRedirects = followRedirects
      ..persistentConnection = true;
    outbound.headers.addAll(request.headers);

    final body = request.body;
    if (body != null) {
      // Encode explicitly rather than through `Request.body`, whose choice of
      // encoding depends on the charset parameter of the content-type header.
      outbound.bodyBytes = utf8.encode(body);
    }

    final streamed = await _client.send(outbound).timeout(timeout);
    final response = await http.Response.fromStream(streamed);
    return TraciveHttpResponse(
      statusCode: response.statusCode,
      headers: response.headers,
      body: utf8.decode(response.bodyBytes, allowMalformed: true),
    );
  }

  @override
  void close() {
    if (_ownsClient) _client.close();
  }

  @override
  String toString() => 'HttpPackageTransport(timeout: $timeout, '
      'followRedirects: $followRedirects)';
}

/// The transport used when a caller passes none.
HttpTransport createDefaultHttpTransport() => HttpPackageTransport();
