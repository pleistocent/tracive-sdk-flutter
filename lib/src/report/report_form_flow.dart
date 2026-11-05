// Copyright 2026 PT Pleistocent Teknologi Nusantara.
// Licensed under the Apache License, Version 2.0.
//
// The decision chain behind `TraciveClient.openReportForm`. It lives in Dart,
// not in the native halves, so that every branch is unit-tested with a fake.

import 'dart:typed_data';

import '../oauth/auth_launcher.dart';
import '../oauth/authorize_url.dart';
import 'report_attachment.dart';
import 'report_form_launcher.dart';
import 'report_form_result.dart';
import 'report_form_target.dart';
import 'report_package.dart';

/// A platform failure with a reason token, raised by the method-channel
/// launcher. Any other exception is reported as `unexpected`.
final class ReportFormPlatformException implements Exception {
  /// Creates the exception.
  const ReportFormPlatformException(this.reason);

  /// One of the tokens listed on [ReportFormPlatformFailure].
  final String reason;

  @override
  String toString() => 'ReportFormPlatformException($reason)';
}

/// Runs the chain above. Never throws.
Future<ReportFormResult> runReportForm({
  required String query,
  required DateTime? incidentDate,
  required List<ReportAttachment> attachments,
  required DateTime today,
  required ReportFormTarget target,
  required ReportFormAnchor? anchor,
  required ReportFormLauncher launcher,
  required AuthLauncher authLauncher,
  required String installUrl,
  required String? clientId,
}) async {
  final Uint8List package;
  try {
    final built = buildReportPackage(
      query: query,
      incidentDate: incidentDate,
      attachments: attachments,
      today: today,
    );
    final error = built.error;
    if (error != null) return ReportFormResult.failed(error);
    package = built.bytes!;
  } catch (_) {
    return const ReportFormResult.failed(
      ReportFormPlatformFailure('unexpected'),
    );
  }

  try {
    switch (await launcher.handOver(target, package, anchor: anchor)) {
      case ReportHandoffStarted():
        return const ReportFormResult.opened(attachmentsDelivered: true);
      case ReportHandoffSentTo(:final bundleId):
        // Any app may claim the extension; only the target build counts.
        return bundleId == target.iosBundleId
            ? const ReportFormResult.opened(attachmentsDelivered: true)
            : const ReportFormResult.cancelled();
      case ReportHandoffDismissed():
        return const ReportFormResult.cancelled();
      case ReportHandoffNotAccepted():
        break;
    }

    if (await launcher.isInstalled(target)) {
      final opened = await launcher.openLink(
        target,
        buildReportLink(target.appScheme, query),
      );
      return opened
          ? const ReportFormResult.opened(attachmentsDelivered: false)
          : const ReportFormResult.cancelled();
    }

    // The install link goes through a third-party link service, so it carries
    // neither the identifier nor the files.
    final installLink = buildInstallUrl(installUrl, clientId: clientId);
    if (await authLauncher.openExternally(installLink)) {
      return const ReportFormResult.installPageOpened();
    }
    return const ReportFormResult.failed(
      ReportFormPlatformFailure('install_link_refused'),
    );
  } on ReportFormPlatformException catch (error) {
    return ReportFormResult.failed(ReportFormPlatformFailure(error.reason));
  } catch (_) {
    return const ReportFormResult.failed(
      ReportFormPlatformFailure('unexpected'),
    );
  }
}
