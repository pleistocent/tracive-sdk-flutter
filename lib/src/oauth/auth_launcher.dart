// Copyright (c) Tracive. Licensed under the Apache License, Version 2.0.
//
// Opening URLs outside the app — steps 1 and 3 of the flow in `doc/oauth.md`.
//
//   "open the authorize URL via **Custom Tabs (Android) / `UIApplication.open`
//    Universal Link (iOS)**. **Never a WebView** — App Links do not fire from
//    an in-app WebView (RFC 8252 also forbids it)."
//
// That is why this interface has exactly one opening method and it is named
// [openExternally]. There is no `openInWebView`, no `mode` parameter, no way to
// ask for an embedded browser. The shipped implementation calls
// `url_launcher`'s `launchUrl(url, mode: LaunchMode.externalApplication)`, and
// external-application mode is the whole point: it hands the URL to the OS, so
// Android's App Links / iOS's Universal Links resolve to the Tracive app if it
// is installed. `LaunchMode.inAppWebView` would keep the URL inside the host
// app's WebView, where the App Link never fires — and where the host app can
// read the user's Tracive credentials, which is what RFC 8252 §8.12 forbids.
//
// The interface is pure Dart so the OAuth flow is testable with no Flutter
// engine; the `url_launcher` implementation is `UrlLauncherAuthLauncher` in
// `platform_flutter.dart`, selected automatically on Flutter.

/// Opens URLs in the operating system's own handler.
abstract class AuthLauncher {
  /// Allows `const` implementations.
  const AuthLauncher();

  /// Whether the OS has a handler for [url].
  ///
  /// Used only as the **app-presence probe**, against a custom
  /// scheme (`tracive://…`). Asking this about an `https://` URL is
  /// meaningless: a browser is always installed, so the answer is always
  /// `true`, which is exactly why the probe cannot use the authorize URL.
  ///
  /// The probe needs a manifest declaration to work at all:
  ///
  /// * **Android** — package visibility. Declare a `<queries><intent>` for
  ///   every scheme the probe may use, in your own
  ///   `android/app/src/main/AndroidManifest.xml`. Nothing declares it for you:
  ///   this package is pure Dart with no Android module, so there is no
  ///   manifest of its own to merge into yours. Without the declaration
  ///   Android 11+ answers `false` even when the app is installed.
  ///
  ///   Declare the **scheme**, not a `<package>` entry. The probe resolves an
  ///   intent, so a scheme query is what answers it; a `<package>` entry names
  ///   one build and so cannot follow [TraciveEnvironment], which is what the
  ///   probe does. See `doc/oauth.md` for the block to paste.
  /// * **iOS** — add every such scheme to `LSApplicationQueriesSchemes` in
  ///   `Info.plist`. Without it `canOpenURL` answers `false`, again regardless
  ///   of the truth.
  ///
  /// A `false` from a missing declaration is indistinguishable from a `false`
  /// from a missing app, and both send the user to the install link. That is
  /// annoying but safe; the reverse would be worse.
  Future<bool> canOpen(Uri url);

  /// Opens [url] in the OS's handler — a Custom Tab / the default browser, or
  /// the Tracive app when the URL is one of its App Links / Universal Links.
  ///
  /// Returns whether the OS accepted it. **Must never** open an in-app WebView.
  Future<bool> openExternally(Uri url);
}

/// The launcher used when the SDK is running outside Flutter.
///
/// It answers "no handler" and "could not open" for everything, because in a
/// plain Dart process that is the truth: there is no OS UI to hand a URL to.
/// The practical effect is that `authorize()` reports
/// `AuthResult.appNotInstalled` instead of throwing — a unit test or a
/// server-side isolate gets a defined answer rather than a crash.
class UnsupportedAuthLauncher extends AuthLauncher {
  /// Creates the no-op launcher.
  const UnsupportedAuthLauncher();

  @override
  Future<bool> canOpen(Uri url) async => false;

  @override
  Future<bool> openExternally(Uri url) async => false;

  @override
  String toString() => 'UnsupportedAuthLauncher()';
}
