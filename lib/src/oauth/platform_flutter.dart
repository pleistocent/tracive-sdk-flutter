// Copyright (c) Tracive. Licensed under the Apache License, Version 2.0.
//
// Platform wiring for Flutter.
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
/// — never in SharedPreferences, UserDefaults or a plain file.
///
/// Records are JSON, written under two keys derived from [namespace]. Change
/// [namespace] if one app holds grants for more than one Tracive client id;
/// otherwise the second client silently overwrites the first's tokens.
///
/// ## The storage options are set deliberately, and they matter
///
/// `flutter_secure_storage`'s defaults are weaker than its name suggests, on
/// both platforms, and a refresh token is the most sensitive thing this SDK
/// holds. [defaultSecureStorage] therefore sets them explicitly rather than
/// inheriting them; see that constant for what each one buys.
///
/// This class is internal, so an app that needs *different* options does not
/// subclass or reconstruct it — it implements the exported `TokenStore`
/// interface over its own `FlutterSecureStorage` and passes the result as
/// `TraciveOAuth(tokenStore: …)` / `TraciveClient(tokenStore: …)`. The record
/// encoding it needs (`TraciveTokens.toStorageJson`, `encodeStorageJson` and
/// their inverses) is exported for exactly that.
class SecureStorageTokenStore extends TokenStore {
  /// Creates a store.
  ///
  /// Pass [storage] only if your app genuinely needs different platform options
  /// from [defaultSecureStorage] — read that constant first, because the
  /// defaults it overrides are weaker than they look.
  SecureStorageTokenStore({
    FlutterSecureStorage? storage,
    this.namespace = 'tracive_sdk',
  }) : _storage = storage ?? defaultSecureStorage;

  /// The options tokens are stored with, chosen rather than inherited.
  ///
  /// * `encryptedSharedPreferences: true` — the plugin's default is `false`,
  ///   which puts the tokens through a legacy path: an RSA key in the Keystore
  ///   wrapping an AES key, with the ciphertext in an ordinary
  ///   `SharedPreferences` XML file. `true` selects `EncryptedSharedPreferences`
  ///   instead. Existing entries are not stranded — the plugin migrates them
  ///   into the encrypted store on first use.
  /// * `accessibility: first_unlock_this_device` — the plugin's default is
  ///   `unlocked`, which is wrong here twice over. It makes the refresh token
  ///   unreadable while the device is locked, so a refresh from a background
  ///   task fails; and, being no `…ThisDeviceOnly` variant, it lets the item
  ///   travel in an encrypted device backup and be restored onto a *different*
  ///   device. A refresh token that exists on two devices is exactly the
  ///   multi-device replay that reuse detection punishes by revoking the grant.
  ///   `first_unlock_this_device` fixes both: readable after the first unlock
  ///   following a boot, and never leaving this device. The plugin's read query
  ///   carries no accessibility attribute, so entries written under the old
  ///   default stay readable and are re-tagged on the next write.
  /// * `synchronizable: false` — already the plugin's default, and stated here
  ///   so that it is a decision rather than an accident. A token synced to
  ///   iCloud Keychain is a token on every device the user owns.
  ///
  /// This is the same shape, and the same reasoning, as the cache encryption
  /// key's store. The two should never diverge: it would be absurd for the
  /// cache key to be better protected than the credential that can refill the
  /// cache.
  ///
  /// Built lazily rather than as a `const` so that a change to the plugin's
  /// constructor cannot turn into a compile error in a `const` context.
  static final FlutterSecureStorage defaultSecureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
      synchronizable: false,
    ),
  );

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
    // An entry carrying neither credential is unusable — treat it as "not
    // signed in". One that has lost its access token but kept a live refresh
    // token is not: `ensureAccessToken` repairs it with a single refresh.
    //
    // This used to drop the whole record whenever the access token was blank,
    // to keep an empty bearer off the wire. That guard now lives where the
    // token is used, so all this one did was take a working refresh token down
    // with the damaged half and charge the user a fresh consent for it.
    return tokens.isUsable ? tokens : null;
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
/// a preference — it is a requirement. External-application mode
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
