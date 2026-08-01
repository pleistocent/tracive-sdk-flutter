// Copyright (c) Tracive. Licensed under the Apache License, Version 2.0.
//
// The default [HttpTransport], on `package:http`: the platform HTTP client.
//
// `package:http` is pure Dart (no Flutter plugin, no platform channel), which
// is what lets the whole client layer be exercised by a plain `dart test` run
// against a fake transport.

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'http_transport.dart';

/// Thrown inside [HttpPackageTransport.send] when a response arrives after the
/// caller has already timed out. Never escapes the method: the caller has its
/// [TimeoutException] by then, and this only exists to end the drained
/// exchange.
class _AbandonedExchange implements Exception {
  const _AbandonedExchange();

  @override
  String toString() => 'The response arrived after the caller timed out';
}

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

  /// Per-request timeout, covering the **whole** exchange: sending the request,
  /// receiving the headers, and reading the body to the last byte.
  ///
  /// Bounding the whole exchange rather than just the headers is not a detail.
  /// `Client.send` completes as soon as the response headers arrive, so a
  /// timeout attached only to it is already satisfied by a server that answers
  /// promptly and then stops sending the body — and the caller waits for ever,
  /// which is the exact failure this field exists to prevent.
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

    // Flipped when the caller gives up, so that a response arriving afterwards
    // can be thrown away deliberately instead of being left dangling.
    var abandoned = false;
    // The body is read through a subscription this method keeps hold of,
    // rather than through `Response.fromStream`, for one reason: a stalled body
    // has to be *cancellable*. `fromStream` hands the subscription to a future
    // nobody can reach, so a server that sends headers and then stops leaves a
    // live listener on a socket that never returns to the pool — and the
    // client's retry loop can do that three times for one call.
    StreamSubscription<List<int>>? bodyReader;
    final bodyBytes = Completer<List<int>>();

    Future<TraciveHttpResponse> exchange() async {
      final streamed = await _client.send(outbound);
      if (abandoned) {
        // The caller gave up before the headers even landed. `package:http`
        // cannot abort the request, so consume the response and let go of it.
        await streamed.stream.listen(null).cancel();
        throw const _AbandonedExchange();
      }
      final collected = <int>[];
      bodyReader = streamed.stream.listen(
        collected.addAll,
        onError: (Object error, StackTrace stackTrace) {
          if (!bodyBytes.isCompleted) {
            bodyBytes.completeError(error, stackTrace);
          }
        },
        onDone: () {
          if (!bodyBytes.isCompleted) bodyBytes.complete(collected);
        },
        cancelOnError: true,
      );
      return TraciveHttpResponse(
        statusCode: streamed.statusCode,
        headers: streamed.headers,
        body: utf8.decode(await bodyBytes.future, allowMalformed: true),
      );
    }

    final pending = exchange();
    // Once the timeout below has fired, nothing is listening to `pending` any
    // more, and an unlistened error future is reported as an unhandled
    // asynchronous error — which in a host app means a crash report for a
    // request the SDK deliberately discarded. This listener is what makes
    // discarding it silent.
    unawaited(pending.then<void>((_) {}, onError: (Object _) {}));

    try {
      return await pending.timeout(timeout);
    } on TimeoutException {
      abandoned = true;
      final reader = bodyReader;
      if (reader != null) {
        await reader.cancel();
        if (!bodyBytes.isCompleted) {
          // Cancelling means `onDone` will never fire, so settle the exchange
          // here rather than leaving a future pending for the process's life.
          bodyBytes.completeError(const _AbandonedExchange());
        }
      }
      rethrow;
    }
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
