// Copyright (c) Tracive. Licensed under the Apache License, Version 2.0.

import 'package:flutter/services.dart' show appFlavor;
import 'package:tracive_sdk/tracive_sdk.dart';

/// How this build of the example runs: `flutter run --flavor <name>`.
///
/// `demo` is the default (`default-flavor` in pubspec.yaml) and never opens a
/// socket, so a fresh clone runs with no credentials. `sandbox` and
/// `production` are the real integration against that environment.
///
/// Each flavor installs as its own app. The SDK's token store and cache are
/// not keyed by environment, so a sandbox grant and sandbox verdicts left in
/// an app later rebuilt as production would be sent to production and served
/// as production answers. Separate apps need separate redirect schemes too, or
/// the OS picks which one receives the authorization code.
///
/// The redirect has to match what the platform registers: `productFlavors` in
/// `android/app/build.gradle.kts`, and `ios/Flavors/*.xcconfig`.
enum ExampleFlavor {
  demo(
    environment: null,
    clientId: 'demo-client',
    redirectUri: 'tracive-flutter-demo://oauth/callback',
  ),
  sandbox(
    environment: TraciveEnvironment.sandbox,
    // TODO(partner): the client id Tracive issued you in sandbox, with the
    // redirect below registered on it. Sandbox and production are separate
    // registrations: a sandbox client id is unknown to production.
    clientId: 'REPLACE_WITH_YOUR_SANDBOX_CLIENT_ID',
    // TODO(partner): your own redirect. A private-use scheme only because this
    // example controls no domain; use an App Link / Universal Link you own —
    // SECURITY.md says why.
    redirectUri: 'tracive-flutter-sandbox://oauth/callback',
  ),
  production(
    environment: TraciveEnvironment.production,
    // TODO(partner): the client id Tracive issued you in production.
    clientId: 'REPLACE_WITH_YOUR_PRODUCTION_CLIENT_ID',
    // TODO(partner): your own redirect, as for sandbox.
    redirectUri: 'tracive-flutter://oauth/callback',
  );

  const ExampleFlavor({
    required this.environment,
    required this.clientId,
    required this.redirectUri,
  });

  /// The deployment a live flavor talks to; `null` for [demo].
  final TraciveEnvironment? environment;

  final String clientId;

  final String redirectUri;

  bool get isLive => environment != null;

  /// The flavor this binary was built with.
  ///
  /// `null` means no `--flavor` reached the build — `flutter test`, or a
  /// Flutter too old to read `default-flavor` — and that is the demo.
  static ExampleFlavor get current {
    final name = appFlavor;
    if (name == null) return demo;
    return values.firstWhere(
      (flavor) => flavor.name == name,
      orElse: () => throw StateError(
        'No example flavor named "$name". '
        'Expected one of ${values.map((f) => f.name).join(", ")}.',
      ),
    );
  }
}
