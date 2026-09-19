// Copyright 2026 PT Pleistocent Teknologi Nusantara.
// Licensed under the Apache License, Version 2.0.
//
// The platform storage options this SDK stores secrets with.
//
// NO NETWORK, and no platform channel either: nothing here calls `read` or
// `write`. It asserts the *options* the two secure stores are constructed with,
// which is a pure-Dart fact about this SDK and not a fact about a device.
//
// Why it is worth a test at all: `flutter_secure_storage`'s defaults are weaker
// than its name suggests (`encryptedSharedPreferences: false`,
// `accessibility: unlocked`, i.e. an item that travels in a device backup), the
// weakening is invisible at the call site because it is an omission rather than
// a statement, and the cost of getting it wrong is a refresh token restorable
// onto somebody else's phone. An omission cannot be reviewed; this test is what
// makes it reviewable.
//
// This file needs `dart:ui`, so it runs under `flutter test` and not under a
// bare `dart test`. That is the same conditional import the SDK itself uses to
// keep the Flutter plugins off the pure-Dart path.
@TestOn('vm')
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
// Imported by path because the platform wiring is deliberately not public
// surface (see the "not exported" list in `lib/tracive_sdk.dart`). The options
// are an invariant of that wiring, so this is the only place they can be
// asserted from.
// ignore: implementation_imports
import 'package:tracive_sdk/src/cache/tracive_cache.dart';
// ignore: implementation_imports
import 'package:tracive_sdk/src/oauth/platform_flutter.dart';

void main() {
  group('the cache key survives a transient Keystore failure', () {
    test('a read that fails once is retried before the key is destroyed',
        () async {
      // The old code deleted the entry on the *first* error. Deleting is not
      // recoverable: the key is gone, the encrypted database can no longer be
      // opened, it is rebuilt empty, and every identifier in it costs a credit
      // again. A Keystore read fails transiently for ordinary reasons — the
      // device has not been unlocked since boot, another process holds the
      // keystore — and treating one of those as "this entry is corrupt" is a
      // very expensive way to be careful.
      final storage = _FlakyStorage(failFirstReads: 1, value: 'the-key');
      final store = SecureStorageCacheSecretStore(storage: storage);

      expect(await store.read('entry'), 'the-key');
      expect(storage.reads, 2, reason: 'the read was not retried');
      expect(storage.deletes, 0, reason: 'the key was destroyed anyway');
    });

    test('a read that fails twice does give up, and clears the entry',
        () async {
      // The genuinely-undecryptable case is real and has to stay recoverable:
      // returning null makes the caller mint a fresh key, which rebuilds the
      // database. Two failures a moment apart are the evidence for it; one is
      // not evidence of anything.
      final storage = _FlakyStorage(failFirstReads: 2, value: 'the-key');
      final store = SecureStorageCacheSecretStore(storage: storage);

      expect(await store.read('entry'), isNull);
      expect(storage.reads, 2);
      expect(storage.deletes, 1);
    });

    test('a read that works first time is not retried', () async {
      final storage = _FlakyStorage(failFirstReads: 0, value: 'the-key');
      final store = SecureStorageCacheSecretStore(storage: storage);

      expect(await store.read('entry'), 'the-key');
      expect(storage.reads, 1);
    });
  });

  group('token storage options', () {
    final options = SecureStorageTokenStore.defaultSecureStorage;

    test('Android tokens go into EncryptedSharedPreferences', () {
      // The plugin's default is `false`, which stores the ciphertext in an
      // ordinary SharedPreferences XML file behind a Keystore-wrapped AES key.
      expect(
        options.aOptions.params['encryptedSharedPreferences'],
        'true',
        reason: 'the legacy path is not what this SDK claims to use',
      );
      expect(
        AndroidOptions().params['encryptedSharedPreferences'],
        'false',
        reason: "the plugin's default is the weak one, so this must be set",
      );
    });

    test('the Keychain item cannot be restored onto another device', () {
      // `unlocked` (the plugin's default) is not a `…ThisDeviceOnly` variant,
      // so the item is included in an encrypted device backup and can be
      // restored onto a different phone. A refresh token on two devices is the
      // multi-device replay reuse detection revokes the whole grant for.
      expect(
        options.iOptions.params['accessibility'],
        'first_unlock_this_device',
      );
      expect(
        IOSOptions().params['accessibility'],
        'unlocked',
        reason: "the plugin's default is device-portable, so this must be set",
      );
    });

    test('the Keychain item is never synced to iCloud', () {
      expect(options.iOptions.params['synchronizable'], 'false');
    });
  });

  test('tokens are stored no more weakly than the cache encryption key', () {
    // The credential that can refill the cache must not be protected less well
    // than the key the cache is encrypted with. Asserted as a relationship
    // rather than as two independent constants, so that hardening one store
    // later cannot silently leave the other behind.
    final tokens = SecureStorageTokenStore.defaultSecureStorage;
    final cacheKey = SecureStorageCacheSecretStore.defaultSecureStorage;

    expect(
      tokens.aOptions.params['encryptedSharedPreferences'],
      cacheKey.aOptions.params['encryptedSharedPreferences'],
    );
    expect(
      tokens.iOptions.params['accessibility'],
      cacheKey.iOptions.params['accessibility'],
    );
  });
}

/// A `FlutterSecureStorage` whose first [failFirstReads] reads throw.
///
/// Models a keystore that is not ready yet rather than one that is broken —
/// the distinction the retry exists to make.
class _FlakyStorage extends FlutterSecureStorage {
  _FlakyStorage({required this.failFirstReads, required this.value});

  /// How many leading reads should fail.
  final int failFirstReads;

  /// What a successful read returns.
  final String value;

  /// How many times [read] was called.
  int reads = 0;

  /// How many times [delete] was called.
  int deletes = 0;

  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    reads++;
    if (reads <= failFirstReads) throw StateError('keystore not ready');
    return value;
  }

  @override
  Future<void> delete({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    deletes++;
  }
}
