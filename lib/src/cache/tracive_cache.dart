// Copyright (c) Tracive. Licensed under the Apache License, Version 2.0.
//
// The Flutter half of the cache.
//
// This is the only file in `lib/src/cache/` that imports a plugin. Everything
// it does is bind two platform packages to the seams declared next door:
//
//     sqflite_sqlcipher     -> CacheDatabase        (encrypted storage)
//     flutter_secure_storage -> CacheSecretStore    (Keystore / Keychain)
//
// Keeping it separate is what lets `test/cache_test.dart` run the cache's
// entire decision-making with `dart test` and no device. The trade is that this
// file is exercised by integration testing on a device, not by unit tests —
// which is why it is kept as small and as obvious as it can be.
//
// AT-REST ENCRYPTION, HONESTLY STATED. The contract asks for "AES-GCM with a
// random 96-bit
// nonce per record". That is what the Swift SDK does, because it has no
// SQLCipher and encrypts row by row with CryptoKit. On Flutter the encryption
// is SQLCipher's: AES-256-CBC per page with a per-page random IV, and an
// HMAC-SHA512 per page for tamper detection. It is not GCM, and it is per page
// rather than per record. The property being bought — the cache is unreadable
// without a key held in the platform keystore — holds either way, and using
// SQLCipher is what the contract itself prescribes for Flutter.
// `doc/caching.md` records
// this so nobody has to rediscover it from the code.

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_sqlcipher/sqflite.dart';

import '../model/cache_policy.dart';
// One import, not four: `check_cache.dart` re-exports the seams this file binds
// (`CacheDatabase`, `CacheSecretStore`, `SqlCheckCacheStore`), and importing
// them again is what `unnecessary_import` flags.
import 'check_cache.dart';

/// File name of the cache database, inside the app's private database
/// directory.
const String defaultCacheDatabaseName = 'tracive_check_cache.db';

/// Opens the on-device cache: SQLCipher storage, key in Keystore/Keychain.
///
/// **Never throws.** A cache is an optimisation, and an app must not fail to
/// start because a database file is locked or a Keystore entry is unreadable.
/// When the open fails, the returned cache simply misses on every read and the
/// error is left in [CheckCache.lastStoreError] — watch that in telemetry,
/// because a cache that stopped working means every check now costs a credit.
///
/// Pass [secretStore] or [databaseName] only if you have a reason to; the
/// defaults are the ones the SDK is tested with. [clock] is a test seam.
///
/// This call is only meaningful on Android and iOS. On any other platform
/// `sqflite_sqlcipher` has no implementation, the open fails, and you get the
/// same degraded cache — use `CheckCache.inMemory()` there instead.
Future<CheckCache> openTraciveCache({
  CachePolicy policy = CachePolicy.defaultPolicy,
  CacheClock? clock,
  String databaseName = defaultCacheDatabaseName,
  CacheSecretStore? secretStore,
}) async {
  final secrets = secretStore ?? const SecureStorageCacheSecretStore();
  final cache = DefaultCheckCache(
    store: SqlCheckCacheStore(
      opener: () => openEncryptedCacheDatabase(
        secretStore: secrets,
        databaseName: databaseName,
      ),
    ),
    policy: policy,
    clock: clock,
  );
  try {
    await cache.open();
  } on Object {
    // Swallowed on purpose — see the doc comment. `cache.lastStoreError` has
    // it, and every read from here on is a miss rather than a crash.
  }
  return cache;
}

/// Opens the SQLCipher database the cache stores rows in.
///
/// Recovery: if the file will not open — almost always because the key in the
/// keystore no longer matches the file, which happens when a device backup
/// restores app files without the (non-backed-up) keystore entry — the file is
/// **deleted and rebuilt**. Nothing of value is lost: every row is a copy of an
/// answer the server can produce again. The alternative is an SDK whose cache
/// never opens again on that device.
Future<CacheDatabase> openEncryptedCacheDatabase({
  required CacheSecretStore secretStore,
  String databaseName = defaultCacheDatabaseName,
}) async {
  final path = p.join(await getDatabasesPath(), databaseName);
  final key = await readOrCreateCacheDatabaseKey(secretStore);
  try {
    return SqfliteCacheDatabase(await _open(path, key));
  } on Object {
    await deleteDatabase(path);
    return SqfliteCacheDatabase(await _open(path, key));
  }
}

// No `version:` argument on purpose. sqflite implements its own migration
// hooks on top of `PRAGMA user_version`, and this SDK drives that pragma
// itself (see `checkCacheSchemaVersion`) so the schema rule is identical in the
// Kotlin and Swift SDKs, which have no sqflite. Passing both would leave two
// owners for one integer.
Future<Database> _open(String path, String key) =>
    openDatabase(path, password: key);

/// A [CacheDatabase] backed by a `sqflite` (SQLCipher) [Database].
///
/// Also usable with `sqflite_common_ffi` on desktop for integration tests —
/// unencrypted there, so do not ship it that way.
class SqfliteCacheDatabase extends CacheDatabase {
  /// Wraps an already-open [database].
  const SqfliteCacheDatabase(this.database);

  /// The underlying sqflite database.
  final Database database;

  @override
  Future<void> execute(String sql, [List<Object?>? arguments]) =>
      database.execute(sql, arguments);

  @override
  Future<List<Map<String, Object?>>> query(
    String sql, [
    List<Object?>? arguments,
  ]) async {
    final rows = await database.rawQuery(sql, arguments);
    // Copied rather than cast: sqflite has returned both `Map<String, Object?>`
    // and `Map<String, dynamic>` rows across versions, and a cast of the wrong
    // one throws at runtime rather than at compile time.
    return <Map<String, Object?>>[
      for (final row in rows) Map<String, Object?>.from(row),
    ];
  }

  @override
  Future<int> insert(String sql, [List<Object?>? arguments]) =>
      database.rawInsert(sql, arguments);

  @override
  Future<int> delete(String sql, [List<Object?>? arguments]) =>
      database.rawDelete(sql, arguments);

  @override
  Future<void> close() => database.close();
}

/// A [CacheSecretStore] backed by `flutter_secure_storage`: the Android
/// Keystore (through EncryptedSharedPreferences) and the iOS Keychain.
///
/// The Keychain entry is written with `first_unlock_this_device`: readable
/// after the first unlock following a boot, never synced to iCloud and never
/// included in an iTunes/Finder backup. That is what makes the "restored
/// backup, missing key" case above real, and it is the right trade — a cache
/// key that follows the user's iCloud account around is a worse problem than a
/// cold cache.
class SecureStorageCacheSecretStore extends CacheSecretStore {
  /// Creates the store. [storage] is injectable for integration tests; the
  /// default is the shared instance configured in [defaultSecureStorage].
  const SecureStorageCacheSecretStore({FlutterSecureStorage? storage})
      : _storage = storage;

  /// The options this SDK stores its key with. Built once, lazily, rather than
  /// as a `const` default so that a change to the plugin's constructor cannot
  /// turn into a compile error in a `const` context.
  static final FlutterSecureStorage defaultSecureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );

  final FlutterSecureStorage? _storage;

  FlutterSecureStorage get _target => _storage ?? defaultSecureStorage;

  /// Reads an entry, treating an unreadable store as an empty one.
  ///
  /// Android's EncryptedSharedPreferences can end up undecryptable (a known
  /// failure after some backup/restore and keystore-reset paths). Returning
  /// `null` makes the caller mint a fresh key, which then fails to open the old
  /// database file, which is then rebuilt — the same recovery as any other
  /// key mismatch. Throwing here would instead disable the cache permanently.
  @override
  Future<String?> read(String key) async {
    try {
      return await _target.read(key: key);
    } on Object {
      await delete(key);
      return null;
    }
  }

  @override
  Future<void> write(String key, String value) =>
      _target.write(key: key, value: value);

  @override
  Future<void> delete(String key) async {
    try {
      await _target.delete(key: key);
    } on Object {
      // Best effort: a delete that fails leaves an entry we are about to
      // overwrite anyway.
    }
  }
}
