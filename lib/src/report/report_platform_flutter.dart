// Copyright 2026 PT Pleistocent Teknologi Nusantara.
// Licensed under the Apache License, Version 2.0.
//
// The Flutter half of the conditional import in `report_platform_default.dart`.
// Only compiled when `dart:ui` exists. The native halves are
// `android/src/main/kotlin/id/tracive/sdk/flutter/TraciveSdkPlugin.kt` and
// `ios/tracive_sdk/Sources/tracive_sdk/TraciveSdkPlugin.swift`.

import 'package:flutter/services.dart';

import 'report_form_flow.dart';
import 'report_form_launcher.dart';
import 'report_form_target.dart';

/// The default [ReportFormLauncher] on Flutter: [MethodChannelReportFormLauncher].
ReportFormLauncher createDefaultReportFormLauncher() =>
    const MethodChannelReportFormLauncher();

/// [ReportFormLauncher] over this package's own method channel.
///
/// Each method is one native step and answers with what happened; every
/// decision stays in Dart.
class MethodChannelReportFormLauncher extends ReportFormLauncher {
  /// Creates the launcher.
  const MethodChannelReportFormLauncher();

  /// The channel name the native halves register.
  static const MethodChannel channel = MethodChannel('tracive_sdk/report_form');

  @override
  Future<ReportHandoff> handOver(
    ReportFormTarget target,
    Uint8List package, {
    ReportFormAnchor? anchor,
  }) async {
    final reply = await _invoke<Map<Object?, Object?>>(
      'handOver',
      <String, Object?>{
        'androidPackage': target.androidPackage,
        'capabilityScheme': target.capabilityScheme,
        'fileExtension': target.fileExtension,
        'mimeType': ReportFormTarget.androidMimeType,
        'package': package,
        if (anchor != null)
          'anchor': <String, double>{
            'left': anchor.left,
            'top': anchor.top,
            'width': anchor.width,
            'height': anchor.height,
          },
      },
    );
    return switch (reply?['outcome']) {
      'started' => const ReportHandoff.started(),
      'sentTo' => ReportHandoff.sentTo('${reply?['bundleId'] ?? ''}'),
      'dismissed' => const ReportHandoff.dismissed(),
      'notAccepted' => const ReportHandoff.notAccepted(),
      _ => throw const ReportFormPlatformException('unexpected'),
    };
  }

  @override
  Future<bool> isInstalled(ReportFormTarget target) async =>
      await _invoke<bool>('isInstalled', <String, Object?>{
        'androidPackage': target.androidPackage,
        'appScheme': target.appScheme,
      }) ??
      false;

  @override
  Future<bool> openLink(ReportFormTarget target, Uri link) async =>
      await _invoke<bool>('openLink', <String, Object?>{
        'androidPackage': target.androidPackage,
        'link': link.toString(),
      }) ??
      false;

  /// The platform's own exception text is dropped: only the code, which the
  /// native halves set to one of this SDK's reason tokens, travels on.
  Future<T?> _invoke<T>(String method, Map<String, Object?> arguments) async {
    try {
      return await channel.invokeMethod<T>(method, arguments);
    } on MissingPluginException {
      throw const ReportFormPlatformException('missing_plugin');
    } on PlatformException catch (error) {
      throw ReportFormPlatformException(error.code);
    }
  }

  @override
  String toString() => 'MethodChannelReportFormLauncher()';
}
