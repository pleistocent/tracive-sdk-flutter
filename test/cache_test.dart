// Copyright 2026 PT Pleistocent Teknologi Nusantara.
// Licensed under the Apache License, Version 2.0.
//
// Cache tests.
//
// NO NETWORK, NO DEVICE. Every `CheckResult` here is built in-process, the
// clock is injected, and the only two storage backends exercised are the real
// in-memory store and a fake database. Nothing opens a socket, a file, a
// platform channel or a keystore, so this file runs under `dart test` as well
// as `flutter test`.
//
// What is deliberately NOT covered, so nobody mistakes green for complete:
// `lib/src/cache/tracive_cache.dart`, the ~120 lines that bind
// `sqflite_sqlcipher` and `flutter_secure_storage` to the seams below. Those
// need a device or an emulator; see `doc/caching.md`.
//
// Imported through `src/` rather than the barrel because the barrel does not
// export the cache yet — same as `test/query_grammar_test.dart` does for the
// document-id guard. See the packaging note in `lib/src/cache/check_cache.dart`.

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:tracive_sdk/tracive_sdk.dart';

void main() {
  // A distinctive number: several tests assert it appears nowhere in storage.
  final phone = TraciveQuery.phone('+6281234567891');
  final otherPhone = TraciveQuery.phone('+6281100002222');

  group('cache key', () {
    test('is the SHA-256 of the folded key, in lowercase hex', () {
      final expected =
          sha256.convert(utf8.encode('PHONE_+6281234567891')).toString();
      expect(cacheKeyFor(phone), expected);
      expect(cacheKeyFor(phone), hasLength(64));
      expect(cacheKeyFor(phone), matches(RegExp(r'^[0-9a-f]{64}$')));
    });

    test('never contains the identifier it was derived from', () {
      expect(cacheKeyFor(phone), isNot(contains('6281234567891')));
      expect(cacheKeyFor(phone), isNot(contains('PHONE')));
    });

    test('separates different identifiers and collapses equal ones', () {
      expect(cacheKeyFor(phone), isNot(cacheKeyFor(otherPhone)));
      expect(cacheKeyFor(phone),
          cacheKeyFor(TraciveQuery.phone('+62 812-3456-7891')));
    });

    test('is the same whichever builder produced an equal folded key', () {
      final email = TraciveQuery.email('Budi@Example.COM');
      expect(cacheKeyFor(email), cacheKeyForIndex('EMAIL_budi@example.com'));
    });
  });

  group('TTL by tier', () {
    // HIGH 30 d, ELEVATED 7 d, CAUTION 24 h, NONE 1 h.
    const expectations = <RiskTier, Duration>{
      RiskTier.high: Duration(days: 30),
      RiskTier.elevated: Duration(days: 7),
      RiskTier.caution: Duration(hours: 24),
      RiskTier.none: Duration(hours: 1),
    };

    expectations.forEach((tier, ttl) {
      test('${tier.wireValue} is live for $ttl and stale after', () async {
        final clock = _MutableClock(DateTime.utc(2026, 7, 31, 9));
        final cache = CheckCache.inMemory(clock: clock.call);
        await cache.write(phone, _result(tier: tier, fetchedAt: clock.now));

        clock.advance(ttl - const Duration(seconds: 1));
        final live = await cache.read(phone);
        expect(live, isNotNull, reason: 'still inside the $tier TTL');
        expect(live!.riskTier, tier);

        clock.advance(const Duration(seconds: 2));
        expect(await cache.read(phone), isNull, reason: 'past the $tier TTL');
      });
    });

    test('expires exactly at the boundary, not a tick later', () async {
      final clock = _MutableClock(DateTime.utc(2026, 7, 31, 9));
      final cache = CheckCache.inMemory(clock: clock.call);
      await cache.write(
        phone,
        _result(tier: RiskTier.none, fetchedAt: clock.now),
      );

      clock.advance(const Duration(hours: 1));
      expect(await cache.read(phone), isNull);
    });

    test('measures the TTL from fetchedAt, not from the write', () async {
      final clock = _MutableClock(DateTime.utc(2026, 7, 31, 9));
      final cache = CheckCache.inMemory(clock: clock.call);

      // A result that was already 50 minutes old when it was stored.
      await cache.write(
        phone,
        _result(
          tier: RiskTier.none,
          fetchedAt: clock.now.subtract(const Duration(minutes: 50)),
        ),
      );

      clock.advance(const Duration(minutes: 9));
      expect(await cache.read(phone), isNotNull);
      clock.advance(const Duration(minutes: 2));
      expect(await cache.read(phone), isNull);
    });

    test('a lapsed entry is deleted on read, not left to rot', () async {
      final clock = _MutableClock(DateTime.utc(2026, 7, 31, 9));
      final store = MemoryCheckCacheStore();
      final cache = DefaultCheckCache(store: store, clock: clock.call);

      await cache.write(
        phone,
        _result(tier: RiskTier.none, fetchedAt: clock.now),
      );
      expect(await store.count(), 1);

      clock.advance(const Duration(hours: 2));
      expect(await cache.read(phone), isNull);
      expect(await store.count(), 0, reason: 'lazy expiry');
    });

    test('a policy change applies to rows already stored', () async {
      final clock = _MutableClock(DateTime.utc(2026, 7, 31, 9));
      final store = MemoryCheckCacheStore();
      final written = DefaultCheckCache(store: store, clock: clock.call);
      await written.write(
        phone,
        _result(tier: RiskTier.high, fetchedAt: clock.now),
      );

      // Same rows, a build that trusts HIGH for one day instead of thirty.
      final shorter = DefaultCheckCache(
        store: store,
        clock: clock.call,
        policy: const CachePolicy(highTtl: Duration(days: 1)),
      );
      clock.advance(const Duration(days: 2));
      expect(
        await shorter.read(phone),
        isNull,
        reason: 'the live policy decides, not the stamp written at write time',
      );
    });
  });

  group('the tier ladder is the only TTL policy', () {
    test('a shorter configured tier TTL is obeyed', () async {
      final clock = _MutableClock(DateTime.utc(2026, 7, 31, 9));
      final cache = CheckCache.inMemory(
        clock: clock.call,
        policy: const CachePolicy(highTtl: Duration(seconds: 60)),
      );
      await cache.write(
        phone,
        _result(tier: RiskTier.high, fetchedAt: clock.now),
      );

      clock.advance(const Duration(seconds: 59));
      expect(await cache.read(phone), isNotNull);
      clock.advance(const Duration(seconds: 2));
      expect(await cache.read(phone), isNull);
    });

    test('a zero tier TTL stores nothing and drops what was there', () async {
      final clock = _MutableClock(DateTime.utc(2026, 7, 31, 9));
      final store = MemoryCheckCacheStore();
      final cache = DefaultCheckCache(
        store: store,
        clock: clock.call,
        policy: const CachePolicy(noneTtl: Duration.zero),
      );

      await cache.write(
        phone,
        _result(tier: RiskTier.high, fetchedAt: clock.now),
      );
      expect(await store.count(), 1);

      // The verdict flips to a tier this host does not cache. Declining to
      // store the new answer is not enough — the old HIGH would keep being
      // served for the rest of its thirty days.
      await cache.write(
        phone,
        _result(tier: RiskTier.none, fetchedAt: clock.now),
      );
      expect(await store.count(), 0);
      expect(await cache.read(phone), isNull);
    });

    test('a cacheTtlSeconds still on the wire is ignored', () async {
      // The backend stopped sending it and the SDK no longer models it.
      // `fromJson` must skip the key rather than throw, and the tier default
      // must decide the lifetime.
      final clock = _MutableClock(DateTime.utc(2026, 7, 31, 9));
      final cache = CheckCache.inMemory(clock: clock.call);
      final decoded = CheckResult.fromJson(
        <String, Object?>{
          'found': true,
          'riskTier': 'HIGH',
          'cacheTtlSeconds': 60,
        },
        fetchedAt: clock.now,
      );

      await cache.write(phone, decoded);

      clock.advance(const Duration(days: 2));
      expect(await cache.read(phone), isNotNull,
          reason: 'HIGH default is 30 d');
    });
  });

  group('full detail is never cached', () {
    late CheckResult stored;

    setUp(() async {
      final clock = _MutableClock(DateTime.utc(2026, 7, 31, 9));
      final cache = CheckCache.inMemory(clock: clock.call);
      await cache.write(
        phone,
        _result(
          tier: RiskTier.high,
          fetchedAt: clock.now,
          checkId: 'chk_abc123',
          full: true,
        ),
      );
      stored = (await cache.read(phone))!;
    });

    test('drops topChronologies and comments', () {
      expect(stored.topChronologies, isNull);
      expect(stored.comments, isNull);
      expect(stored.hasFullDetail, isFalse);
    });

    test('drops billing — a replayed charge would misreport spend', () {
      expect(stored.billing, isNull);
    });

    test('drops checkId — nothing was checked on a hit', () {
      expect(stored.checkId, isNull);
    });

    test('keeps everything that is invariant across detail and locale', () {
      expect(stored.found, isTrue);
      expect(stored.riskTier, RiskTier.high);
      expect(stored.reportTotal, 12);
      expect(stored.credibleReports, 9);
      expect(stored.ambiguousReports, 3);
      expect(stored.tags, <String>['investment']);
      expect(stored.fraudAmount, <String, double>{'IDR': 4500000});
      expect(stored.relatedScammerCount, 4);
      expect(stored.disclaimer, isNotNull);
    });

    test('is stamped as a cache hit, keeping the original fetch time', () {
      expect(stored.origin, Origin.cache);
      expect(stored.isFromCache, isTrue);
      expect(stored.fetchedAt, DateTime.utc(2026, 7, 31, 9));
    });

    test('nothing full-detail reaches storage in the first place', () async {
      final store = MemoryCheckCacheStore();
      final cache = DefaultCheckCache(store: store);
      await cache.write(
        phone,
        _result(
          tier: RiskTier.high,
          fetchedAt: DateTime.utc(2026, 7, 31, 9),
          checkId: 'chk_abc123',
          full: true,
        ),
      );

      final payload = (await store.read(cacheKeyFor(phone)))!.payload;
      expect(payload, isNot(contains('Promised 30% monthly returns')));
      expect(payload, isNot(contains('chk_abc123')));
      expect(payload, isNot(contains('unitsCharged')));
    });
  });

  group('privacy', () {
    test('no stored field carries the identifier', () async {
      final store = MemoryCheckCacheStore();
      final cache = DefaultCheckCache(store: store);
      await cache.write(
        phone,
        _result(tier: RiskTier.high, fetchedAt: DateTime.utc(2026, 7, 31, 9)),
      );

      final row = (await store.read(cacheKeyFor(phone)))!;
      for (final field in <String>[row.cacheKey, row.payload, row.riskTier]) {
        expect(field, isNot(contains('6281234567891')));
        expect(field, isNot(contains('PHONE_')));
      }
      expect(row.toString(), isNot(contains('6281234567891')));
    });
  });

  group('policy off', () {
    test('an enabled: false policy reads and writes nothing', () async {
      final store = MemoryCheckCacheStore();
      final cache = DefaultCheckCache(
        store: store,
        policy: CachePolicy.disabled,
      );
      await cache.write(
        phone,
        _result(tier: RiskTier.high, fetchedAt: DateTime.utc(2026, 7, 31, 9)),
      );
      expect(await store.count(), 0);
      expect(await cache.read(phone), isNull);
    });

    test('CheckCache.disabled() is inert', () async {
      const cache = CheckCache.disabled();
      await cache.write(
        phone,
        _result(tier: RiskTier.high, fetchedAt: DateTime.utc(2026, 7, 31, 9)),
      );
      expect(await cache.read(phone), isNull);
      expect(await cache.prune(), 0);
      expect(await cache.remove(phone), isFalse);
      expect(cache.policy.enabled, isFalse);
      expect(cache.lastStoreError, isNull);
    });
  });

  group('housekeeping', () {
    test('remove drops one entry and leaves the rest', () async {
      // Pinned, like every other TTL-sensitive test here. Without the clock this
      // wrote a HIGH entry dated 31 July against the real one, so it passed until
      // the 30-day TTL ran out on 30 August and then failed on the calendar rather
      // than on `remove`. Moving the date forward buys another 30 days; pinning the
      // clock is what makes the test about what it claims to test.
      final clock = _MutableClock(DateTime.utc(2026, 7, 31, 9));
      final cache = CheckCache.inMemory(clock: clock.call);
      await cache.write(
        phone,
        _result(tier: RiskTier.high, fetchedAt: clock.now),
      );
      await cache.write(
        otherPhone,
        _result(tier: RiskTier.high, fetchedAt: clock.now),
      );

      expect(await cache.remove(phone), isTrue);
      expect(await cache.remove(phone), isFalse);
      expect(await cache.read(phone), isNull);
      expect(await cache.read(otherPhone), isNotNull);
    });

    test('clear empties everything', () async {
      final cache = CheckCache.inMemory();
      final now = DateTime.utc(2026, 7, 31, 9);
      await cache.write(phone, _result(tier: RiskTier.high, fetchedAt: now));
      await cache.write(
        otherPhone,
        _result(tier: RiskTier.high, fetchedAt: now),
      );

      await cache.clear();
      expect(await cache.read(phone), isNull);
      expect(await cache.read(otherPhone), isNull);
    });

    test('open prunes what expired while the app was closed', () async {
      final clock = _MutableClock(DateTime.utc(2026, 7, 31, 9));
      final store = MemoryCheckCacheStore();

      // A previous run of the app.
      final before = DefaultCheckCache(store: store, clock: clock.call);
      await before.write(
        phone,
        _result(tier: RiskTier.none, fetchedAt: clock.now),
      );
      await before.write(
        otherPhone,
        _result(tier: RiskTier.high, fetchedAt: clock.now),
      );
      expect(await store.count(), 2);

      // Two days later, a fresh process over the same rows.
      clock.advance(const Duration(days: 2));
      final after = DefaultCheckCache(store: store, clock: clock.call);
      await after.open();
      expect(await store.count(), 1, reason: 'the NONE entry lapsed');
      expect(await after.read(otherPhone), isNotNull);
    });

    test('prune evicts down to maxEntries, keeping the longest-lived',
        () async {
      final clock = _MutableClock(DateTime.utc(2026, 7, 31, 9));
      final store = MemoryCheckCacheStore();
      final cache = DefaultCheckCache(
        store: store,
        clock: clock.call,
        policy: const CachePolicy(maxEntries: 2),
      );

      await cache.write(
        TraciveQuery.phone('+6281000000001'),
        _result(tier: RiskTier.none, fetchedAt: clock.now), // 1 h
      );
      await cache.write(
        TraciveQuery.phone('+6281000000002'),
        _result(tier: RiskTier.caution, fetchedAt: clock.now), // 24 h
      );
      await cache.write(
        TraciveQuery.phone('+6281000000003'),
        _result(tier: RiskTier.high, fetchedAt: clock.now), // 30 d
      );

      expect(await cache.prune(), 1);
      expect(await store.count(), 2);
      expect(await cache.read(TraciveQuery.phone('+6281000000001')), isNull);
      expect(await cache.read(TraciveQuery.phone('+6281000000002')), isNotNull);
      expect(await cache.read(TraciveQuery.phone('+6281000000003')), isNotNull);
    });

    test('a maxEntries of 0 means no cap', () async {
      final store = MemoryCheckCacheStore();
      final clock = _MutableClock(DateTime.utc(2026, 7, 31, 9));
      final cache = DefaultCheckCache(
        store: store,
        policy: const CachePolicy(maxEntries: 0),
        clock: clock.call,
      );
      for (var i = 0; i < 5; i++) {
        await cache.write(
          TraciveQuery.phone('+628100000000$i'),
          _result(tier: RiskTier.high, fetchedAt: clock.now),
        );
      }
      // Nothing pruned because nothing is capped — not because nothing is stale.
      // Against the real clock these entries aged out and `prune` returned 5.
      expect(await cache.prune(), 0);
      expect(await store.count(), 5);
    });
  });

  group('a broken store degrades instead of breaking the SDK', () {
    test('read and write swallow, and record, a storage failure', () async {
      final cache = DefaultCheckCache(store: _BrokenStore());
      final result = _result(
        tier: RiskTier.high,
        fetchedAt: DateTime.utc(2026, 7, 31, 9),
      );

      await expectLater(cache.write(phone, result), completes);
      await expectLater(cache.read(phone), completion(isNull));
      expect(
        cache.lastStoreError,
        isNotNull,
        reason: 'the caller has to be able to see that the cache is dead',
      );
    });

    test('an undecodable row is dropped rather than retried forever', () async {
      final store = MemoryCheckCacheStore();
      final cache = DefaultCheckCache(store: store);
      await store.write(
        StoredCheck(
          cacheKey: cacheKeyFor(phone),
          payload: 'this is not JSON',
          riskTier: 'HIGH',
          fetchedAt: DateTime.utc(2026, 7, 31, 9),
          expiresAt: DateTime.utc(2099),
          storedAt: DateTime.utc(2026, 7, 31, 9),
        ),
      );

      expect(await cache.read(phone), isNull);
      expect(await store.count(), 0);
    });
  });

  group('SQL store', () {
    late _FakeCacheDatabase database;
    late SqlCheckCacheStore store;

    setUp(() {
      database = _FakeCacheDatabase();
      store = SqlCheckCacheStore(opener: () async => database);
    });

    test('creates the table and stamps the schema version on a fresh file',
        () async {
      await store.open();
      expect(database.statements, <String>[
        SqlCheckCacheStore.readSchemaVersionSql,
        SqlCheckCacheStore.dropTableSql,
        SqlCheckCacheStore.createTableSql,
        SqlCheckCacheStore.createIndexSql,
        SqlCheckCacheStore.writeSchemaVersionSql,
      ]);
      expect(database.userVersion, checkCacheSchemaVersion);
    });

    test('leaves rows alone when the schema version already matches', () async {
      database
        ..userVersion = checkCacheSchemaVersion
        ..rows['existing'] = _columns(_row('existing'));

      await store.open();
      expect(database.statements,
          isNot(contains(SqlCheckCacheStore.dropTableSql)));
      expect(database.rows, contains('existing'));
    });

    test('drops every row when the stored schema version is older', () async {
      database
        ..userVersion = checkCacheSchemaVersion - 1
        ..rows['stale'] = _columns(_row('stale'));

      await store.open();
      expect(database.statements, contains(SqlCheckCacheStore.dropTableSql));
      expect(database.rows, isEmpty, reason: 'schema-version invalidation');
      expect(database.userVersion, checkCacheSchemaVersion);
    });

    test('drops every row when the schema version cannot be read', () async {
      database.userVersion = null;
      await store.open();
      expect(database.statements, contains(SqlCheckCacheStore.dropTableSql));
      expect(database.userVersion, checkCacheSchemaVersion);
    });

    test('round-trips a row through bound parameters only', () async {
      final entry = _row('abc');
      await store.write(entry);

      final insertIndex = database.statements.indexOf(
        SqlCheckCacheStore.insertSql,
      );
      expect(insertIndex, isNonNegative);
      expect(database.arguments[insertIndex], <Object?>[
        'abc',
        entry.payload,
        'HIGH',
        entry.fetchedAt.millisecondsSinceEpoch,
        entry.expiresAt.millisecondsSinceEpoch,
        entry.storedAt.millisecondsSinceEpoch,
      ]);

      final read = await store.read('abc');
      expect(read, isNotNull);
      expect(read!.cacheKey, 'abc');
      expect(read.payload, entry.payload);
      expect(read.riskTier, 'HIGH');
      expect(read.fetchedAt, entry.fetchedAt);
      expect(read.expiresAt, entry.expiresAt);
      expect(await store.read('missing'), isNull);
    });

    test('delete, clear and count', () async {
      await store.write(_row('a'));
      await store.write(_row('b'));
      expect(await store.count(), 2);
      expect(await store.delete('a'), isTrue);
      expect(await store.delete('a'), isFalse);
      expect(await store.count(), 1);
      await store.clear();
      expect(await store.count(), 0);
    });

    test('prune deletes what expired and then trims to the cap', () async {
      final now = DateTime.utc(2026, 7, 31, 9);
      await store.write(
          _row('expired', expiresAt: now.subtract(const Duration(minutes: 1))));
      await store
          .write(_row('short', expiresAt: now.add(const Duration(hours: 1))));
      await store
          .write(_row('long', expiresAt: now.add(const Duration(days: 30))));

      expect(await store.pruneExpired(now, maxEntries: 1), 2);
      expect(database.rows.keys, <String>['long']);
    });

    test('prune with no cap only deletes what expired', () async {
      final now = DateTime.utc(2026, 7, 31, 9);
      await store.write(
          _row('expired', expiresAt: now.subtract(const Duration(minutes: 1))));
      await store
          .write(_row('live', expiresAt: now.add(const Duration(days: 1))));

      expect(await store.pruneExpired(now), 1);
      expect(database.rows.keys, <String>['live']);
    });

    test('reopens after close', () async {
      await store.open();
      await store.close();
      expect(database.closed, isTrue);
      await store.write(_row('after-close'));
      expect(database.rows, contains('after-close'));
    });

    test('sends no statement this test does not know about', () async {
      // The fake throws on an unrecognised statement, so simply exercising
      // every operation is the assertion. If someone adds a statement to the
      // store without adding it here, this fails.
      await store.open();
      await store.write(_row('x'));
      await store.read('x');
      await store.count();
      await store.pruneExpired(DateTime.utc(2026), maxEntries: 10);
      await store.delete('x');
      await store.clear();
      await store.close();
    });
  });

  group('cache over SQL', () {
    test('nothing that identifies the user is bound into a statement',
        () async {
      final database = _FakeCacheDatabase();
      final clock = _MutableClock(DateTime.utc(2026, 7, 31, 9));
      final cache = DefaultCheckCache(
        store: SqlCheckCacheStore(opener: () async => database),
        clock: clock.call,
      );

      await cache.write(
        phone,
        _result(
          tier: RiskTier.high,
          fetchedAt: clock.now,
          checkId: 'chk_abc123',
          full: true,
        ),
      );
      expect(await cache.read(phone), isNotNull);

      final everything = <String>[
        ...database.statements,
        ...database.arguments.expand((args) => args.map((a) => '$a')),
      ].join('\n');
      expect(everything, isNot(contains('6281234567891')));
      expect(everything, isNot(contains('PHONE_')));
      expect(everything, isNot(contains('chk_abc123')));
      expect(everything, isNot(contains('Promised 30% monthly returns')));
    });

    test('survives a full write-read-expire cycle on the fake database',
        () async {
      final clock = _MutableClock(DateTime.utc(2026, 7, 31, 9));
      final database = _FakeCacheDatabase();
      final cache = DefaultCheckCache(
        store: SqlCheckCacheStore(opener: () async => database),
        clock: clock.call,
      );

      await cache.write(
        phone,
        _result(tier: RiskTier.caution, fetchedAt: clock.now),
      );
      expect((await cache.read(phone))!.riskTier, RiskTier.caution);

      clock.advance(const Duration(hours: 25));
      expect(await cache.read(phone), isNull);
      expect(database.rows, isEmpty);
    });
  });

  group('close', () {
    test('is idempotent', () async {
      final cache = CheckCache.inMemory();
      await cache.open();
      await cache.close();
      await expectLater(cache.close(), completes);
    });

    test('a read after close does not reopen the store', () async {
      // `close()` used to clear its latch *before* awaiting, so a read arriving
      // afterwards called `open()` again and reopened the database underneath
      // the close — two handles on one file. Degrading to a miss is what the
      // read contract promises anyway.
      final store = _CountingOpenStore();
      final cache = DefaultCheckCache(store: store);
      await cache.open();
      expect(store.opens, 1);

      await cache.close();
      expect(await cache.read(phone), isNull);

      expect(store.opens, 1, reason: 'the store was reopened after close');
      expect(cache.lastStoreError, isA<StateError>());
    });

    test('a write after close is a no-op, not a throw', () async {
      // read/write are documented never to throw. A closed cache must not be
      // the exception that proves the rule.
      final store = _CountingOpenStore();
      final cache = DefaultCheckCache(store: store);
      await cache.close();

      await expectLater(
        cache.write(
          phone,
          _result(tier: RiskTier.high, fetchedAt: DateTime.utc(2026, 7, 31, 9)),
        ),
        completes,
      );
      expect(store.opens, 0);
      expect(cache.lastStoreError, isA<StateError>());
    });

    test('remove/clear/prune after close throw, and say why', () async {
      final cache = CheckCache.inMemory();
      await cache.close();

      await expectLater(cache.remove(phone), throwsStateError);
      await expectLater(cache.clear(), throwsStateError);
      await expectLater(cache.prune(), throwsStateError);
    });

    test('a read that was waiting on the open gives up when it closes',
        () async {
      // The interleaving the flag has to be checked twice for: the read is
      // parked inside `open()` when `close()` runs, and resumes afterwards.
      final store =
          _CountingOpenStore(openDelay: const Duration(milliseconds: 40));
      final cache = DefaultCheckCache(store: store);

      final reading = cache.read(phone);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await cache.close();

      expect(await reading, isNull);
      expect(cache.lastStoreError, isA<StateError>());
    });
  });

  // --------------------------------------------------------------------------
  // The two open paths are read-then-write races, and both fail expensively:
  // a lost database key means the file cannot be decrypted, which the SDK
  // recovers from by rebuilding the cache — so every identifier in it costs a
  // credit again.
  // --------------------------------------------------------------------------
  group('concurrent open', () {
    test('two callers asking for the key at once get the same key', () async {
      // Both find the entry empty, both mint a key, both write. The loser's key
      // is the one the database was opened under, and it is now gone.
      final store = _CountingSecretStore();

      final a = readOrCreateCacheDatabaseKey(store);
      final b = readOrCreateCacheDatabaseKey(store);
      final keys = await Future.wait(<Future<String>>[a, b]);

      expect(keys.first, keys.last, reason: 'the callers disagree on the key');
      expect(store.writes, 1, reason: 'the key was minted twice');
      expect(await store.read(cacheDatabaseKeyEntry), keys.first);
    });

    test('a later caller still gets the stored key', () async {
      // The latch must not outlive its flight, or the second run of an app
      // would be handed a stale future.
      final store = _CountingSecretStore();
      final first = await readOrCreateCacheDatabaseKey(store);
      final second = await readOrCreateCacheDatabaseKey(store);

      expect(second, first);
      expect(store.writes, 1);
      expect(store.reads, 2, reason: 'the second call really did read again');
    });

    test('two callers opening the SQL store open one database', () async {
      // `if (_database != null) return` is not a latch: both callers pass it
      // and both call the opener, so one database handle is opened and then
      // dropped on the floor without ever being closed.
      var opened = 0;
      final store = SqlCheckCacheStore(opener: () async {
        opened++;
        await Future<void>.delayed(Duration.zero);
        return _FakeCacheDatabase();
      });

      await Future.wait(<Future<void>>[store.open(), store.open()]);

      expect(opened, 1, reason: 'a second database handle was leaked');
    });

    test('a database that fails mid-open is closed, not leaked', () async {
      // The handle is opened at the top of open() and only recorded at the
      // bottom. Anything that throws in between — a PRAGMA read, the DROP, the
      // CREATE — leaves an open handle that nothing can ever reach or close,
      // and the cache retries on the next read and leaks another.
      final database = _FakeCacheDatabase()..failNextExecute = true;
      final store = SqlCheckCacheStore(opener: () async => database);

      await expectLater(store.open(), throwsA(isA<StateError>()));
      expect(
        database.closed,
        isTrue,
        reason: 'the half-opened database was never closed',
      );
      expect(store.database, isNull);
    });
  });
}

/// A result with the shape of a `POST /scammer-checks` answer.
///
/// [full] adds the `detail = full` payload plus billing, which the cache must
/// drop.
CheckResult _result({
  required RiskTier tier,
  required DateTime fetchedAt,
  String? checkId,
  bool full = false,
}) =>
    CheckResult(
      checkId: checkId,
      found: tier != RiskTier.none,
      riskTier: tier,
      reportTotal: 12,
      credibleReports: 9,
      ambiguousReports: 3,
      firstReportOn: DateTime.utc(2025, 1, 15, 12),
      lastReportOn: DateTime.utc(2026, 7, 15, 12),
      fraudAmount: const <String, double>{'IDR': 4500000},
      tags: const <String>['investment'],
      relatedScammerCount: 4,
      topChronologies: full
          ? <Chronology>[
              const Chronology(
                chronology: 'Promised 30% monthly returns.',
                riskLevel: 3,
                incidentDate: '2026-06',
              ),
            ]
          : null,
      comments: full
          ? <Comment>[
              const Comment(
                date: '2026-06',
                text: 'Took my deposit and blocked me.',
                fromCredibleReport: true,
              ),
            ]
          : null,
      billing:
          full ? const Billing(creditSource: 'USER', unitsCharged: 1) : null,
      disclaimer: 'User reports, not adjudicated findings.',
      origin: Origin.server,
      fetchedAt: fetchedAt,
    );

StoredCheck _row(String key, {DateTime? expiresAt}) => StoredCheck(
      cacheKey: key,
      payload: jsonEncode(<String, Object?>{'found': true, 'riskTier': 'HIGH'}),
      riskTier: 'HIGH',
      fetchedAt: DateTime.utc(2026, 7, 31, 9),
      expiresAt: expiresAt ?? DateTime.utc(2026, 8, 30, 9),
      storedAt: DateTime.utc(2026, 7, 31, 9),
    );

/// [entry] as the column map [_FakeCacheDatabase] holds, for seeding a row that
/// is supposed to already be in the file before `open()` runs.
Map<String, Object?> _columns(StoredCheck entry) => <String, Object?>{
      'cache_key': entry.cacheKey,
      'payload': entry.payload,
      'risk_tier': entry.riskTier,
      'fetched_at': entry.fetchedAt.millisecondsSinceEpoch,
      'expires_at': entry.expiresAt.millisecondsSinceEpoch,
      'stored_at': entry.storedAt.millisecondsSinceEpoch,
    };

/// A clock the tests move by hand. `clock.call` is the [CacheClock].
class _MutableClock {
  _MutableClock(this.now);

  DateTime now;

  DateTime call() => now;

  void advance(Duration by) => now = now.add(by);
}

/// A store whose every operation fails, standing in for a corrupted database
/// or an unreadable keystore.
class _BrokenStore extends CheckCacheStore {
  @override
  Future<void> open() async => throw StateError('database unavailable');

  @override
  Future<StoredCheck?> read(String cacheKey) async =>
      throw StateError('database unavailable');

  @override
  Future<void> write(StoredCheck entry) async =>
      throw StateError('database unavailable');

  @override
  Future<bool> delete(String cacheKey) async =>
      throw StateError('database unavailable');

  @override
  Future<void> clear() async => throw StateError('database unavailable');

  @override
  Future<int> pruneExpired(DateTime now, {int maxEntries = 0}) async =>
      throw StateError('database unavailable');

  @override
  Future<int> count() async => throw StateError('database unavailable');

  @override
  Future<void> close() async {}
}

/// A stand-in for SQLite that understands exactly the statements
/// [SqlCheckCacheStore] issues — matched against that class's own constants,
/// not parsed — and throws on anything else.
///
/// It is deliberately not a SQL engine. What it proves is that the store issues
/// the right statement with the right bound arguments in the right order; that
/// those statements are *valid SQLite* is proved by running them against a real
/// database on a device (see `doc/caching.md`).
class _FakeCacheDatabase extends CacheDatabase {
  final List<String> statements = <String>[];
  final List<List<Object?>> arguments = <List<Object?>>[];
  final Map<String, Map<String, Object?>> rows =
      <String, Map<String, Object?>>{};

  int? userVersion = 0;
  bool closed = false;

  void _record(String sql, List<Object?>? args) {
    statements.add(sql);
    arguments.add(args ?? const <Object?>[]);
  }

  /// Makes the next [execute] throw, to model a statement failing part-way
  /// through opening.
  bool failNextExecute = false;

  @override
  Future<void> execute(String sql, [List<Object?>? args]) async {
    _record(sql, args);
    if (failNextExecute) {
      failNextExecute = false;
      throw StateError('statement failed: $sql');
    }
    switch (sql) {
      case SqlCheckCacheStore.dropTableSql:
        rows.clear();
      case SqlCheckCacheStore.createTableSql:
      case SqlCheckCacheStore.createIndexSql:
        break;
      case SqlCheckCacheStore.writeSchemaVersionSql:
        userVersion = checkCacheSchemaVersion;
      default:
        throw UnsupportedError('unexpected statement: $sql');
    }
  }

  @override
  Future<List<Map<String, Object?>>> query(
    String sql, [
    List<Object?>? args,
  ]) async {
    _record(sql, args);
    switch (sql) {
      case SqlCheckCacheStore.readSchemaVersionSql:
        return <Map<String, Object?>>[
          <String, Object?>{'user_version': userVersion},
        ];
      case SqlCheckCacheStore.selectSql:
        final row = rows[args!.first];
        return row == null
            ? const <Map<String, Object?>>[]
            : <Map<String, Object?>>[row];
      case SqlCheckCacheStore.countSql:
        return <Map<String, Object?>>[
          <String, Object?>{'row_count': rows.length},
        ];
      default:
        throw UnsupportedError('unexpected query: $sql');
    }
  }

  @override
  Future<int> insert(String sql, [List<Object?>? args]) async {
    _record(sql, args);
    if (sql != SqlCheckCacheStore.insertSql) {
      throw UnsupportedError('unexpected insert: $sql');
    }
    final values = args!;
    rows[values[0]! as String] = <String, Object?>{
      'cache_key': values[0],
      'payload': values[1],
      'risk_tier': values[2],
      'fetched_at': values[3],
      'expires_at': values[4],
      'stored_at': values[5],
    };
    return rows.length;
  }

  @override
  Future<int> delete(String sql, [List<Object?>? args]) async {
    _record(sql, args);
    switch (sql) {
      case SqlCheckCacheStore.deleteSql:
        return rows.remove(args!.first) == null ? 0 : 1;
      case SqlCheckCacheStore.deleteAllSql:
        final removed = rows.length;
        rows.clear();
        return removed;
      case SqlCheckCacheStore.deleteExpiredSql:
        final cutoff = args!.first! as int;
        final doomed = rows.entries
            .where((entry) => (entry.value['expires_at']! as int) <= cutoff)
            .map((entry) => entry.key)
            .toList(growable: false);
        doomed.forEach(rows.remove);
        return doomed.length;
      case SqlCheckCacheStore.deleteOverCapSql:
        final offset = args!.first! as int;
        // ORDER BY expires_at DESC, stored_at DESC LIMIT -1 OFFSET ?
        final ordered = rows.values.toList(growable: false)
          ..sort((a, b) {
            final byExpiry = (b['expires_at']! as int).compareTo(
              a['expires_at']! as int,
            );
            return byExpiry != 0
                ? byExpiry
                : (b['stored_at']! as int).compareTo(a['stored_at']! as int);
          });
        final doomed = ordered
            .skip(offset)
            .map((row) => row['cache_key']! as String)
            .toList(growable: false);
        doomed.forEach(rows.remove);
        return doomed.length;
      default:
        throw UnsupportedError('unexpected delete: $sql');
    }
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

/// A [CacheSecretStore] that counts what it is asked to do.
///
/// Its `read` is `async`, which is all it takes to reproduce the race: the
/// await gives a second caller a turn before the first has written anything.
/// A real Keystore read, which crosses a platform channel, gives it far more.
class _CountingSecretStore extends CacheSecretStore {
  final Map<String, String> _entries = <String, String>{};

  int reads = 0;
  int writes = 0;

  @override
  Future<String?> read(String key) async {
    reads++;
    return _entries[key];
  }

  @override
  Future<void> write(String key, String value) async {
    writes++;
    _entries[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _entries.remove(key);
  }
}

/// A [CheckCacheStore] that counts how many times it was opened, and can be
/// made slow to open so a close can be interleaved with a read that is waiting.
class _CountingOpenStore extends MemoryCheckCacheStore {
  _CountingOpenStore({this.openDelay = Duration.zero});

  /// How long [open] takes.
  final Duration openDelay;

  /// How many times [open] has actually run.
  int opens = 0;

  @override
  Future<void> open() async {
    opens++;
    if (openDelay > Duration.zero) await Future<void>.delayed(openDelay);
  }
}
