// Copyright (c) Tracive. Licensed under the Apache License, Version 2.0.
//
// Where the cache's encryption key lives.
//
// The data key must sit in the Android Keystore / iOS Keychain,
// Secure Enclave-backed where available. On Flutter that is
// `flutter_secure_storage`, which is a plugin, so it lives behind this seam and
// is bound in `tracive_cache.dart`. This file is plain Dart.
//
// PRIVACY: the value handled here is a database encryption key. It is never
// logged, never printed, never included in an exception message, and never
// written anywhere but the platform secret store.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

/// A platform secret store — Keystore on Android, Keychain on iOS.
///
/// The SDK keeps exactly one secret here: the cache database's key.
abstract class CacheSecretStore {
  /// Allows `const` implementations.
  const CacheSecretStore();

  /// The value stored under [key], or `null`.
  Future<String?> read(String key);

  /// Stores [value] under [key], replacing anything already there.
  Future<void> write(String key, String value);

  /// Removes [key]. Must not throw when there is nothing to remove.
  Future<void> delete(String key);
}

/// The entry the cache database key is stored under.
///
/// Versioned: if the key derivation ever changes, the new build writes a new
/// entry rather than misreading the old one.
const String cacheDatabaseKeyEntry = 'tracive.cache.database_key.v1';

/// Length of the generated database key, in bytes. 32 bytes = 256 bits, which
/// is what SQLCipher uses for AES-256.
const int cacheDatabaseKeyBytes = 32;

/// Generates a fresh database key: [cacheDatabaseKeyBytes] random bytes,
/// base64url-encoded so it survives a string-only secret store.
///
/// [random] exists for tests only. **Production must use the default**, which
/// is [Random.secure] — a `Random()` seeded from the clock would make the key
/// guessable from the install time.
String generateCacheDatabaseKey({Random? random}) {
  final source = random ?? Random.secure();
  final bytes = Uint8List(cacheDatabaseKeyBytes);
  for (var i = 0; i < bytes.length; i++) {
    bytes[i] = source.nextInt(256);
  }
  return base64UrlEncode(bytes);
}

/// Returns the cache database key, creating and storing one on first run.
///
/// The key never leaves the device and is never derived from anything the user
/// knows or the partner supplies: it is random, per install, and lives only in
/// the platform secret store.
///
/// Losing it (a restored backup that carried the database file but not the
/// Keystore entry, a user clearing app data) makes the existing database
/// unreadable. That is handled where the database is opened — the file is
/// discarded and rebuilt — because a cache that cannot be read is worth
/// nothing, and the alternative is an SDK that never opens its cache again.
Future<String> readOrCreateCacheDatabaseKey(
  CacheSecretStore store, {
  String entry = cacheDatabaseKeyEntry,
  Random? random,
}) async {
  final existing = await store.read(entry);
  if (existing != null && existing.isNotEmpty) return existing;
  final created = generateCacheDatabaseKey(random: random);
  await store.write(entry, created);
  return created;
}

/// A [CacheSecretStore] that keeps secrets in memory.
///
/// For tests, and for platforms with no secret store at all — where it means
/// the key dies with the process, so the database from the previous run cannot
/// be read and is rebuilt. That is the correct failure: better a cold cache
/// than a key on disk in the clear.
class InMemoryCacheSecretStore extends CacheSecretStore {
  /// Creates an empty store.
  InMemoryCacheSecretStore();

  final Map<String, String> _entries = <String, String>{};

  @override
  Future<String?> read(String key) async => _entries[key];

  @override
  Future<void> write(String key, String value) async {
    _entries[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _entries.remove(key);
  }
}
