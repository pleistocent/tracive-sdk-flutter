// Copyright 2026 PT Pleistocent Teknologi Nusantara.
// Licensed under the Apache License, Version 2.0.
//
// The storage seam under `CheckCache`.
//
// The split between `CheckCache` and `CheckCacheStore` is where the cache is
// cut so each half can be checked on its own:
//
//   CheckCache      decides *whether* a row may be used (policy, TTL, the
//                   full-detail rule, key derivation) and never touches SQL.
//   CheckCacheStore decides *how* rows are kept, and has no opinion about
//                   freshness beyond the `expiresAt` stamp it is handed.
//
// So the policy rules are tested against [MemoryCheckCacheStore] — a real
// store, not a mock — and the SQL is tested separately against a fake database.

/// One row of the cache.
///
/// PRIVACY: there is deliberately no field for the query. The raw identifier is
/// not stored anywhere; [cacheKey] is `SHA-256(searchQueryIndex)` and [payload]
/// is a `CheckResult` that has been through `CheckResult.cacheable()` (counts,
/// tier, dates, tags, disclaimer — nothing that identifies anyone).
class StoredCheck {
  /// Creates a row. All instants are stored and compared in UTC.
  StoredCheck({
    required this.cacheKey,
    required this.payload,
    required this.riskTier,
    required DateTime fetchedAt,
    required DateTime expiresAt,
    required DateTime storedAt,
  })  : fetchedAt = fetchedAt.toUtc(),
        expiresAt = expiresAt.toUtc(),
        storedAt = storedAt.toUtc();

  /// `SHA-256(searchQueryIndex)`, lowercase hex. The primary key.
  final String cacheKey;

  /// The cacheable `CheckResult`, JSON-encoded.
  final String payload;

  /// `RiskTier.wireValue`, for diagnostics and for reading a database dump
  /// without decoding every payload. Not used to decide freshness — the tier
  /// inside [payload] is authoritative.
  final String riskTier;

  /// When the server produced the answer. TTL is measured from here, not from
  /// [storedAt], so a result that was already an hour old when it was written
  /// expires an hour early.
  final DateTime fetchedAt;

  /// When this row stops being usable, under the policy in force at write
  /// time.
  ///
  /// A **prune hint**, not the authority: `CheckCache.read` re-derives
  /// freshness from the live `CachePolicy` and the payload, so changing the
  /// policy takes effect on already-stored rows instead of waiting them out.
  final DateTime expiresAt;

  /// When the row was written. Used only as a tie-break when evicting.
  final DateTime storedAt;

  /// Redacted by convention: [payload] is small but there is no reason to put
  /// a whole result in a log line, and [cacheKey] is truncated because a full
  /// hash is a stable identifier for "someone checked this thing".
  @override
  String toString() => 'StoredCheck(key: $_shortKey, tier: $riskTier, '
      'fetchedAt: $fetchedAt, expiresAt: $expiresAt)';

  String get _shortKey =>
      cacheKey.length <= 8 ? cacheKey : '${cacheKey.substring(0, 8)}...';
}

/// Where cache rows are kept.
///
/// Implementations are storage only. They must not interpret [StoredCheck] or
/// second-guess an expiry; freshness belongs to `CheckCache`.
abstract class CheckCacheStore {
  /// Allows `const` implementations.
  const CheckCacheStore();

  /// Prepares the store: opens the file, applies the schema version, creates
  /// the table. Called once by `CheckCache.open`; must tolerate being called
  /// again after [close].
  Future<void> open();

  /// The row for [cacheKey], expired or not. Expiry is the caller's business.
  Future<StoredCheck?> read(String cacheKey);

  /// Inserts [entry], replacing any row with the same key.
  Future<void> write(StoredCheck entry);

  /// Deletes the row for [cacheKey]. Returns whether one existed.
  Future<bool> delete(String cacheKey);

  /// Deletes every row.
  Future<void> clear();

  /// Deletes rows that expired at or before [now], then evicts down to
  /// [maxEntries] (a value of zero or less means "no cap").
  ///
  /// Eviction drops the rows closest to expiry first: they are the ones with
  /// the least value left. In practice that means a `NONE` verdict (one hour)
  /// is dropped long before a `HIGH` one (thirty days), which is also the
  /// cheaper thing to re-fetch in credit terms — a `HIGH` result is the one a
  /// user is most likely to look at twice.
  ///
  /// Returns the number of rows deleted.
  Future<int> pruneExpired(DateTime now, {int maxEntries = 0});

  /// How many rows are stored, expired ones included.
  Future<int> count();

  /// Releases the underlying resources.
  Future<void> close();
}

/// A [CheckCacheStore] that lives in memory for the life of the process.
///
/// Real storage, not a test double: it is what `CheckCache.inMemory()` runs on
/// and what the SDK falls back to where `sqflite_sqlcipher` has no
/// implementation. It is also the store the policy tests use, so those tests
/// exercise the same code path a host app would.
class MemoryCheckCacheStore extends CheckCacheStore {
  /// Creates an empty store.
  MemoryCheckCacheStore();

  final Map<String, StoredCheck> _rows = <String, StoredCheck>{};

  @override
  Future<void> open() async {}

  @override
  Future<StoredCheck?> read(String cacheKey) async => _rows[cacheKey];

  @override
  Future<void> write(StoredCheck entry) async {
    _rows[entry.cacheKey] = entry;
  }

  @override
  Future<bool> delete(String cacheKey) async => _rows.remove(cacheKey) != null;

  @override
  Future<void> clear() async => _rows.clear();

  @override
  Future<int> pruneExpired(DateTime now, {int maxEntries = 0}) async {
    final cutoff = now.toUtc();
    var removed = 0;
    _rows.removeWhere((_, row) {
      final expired = !row.expiresAt.isAfter(cutoff);
      if (expired) removed++;
      return expired;
    });

    if (maxEntries > 0 && _rows.length > maxEntries) {
      // Same order as the SQL store: keep the rows that live longest.
      final byValue = _rows.values.toList(growable: false)
        ..sort((a, b) {
          final byExpiry = b.expiresAt.compareTo(a.expiresAt);
          return byExpiry != 0 ? byExpiry : b.storedAt.compareTo(a.storedAt);
        });
      for (final row in byValue.skip(maxEntries)) {
        _rows.remove(row.cacheKey);
        removed++;
      }
    }
    return removed;
  }

  @override
  Future<int> count() async => _rows.length;

  @override
  Future<void> close() async {}
}
