// Copyright 2026 PT Pleistocent Teknologi Nusantara.
// Licensed under the Apache License, Version 2.0.

import 'dart:ui' show Color;

import 'package:tracive_sdk/tracive_sdk.dart';

import 'report_bridge.dart';
import 'report_draft.dart';
import 'report_models.dart';
import 'tracive_reports.dart';

/// Your brand on Tracive's screens, in light and dark. The terms line above the
/// Send button ignores it: the user must always be able to read what they agree
/// to.
final class TraciveReportTheme {
  /// Creates a theme. Null fields use Tracive's look.
  const TraciveReportTheme({this.primaryColor, this.cornerRadius});

  /// For buttons and highlights. Transparency is ignored, and a colour too
  /// close to the background is shifted until it can be seen.
  final Color? primaryColor;

  /// In logical pixels, from 0 to 28.
  final int? cornerRadius;
}

/// What you already know about the scammer. The user writes the chronology, so
/// it cannot be prefilled.
final class ReportPrefill {
  /// Creates a prefill. Throws [ArgumentError] with no identifier, because the
  /// form could never be sent.
  ///
  /// [identifiers] are `TraciveQuery.searchQueryIndex` values, shown read-only.
  /// The user can change [incidentDate], though not to a day in the future, and
  /// [title], and can remove [attachments], each compressed when the form
  /// opens.
  ReportPrefill({
    required this.identifiers,
    this.incidentDate,
    this.title,
    this.attachments = const <ReportAttachment>[],
  }) {
    if (identifiers.isEmpty) {
      throw ArgumentError.value(
        identifiers,
        'identifiers',
        'A ReportPrefill needs at least one identifier.',
      );
    }
  }

  /// A prefill about one [query].
  ReportPrefill.forQuery(
    TraciveQuery query, {
    DateTime? incidentDate,
    String? title,
    List<ReportAttachment> attachments = const <ReportAttachment>[],
  }) : this(
          identifiers: <String>[query.searchQueryIndex],
          incidentDate: incidentDate,
          title: title,
          attachments: attachments,
        );

  /// `TraciveQuery.searchQueryIndex` values.
  final List<String> identifiers;

  /// The day it happened.
  final DateTime? incidentDate;

  /// A suggested title.
  final String? title;

  /// Receipts or screenshots to attach.
  final List<ReportAttachment> attachments;
}

/// How Tracive's form ended.
sealed class ReportFormOutcome {
  const ReportFormOutcome();
}

/// The report was filed. Keep [reportId] with your transaction: reports cannot
/// be listed.
final class ReportFormSubmitted extends ReportFormOutcome {
  /// Creates the outcome.
  const ReportFormSubmitted(this.reportId, this.status);

  /// The filed report.
  final String reportId;

  /// Its stage right after filing.
  final ReportStatus status;
}

/// No grant, or a grant without `report.create`. Authorize with the scope and
/// open it again.
final class ReportFormNeedsConsent extends ReportFormOutcome {
  /// Creates the outcome.
  const ReportFormNeedsConsent();
}

/// The user closed the form.
final class ReportFormUserCancelled extends ReportFormOutcome {
  /// Creates the outcome.
  const ReportFormUserCancelled();
}

/// How Tracive's status screen ended.
enum ReportStatusOutcome {
  /// The user closed it.
  closed,

  /// No grant, or a grant without `report.read`. Authorize with the scope and
  /// open it again.
  needsConsent,
}

/// Tracive's report form, as a native screen over your app.
abstract final class TraciveReportForm {
  static Future<ReportFormOutcome>? _open;

  /// Shows the form and waits for it to close. Closing it cancels an upload in
  /// progress. A second call while it is open joins the first.
  static Future<ReportFormOutcome> present(
    TraciveReports reports, {
    required ReportPrefill prefill,
    TraciveReportTheme? theme,
  }) =>
      _open ??=
          _present(reports, prefill, theme).whenComplete(() => _open = null);

  static Future<ReportFormOutcome> _present(
    TraciveReports reports,
    ReportPrefill prefill,
    TraciveReportTheme? theme,
  ) async {
    final date = prefill.incidentDate;
    final reply = await ReportBridge.instance
        .call<Map<Object?, Object?>>('presentForm', <String, Object?>{
      'reports': await reportsHandle(reports),
      'identifiers': prefill.identifiers,
      'incidentDate': date == null ? null : reportDay(date),
      'title': prefill.title,
      'attachments': prefill.attachments
          .map(
            (attachment) => <String, Object?>{
              'bytes': attachment.bytes,
              'mimeType': attachment.mimeType,
            },
          )
          .toList(growable: false),
      ..._themeWire(theme),
    });
    return switch (reply!['outcome']) {
      'submitted' => ReportFormSubmitted(
          reply['reportId'] as String,
          ReportStatus.fromWire(reply['status'] as String?),
        ),
      'needsConsent' => const ReportFormNeedsConsent(),
      _ => const ReportFormUserCancelled(),
    };
  }
}

/// Tracive's status screen for one report, as a native screen over your app.
abstract final class TraciveReportStatus {
  static Future<ReportStatusOutcome>? _open;

  /// Shows the screen and waits for it to close. Needs a grant with
  /// `report.read`. A second call while it is open joins the first.
  static Future<ReportStatusOutcome> present(
    TraciveReports reports,
    String reportId, {
    TraciveReportTheme? theme,
  }) =>
      _open ??=
          _present(reports, reportId, theme).whenComplete(() => _open = null);

  static Future<ReportStatusOutcome> _present(
    TraciveReports reports,
    String reportId,
    TraciveReportTheme? theme,
  ) async {
    final outcome = await ReportBridge.instance
        .call<String>('presentStatus', <String, Object?>{
      'reports': await reportsHandle(reports),
      'reportId': reportId,
      ..._themeWire(theme),
    });
    return outcome == 'needsConsent'
        ? ReportStatusOutcome.needsConsent
        : ReportStatusOutcome.closed;
  }
}

Map<String, Object?> _themeWire(TraciveReportTheme? theme) => <String, Object?>{
      'primaryColor': theme?.primaryColor?.toARGB32(),
      'cornerRadius': theme?.cornerRadius,
    };
