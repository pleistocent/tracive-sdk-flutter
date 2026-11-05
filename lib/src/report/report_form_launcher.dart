// Copyright 2026 PT Pleistocent Teknologi Nusantara.
// Licensed under the Apache License, Version 2.0.
//
// The platform half of `openReportForm`.
//
// Dart validates and encodes the package and decides what to do next; the
// platform only performs one step at a time and reports what happened. That is
// what lets every branch of the fallback chain be unit-tested with a fake, in a
// plain `flutter test`, with no device. The shipped implementation is the
// method channel in `report_platform_flutter.dart`, selected automatically on
// Flutter.

import 'dart:typed_data';

import 'report_form_target.dart';

/// Where the iOS "Open in" sheet points from, in logical pixels in the
/// coordinate space of the Flutter view (the same space `localToGlobal`
/// answers in).
///
/// On iPad the sheet is a popover and needs it; on iPhone it is an action
/// sheet and ignores it. Android ignores it.
///
/// ```dart
/// final box = context.findRenderObject()! as RenderBox;
/// final origin = box.localToGlobal(Offset.zero);
/// final anchor = ReportFormAnchor(
///   left: origin.dx, top: origin.dy,
///   width: box.size.width, height: box.size.height,
/// );
/// ```
final class ReportFormAnchor {
  /// Creates an anchor rectangle.
  const ReportFormAnchor({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  /// Distance from the left edge of the Flutter view.
  final double left;

  /// Distance from the top edge of the Flutter view.
  final double top;

  /// Width of the rectangle.
  final double width;

  /// Height of the rectangle.
  final double height;

  @override
  bool operator ==(Object other) =>
      other is ReportFormAnchor &&
      other.left == left &&
      other.top == top &&
      other.width == width &&
      other.height == height;

  @override
  int get hashCode => Object.hash(left, top, width, height);

  @override
  String toString() => 'ReportFormAnchor($left, $top, $width x $height)';
}

/// What happened when the package was offered to the Tracive app.
sealed class ReportHandoff {
  const ReportHandoff();

  /// Android: the app's report activity was started with the package.
  const factory ReportHandoff.started() = ReportHandoffStarted;

  /// iOS: the user picked the app with [ReportHandoffSentTo.bundleId] in the
  /// "Open in" sheet, and iOS is sending it the file.
  const factory ReportHandoff.sentTo(String bundleId) = ReportHandoffSentTo;

  /// iOS: the sheet closed without sending the file to any app.
  const factory ReportHandoff.dismissed() = ReportHandoffDismissed;

  /// The installed app, if any, does not accept a package. Nothing was shown.
  const factory ReportHandoff.notAccepted() = ReportHandoffNotAccepted;
}

/// Android: the activity was started.
final class ReportHandoffStarted extends ReportHandoff {
  /// Creates the outcome.
  const ReportHandoffStarted();

  @override
  bool operator ==(Object other) => other is ReportHandoffStarted;

  @override
  int get hashCode => (ReportHandoffStarted).hashCode;

  @override
  String toString() => 'ReportHandoff.started()';
}

/// iOS: `willBeginSendingToApplication` fired for [bundleId].
final class ReportHandoffSentTo extends ReportHandoff {
  /// Creates the outcome.
  const ReportHandoffSentTo(this.bundleId);

  /// The bundle id of the app the user picked. Not necessarily Tracive's:
  /// any app may claim the file extension.
  final String bundleId;

  @override
  bool operator ==(Object other) =>
      other is ReportHandoffSentTo && other.bundleId == bundleId;

  @override
  int get hashCode => Object.hash(ReportHandoffSentTo, bundleId);

  @override
  String toString() => 'ReportHandoff.sentTo($bundleId)';
}

/// iOS: the sheet was dismissed, or "Save to Files" was picked.
final class ReportHandoffDismissed extends ReportHandoff {
  /// Creates the outcome.
  const ReportHandoffDismissed();

  @override
  bool operator ==(Object other) => other is ReportHandoffDismissed;

  @override
  int get hashCode => (ReportHandoffDismissed).hashCode;

  @override
  String toString() => 'ReportHandoff.dismissed()';
}

/// The package was not offered: Android found no activity in the target that
/// takes it, or iOS could not open the target's capability scheme.
final class ReportHandoffNotAccepted extends ReportHandoff {
  /// Creates the outcome.
  const ReportHandoffNotAccepted();

  @override
  bool operator ==(Object other) => other is ReportHandoffNotAccepted;

  @override
  int get hashCode => (ReportHandoffNotAccepted).hashCode;

  @override
  String toString() => 'ReportHandoff.notAccepted()';
}

/// The three platform steps `openReportForm` is built from.
///
/// Exported so a host app can fake it in its own tests, the way it fakes
/// `AuthLauncher`. An app never implements it for real.
///
/// A failure is a thrown exception, which `openReportForm` reports as
/// `ReportFormFailed(ReportFormPlatformFailure('unexpected'))`; it never
/// escapes.
abstract class ReportFormLauncher {
  /// Allows `const` implementations.
  const ReportFormLauncher();

  /// Offers [package] to [target].
  ///
  /// * Android: writes it to `cache/tracive-sdk/report/` (removing whatever an
  ///   earlier call left there), and starts an explicit `ACTION_VIEW` for
  ///   `ReportFormTarget.androidMimeType` in `target.androidPackage`, with a
  ///   read grant on the SDK's own `content://` URI. [ReportHandoff.started],
  ///   or [ReportHandoff.notAccepted] when nothing in that package takes it.
  /// * iOS: when `target.capabilityScheme` can be opened, writes
  ///   `report.<fileExtension>` to a fresh temporary folder and presents the
  ///   "Open in" sheet from [anchor]; resolves on the user's choice.
  ///   Otherwise [ReportHandoff.notAccepted], with nothing shown.
  Future<ReportHandoff> handOver(
    ReportFormTarget target,
    Uint8List package, {
    ReportFormAnchor? anchor,
  });

  /// Whether [target] is installed and visible to this app.
  ///
  /// Android asks the package manager for `target.androidPackage`; iOS asks
  /// `canOpenURL` about `<appScheme>://`, the same probe `authorize()` uses.
  Future<bool> isInstalled(ReportFormTarget target);

  /// Opens [link] in [target] only (Android: an explicit package; iOS: the
  /// app's own scheme). Returns `false` when iOS reports the open did not
  /// happen, e.g. the user cancelled the system prompt.
  Future<bool> openLink(ReportFormTarget target, Uri link);
}

/// The launcher used outside Flutter, where there is no app to hand anything
/// to: nothing accepts the package and nothing is installed.
class UnsupportedReportFormLauncher extends ReportFormLauncher {
  /// Creates the no-op launcher.
  const UnsupportedReportFormLauncher();

  @override
  Future<ReportHandoff> handOver(
    ReportFormTarget target,
    Uint8List package, {
    ReportFormAnchor? anchor,
  }) async =>
      const ReportHandoff.notAccepted();

  @override
  Future<bool> isInstalled(ReportFormTarget target) async => false;

  @override
  Future<bool> openLink(ReportFormTarget target, Uri link) async => false;

  @override
  String toString() => 'UnsupportedReportFormLauncher()';
}
