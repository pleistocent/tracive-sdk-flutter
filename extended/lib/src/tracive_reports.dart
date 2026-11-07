// Copyright 2026 PT Pleistocent Teknologi Nusantara.
// Licensed under the Apache License, Version 2.0.

import 'package:flutter/services.dart';
import 'package:tracive_sdk/tracive_sdk.dart';

import 'report_bridge.dart';
import 'report_draft.dart';
import 'report_error.dart';
import 'report_models.dart';

export 'report_bridge.dart' show ReportAccessToken;

/// Lets a user report a scammer without leaving your app.
///
/// ```dart
/// final reports = TraciveReports(client: traciveClient);
/// final requirements = await reports.requirements();
/// final evidence = await reports.prepare(bytes, mimeType: 'image/png');
/// final draft = ReportDraft.forQuery(
///   query: query,
///   title: title,
///   chronology: chronology,
///   incidentDate: date,
///   evidence: [evidence],
///   acceptedTerms: requirements.terms,
/// );
/// final result = await reports.submit(draft);
/// ```
///
/// Evidence goes straight from the device to Tracive when [submit] runs. It
/// never passes through your servers or through Dart again.
///
/// Call [dispose] when you are done: the native core holds an HTTP client and
/// the prepared evidence.
final class TraciveReports {
  /// Uses the grant [client] already holds, and its single-flight refresh.
  ///
  /// [target] is the Tracive build [openInTracive] opens; null follows the
  /// client's environment. Throws [ArgumentError] for a client without OAuth.
  TraciveReports({required TraciveClient client, ReportFormTarget? target})
      : this.withTokens(
          environment: client.environment,
          accessToken: _clientTokens(client),
          target: target,
        );

  /// For a partner that keeps tokens on its own backend.
  ///
  /// [accessToken] receives the token the server just refused, or null on a
  /// first call. Keep refresh in one place: a refresh token rotates and a
  /// reused one revokes the grant, so refresh only when `stale` asks for it.
  /// Throw a [TraciveReportException] with [ReportErrorCode.needsConsent] when
  /// there is no grant.
  TraciveReports.withTokens({
    required TraciveEnvironment environment,
    required ReportAccessToken accessToken,
    ReportFormTarget? target,
  })  : _baseUrl = environment.baseUrl,
        _appUrlScheme =
            (target ?? ReportFormTarget.forEnvironment(environment)).appScheme,
        _accessToken = accessToken;

  final String _baseUrl;
  final String _appUrlScheme;
  final ReportAccessToken _accessToken;
  final ReportBridge _bridge = ReportBridge.instance;

  Future<int>? _native;
  bool _disposed = false;

  final Map<String?, Future<String>> _tokenFlights =
      <String?, Future<String>>{};
  final Set<PreparedEvidence> _evidence = <PreparedEvidence>{};
  final Map<String, Future<SubmitResult>> _submitting =
      <String, Future<SubmitResult>>{};
  final Map<String, ReportSubmitted> _filed = <String, ReportSubmitted>{};

  /// What a report must satisfy right now, and the terms the user accepts by
  /// submitting.
  Future<ReportRequirements> requirements() async {
    final reply = await _bridge.call<Map<Object?, Object?>>(
      'requirements',
      <String, Object?>{'reports': await _handle()},
    );
    return requirementsFromWire(reply!);
  }

  /// Compresses one piece of evidence: to AVIF, under 200 KB, 1024 px on the
  /// shortest side, with metadata dropped. A PDF under 1 MiB passes through.
  ///
  /// [bytes] cross to the native side here, once, and stay there until the
  /// evidence is released.
  Future<PreparedEvidence> prepare(
    Uint8List bytes, {
    required String mimeType,
  }) async {
    final handle = await _handle();
    final reply = await _bridge.call<Map<Object?, Object?>>(
      'prepare',
      <String, Object?>{
        'reports': handle,
        'bytes': bytes,
        'mimeType': mimeType,
      },
    );
    final evidence = newPreparedEvidence(
      handle: reply!['evidence'] as int,
      mimeType: reply['mimeType'] as String,
      byteCount: reply['byteCount'] as int,
      release: (evidence) => _release(handle, evidence),
    );
    _evidence.add(evidence);
    return evidence;
  }

  /// Uploads the evidence and files the report.
  ///
  /// Call again with the same [draft] after a failure: finished uploads are
  /// skipped and the report is created once. A call for a draft already filed,
  /// or still running, answers the same result. The draft's evidence is
  /// released when the report is filed.
  ///
  /// [onProgress] receives the share of evidence uploaded, from 0 to 1.
  ///
  /// Throws [StateError] for a draft whose evidence was released.
  Future<SubmitResult> submit(
    ReportDraft draft, {
    void Function(double fraction)? onProgress,
  }) {
    _requireOpen();
    final key = draft.idempotencyKey;
    final filed = _filed[key];
    if (filed != null) return Future<SubmitResult>.value(filed);
    return _submitting[key] ??= _submit(draft, onProgress).whenComplete(() {
      _submitting.remove(key);
    });
  }

  /// Stops [draft]'s running [submit], which answers [ReportFailed] with
  /// [ReportErrorCode.cancelled]. The draft can be sent again.
  Future<void> cancelSubmit(ReportDraft draft) async {
    final native = _native;
    if (native == null || !_submitting.containsKey(draft.idempotencyKey)) {
      return;
    }
    await _bridge.call<void>('cancelSubmit', <String, Object?>{
      'reports': await native,
      'key': draft.idempotencyKey,
    });
  }

  /// One report's status. Needs [TraciveReportScopes.read]. Reports answer for
  /// 30 days.
  Future<ReportStatus> status(String reportId) async {
    final status = await _bridge.call<String>('status', <String, Object?>{
      'reports': await _handle(),
      'reportId': reportId,
    });
    return ReportStatus.fromWire(status);
  }

  /// Opens the report in the Tracive app, where a revision is made. False
  /// without the app.
  Future<bool> openInTracive(String reportId) async =>
      await _bridge.call<bool>('openInTracive', <String, Object?>{
        'reports': await _handle(),
        'reportId': reportId,
      }) ??
      false;

  /// Releases the native core, cancelling whatever it was doing, and all
  /// prepared evidence.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _evidence
      ..forEach(markEvidenceReleased)
      ..clear();
    final native = _native;
    if (native != null) await _bridge.dispose(await native);
  }

  Future<SubmitResult> _submit(
    ReportDraft draft,
    void Function(double fraction)? onProgress,
  ) async {
    if (draft.evidence.any((evidence) => evidence.isReleased)) {
      throw StateError('This draft holds evidence that was released.');
    }
    final key = draft.idempotencyKey;
    if (onProgress != null) _bridge.listen(key, onProgress);
    try {
      final reply = await _bridge.call<Map<Object?, Object?>>(
        'submit',
        <String, Object?>{
          'reports': await _handle(),
          'key': key,
          'identifiers': draft.identifiers,
          'title': draft.title,
          'chronology': draft.chronology,
          'comment': draft.comment,
          'incidentDate': draft.incidentDate,
          'evidence': draft.evidence
              .map((evidence) => evidence.handle)
              .toList(growable: false),
          'terms': draft.acceptedTerms
              .map(
                (term) => <String, String>{
                  'id': term.id,
                  'version': term.version,
                  'url': term.url,
                },
              )
              .toList(growable: false),
          'language': draft.language,
        },
      );
      if (reply!['outcome'] == 'needsConsent') {
        return const ReportNeedsConsent();
      }
      final filed = ReportSubmitted(
        reply['reportId'] as String,
        ReportStatus.fromWire(reply['status'] as String?),
      );
      _filed[key] = filed;
      await Future.wait(draft.evidence.map((evidence) => evidence.dispose()));
      return filed;
    } on TraciveReportException catch (failure) {
      return failure.code == ReportErrorCode.needsConsent
          ? const ReportNeedsConsent()
          : ReportFailed(failure);
    } finally {
      _bridge.unlisten(key);
    }
  }

  Future<void> _release(int reports, PreparedEvidence evidence) async {
    _evidence.remove(evidence);
    await _bridge.call<void>('releaseEvidence', <String, Object?>{
      'reports': reports,
      'evidence': evidence.handle,
    });
  }

  void _requireOpen() {
    if (_disposed) throw StateError('This TraciveReports was disposed.');
  }

  Future<int> _handle() {
    _requireOpen();
    return _native ??= _bridge
        .create(
      baseUrl: _baseUrl,
      appUrlScheme: _appUrlScheme,
      tokens: _token,
    )
        .catchError((Object failure) {
      _native = null;
      throw failure;
    });
  }

  // Native calls that hit a 401 together all ask at once. Joining them here keeps a partner's
  // callback, which has no single-flight of its own, from spending a rotating token twice.
  //
  // A block body on purpose: `whenComplete` waits for a Future its callback returns, and `remove`
  // returns this very Future, so an arrow body would wait on itself forever.
  Future<String> _token(String? stale) =>
      _tokenFlights[stale] ??= _accessToken(stale).whenComplete(() {
        _tokenFlights.remove(stale);
      });
}

/// The native handle of [reports], which the screens present on. Not exported.
Future<int> reportsHandle(TraciveReports reports) => reports._handle();

ReportAccessToken _clientTokens(TraciveClient client) {
  final oauth = client.oauth;
  if (oauth == null) {
    throw ArgumentError.value(
      client,
      'client',
      'TraciveReports needs a client in OAuth mode.',
    );
  }
  return (stale) async {
    if (stale == null) return oauth.ensureAccessToken();
    final tokens = await oauth.refreshTokens(staleAccessToken: stale);
    return tokens.accessToken;
  };
}
