// Copyright 2026 PT Pleistocent Teknologi Nusantara.
// Licensed under the Apache License, Version 2.0.

/// Why a call failed.
enum ReportErrorCode {
  /// No grant, or a grant without the scope. Run your authorize flow, then
  /// call again.
  needsConsent('NEEDS_CONSENT'),

  /// The user must verify their email in Tracive.
  emailNotVerified('EMAIL_NOT_VERIFIED'),

  /// Unknown, not sent through this app for this user, or older than 30 days.
  reportNotFound('REPORT_NOT_FOUND'),

  /// The terms changed. Read the requirements again, show the new links, and
  /// build a new draft.
  termsOutdated('TERMS_OUTDATED'),

  /// A field failed. The message names it.
  invalidReport('INVALID_REPORT'),

  /// A file is missing, or its bytes do not match its type.
  attachmentInvalid('ATTACHMENT_INVALID'),

  /// Account or device cap. See [TraciveReportException.retryAfterSeconds].
  dailyLimitReached('DAILY_LIMIT_REACHED'),

  /// Reporting is switched off for now.
  reportingDisabled('REPORTING_DISABLED'),

  /// No answer. Call `submit` again with the same draft: nothing is sent twice.
  network('NETWORK'),

  /// The server failed, or answered something this version does not know.
  server('SERVER'),

  /// Neither an image nor a PDF.
  unsupportedFile('UNSUPPORTED_FILE'),

  /// A PDF of 1 MiB or more.
  fileTooLarge('FILE_TOO_LARGE'),

  /// The image could not be decoded, or could not be brought under the size
  /// limit.
  imageUnreadable('IMAGE_UNREADABLE'),

  /// `cancelSubmit` or `dispose` stopped the call. A cancelled draft can be
  /// sent again.
  cancelled('CANCELLED');

  const ReportErrorCode(this.wire);

  /// The name both native cores use.
  final String wire;

  /// [server] for a value this version does not know.
  static ReportErrorCode fromWire(String? value) => values.firstWhere(
        (code) => code.wire == value,
        orElse: () => ReportErrorCode.server,
      );
}

/// A failed report call. The message never carries user data.
final class TraciveReportException implements Exception {
  /// Creates the exception. Throw one with [ReportErrorCode.needsConsent] from
  /// a `TraciveReports.withTokens` callback when your backend has no grant.
  const TraciveReportException(
    this.code,
    this.message, {
    this.httpStatus,
    this.retryAfterSeconds,
  });

  /// Why the call failed.
  final ReportErrorCode code;

  /// A sentence for logs, not for the user.
  final String message;

  /// The HTTP status, when the error came from a response.
  final int? httpStatus;

  /// Seconds to wait, for [ReportErrorCode.dailyLimitReached].
  final int? retryAfterSeconds;

  @override
  String toString() => 'TraciveReportException(${code.wire}): $message';
}
