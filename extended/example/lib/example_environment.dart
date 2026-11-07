// Copyright 2026 PT Pleistocent Teknologi Nusantara.
// Licensed under the Apache License, Version 2.0.

import 'package:tracive_sdk/tracive_sdk.dart';

/// Tracive's sandbox, unless a build says otherwise. README.md lists the keys
/// `--dart-define-from-file` can set.
abstract final class ExampleEnvironment {
  static const String _baseUrl = String.fromEnvironment('TRACIVE_API_BASE_URL');
  static const String _authorizeUrl =
      String.fromEnvironment('TRACIVE_AUTHORIZE_URL');
  static const String _appScheme = String.fromEnvironment('TRACIVE_APP_SCHEME');
  static const String _redirectScheme = String.fromEnvironment(
    'TRACIVE_REDIRECT_SCHEME',
    defaultValue: 'tracive-extended-flutter-sandbox',
  );

  /// Uses the stand-in for the Tracive API, inside this app.
  static const bool isLocal = bool.fromEnvironment('TRACIVE_EXAMPLE_LOCAL');

  // TODO(partner): the client id Tracive issued you, with this redirect on it.
  /// The OAuth client.
  static const String clientId = String.fromEnvironment(
    'TRACIVE_CLIENT_ID',
    defaultValue: 'REPLACE_WITH_YOUR_SANDBOX_CLIENT_ID',
  );

  // TODO(partner): an App Link or Universal Link you own.
  /// Must match the scheme the Android manifest and Info.plist register.
  static const String redirectUri = '$_redirectScheme://oauth/callback';

  /// The API to talk to.
  static TraciveEnvironment get api {
    if (_baseUrl.isEmpty) return TraciveEnvironment.sandbox;
    if (_authorizeUrl.isEmpty) {
      throw StateError('TRACIVE_API_BASE_URL needs TRACIVE_AUTHORIZE_URL.');
    }
    return _OverriddenEnvironment(_baseUrl, Uri.parse(_authorizeUrl));
  }

  /// The Tracive build `openInTracive` opens. Null follows [api].
  static ReportFormTarget? get target {
    if (_appScheme.isEmpty) return null;
    // Only the scheme is read here: this example never hands over a package.
    return ReportFormTarget(
      androidPackage: 'com.example.unused',
      iosBundleId: 'com.example.unused',
      appScheme: _appScheme,
      capabilityScheme: _appScheme,
      fileExtension: 'unused',
    );
  }
}

/// A custom host's authorize page is not on its API host, which answers 404,
/// and the client builds its link from [authorizeEndpoint].
final class _OverriddenEnvironment implements TraciveEnvironment {
  _OverriddenEnvironment(String baseUrl, this.authorizeEndpoint)
      : _api = TraciveEnvironment.custom(baseUrl);

  final TraciveEnvironment _api;

  @override
  final Uri authorizeEndpoint;

  @override
  String get baseUrl => _api.baseUrl;

  @override
  String get name => _api.name;

  @override
  Uri resolve(String path) => _api.resolve(path);
}
