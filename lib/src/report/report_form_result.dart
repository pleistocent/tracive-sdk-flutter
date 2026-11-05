// Copyright 2026 PT Pleistocent Teknologi Nusantara.
// Licensed under the Apache License, Version 2.0.

/// Outcome of `TraciveClient.openReportForm`.
///
/// Sealed, so a `switch` over it is exhaustive:
///
/// ```dart
/// switch (await client.openReportForm(query, attachments: receipt)) {
///   case ReportFormOpened(:final attachmentsDelivered): /* form is open */
///   case ReportFormCancelled():                         /* iOS: user backed out */
///   case ReportFormInstallPageOpened():                 /* no Tracive app */
///   case ReportFormFailed(:final error):                /* nothing was opened */
/// }
/// ```
sealed class ReportFormResult {
  const ReportFormResult();

  /// The Tracive app opened its report form.
  const factory ReportFormResult.opened({
    required bool attachmentsDelivered,
  }) = ReportFormOpened;

  /// The user dismissed the iOS "Open in" sheet, or sent the file somewhere
  /// other than the Tracive app.
  const factory ReportFormResult.cancelled() = ReportFormCancelled;

  /// The Tracive app is not installed; the install page was opened.
  const factory ReportFormResult.installPageOpened() =
      ReportFormInstallPageOpened;

  /// Nothing was opened.
  const factory ReportFormResult.failed(ReportFormError error) =
      ReportFormFailed;
}

/// The Tracive app opened its report form.
///
/// [attachmentsDelivered] is `true` when the app received the whole package:
/// identifier, date and attachments. It is `false` when the installed app is
/// too old to accept a package and was opened on the identifier alone, so the
/// form shows the account but not the date or the receipt.
final class ReportFormOpened extends ReportFormResult {
  /// Creates an opened outcome.
  const ReportFormOpened({required this.attachmentsDelivered});

  /// Whether the date and the attachments reached the app too.
  final bool attachmentsDelivered;

  @override
  bool operator ==(Object other) =>
      other is ReportFormOpened &&
      other.attachmentsDelivered == attachmentsDelivered;

  @override
  int get hashCode => Object.hash(ReportFormOpened, attachmentsDelivered);

  @override
  String toString() =>
      'ReportFormResult.opened(attachmentsDelivered: $attachmentsDelivered)';
}

/// iOS only: the user closed the "Open in" sheet, picked "Save to Files" or
/// another app, or cancelled the system prompt before the app opened.
final class ReportFormCancelled extends ReportFormResult {
  /// Creates a cancelled outcome.
  const ReportFormCancelled();

  @override
  bool operator ==(Object other) => other is ReportFormCancelled;

  @override
  int get hashCode => (ReportFormCancelled).hashCode;

  @override
  String toString() => 'ReportFormResult.cancelled()';
}

/// The Tracive build for this environment is not installed.
///
/// The same clean install link `authorize()` opens was opened, carrying neither
/// the identifier nor the files. There is no deferred hand-off: the user
/// installs Tracive and taps your button again.
final class ReportFormInstallPageOpened extends ReportFormResult {
  /// Creates an install-page outcome.
  const ReportFormInstallPageOpened();

  @override
  bool operator ==(Object other) => other is ReportFormInstallPageOpened;

  @override
  int get hashCode => (ReportFormInstallPageOpened).hashCode;

  @override
  String toString() => 'ReportFormResult.installPageOpened()';
}

/// Nothing was opened, and [error] says why.
final class ReportFormFailed extends ReportFormResult {
  /// Creates a failed outcome.
  const ReportFormFailed(this.error);

  /// Why nothing was opened.
  final ReportFormError error;

  @override
  bool operator ==(Object other) =>
      other is ReportFormFailed && other.error == error;

  @override
  int get hashCode => Object.hash(ReportFormFailed, error);

  @override
  String toString() => 'ReportFormResult.failed($error)';
}

/// Why `openReportForm` opened nothing.
///
/// Every case except [ReportFormPlatformFailure] is a validation failure, found
/// before anything is written or opened, and checked in this order:
/// [ReportFormIncidentDateInFuture], [ReportFormTooManyAttachments], then per
/// attachment in order [ReportFormUnsupportedType], [ReportFormContentMismatch]
/// and [ReportFormPdfTooLarge], and last [ReportFormPackageTooLarge].
///
/// [code] is spelled identically in every Tracive SDK.
sealed class ReportFormError {
  const ReportFormError();

  /// The cross-SDK code, e.g. `TOO_MANY_ATTACHMENTS`.
  String get code;
}

/// The incident date is after the device's local today.
final class ReportFormIncidentDateInFuture extends ReportFormError {
  /// Creates the error.
  const ReportFormIncidentDateInFuture();

  @override
  String get code => 'INCIDENT_DATE_IN_FUTURE';

  @override
  bool operator ==(Object other) => other is ReportFormIncidentDateInFuture;

  @override
  int get hashCode => code.hashCode;

  @override
  String toString() => code;
}

/// More attachments than the report form takes: [max] is 5, or 10 when the
/// query is a phone number.
final class ReportFormTooManyAttachments extends ReportFormError {
  /// Creates the error.
  const ReportFormTooManyAttachments(this.max);

  /// How many this query allows.
  final int max;

  @override
  String get code => 'TOO_MANY_ATTACHMENTS';

  @override
  bool operator ==(Object other) =>
      other is ReportFormTooManyAttachments && other.max == max;

  @override
  int get hashCode => Object.hash(code, max);

  @override
  String toString() => '$code(max: $max)';
}

/// The attachment at [index] declares a type the report form does not take.
final class ReportFormUnsupportedType extends ReportFormError {
  /// Creates the error.
  const ReportFormUnsupportedType(this.index);

  /// Position in the `attachments` list, from 0.
  final int index;

  @override
  String get code => 'UNSUPPORTED_TYPE';

  @override
  bool operator ==(Object other) =>
      other is ReportFormUnsupportedType && other.index == index;

  @override
  int get hashCode => Object.hash(code, index);

  @override
  String toString() => '$code(index: $index)';
}

/// The bytes of the attachment at [index] are not the type it declares.
/// Empty bytes never match.
final class ReportFormContentMismatch extends ReportFormError {
  /// Creates the error.
  const ReportFormContentMismatch(this.index);

  /// Position in the `attachments` list, from 0.
  final int index;

  @override
  String get code => 'CONTENT_MISMATCH';

  @override
  bool operator ==(Object other) =>
      other is ReportFormContentMismatch && other.index == index;

  @override
  int get hashCode => Object.hash(code, index);

  @override
  String toString() => '$code(index: $index)';
}

/// The PDF at [index] is 1 MiB (1,048,576 bytes) or larger.
final class ReportFormPdfTooLarge extends ReportFormError {
  /// Creates the error.
  const ReportFormPdfTooLarge(this.index);

  /// Position in the `attachments` list, from 0.
  final int index;

  @override
  String get code => 'PDF_TOO_LARGE';

  @override
  bool operator ==(Object other) =>
      other is ReportFormPdfTooLarge && other.index == index;

  @override
  int get hashCode => Object.hash(code, index);

  @override
  String toString() => '$code(index: $index)';
}

/// The encoded package would exceed [max] bytes (20 MiB).
///
/// The attachments travel base64-encoded, so they may total about 15 MiB.
final class ReportFormPackageTooLarge extends ReportFormError {
  /// Creates the error.
  const ReportFormPackageTooLarge(this.max);

  /// The cap on the encoded package, in bytes.
  final int max;

  @override
  String get code => 'PACKAGE_TOO_LARGE';

  @override
  bool operator ==(Object other) =>
      other is ReportFormPackageTooLarge && other.max == max;

  @override
  int get hashCode => Object.hash(code, max);

  @override
  String toString() => '$code(max: $max)';
}

/// The platform could not complete the hand-off.
///
/// [reason] is a short token this SDK writes, never platform text:
///
/// * `missing_plugin` — the native half is not in this build. Rebuild the app
///   after adding or upgrading the package; a hot restart is not enough.
/// * `busy` — iOS: the "Open in" sheet from an earlier call is still showing.
/// * `write_failed` — the package could not be written to the cache folder.
/// * `provider_unavailable` — Android: the SDK's file provider is missing
///   from the merged manifest.
/// * `activity_not_found` — Android: the Tracive app refused the intent.
/// * `no_view_controller` — iOS: no window to present the sheet from.
/// * `menu_not_presented` — iOS: the sheet could not be shown.
/// * `install_link_refused` — the OS would not open the install link.
/// * `unexpected` — anything else.
final class ReportFormPlatformFailure extends ReportFormError {
  /// Creates the error.
  const ReportFormPlatformFailure(this.reason);

  /// What failed, as a short token.
  final String reason;

  @override
  String get code => 'PLATFORM_FAILURE';

  @override
  bool operator ==(Object other) =>
      other is ReportFormPlatformFailure && other.reason == reason;

  @override
  int get hashCode => Object.hash(code, reason);

  @override
  String toString() => '$code($reason)';
}
