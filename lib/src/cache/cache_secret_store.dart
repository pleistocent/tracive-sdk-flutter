// Copyright 2026 PT Pleistocent Teknologi Nusantara.
// Licensed under the Apache License, Version 2.0.
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

/// Length of the generated database key, in bytes.
///
/// 32 bytes of entropy, base64url-encoded. It is handed to
/// `openDatabase(path, password:)` as a **passphrase**, not as a raw key:
/// SQLCipher runs it through PBKDF2 to derive the actual AES-256 key. So the 32
/// is about how much entropy goes in, not about matching a cipher's key size —
/// the derived key is 256 bits either way, and would be even if this were
/// shorter. It is 32 because a passphrase should carry at least as much
/// entropy as the key derived from it.
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
///
/// **Single-flight.** Concurrent callers share one flight; see
/// [_keyRequestsInFlight] for why that is a correctness requirement and not an
/// optimisation.
Future<String> readOrCreateCacheDatabaseKey(
  CacheSecretStore store, {
  String entry = cacheDatabaseKeyEntry,
  Random? random,
}) {
  final request = (store, entry);
  final joined = _keyRequestsInFlight[request];
  if (joined != null) return joined;

  // Registered synchronously, before the first `await` inside the helper can
  // yield, so no second caller can slip through between the lookup above and
  // this line.
  // The callback body is a statement, not an expression, on purpose:
  // `Map.remove` returns the value it removed, `whenComplete` awaits a Future
  // its callback returns, and the value being removed here *is* this flight —
  // so an arrow body makes the future wait for itself and never completes.
  final flight =
      _readOrCreateCacheDatabaseKey(store, entry, random).whenComplete(() {
    _keyRequestsInFlight.remove(request);
  });
  _keyRequestsInFlight[request] = flight;
  return flight;
}

/// Flights of [readOrCreateCacheDatabaseKey] that have not finished, keyed by
/// the store instance and the entry name.
///
/// Without this, two callers that both find the entry empty both generate a key
/// and both write it. The loser's key is silently overwritten — and the
/// database opened under it is then undecryptable, which `openTraciveCache`
/// recovers from by deleting the file and rebuilding it. Every identifier in
/// that cache costs a credit again. It is not an exotic interleaving either:
/// any app that calls `openTraciveCache()` from two places, or from a
/// `FutureBuilder` that rebuilds, reaches it.
///
/// Entries are removed when their flight settles, so this holds nothing between
/// calls. It is keyed by store *identity* rather than being a single slot
/// because a host may legitimately keep more than one store.
final Map<(CacheSecretStore, String), Future<String>> _keyRequestsInFlight =
    <(CacheSecretStore, String), Future<String>>{};

Future<String> _readOrCreateCacheDatabaseKey(
  CacheSecretStore store,
  String entry,
  Random? random,
) async {
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
