// Copyright (c) Tracive. Licensed under the Apache License, Version 2.0.
//
// The HTTP seam: `transport: HttpTransport? = null`, a test seam whose
// default is the platform HTTP client.
//
// This interface exists so that **no test in this repo can reach a network**.
// A test suite that talks to a live environment fails when someone else's
// deploy is mid-flight, and cannot make the server answer a 402 or a 429 on
// demand. Everything above this line is exercised against a fake.
//
// Deliberately smaller than `package:http`'s `Client`: one method, plain
// strings, no streaming. A fake for it is ten lines, which is the point.

import 'dart:collection';

/// One outbound HTTP request.
///
/// PRIVACY: [headers] carries the bearer token and [body] carries the folded
/// query (which contains the raw identifier). Neither is printed by
/// [toString] — see the redaction there before adding any logging.
class TraciveHttpRequest {
  /// Creates a request. [headers] keys are lower-cased on the way in, so
  /// lookups do not have to guess at capitalisation: HTTP header names are
  /// case-insensitive (RFC 9110 §5.1) and HTTP/2 requires them lower-case
  /// anyway.
  TraciveHttpRequest({
    required this.method,
    required this.url,
    Map<String, String> headers = const <String, String>{},
    this.body,
  }) : headers = UnmodifiableMapView<String, String>(<String, String>{
          for (final entry in headers.entries)
            entry.key.toLowerCase(): entry.value,
        });

  /// `GET`, `POST`, …
  final String method;

  /// Absolute request URL.
  final Uri url;

  /// Request headers, keyed by **lower-case** name. Unmodifiable.
  final Map<String, String> headers;

  /// Encoded request body, or `null` for a body-less request.
  final String? body;

  /// Reads a header case-insensitively.
  String? header(String name) => headers[name.toLowerCase()];

  /// This request with [name] set to [value] (replacing any existing value).
  TraciveHttpRequest withHeader(String name, String value) =>
      TraciveHttpRequest(
        method: method,
        url: url,
        headers: <String, String>{...headers, name.toLowerCase(): value},
        body: body,
      );

  /// **Never** prints header values or the body: the `authorization` header is
  /// a bearer token and the body contains the raw identifier being checked.
  @override
  String toString() =>
      'TraciveHttpRequest($method $url, headers: ${headers.keys.toList()} '
      '(values redacted), body: ${body == null ? 'none' : '${body!.length} bytes redacted'})';
}

/// One inbound HTTP response.
class TraciveHttpResponse {
  /// Creates a response. [headers] keys are lower-cased on the way in.
  TraciveHttpResponse({
    required this.statusCode,
    Map<String, String> headers = const <String, String>{},
    this.body = '',
  }) : headers = UnmodifiableMapView<String, String>(<String, String>{
          for (final entry in headers.entries)
            entry.key.toLowerCase(): entry.value,
        });

  /// HTTP status.
  final int statusCode;

  /// Response headers, keyed by **lower-case** name. Unmodifiable.
  final Map<String, String> headers;

  /// Response body, already decoded as UTF-8.
  ///
  /// UTF-8 rather than "whatever the charset says" is deliberate: the API is
  /// JSON, and RFC 8259 §8.1 requires UTF-8 for JSON exchanged between
  /// systems. `package:http`'s `Response.body` defaults to **latin-1** when
  /// the server omits a charset, which would quietly mangle every Indonesian
  /// name in a `comments` payload.
  final String body;

  /// Reads a header case-insensitively.
  String? header(String name) => headers[name.toLowerCase()];

  /// 2xx.
  bool get isSuccess => statusCode >= 200 && statusCode < 300;

  /// **Never** prints the body: it can contain report text and identifiers.
  @override
  String toString() =>
      'TraciveHttpResponse($statusCode, headers: ${headers.keys.toList()}, '
      'body: ${body.length} bytes redacted)';
}

/// How the SDK reaches the network.
///
/// Implement it to route Tracive traffic through your own stack (a shared
/// `Dio`/`http` client, a certificate-pinned client, an offline fake) and pass
/// the implementation as `TraciveClient(transport: …)`.
///
/// A transport may throw **any** exception on failure — socket errors, TLS
/// errors, timeouts. Callers wrap whatever comes out in
/// `TraciveNetworkException`; a transport does not need to know the SDK's error
/// types.
abstract class HttpTransport {
  /// Allows `const` implementations.
  const HttpTransport();

  /// Sends [request] and completes with the response.
  ///
  /// Must **not** follow a redirect to a different origin with the
  /// `Authorization` header still attached, and must not retry: retry policy
  /// lives one layer up, where it can tell an idempotent call from one that
  /// would double-charge.
  Future<TraciveHttpResponse> send(TraciveHttpRequest request);

  /// Releases any underlying resources. Default: nothing to release.
  void close() {}
}
