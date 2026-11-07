// Copyright 2026 PT Pleistocent Teknologi Nusantara.
// Licensed under the Apache License, Version 2.0.

import 'package:flutter/services.dart';
import 'package:tracive_sdk/tracive_sdk.dart';

import 'report_error.dart';
import 'report_models.dart';

/// Answers the native core's request for an access token.
typedef ReportAccessToken = Future<String> Function(String? stale);

/// The one channel to the native core, and the routing of what it calls back.
final class ReportBridge {
  ReportBridge._();

  /// The bridge every `TraciveReports` shares.
  static final ReportBridge instance = ReportBridge._();

  /// The channel the native halves register.
  static const MethodChannel channel =
      MethodChannel('tracive_sdk_extended/reports');

  final Map<int, ReportAccessToken> _tokens = <int, ReportAccessToken>{};
  final Map<String, void Function(double)> _progress =
      <String, void Function(double)>{};

  /// Creates a native core and answers its handle.
  Future<int> create({
    required String baseUrl,
    required String appUrlScheme,
    required ReportAccessToken tokens,
  }) async {
    channel.setMethodCallHandler(_onNativeCall);
    final handle = await call<int>('create', <String, Object?>{
      'baseUrl': baseUrl,
      'appUrlScheme': appUrlScheme,
    });
    _tokens[handle!] = tokens;
    return handle;
  }

  /// Drops the native core behind [handle], with its evidence and running
  /// calls.
  Future<void> dispose(int handle) async {
    _tokens.remove(handle);
    await call<void>('dispose', <String, Object?>{'reports': handle});
  }

  /// Sends [onProgress] the fractions the native call under [key] reports.
  void listen(String key, void Function(double) onProgress) =>
      _progress[key] = onProgress;

  /// Ends [listen].
  void unlisten(String key) => _progress.remove(key);

  /// Invokes [method], with a native failure as [TraciveReportException].
  Future<T?> call<T>(String method, Map<String, Object?> arguments) async {
    try {
      return await channel.invokeMethod<T>(method, arguments);
    } on PlatformException catch (failure) {
      throw _reportException(failure);
    }
  }

  Future<Object?> _onNativeCall(MethodCall call) async {
    final arguments = call.arguments as Map<Object?, Object?>;
    switch (call.method) {
      case 'accessToken':
        return _accessToken(
          arguments['reports'] as int,
          arguments['stale'] as String?,
        );
      case 'progress':
        final fraction = (arguments['fraction'] as num).toDouble();
        _progress[arguments['key'] as String]?.call(fraction);
        return null;
    }
    throw MissingPluginException(call.method);
  }

  Future<String> _accessToken(int reports, String? stale) async {
    final tokens = _tokens[reports];
    if (tokens == null) throw _platformFailure(_noGrant);
    try {
      return await tokens(stale);
    } catch (failure) {
      throw _platformFailure(_tokenFailure(failure));
    }
  }
}

const TraciveReportException _noGrant = TraciveReportException(
  ReportErrorCode.needsConsent,
  'This user has not granted the report permission. Authorize, then call '
  'again.',
);

TraciveReportException _tokenFailure(Object failure) {
  if (failure is TraciveReportException) return failure;
  const message = 'The token call failed.';
  if (failure is! TraciveException) {
    return const TraciveReportException(ReportErrorCode.server, message);
  }
  return switch (failure) {
    TraciveInvalidTokenException() ||
    TraciveExpiredTokenException() ||
    TraciveGrantRevokedException() ||
    TraciveMissingScopeException() =>
      TraciveReportException(
        ReportErrorCode.needsConsent,
        _noGrant.message,
        httpStatus: failure.statusCode,
      ),
    TraciveNetworkException() => const TraciveReportException(
        ReportErrorCode.network,
        'The Tracive API could not be reached.',
      ),
    TraciveRateLimitedException(:final retryAfter) => TraciveReportException(
        ReportErrorCode.server,
        message,
        httpStatus: failure.statusCode,
        retryAfterSeconds: retryAfter?.inSeconds,
      ),
    _ => TraciveReportException(
        ReportErrorCode.server,
        message,
        httpStatus: failure.statusCode,
      ),
  };
}

PlatformException _platformFailure(TraciveReportException failure) =>
    PlatformException(
      code: failure.code.wire,
      message: failure.message,
      details: <String, Object?>{
        'httpStatus': failure.httpStatus,
        'retryAfterSeconds': failure.retryAfterSeconds,
      },
    );

TraciveReportException _reportException(PlatformException failure) {
  final details = failure.details;
  final extras = details is Map<Object?, Object?> ? details : null;
  return TraciveReportException(
    ReportErrorCode.fromWire(failure.code),
    failure.message ?? failure.code,
    httpStatus: extras?['httpStatus'] as int?,
    retryAfterSeconds: extras?['retryAfterSeconds'] as int?,
  );
}

/// [ReportRequirements] from what the native side sends.
ReportRequirements requirementsFromWire(Map<Object?, Object?> wire) {
  final limits = wire['limits'] as Map<Object?, Object?>;
  return ReportRequirements(
    enabled: wire['enabled'] as bool,
    remainingToday: wire['remainingToday'] as int,
    limits: ReportLimits(
      titleMaxLength: limits['titleMaxLength'] as int,
      chronologyMinLength: limits['chronologyMinLength'] as int,
      chronologyMaxLength: limits['chronologyMaxLength'] as int,
      commentMaxLength: limits['commentMaxLength'] as int,
      maxIdentifiers: limits['maxIdentifiers'] as int,
      attachmentsPerIdentifier: limits['attachmentsPerIdentifier'] as int,
      extraAttachmentsWithPhone: limits['extraAttachmentsWithPhone'] as int,
      maxAttachmentBytes: limits['maxAttachmentBytes'] as int,
      attachmentTypes:
          (limits['attachmentTypes'] as List<Object?>).cast<String>(),
    ),
    terms: (wire['terms'] as List<Object?>)
        .cast<Map<Object?, Object?>>()
        .map(
          (term) => RequiredTerm(
            id: term['id'] as String,
            version: term['version'] as String,
            url: term['url'] as String,
          ),
        )
        .toList(growable: false),
  );
}
