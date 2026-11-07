// Copyright 2026 PT Pleistocent Teknologi Nusantara.
// Licensed under the Apache License, Version 2.0.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Stands in for both native halves, on the real channel.
final class FakeNative {
  FakeNative() {
    _messenger.setMockMethodCallHandler(_channel, _handle);
  }

  static const MethodChannel _channel =
      MethodChannel('tracive_sdk_extended/reports');
  static const StandardMethodCodec _codec = StandardMethodCodec();

  TestDefaultBinaryMessenger get _messenger =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  /// Every call Dart made, in order.
  final List<MethodCall> calls = <MethodCall>[];

  /// Answers by method. A thrown [PlatformException] crosses as a failure.
  final Map<String, FutureOr<Object?> Function(MethodCall)> answers =
      <String, FutureOr<Object?> Function(MethodCall)>{};

  int _nextHandle = 1;

  /// The calls of one method.
  List<MethodCall> named(String method) =>
      calls.where((call) => call.method == method).toList();

  /// Removes the handler.
  void close() => _messenger.setMockMethodCallHandler(_channel, null);

  Future<Object?> _handle(MethodCall call) async {
    calls.add(call);
    final answer = answers[call.method];
    if (answer != null) return answer(call);
    return switch (call.method) {
      'create' => _nextHandle++,
      'prepare' => <String, Object?>{
          'evidence': _nextHandle++,
          'mimeType': 'image/avif',
          'byteCount': 1234,
        },
      _ => null,
    };
  }

  /// Sends a native call to Dart and answers with its decoded reply.
  Future<Object?> callDart(String method, Map<String, Object?> arguments) {
    final reply = Completer<Object?>();
    unawaited(
      _messenger.handlePlatformMessage(
        _channel.name,
        _codec.encodeMethodCall(MethodCall(method, arguments)),
        (data) {
          try {
            reply.complete(_codec.decodeEnvelope(data!));
          } on Object catch (failure) {
            reply.completeError(failure);
          }
        },
      ),
    );
    return reply.future;
  }
}
