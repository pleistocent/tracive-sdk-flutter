// Copyright 2026 PT Pleistocent Teknologi Nusantara.
// Licensed under the Apache License, Version 2.0.
//
// The default transport's timeout behaviour.
//
// NO NETWORK. `_ScriptedClient` is a `package:http` client that hands back a
// `StreamedResponse` whose body this file controls, so a server that sends
// headers and then stops can be reproduced without a socket.
//
// This is the one part of the transport that cannot be checked by reading it:
// whether the timeout actually bounds anything depends on which future it is
// attached to, and getting that wrong looks identical in the source.

import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:test/test.dart';
import 'package:tracive_sdk/tracive_sdk.dart';

void main() {
  final request = TraciveHttpRequest(
    method: 'GET',
    url: Uri.parse('https://api.example/v1/thing'),
  );

  test('a body that never arrives is bounded by the timeout', () async {
    // The failure mode this guards against is a server that sends its headers
    // promptly and then stalls. `Client.send` completes when the headers land,
    // so a timeout attached to that future alone has already been satisfied by
    // the time the body hangs — and the caller waits for ever, which is exactly
    // what the timeout field's own doc says it prevents.
    final client = _ScriptedClient(body: StreamController<List<int>>().stream);
    final transport = HttpPackageTransport(
      client: client,
      timeout: const Duration(milliseconds: 100),
    );

    await expectLater(
      transport.send(request),
      throwsA(isA<TimeoutException>()),
    );
  });

  test('a stalled body is released rather than left holding the connection',
      () async {
    // On timeout the request is not aborted, so the response body — whenever it
    // does arrive — is a stream nobody is listening to. Left undrained, the
    // underlying connection never returns to the pool, and the client's retry
    // loop can do this three times per call.
    final controller = StreamController<List<int>>();
    var released = false;
    controller.onCancel = () => released = true;

    final client = _ScriptedClient(body: controller.stream);
    final transport = HttpPackageTransport(
      client: client,
      timeout: const Duration(milliseconds: 50),
    );

    await expectLater(
      transport.send(request),
      throwsA(isA<TimeoutException>()),
    );
    // Give the abandoned exchange a turn to notice and let go.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(
      released,
      isTrue,
      reason: 'the abandoned response body was never cancelled',
    );
  });

  test('a response that arrives in time is returned normally', () async {
    final client = _ScriptedClient(
      body: Stream<List<int>>.value(<int>[123, 125]), // "{}"
      statusCode: 201,
      headers: const <String, String>{'content-type': 'application/json'},
    );
    final transport = HttpPackageTransport(
      client: client,
      timeout: const Duration(seconds: 5),
    );

    final response = await transport.send(request);
    expect(response.statusCode, 201);
    expect(response.body, '{}');
    expect(response.headers['content-type'], 'application/json');
  });

  test('a slow header phase is bounded too', () async {
    final client = _ScriptedClient(
      body: const Stream<List<int>>.empty(),
      headerDelay: const Duration(seconds: 5),
    );
    final transport = HttpPackageTransport(
      client: client,
      timeout: const Duration(milliseconds: 50),
    );

    await expectLater(
      transport.send(request),
      throwsA(isA<TimeoutException>()),
    );
  });
}

/// An [http.Client] that answers with a caller-supplied body stream.
class _ScriptedClient extends http.BaseClient {
  _ScriptedClient({
    required this.body,
    this.statusCode = 200,
    this.headers = const <String, String>{},
    this.headerDelay = Duration.zero,
  });

  final Stream<List<int>> body;
  final int statusCode;
  final Map<String, String> headers;

  /// How long `send` takes to "receive the headers".
  final Duration headerDelay;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (headerDelay > Duration.zero) await Future<void>.delayed(headerDelay);
    return http.StreamedResponse(
      body,
      statusCode,
      headers: headers,
      request: request,
    );
  }
}
