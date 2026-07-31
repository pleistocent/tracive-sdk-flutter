// Copyright (c) Tracive. Licensed under the Apache License, Version 2.0.
//
// Platform wiring for Flutter — the SDK specification §6.
//
// The Flutter half of the conditional import declared in
// `platform_default.dart`. **Only compiled when `dart:ui` exists**, which is
// why this is the only file in `lib/` that imports a Flutter plugin: everything
// else stays pure Dart and therefore unit-testable without an engine.
//
// If you are reading this because a `dart test` run failed with "target of URI
// doesn't exist: package:flutter_secure_storage/…", the conditional import is
// doing its job and something imported this file *directly*. Import
// `platform_default.dart if (dart.library.ui) 'platform_flutter.dart'` instead.

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:url_launcher/url_launcher.dart';

import 'auth_launcher.dart';
import 'token_store.dart';

/// The default [TokenStore] on Flutter: [SecureStorageTokenStore].
TokenStore createDefaultTokenStore() => SecureStorageTokenStore();

/// The default [AuthLauncher] on Flutter: [UrlLauncherAuthLauncher].
AuthLauncher createDefaultAuthLauncher() => const UrlLauncherAuthLauncher();

/// Tokens in the Android Keystore / iOS Keychain, via `flutter_secure_storage`
/// — §6's "**never** in SharedPreferences/UserDefaults/plain files".
///
/// Records are JSON, written under two keys derived from [namespace]. Change
/// [namespace] if one app holds grants for more than one Tracive client id;
/// otherwise the second client silently overwrites the first's tokens.
///
/// ## Platform notes worth setting deliberately
///
/// No `IOSOptions` / `AndroidOptions` are passed, so each platform's default
/// applies (Keychain on Apple platforms, Keystore-backed encrypted preferences
/// on Android). Two adjustments are worth making in an app that needs them, by
/// constructing `FlutterSecureStorage` yourself and passing it in:
///
/// * `IOSOptions(accessibility: KeychainAccessibility.first_unlock)` — the
///   Keychain default (`unlocked`) makes the refresh token unreadable while the
///   device is locked, which breaks a refresh from a background task.
/// * `IOSOptions(synchronizable: false)` is already the default; leave it
///   there. A refresh token synced to iCloud Keychain is a refresh token on
///   every device the user owns, which is precisely the multi-device replay
///   that reuse detection exists to punish.
class SecureStorageTokenStore extends TokenStore {
  /// Creates a store.
  ///
  /// Pass [storage] to control the platform options (see the class docs);
  /// otherwise a default `FlutterSecureStorage` is used.
  SecureStorageTokenStore({
    FlutterSecureStorage? storage,
    this.namespace = 'tracive_sdk',
  }) : _storage = storage ?? FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  /// Key prefix. One namespace per Tracive client id.
  final String namespace;

  String get _tokensKey => '$namespace.tokens.v1';
  String get _pendingKey => '$namespace.pending_authorization.v1';

  @override
  Future<TraciveTokens?> read() async {
    final json = decodeStorageJson(await _storage.read(key: _tokensKey));
    if (json == null) return null;
    final tokens = TraciveTokens.fromStorageJson(json);
    // An entry that decoded but carries no access token is corrupt. Treat it as
    // "not signed in" rather than handing an empty bearer token to the API.
    return tokens.hasAccessToken ? tokens : null;
  }

  @override
  Future<void> write(TraciveTokens tokens) => _storage.write(
        key: _tokensKey,
        value: encodeStorageJson(tokens.toStorageJson()),
      );

  @override
  Future<void> clear() async {
    // Both keys, and the pending record first: if the process dies between the
    // two, a leftover pending authorization is harmless, whereas leftover
    // tokens are not.
    await _storage.delete(key: _pendingKey);
    await _storage.delete(key: _tokensKey);
  }

  @override
  Future<PendingAuthorization?> readPending() async {
    final json = decodeStorageJson(await _storage.read(key: _pendingKey));
    return json == null ? null : PendingAuthorization.fromStorageJson(json);
  }

  @override
  Future<void> writePending(PendingAuthorization? pending) async {
    if (pending == null) {
      await _storage.delete(key: _pendingKey);
      return;
    }
    await _storage.write(
      key: _pendingKey,
      value: encodeStorageJson(pending.toStorageJson()),
    );
  }

  @override
  String toString() => 'SecureStorageTokenStore(namespace: $namespace)';
}

/// [AuthLauncher] on `url_launcher`.
///
/// [openExternally] uses **`LaunchMode.externalApplication`**, and that is not
/// a preference — it is the requirement in §6 step 4. External-application mode
/// hands the URL to the OS, which is what lets an Android App Link / iOS
/// Universal Link resolve to the installed Tracive app, and what keeps the
/// authorization page out of the host app's process. `LaunchMode.inAppWebView`
/// would break both: App Links do not fire from a WebView, and RFC 8252 §8.12
/// forbids an embedded user-agent for exactly the reason it looks convenient —
/// the embedding app can read what the user types into it.
class UrlLauncherAuthLauncher extends AuthLauncher {
  /// Creates the launcher.
  const UrlLauncherAuthLauncher();

  @override
  Future<bool> canOpen(Uri url) => canLaunchUrl(url);

  @override
  Future<bool> openExternally(Uri url) =>
      launchUrl(url, mode: LaunchMode.externalApplication);

  @override
  String toString() => 'UrlLauncherAuthLauncher()';
}
