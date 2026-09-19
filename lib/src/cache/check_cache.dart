// Copyright 2026 PT Pleistocent Teknologi Nusantara.
// Licensed under the Apache License, Version 2.0.
//
// The local result cache.
//
// ---------------------------------------------------------------------------
// PACKAGING NOTE — read this before editing lib/tracive_sdk.dart
// ---------------------------------------------------------------------------
// The public barrel should export **two** files from this directory:
//
//     export 'src/cache/check_cache.dart';   // this file: plain Dart
//     export 'src/cache/tracive_cache.dart'; // Flutter plugin wiring
//
// The split is deliberate, not an oversight. This file and everything it
// exports import nothing outside `dart:*` and `package:crypto`, so the whole of
// the cache's decision-making — key derivation, TTL, expiry, pruning, the
// "never cache full detail" rule — is unit-testable with `dart test`, with no
// Flutter engine, no platform channels and no database binary. `test/
// cache_test.dart` runs entirely against this half.
//
// `tracive_cache.dart` is the other half: the ~100 lines that bind
// `sqflite_sqlcipher` and `flutter_secure_storage` to the seams declared here.
// Keeping it out of this file's import graph is what keeps that graph testable.
// ---------------------------------------------------------------------------
//
// PRIVACY. Three rules hold everywhere below:
//
//   1. The raw identifier is never stored. The row key is
//      `SHA-256(searchQueryIndex)` hex — see [cacheKeyFor].
//   2. Full-detail content (`topChronologies`, `comments`) and `billing` /
//      `checkId` are never written. [CheckResult.cacheable] drops them and this
//      file always writes that projection, never the result it was handed.
//   3. Nothing here logs. No `print`, no `debugPrint`, no analytics hook.

import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../model/cache_policy.dart';
import '../model/check_result.dart';
import '../model/json.dart';
import '../model/origin.dart';
import '../query/tracive_query.dart';
import 'check_cache_store.dart';

export 'cache_database.dart';
export 'cache_secret_store.dart';
export 'check_cache_store.dart';
export 'sql_check_cache_store.dart';

/// Supplies "now", so TTL behaviour can be tested without waiting 30 days.
///
/// Declared as a bare function type on purpose: any `DateTime Function()` —
/// including a `Clock` typedef declared elsewhere in this SDK, or
/// `DateTime.now` itself — satisfies it structurally.
typedef CacheClock = DateTime Function();

/// The cache key for [query]: `SHA-256(searchQueryIndex)`, lowercase hex.
///
/// The raw identifier never reaches storage. Hashing is not encryption — an
/// attacker holding the database and a list of candidate phone numbers can
/// confirm a guess — which is why the database is *also* encrypted at rest
/// (see `tracive_cache.dart`). What hashing buys is that a database read on
/// its own does not enumerate who the user checked.
///
/// The key deliberately carries neither `detail` nor `locale`. That is sound
/// only because `TraciveClient` keeps localized answers out of the cache
/// entirely — see `CheckResult.cacheable()`. **If that ever changes, this key
/// must become `(query, detail, locale)` first.**
String cacheKeyFor(TraciveQuery query) =>
    cacheKeyForIndex(query.searchQueryIndex);

/// [cacheKeyFor] for a pre-folded `searchQueryIndex`.
///
/// Only pass a string that came out of a `TraciveQuery`. An unfolded key hashes
/// to a different row, which is a cache miss, and a miss is billed.
String cacheKeyForIndex(String searchQueryIndex) =>
    sha256.convert(utf8.encode(searchQueryIndex)).toString();

/// The prefix that separates a transaction record's key from a cache entry's.
///
/// A cache key is 64 lowercase hex digits and `:` is not a hex digit, so the
/// two key spaces cannot collide. That is what lets both kinds of row live in
/// one table without a `kind` column to tell them apart.
const String transactionKeyPrefix = 'txn:';

/// The row key of a transaction record: `txn:` + `SHA-256(transactionId)`.
///
/// The id is hashed for the same reason an identifier is. A transaction
/// reference is the host's own string rather than a person's phone number, but
/// stored in cleartext beside a verdict it says *which* transfers a device
/// holds a fraud answer for.
///
/// The id is trimmed of surrounding whitespace and otherwise used verbatim, so
/// `TRF-1` and `trf-1` are two records. A reference format this SDK has never
/// seen is not one it can fold safely.
///
/// Throws [ArgumentError] on a blank id: the record is looked up by it, and a
/// blank one would file every unlabelled transaction under a single shared row.
String transactionRecordKeyFor(String transactionId) {
  final trimmed = transactionId.trim();
  if (trimmed.isEmpty) {
    throw ArgumentError.value(
      transactionId,
      'transactionId',
      'A transaction record needs a non-blank id',
    );
  }
  return '$transactionKeyPrefix${cacheKeyForIndex(trimmed)}';
}

/// The local cache of check results.
///
/// Reached from the client as `client.cache`, so a host app can clear it (for
/// example on sign-out, or from a "reset app data" screen).
///
/// A hit costs zero credits and does no network I/O. Everything about *when* a
/// hit is allowed lives in [CachePolicy]; this type is the storage and the
/// bookkeeping around it.
abstract class CheckCache {
  /// Allows `const` implementations.
  const CheckCache();

  /// A cache held in memory for the lifetime of the process.
  ///
  /// Nothing is written to disk, so nothing survives a restart — but within a
  /// session it saves exactly the same credits as the persistent cache. Use it
  /// on platforms where `sqflite_sqlcipher` has no implementation (web,
  /// desktop) and in tests.
  factory CheckCache.inMemory({
    CachePolicy policy,
    CacheClock? clock,
  }) = _InMemoryCheckCache;

  /// A cache that stores nothing and never hits.
  ///
  /// Every check then costs a credit. That is the point: it exists for callers
  /// who must have a live answer every time, and for `CachePolicy.disabled`.
  const factory CheckCache.disabled() = DisabledCheckCache;

  /// The policy this cache enforces.
  CachePolicy get policy;

  /// The last error the underlying storage raised, or `null`.
  ///
  /// [read] and [write] never throw (see their docs), so this is the only way
  /// to notice that the cache has stopped working. **Surface it in your
  /// telemetry**: a cache that silently stopped storing does not break
  /// anything, it just means every check from that device now costs a credit.
  Object? get lastStoreError;

  /// Opens the underlying storage and runs the prune pass.
  ///
  /// Idempotent and single-flight: concurrent callers share one open. Called
  /// automatically by [read] and [write]; call it yourself at start-up if you
  /// would rather pay the cost before the first check.
  Future<void> open();

  /// The live result for [query], or `null` when there is none.
  ///
  /// `null` covers "never stored", "expired" and "storage unavailable" alike —
  /// the caller cannot act differently on those, and distinguishing them here
  /// would leak whether an identifier was ever checked into whatever handles
  /// the difference. An expired row is deleted on the way out (lazy expiry).
  ///
  /// Returns a result stamped `Origin.cache`, whose `fetchedAt` is the
  /// *original* server fetch — not now. Never throws: a broken cache degrades
  /// to a miss, and the error is left in [lastStoreError].
  ///
  /// `Source.cache` with no live entry is a `TraciveCacheMissException`, but
  /// raising it is the client's job — the cache itself has no opinion
  /// about why it was asked.
  Future<CheckResult?> read(TraciveQuery query);

  /// Stores [result] for [query], subject to [policy].
  ///
  /// Writes [CheckResult.cacheable] — never the result as given. Full-detail
  /// content, billing and `checkId` are dropped on the way in, because the key
  /// is the query alone and a `detail=full`, `locale=id` answer must never be
  /// served to a `detail=minimal`, `locale=en` caller.
  ///
  /// A TTL of zero or less (a server `cacheTtlSeconds: 0`, the fleet-wide
  /// invalidation lever) does not merely skip the write: it **deletes** any
  /// row already stored for [query]. Never throws.
  Future<void> write(TraciveQuery query, CheckResult result);

  /// Files [result] as the answer that was shown for [transactionId].
  ///
  /// This is what a transaction-detail screen reads back weeks later —
  /// "checked before you sent it, no reports found" — and it exists because
  /// [read] cannot answer that question. [read] is keyed on the identifier and
  /// holds whatever the *latest* check said; a transaction detail has to show
  /// what the user was shown **at the time they decided**, and those two
  /// diverge the moment the same account is checked again.
  ///
  /// Three differences from [write], all following from that:
  ///
  ///   * **It is a snapshot, not a pointer.** Each call stores its own copy, so
  ///     a later check of the same account cannot rewrite what an earlier
  ///     transaction says. Recording one answer against two transactions — a
  ///     user who transfers to the same account twice — is two calls with two
  ///     ids and one billed check.
  ///   * **It outlives the cache entry.** The lifetime is
  ///     [CachePolicy.transactionCheckRetention], not a tier TTL, and
  ///     `cacheTtlSeconds` is not applied: that field retracts a verdict, and a
  ///     record of the past cannot be retracted.
  ///   * **`origin` and `fetchedAt` are stored as given**, so a record marked
  ///     `Origin.cache` is the honest statement that this transfer spent no
  ///     credit.
  ///
  /// Writes [CheckResult.transactionRecord], never the result as given.
  ///
  /// Call it **after** the transaction exists. In a transfer flow the check
  /// happens on the confirmation screen and the reference number is minted
  /// after the PIN, so there is no id to pass when the check is made — which is
  /// why this is a separate call rather than a parameter on `checkScammer`.
  ///
  /// Never throws on a storage fault; see [write]. Throws [ArgumentError] on a
  /// blank [transactionId].
  Future<void> writeTransactionCheck(String transactionId, CheckResult result);

  /// The answer recorded for [transactionId], or `null` when there is none.
  ///
  /// `null` covers a transaction that was never recorded, one past its
  /// retention, and a row that would not decode. A UI must read it as **"no
  /// check is on file"** and show nothing, never as "no reports were found":
  /// the second is a clean bill of health for a transfer nobody checked.
  ///
  /// Unlike [read] this does not restamp `origin`, and it does not apply the
  /// tier TTL. The record is a statement about a past moment, not a cached
  /// answer offered as current.
  ///
  /// Never throws on a storage fault; see [read]. Throws [ArgumentError] on a
  /// blank [transactionId].
  Future<CheckResult?> readTransactionCheck(String transactionId);

  /// Drops the record for [transactionId]. Returns whether a row was removed.
  ///
  /// Leaves the cache entry it was copied from, and every other transaction's
  /// record, alone. Throws like [remove] does, and [ArgumentError] on a blank
  /// [transactionId].
  Future<bool> removeTransactionCheck(String transactionId);

  /// Drops any entry for [query]. Returns whether a row was removed.
  ///
  /// **Unlike [read] and [write], this throws** if the storage cannot be
  /// opened or the cache is closed. That asymmetry is deliberate: a cache miss
  /// is a normal outcome a caller can carry on from, whereas "delete this
  /// entry" that quietly did nothing would leave the caller believing a stale
  /// verdict is gone when it is not. Same for [clear] and [prune].
  Future<bool> remove(TraciveQuery query);

  /// Empties the cache, transaction records included. The next check for every
  /// identifier costs a credit, and the check card on every transaction that
  /// still shows one goes quiet.
  ///
  /// Throws if the storage cannot be opened or the cache is closed — see
  /// [remove] for why this does not degrade silently the way [read] does.
  Future<void> clear();

  /// Deletes expired rows and enforces [CachePolicy.maxEntries]. Returns how
  /// many rows went. Runs automatically as part of [open].
  ///
  /// Throws if the storage cannot be opened or the cache is closed — see
  /// [remove].
  Future<int> prune();

  /// Closes the underlying storage.
  ///
  /// **Terminal.** A closed cache stays closed: [read] and [write] degrade to a
  /// miss and a no-op with the reason in [lastStoreError], and [remove],
  /// [clear] and [prune] throw. Build a new cache if you need one again.
  ///
  /// It used to reopen on the next use, which sounds convenient and is a race:
  /// a read arriving while the close is in flight reopens the database file
  /// underneath it, and two handles end up on one file.
  ///
  /// Calling it twice is harmless.
  Future<void> close();
}

/// The cache proper: [CachePolicy] and the caching rules on top of a
/// [CheckCacheStore].
///
/// Everything storage-specific is in the store, so the same rules are shared by
/// the in-memory and the SQLCipher-backed cache and are tested once.
class DefaultCheckCache implements CheckCache {
  /// Wraps [store]. [clock] defaults to `DateTime.now`, and is the seam the
  /// TTL tests drive.
  DefaultCheckCache({
    required CheckCacheStore store,
    this.policy = CachePolicy.defaultPolicy,
    CacheClock? clock,
  })  : _store = store,
        _clock = clock ?? DateTime.now;

  final CheckCacheStore _store;
  final CacheClock _clock;

  @override
  final CachePolicy policy;

  Future<void>? _opening;
  bool _closed = false;
  Object? _lastStoreError;

  /// What every operation gets once [close] has been called.
  static final StateError _closedError = StateError(
    'This CheckCache has been closed. Build a new one — a closed cache is '
    'terminal on purpose, because reopening the file underneath an in-flight '
    'close is how two handles end up on one database.',
  );

  @override
  Object? get lastStoreError => _lastStoreError;

  DateTime get _now => _clock().toUtc();

  @override
  Future<void> open() {
    if (_closed) throw _closedError;
    return _opening ??=
        _openOnce().catchError((Object error, StackTrace stackTrace) {
      // Let the next caller retry rather than poisoning the cache for the
      // lifetime of the process: the usual causes (a locked file, a Keystore
      // that is not ready before first unlock) are transient.
      _opening = null;
      _lastStoreError = error;
      Error.throwWithStackTrace(error, stackTrace);
    });
  }

  /// [open], plus a second check on the way out.
  ///
  /// The second check is the point. [close] can only run at an `await`, and
  /// every operation here has one inside [open] — so an operation that started
  /// before the close and resumed after it would otherwise call straight into a
  /// store that is closing, or (worse) reopen the file underneath the close
  /// through `SqlCheckCacheStore`'s reopen-on-demand path.
  Future<void> _ensureOpen() async {
    if (_closed) throw _closedError;
    await open();
    if (_closed) throw _closedError;
  }

  Future<void> _openOnce() async {
    await _store.open();
    await _pruneNow();
  }

  @override
  Future<CheckResult?> read(TraciveQuery query) async {
    if (!policy.enabled) return null;
    final key = cacheKeyFor(query);
    try {
      await _ensureOpen();
      final stored = await _store.read(key);
      if (stored == null) return null;

      final result = _decode(stored);
      if (result == null) {
        // Undecodable: written by a build that is no longer this one, or a
        // corrupted row. Drop it instead of retrying it on every check.
        await _store.delete(key);
        return null;
      }
      if (!policy.isFresh(result, _now)) {
        await _store.delete(key); // lazy expiry
        return null;
      }
      return result;
    } on Object catch (error) {
      // A cache is an optimisation. A device whose database will not open must
      // still be able to check a scammer; it just pays for every check.
      _lastStoreError = error;
      return null;
    }
  }

  @override
  Future<void> write(TraciveQuery query, CheckResult result) async {
    if (!policy.enabled) return;
    final key = cacheKeyFor(query);
    try {
      await _ensureOpen();
      final ttl = policy.ttlFor(result);
      if (ttl <= Duration.zero) {
        // "Do not cache this." Anything already stored is now wrong.
        await _store.delete(key);
        return;
      }

      // cacheable() is what enforces "full detail is never cached". It is
      // called here, once, rather than being left to each caller.
      final cacheable = result.cacheable();
      await _store.write(
        StoredCheck(
          cacheKey: key,
          payload: jsonEncode(cacheable.toJson()),
          riskTier: cacheable.riskTier.wireValue,
          fetchedAt: cacheable.fetchedAt.toUtc(),
          expiresAt: policy.expiryFor(cacheable),
          storedAt: _now,
        ),
      );
    } on Object catch (error) {
      _lastStoreError = error;
    }
  }

  @override
  Future<void> writeTransactionCheck(
    String transactionId,
    CheckResult result,
  ) async {
    // Derived before the try: a blank id is the caller's mistake and must
    // surface, not be swallowed by the storage-fault handler below.
    final key = transactionRecordKeyFor(transactionId);
    if (!policy.enabled) return;
    try {
      await _ensureOpen();
      final retention = policy.transactionCheckRetention;
      if (retention <= Duration.zero) {
        // "Keep no records." Anything already stored goes with it.
        await _store.delete(key);
        return;
      }

      final record = result.transactionRecord();
      await _store.write(
        StoredCheck(
          cacheKey: key,
          payload: jsonEncode(record.toJson()),
          riskTier: record.riskTier.wireValue,
          fetchedAt: record.fetchedAt.toUtc(),
          // Measured from now, not from `fetchedAt`. A cache entry expires when
          // its verdict goes stale, so it is dated from when the data was
          // produced; a record expires when the host stops wanting the history,
          // so it is dated from when the history was made.
          expiresAt: _now.add(retention),
          storedAt: _now,
        ),
      );
    } on Object catch (error) {
      _lastStoreError = error;
    }
  }

  @override
  Future<CheckResult?> readTransactionCheck(String transactionId) async {
    final key = transactionRecordKeyFor(transactionId);
    if (!policy.enabled) return null;
    try {
      await _ensureOpen();
      final stored = await _store.read(key);
      if (stored == null) return null;

      // The row's own `expiresAt`, not `policy.isFresh`. Freshness asks whether
      // a verdict is still worth trusting and is measured from `fetchedAt`;
      // retention asks whether the user may still see what they were told, and
      // a record whose verdict went stale months ago is still the right answer
      // to that.
      if (!_now.isBefore(stored.expiresAt)) {
        await _store.delete(key);
        return null;
      }

      // No `origin:` override: the origin this was recorded under is part of
      // what happened.
      final record = _decodeRecord(stored);
      if (record == null) {
        await _store.delete(key);
        return null;
      }
      return record;
    } on Object catch (error) {
      _lastStoreError = error;
      return null;
    }
  }

  @override
  Future<bool> removeTransactionCheck(String transactionId) async {
    final key = transactionRecordKeyFor(transactionId);
    await _ensureOpen();
    return _store.delete(key);
  }

  @override
  Future<bool> remove(TraciveQuery query) async {
    await _ensureOpen();
    return _store.delete(cacheKeyFor(query));
  }

  @override
  Future<void> clear() async {
    await _ensureOpen();
    await _store.clear();
  }

  @override
  Future<int> prune() async {
    await _ensureOpen();
    return _pruneNow();
  }

  Future<int> _pruneNow() =>
      _store.pruneExpired(_now, maxEntries: policy.maxEntries);

  @override
  Future<void> close() async {
    // Idempotent and terminal, and both flags are set before the first await:
    // a `read()` arriving while this is waiting must not be able to reopen the
    // file that is about to be closed.
    if (_closed) return;
    _closed = true;
    final opening = _opening;
    _opening = null;
    if (opening == null) return;
    // Wait for an in-flight open before closing under it; a failed open has
    // nothing to close.
    try {
      await opening;
    } on Object {
      return;
    }
    await _store.close();
  }

  /// Decodes a stored row, or `null` if it cannot be decoded.
  ///
  /// [CheckResult.fromJson] is deliberately tolerant, so this only fails on a
  /// payload that is not a JSON object at all.
  CheckResult? _decode(StoredCheck stored) {
    try {
      final decoded = asJsonMap(jsonDecode(stored.payload));
      if (decoded == null) return null;
      return CheckResult.fromJson(
        decoded,
        origin: Origin.cache,
        fetchedAt: stored.fetchedAt.toUtc(),
      );
    } on FormatException {
      return null;
    }
  }

  /// [_decode] for a transaction record: the stored `origin` is kept rather
  /// than replaced, because it is part of what the record states.
  CheckResult? _decodeRecord(StoredCheck stored) {
    try {
      final decoded = asJsonMap(jsonDecode(stored.payload));
      if (decoded == null) return null;
      return CheckResult.fromJson(decoded, fetchedAt: stored.fetchedAt.toUtc());
    } on FormatException {
      return null;
    }
  }
}

/// A cache that never stores and never hits — see [CheckCache.disabled].
class DisabledCheckCache implements CheckCache {
  /// Creates the no-op cache.
  const DisabledCheckCache();

  @override
  CachePolicy get policy => CachePolicy.disabled;

  @override
  Object? get lastStoreError => null;

  @override
  Future<void> open() async {}

  @override
  Future<CheckResult?> read(TraciveQuery query) async => null;

  @override
  Future<void> write(TraciveQuery query, CheckResult result) async {}

  @override
  Future<bool> remove(TraciveQuery query) async => false;

  // Transaction records go with the cache, because they are rows in it. A host
  // that wants the check card on its transaction-detail screen has to wire a
  // real cache — there is nowhere else to put them. The blank-id check still
  // runs, so that bug is found with the cache off rather than in production.

  @override
  Future<void> writeTransactionCheck(
    String transactionId,
    CheckResult result,
  ) async {
    transactionRecordKeyFor(transactionId);
  }

  @override
  Future<CheckResult?> readTransactionCheck(String transactionId) async {
    transactionRecordKeyFor(transactionId);
    return null;
  }

  @override
  Future<bool> removeTransactionCheck(String transactionId) async {
    transactionRecordKeyFor(transactionId);
    return false;
  }

  @override
  Future<void> clear() async {}

  @override
  Future<int> prune() async => 0;

  @override
  Future<void> close() async {}
}

/// The concrete type behind [CheckCache.inMemory].
///
/// A thin subclass rather than a factory returning [DefaultCheckCache] so that
/// `CheckCache.inMemory()` is a redirecting factory (which cannot redirect to a
/// non-constructor).
class _InMemoryCheckCache extends DefaultCheckCache {
  _InMemoryCheckCache({super.policy = CachePolicy.defaultPolicy, super.clock})
      : super(store: MemoryCheckCacheStore());
}
