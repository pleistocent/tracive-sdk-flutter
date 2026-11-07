// Copyright 2026 PT Pleistocent Teknologi Nusantara.
// Licensed under the Apache License, Version 2.0.

import 'report_error.dart';

/// The OAuth scopes this SDK needs. Add them to the scopes your client
/// requests.
abstract final class TraciveReportScopes {
  /// Send reports.
  static const String create = 'report.create';

  /// Read the status of reports sent through your app.
  static const String read = 'report.read';
}

/// What a report must satisfy right now. Read it before showing a form.
final class ReportRequirements {
  /// Creates the requirements.
  const ReportRequirements({
    required this.enabled,
    required this.remainingToday,
    required this.limits,
    required this.terms,
  });

  /// False while reporting is switched off.
  final bool enabled;

  /// How many more reports this user can send today.
  final int remainingToday;

  /// Field limits, from the server.
  final ReportLimits limits;

  /// The documents the user accepts by submitting. Show a link to each one.
  final List<RequiredTerm> terms;
}

/// Field limits, from the server.
final class ReportLimits {
  /// Creates the limits.
  const ReportLimits({
    required this.titleMaxLength,
    required this.chronologyMinLength,
    required this.chronologyMaxLength,
    required this.commentMaxLength,
    required this.maxIdentifiers,
    required this.attachmentsPerIdentifier,
    required this.extraAttachmentsWithPhone,
    required this.maxAttachmentBytes,
    required this.attachmentTypes,
  });

  /// Longest title, in UTF-16 code units.
  final int titleMaxLength;

  /// Shortest chronology.
  final int chronologyMinLength;

  /// Longest chronology.
  final int chronologyMaxLength;

  /// Longest comment.
  final int commentMaxLength;

  /// Most identifiers one report can carry.
  final int maxIdentifiers;

  /// Files allowed per identifier.
  final int attachmentsPerIdentifier;

  /// Extra files allowed when an identifier is a phone number.
  final int extraAttachmentsWithPhone;

  /// Largest file the server takes.
  final int maxAttachmentBytes;

  /// The MIME types the server takes.
  final List<String> attachmentTypes;
}

/// One document the user accepts by submitting.
final class RequiredTerm {
  /// Creates the term.
  const RequiredTerm({
    required this.id,
    required this.version,
    required this.url,
  });

  /// The document, such as `TERMS_OF_SERVICE`.
  final String id;

  /// The version the user accepts.
  final String version;

  /// Where the document is published. Show a link to it.
  final String url;
}

/// A report's stage. It never says what a review concluded.
enum ReportStatus {
  /// Accepted, and not picked up yet.
  submitted('SUBMITTED'),

  /// Being reviewed.
  inReview('IN_REVIEW'),

  /// The review is finished.
  reviewed('REVIEWED'),

  /// The user must revise it. `TraciveReports.openInTracive` opens it there.
  needRevision('NEED_REVISION');

  const ReportStatus(this.wire);

  /// The name both native cores use.
  final String wire;

  /// [inReview] for a value this version does not know.
  static ReportStatus fromWire(String? value) => values.firstWhere(
        (status) => status.wire == value,
        orElse: () => ReportStatus.inReview,
      );
}

/// The outcome of `TraciveReports.submit`.
sealed class SubmitResult {
  const SubmitResult();
}

/// Accepted. Keep [reportId] with your transaction; there is no way to list
/// reports.
final class ReportSubmitted extends SubmitResult {
  /// Creates the result.
  const ReportSubmitted(this.reportId, this.status);

  /// The filed report.
  final String reportId;

  /// Its stage right after filing.
  final ReportStatus status;
}

/// No grant, or a grant without [TraciveReportScopes.create]. Authorize and
/// call again with the same draft.
final class ReportNeedsConsent extends SubmitResult {
  /// Creates the result.
  const ReportNeedsConsent();
}

/// The report was not filed. Unless [error] says the draft itself is wrong,
/// call again with the same draft: nothing is sent twice.
final class ReportFailed extends SubmitResult {
  /// Creates the result.
  const ReportFailed(this.error);

  /// What went wrong.
  final TraciveReportException error;
}

/// Field problems a form can show before sending anything.
enum ReportFieldProblem {
  /// No identifier.
  noIdentifier,

  /// More than [ReportLimits.maxIdentifiers].
  tooManyIdentifiers,

  /// The title is blank.
  titleMissing,

  /// Over [ReportLimits.titleMaxLength].
  titleTooLong,

  /// Under [ReportLimits.chronologyMinLength].
  chronologyTooShort,

  /// Over [ReportLimits.chronologyMaxLength].
  chronologyTooLong,

  /// Over [ReportLimits.commentMaxLength].
  commentTooLong,

  /// No file.
  noEvidence,

  /// More files than `ReportDraft.maxEvidence` allows.
  tooManyEvidence,

  /// The date is not a real `YYYY-MM-DD` day.
  incidentDateInvalid,

  /// The date is after today.
  incidentDateInFuture,
}
