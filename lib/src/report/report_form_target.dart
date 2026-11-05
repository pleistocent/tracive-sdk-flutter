// Copyright 2026 PT Pleistocent Teknologi Nusantara.
// Licensed under the Apache License, Version 2.0.

import '../model/tracive_environment.dart';

/// Which build of the Tracive app `openReportForm` hands the report to.
///
/// Normally chosen for you from the client's environment by [forEnvironment]:
/// [sandbox] for `TraciveEnvironment.sandbox`, [production] for everything
/// else, a custom base URL included (a proxy says nothing about which app is
/// on the device).
///
/// Each build has its own file extension on purpose. iOS offers every app that
/// claims an extension, so with one shared extension a device holding both the
/// sandbox and the production app would list both, and a sandbox report picked
/// into production would open a real report form.
final class ReportFormTarget {
  /// A build the SDK does not know about, for testing against it — a QA build,
  /// for instance.
  ///
  /// On Android that build also needs a `<queries><package>` entry in your
  /// own manifest, because the SDK's merged manifest only makes the production
  /// and sandbox builds visible. On iOS both of its schemes need
  /// `LSApplicationQueriesSchemes` entries.
  ///
  /// Throws [ArgumentError] for a value that cannot name an application id, a
  /// URL scheme or a file extension.
  factory ReportFormTarget({
    required String androidPackage,
    required String iosBundleId,
    required String appScheme,
    required String capabilityScheme,
    required String fileExtension,
  }) {
    _require(androidPackage, 'androidPackage', _applicationId);
    _require(iosBundleId, 'iosBundleId', _applicationId);
    _require(appScheme, 'appScheme', _scheme);
    _require(capabilityScheme, 'capabilityScheme', _scheme);
    _require(fileExtension, 'fileExtension', _extension);
    return ReportFormTarget._(
      androidPackage: androidPackage,
      iosBundleId: iosBundleId,
      appScheme: appScheme,
      capabilityScheme: capabilityScheme,
      fileExtension: fileExtension,
    );
  }

  const ReportFormTarget._({
    required this.androidPackage,
    required this.iosBundleId,
    required this.appScheme,
    required this.capabilityScheme,
    required this.fileExtension,
  });

  /// The production Tracive app.
  static const ReportFormTarget production = ReportFormTarget._(
    androidPackage: 'com.pleistocent.tracive',
    iosBundleId: 'com.pleistocent.tracive',
    appScheme: 'tracive',
    capabilityScheme: 'tracive-report',
    fileExtension: 'tracivereport',
  );

  /// The sandbox Tracive app.
  static const ReportFormTarget sandbox = ReportFormTarget._(
    androidPackage: 'com.pleistocent.tracive.sandbox',
    iosBundleId: 'com.pleistocent.tracive.sandbox',
    appScheme: 'tracivesandbox',
    capabilityScheme: 'tracivesandbox-report',
    fileExtension: 'tracivesandboxreport',
  );

  /// The build that belongs to [environment].
  static ReportFormTarget forEnvironment(TraciveEnvironment environment) =>
      environment == TraciveEnvironment.sandbox ? sandbox : production;

  /// The MIME type of the package on Android, the same for every build.
  static const String androidMimeType = 'application/vnd.tracive.report+json';

  /// Android application id. The hand-off and the fallback link are sent to
  /// this package only, so no other app can intercept them.
  final String androidPackage;

  /// iOS bundle id. Delivery counts only when the app the user picks in the
  /// "Open in" sheet has this id.
  final String iosBundleId;

  /// The app's URL scheme: the presence probe on iOS, and the fallback link
  /// `<appScheme>://report/create?media=…` on both platforms.
  final String appScheme;

  /// iOS only: the scheme registered by app versions that accept a package.
  /// The sheet itself cannot tell an old app from a new one.
  final String capabilityScheme;

  /// The package file's extension, which decides which apps iOS offers.
  final String fileExtension;

  static final RegExp _applicationId = RegExp(
    r'^[A-Za-z][A-Za-z0-9_-]*(\.[A-Za-z][A-Za-z0-9_-]*)+$',
  );
  static final RegExp _scheme = RegExp(r'^[A-Za-z][A-Za-z0-9+.-]*$');
  static final RegExp _extension = RegExp(r'^[A-Za-z0-9]+$');

  static void _require(String value, String name, RegExp shape) {
    if (!shape.hasMatch(value)) {
      throw ArgumentError.value(value, name, 'is not a valid $name');
    }
  }

  @override
  bool operator ==(Object other) =>
      other is ReportFormTarget &&
      other.androidPackage == androidPackage &&
      other.iosBundleId == iosBundleId &&
      other.appScheme == appScheme &&
      other.capabilityScheme == capabilityScheme &&
      other.fileExtension == fileExtension;

  @override
  int get hashCode => Object.hash(
        androidPackage,
        iosBundleId,
        appScheme,
        capabilityScheme,
        fileExtension,
      );

  @override
  String toString() => 'ReportFormTarget($androidPackage, $iosBundleId, '
      '$appScheme, $capabilityScheme, .$fileExtension)';
}
