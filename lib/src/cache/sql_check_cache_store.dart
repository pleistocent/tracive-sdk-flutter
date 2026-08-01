// Copyright (c) Tracive. Licensed under the Apache License, Version 2.0.
//
// The SQL storage behind the cache.
//
// Every statement this file runs is a `static const` below. Nothing is built by
// string concatenation from a value, and every value travels as a bound `?`
// parameter, so no cache key or payload can be interpolated into SQL. The one
// interpolation is [checkCacheSchemaVersion] into `PRAGMA user_version`, which
// SQLite does not accept as a bound parameter and which is an `int` constant in
// this file.
//
// PRIVACY: the table has no column for the query. What is stored is the SHA-256
// of the folded key, the cacheable projection of the result, and three
// timestamps.

import 'cache_database.dart';
import 'check_cache_store.dart';

/// The on-disk layout version.
///
/// **Bump this on any change to the table, to the payload's shape, or to the
/// meaning of a stored field.** A mismatch drops every row on open, which
/// is the SDK's only way to invalidate a fleet's worth of caches from inside a
/// release. It costs one credit per identifier afterwards, so bump it when the
/// alternative is serving a wrong answer — not for a cosmetic change.
///
/// History:
///   1 — first release. `check_cache(cache_key, payload, risk_tier,
///       fetched_at, expires_at, stored_at)`, payload = `CheckResult.toJson()`
///       of `CheckResult.cacheable()`.
const int checkCacheSchemaVersion = 1;

/// A [CheckCacheStore] on top of a SQL database.
///
/// In production the database is SQLCipher (see `openTraciveCache`), so the
/// file is encrypted at rest; this class is deliberately unaware of that, and
/// works the same over a plain SQLite file or a fake.
class SqlCheckCacheStore extends CheckCacheStore {
  /// Stores rows in the database returned by [opener].
  ///
  /// [opener] is called on [open] and again after [close], so it must be able
  /// to produce a fresh handle each time.
  SqlCheckCacheStore({required this.opener});

  /// Opens the underlying database. See [CacheDatabaseOpener].
  final CacheDatabaseOpener opener;

  /// The one table this SDK creates.
  static const String tableName = 'check_cache';

  /// Reads the layout version SQLite recorded for this file.
  static const String readSchemaVersionSql = 'PRAGMA user_version';

  /// Records [checkCacheSchemaVersion] on the file.
  static const String writeSchemaVersionSql =
      'PRAGMA user_version = $checkCacheSchemaVersion';

  /// Drops the table, used when the recorded version is not this one.
  static const String dropTableSql = 'DROP TABLE IF EXISTS $tableName';

  /// Creates the table.
  static const String createTableSql = 'CREATE TABLE IF NOT EXISTS $tableName ('
      'cache_key TEXT PRIMARY KEY NOT NULL, '
      'payload TEXT NOT NULL, '
      'risk_tier TEXT NOT NULL, '
      'fetched_at INTEGER NOT NULL, '
      'expires_at INTEGER NOT NULL, '
      'stored_at INTEGER NOT NULL)';

  /// Indexes the column both prune statements filter and order on.
  static const String createIndexSql =
      'CREATE INDEX IF NOT EXISTS idx_${tableName}_expires_at '
      'ON $tableName (expires_at)';

  /// Reads one row by key.
  static const String selectSql =
      'SELECT cache_key, payload, risk_tier, fetched_at, expires_at, stored_at '
      'FROM $tableName WHERE cache_key = ? LIMIT 1';

  /// Writes one row, replacing any row with the same key.
  static const String insertSql = 'INSERT OR REPLACE INTO $tableName '
      '(cache_key, payload, risk_tier, fetched_at, expires_at, stored_at) '
      'VALUES (?, ?, ?, ?, ?, ?)';

  /// Deletes one row by key.
  static const String deleteSql = 'DELETE FROM $tableName WHERE cache_key = ?';

  /// Empties the table.
  static const String deleteAllSql = 'DELETE FROM $tableName';

  /// Deletes everything that has expired.
  static const String deleteExpiredSql =
      'DELETE FROM $tableName WHERE expires_at <= ?';

  /// Evicts down to a cap, keeping the rows that live longest.
  ///
  /// `LIMIT -1 OFFSET ?` is SQLite for "everything past the first N rows".
  static const String deleteOverCapSql =
      'DELETE FROM $tableName WHERE cache_key IN ('
      'SELECT cache_key FROM $tableName '
      'ORDER BY expires_at DESC, stored_at DESC LIMIT -1 OFFSET ?)';

  /// Counts rows, expired ones included.
  static const String countSql = 'SELECT COUNT(*) AS row_count FROM $tableName';

  CacheDatabase? _database;

  /// The open database, or `null` before [open] and after [close]. Exposed for
  /// diagnostics; the store reopens itself on the next call.
  CacheDatabase? get database => _database;

  @override
  Future<void> open() async {
    if (_database != null) return;
    final database = await opener();
    final version = await _readSchemaVersion(database);
    final stale = version != checkCacheSchemaVersion;

    // Schema-version invalidation. A fresh file reports 0, so a first run
    // takes this branch too and simply drops a table that is not there.
    if (stale) await database.execute(dropTableSql);
    await database.execute(createTableSql);
    await database.execute(createIndexSql);
    if (stale) await database.execute(writeSchemaVersionSql);

    _database = database;
  }

  @override
  Future<StoredCheck?> read(String cacheKey) async {
    final database = await _open();
    final rows = await database.query(selectSql, <Object?>[cacheKey]);
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
  }

  @override
  Future<void> write(StoredCheck entry) async {
    final database = await _open();
    await database.insert(insertSql, <Object?>[
      entry.cacheKey,
      entry.payload,
      entry.riskTier,
      entry.fetchedAt.millisecondsSinceEpoch,
      entry.expiresAt.millisecondsSinceEpoch,
      entry.storedAt.millisecondsSinceEpoch,
    ]);
  }

  @override
  Future<bool> delete(String cacheKey) async {
    final database = await _open();
    final removed = await database.delete(deleteSql, <Object?>[cacheKey]);
    return removed > 0;
  }

  @override
  Future<void> clear() async {
    final database = await _open();
    await database.delete(deleteAllSql);
  }

  @override
  Future<int> pruneExpired(DateTime now, {int maxEntries = 0}) async {
    final database = await _open();
    var removed = await database.delete(deleteExpiredSql, <Object?>[
      now.toUtc().millisecondsSinceEpoch,
    ]);
    if (maxEntries > 0) {
      removed += await database.delete(deleteOverCapSql, <Object?>[maxEntries]);
    }
    return removed;
  }

  @override
  Future<int> count() async {
    final database = await _open();
    final rows = await database.query(countSql);
    if (rows.isEmpty) return 0;
    final value = rows.first['row_count'];
    return value is int ? value : 0;
  }

  @override
  Future<void> close() async {
    final database = _database;
    _database = null;
    await database?.close();
  }

  Future<CacheDatabase> _open() async {
    await open();
    final database = _database;
    if (database == null) {
      throw StateError('The cache database closed while it was being used');
    }
    return database;
  }

  /// Reads `PRAGMA user_version`, defaulting to a value that can never match
  /// [checkCacheSchemaVersion] so an unreadable pragma rebuilds the table
  /// rather than trusting it.
  static Future<int> _readSchemaVersion(CacheDatabase database) async {
    final rows = await database.query(readSchemaVersionSql);
    if (rows.isEmpty) return -1;
    final row = rows.first;
    // The column is named `user_version`, but do not rely on it: some engines
    // label a pragma result differently.
    final value =
        row['user_version'] ?? (row.isEmpty ? null : row.values.first);
    return value is int ? value : -1;
  }

  static StoredCheck? _fromRow(Map<String, Object?> row) {
    final cacheKey = row['cache_key'];
    final payload = row['payload'];
    if (cacheKey is! String || payload is! String) return null;
    return StoredCheck(
      cacheKey: cacheKey,
      payload: payload,
      riskTier: row['risk_tier'] is String ? row['risk_tier']! as String : '',
      fetchedAt: _instant(row['fetched_at']),
      expiresAt: _instant(row['expires_at']),
      storedAt: _instant(row['stored_at']),
    );
  }

  /// Epoch milliseconds to UTC. A missing or non-numeric column becomes the
  /// epoch, which reads as "expired long ago" — the safe direction: the row is
  /// dropped and the answer is re-fetched.
  static DateTime _instant(Object? value) =>
      DateTime.fromMillisecondsSinceEpoch(
        value is int ? value : 0,
        isUtc: true,
      );
}
