// Copyright 2026 PT Pleistocent Teknologi Nusantara.
// Licensed under the Apache License, Version 2.0.

import 'dart:math';

import 'package:tracive_sdk/tracive_sdk.dart';

import 'report_models.dart';

const String _phonePrefix = 'PHONE_';

final Random _keys = Random.secure();

/// Evidence ready to send, from `TraciveReports.prepare`.
///
/// The bytes stay on the native side, and this is a handle to them. They are
/// released when `submit` files a report, on [dispose], and when the
/// `TraciveReports` that prepared them is disposed.
final class PreparedEvidence {
  PreparedEvidence._(this.handle, this.mimeType, this.byteCount, this._release);

  /// The native side's key for these bytes.
  final int handle;

  /// The type after compression, such as `image/avif`.
  final String mimeType;

  /// The size after compression.
  final int byteCount;

  final Future<void> Function(PreparedEvidence) _release;

  bool _released = false;

  /// Whether the bytes are gone. A draft holding released evidence cannot be
  /// sent.
  bool get isReleased => _released;

  /// Releases the bytes. Call it when the user removes this file.
  Future<void> dispose() async {
    if (_released) return;
    _released = true;
    await _release(this);
  }

  @override
  String toString() => 'PreparedEvidence($mimeType, $byteCount bytes)';
}

/// Builds a [PreparedEvidence] for `TraciveReports`. Not exported.
PreparedEvidence newPreparedEvidence({
  required int handle,
  required String mimeType,
  required int byteCount,
  required Future<void> Function(PreparedEvidence) release,
}) =>
    PreparedEvidence._(handle, mimeType, byteCount, release);

/// Marks [evidence] gone when the native side dropped it with its owner. Not
/// exported.
void markEvidenceReleased(PreparedEvidence evidence) =>
    evidence._released = true;

/// One report. Keep the same draft across retries: its [idempotencyKey] is what
/// stops a retry from becoming a second report.
///
/// The chronology must be the user's own words. You may prefill everything
/// else.
final class ReportDraft {
  /// Creates a draft.
  ///
  /// [identifiers] are `TraciveQuery.searchQueryIndex` values, [incidentDate]
  /// is `YYYY-MM-DD`, [acceptedTerms] holds only what was shown to the user,
  /// and [language] is `id` or `en`, with null using the device language.
  ReportDraft({
    required this.identifiers,
    required this.title,
    required this.chronology,
    this.comment,
    required this.incidentDate,
    required this.evidence,
    required this.acceptedTerms,
    this.language,
    String? idempotencyKey,
  }) : idempotencyKey = idempotencyKey ?? _newIdempotencyKey();

  /// A draft about one [query], on the calendar day of [incidentDate].
  ReportDraft.forQuery({
    required TraciveQuery query,
    required String title,
    required String chronology,
    String? comment,
    required DateTime incidentDate,
    required List<PreparedEvidence> evidence,
    required List<RequiredTerm> acceptedTerms,
    String? language,
  }) : this(
          identifiers: <String>[query.searchQueryIndex],
          title: title,
          chronology: chronology,
          comment: comment,
          incidentDate: reportDay(incidentDate),
          evidence: evidence,
          acceptedTerms: acceptedTerms,
          language: language,
        );

  /// `TraciveQuery.searchQueryIndex` values.
  final List<String> identifiers;

  /// A short title.
  final String title;

  /// What happened, in the user's own words.
  final String chronology;

  /// An optional note.
  final String? comment;

  /// `YYYY-MM-DD`.
  final String incidentDate;

  /// The files, from `TraciveReports.prepare`.
  final List<PreparedEvidence> evidence;

  /// From [ReportRequirements.terms], only what was shown to the user.
  final List<RequiredTerm> acceptedTerms;

  /// `id` or `en`. Null uses the device language.
  final String? language;

  /// What the server deduplicates on.
  final String idempotencyKey;

  /// Everything wrong with this draft, in form order. Empty means it can be
  /// sent. [today] defaults to the device's date.
  List<ReportFieldProblem> problems(ReportLimits limits, {DateTime? today}) {
    final found = <ReportFieldProblem>[];
    if (identifiers.isEmpty) found.add(ReportFieldProblem.noIdentifier);
    if (identifiers.length > limits.maxIdentifiers) {
      found.add(ReportFieldProblem.tooManyIdentifiers);
    }

    final day = _parseDay(incidentDate);
    if (day == null) {
      found.add(ReportFieldProblem.incidentDateInvalid);
    } else if (day.compareTo(reportDay(today ?? DateTime.now())) > 0) {
      found.add(ReportFieldProblem.incidentDateInFuture);
    }

    if (title.trim().isEmpty) found.add(ReportFieldProblem.titleMissing);
    if (title.length > limits.titleMaxLength) {
      found.add(ReportFieldProblem.titleTooLong);
    }
    if (chronology.length < limits.chronologyMinLength) {
      found.add(ReportFieldProblem.chronologyTooShort);
    }
    if (chronology.length > limits.chronologyMaxLength) {
      found.add(ReportFieldProblem.chronologyTooLong);
    }
    if ((comment?.length ?? 0) > limits.commentMaxLength) {
      found.add(ReportFieldProblem.commentTooLong);
    }

    if (evidence.isEmpty) found.add(ReportFieldProblem.noEvidence);
    if (identifiers.isNotEmpty && evidence.length > maxEvidence(limits)) {
      found.add(ReportFieldProblem.tooManyEvidence);
    }
    return found;
  }

  /// How many files this draft may carry.
  int maxEvidence(ReportLimits limits) {
    final phone = identifiers.any((id) => id.startsWith(_phonePrefix));
    return identifiers.length * limits.attachmentsPerIdentifier +
        (phone ? limits.extraAttachmentsWithPhone : 0);
  }
}

/// The calendar day of [date], as written, in `YYYY-MM-DD`.
String reportDay(DateTime date) {
  final year = date.year.toString().padLeft(4, '0');
  final month = date.month.toString().padLeft(2, '0');
  final day = date.day.toString().padLeft(2, '0');
  return '$year-$month-$day';
}

/// [value] when it names a real day, so a plain string comparison orders it.
String? _parseDay(String value) {
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) return null;
  final parts = value.split('-').map(int.parse).toList();
  final date = DateTime.utc(parts[0], parts[1], parts[2]);
  // DateTime rolls 2026-02-30 over to March rather than refusing it.
  return reportDay(date) == value ? value : null;
}

String _newIdempotencyKey() => List<String>.generate(
      16,
      (_) => _keys.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
