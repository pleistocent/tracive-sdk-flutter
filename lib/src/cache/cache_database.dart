// Copyright (c) Tracive. Licensed under the Apache License, Version 2.0.
//
// The database seam under `SqlCheckCacheStore`.
//
// Why not depend on `sqflite_sqlcipher`'s `Database` directly? Because then no
// test could construct one. `sqflite` is a plugin: it answers over a platform
// channel that only exists inside a running Flutter engine on a device or
// simulator, so a `dart test` process cannot open a database at all, and a
// `flutter test` process only gets a `MissingPluginException`.
//
// This interface is the five calls the cache actually makes. The real
// implementation is ~30 lines in `tracive_cache.dart`; the test one is a fake
// in `test/cache_test.dart`. Both are small enough to read in full, which is
// the point: the SQL is reviewed rather than mocked away.

/// The slice of a SQL database the cache uses.
///
/// Statement-based rather than helper-based (`insert(table, values)` and
/// friends) so that every statement the SDK runs is visible as a literal in
/// `SqlCheckCacheStore`, where it can be read, reviewed and asserted on.
abstract class CacheDatabase {
  /// Allows `const` implementations.
  const CacheDatabase();

  /// Runs a statement that returns nothing (DDL, `PRAGMA`).
  Future<void> execute(String sql, [List<Object?>? arguments]);

  /// Runs a `SELECT` (or a `PRAGMA` that reads) and returns its rows.
  Future<List<Map<String, Object?>>> query(
    String sql, [
    List<Object?>? arguments,
  ]);

  /// Runs an `INSERT`. Returns the inserted row id.
  Future<int> insert(String sql, [List<Object?>? arguments]);

  /// Runs a `DELETE` (or `UPDATE`). Returns the number of rows affected.
  Future<int> delete(String sql, [List<Object?>? arguments]);

  /// Closes the database.
  Future<void> close();
}

/// Opens a [CacheDatabase].
///
/// The opener owns the file path, the encryption key and any recovery from a
/// database that will not open — see `openTraciveCache` in
/// `tracive_cache.dart`. `SqlCheckCacheStore` only ever calls it.
typedef CacheDatabaseOpener = Future<CacheDatabase> Function();
