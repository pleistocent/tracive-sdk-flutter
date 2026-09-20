// Copyright 2026 PT Pleistocent Teknologi Nusantara.
// Licensed under the Apache License, Version 2.0.
//
// Transaction records: the answer that was shown for one of the host's own
// transactions, filed under the host's transaction id.
//
// These rows answer a question the cache cannot. The cache holds the *latest*
// answer for an identifier and expires it as soon as it stops being
// trustworthy; a transaction-detail screen has to show the answer that was on
// screen **when the user decided**, months later, and it must not change when
// that account is checked again. Everything here is one of those two
// properties.
//
// NO NETWORK, NO DEVICE — same rules as `test/cache_test.dart`. The clock is
// injected, so the 90-day retention is asserted as precisely as the 1-hour TTL.

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:tracive_sdk/tracive_sdk.dart';

void main() {
  final scammer = TraciveQuery.bankAccount(
    countryAlpha3: 'IDN',
    bankCode: 'BCA',
    account: '7710442951',
  );
  const firstTransfer = 'TRF26090814320771';
  const secondTransfer = 'TRF26090910160442';
  final start = DateTime.utc(2026, 9, 8, 14, 31);

  group('record key', () {
    test('is the prefixed SHA-256 of the trimmed id', () {
      final expected = sha256.convert(utf8.encode(firstTransfer)).toString();
      expect(transactionRecordKeyFor(' $firstTransfer '), 'txn:$expected');
      // ':' is not a hex digit, which is what keeps the two key spaces in one
      // table disjoint.
      expect(transactionRecordKeyFor(firstTransfer),
          isNot(matches(RegExp(r'^[0-9a-f]{64}$'))));
    });

    test('never contains the reference it was derived from', () {
      expect(transactionRecordKeyFor(firstTransfer),
          isNot(contains(firstTransfer)));
    });

    test('rejects a blank id rather than sharing one row', () {
      expect(() => transactionRecordKeyFor('   '), throwsArgumentError);
      expect(() => transactionRecordKeyFor(''), throwsArgumentError);
    });
  });

  group('outliving the cache entry', () {
    test('a record survives the entry it was taken from', () async {
      // The failure this exists to prevent: a NONE answer is cached for an
      // hour, so by the next morning the transaction detail would have no card
      // at all — for a transfer that genuinely was checked.
      final clock = _MutableClock(start);
      final cache = CheckCache.inMemory(clock: clock.call);
      final shown = _result(tier: RiskTier.none, fetchedAt: clock.now);

      await cache.write(scammer, shown);
      await cache.writeTransactionCheck(firstTransfer, shown);

      clock.advance(const Duration(hours: 2));

      expect(await cache.read(scammer), isNull,
          reason: 'a NONE entry lives one hour; this asserts the premise');
      final record = await cache.readTransactionCheck(firstTransfer);
      expect(record, isNotNull);
      expect(record!.riskTier, RiskTier.none);
      expect(record.fetchedAt, start,
          reason: 'the card says when the check happened');
    });

    test('retention ends the record and drops the row', () async {
      final clock = _MutableClock(start);
      final cache = CheckCache.inMemory(clock: clock.call);

      await cache.writeTransactionCheck(
          firstTransfer, _result(tier: RiskTier.high, fetchedAt: clock.now));

      clock.advance(const Duration(days: 90) - const Duration(minutes: 1));
      expect(await cache.readTransactionCheck(firstTransfer), isNotNull);

      clock.advance(const Duration(minutes: 2));
      expect(await cache.readTransactionCheck(firstTransfer), isNull);
      expect(await cache.prune(), 0,
          reason: 'an expired record is deleted as it is found');
    });

    test('a tier TTL of zero does not stop a record being filed', () async {
      // A host that declines to cache HIGH at all must still be able to show
      // what the user was warned about — precisely what a partner needs when
      // the transfer is disputed.
      final clock = _MutableClock(start);
      final cache = CheckCache.inMemory(
        clock: clock.call,
        policy: const CachePolicy(highTtl: Duration.zero),
      );
      final shown = _result(tier: RiskTier.high, fetchedAt: clock.now);

      await cache.write(scammer, shown);
      await cache.writeTransactionCheck(firstTransfer, shown);

      expect(await cache.read(scammer), isNull,
          reason: 'a zero tier TTL stores no cache entry');
      final record = await cache.readTransactionCheck(firstTransfer);
      expect(record!.riskTier, RiskTier.high);
    });

    test('zero retention keeps nothing and drops what is there', () async {
      final clock = _MutableClock(start);
      final store = MemoryCheckCacheStore();
      final keeping = DefaultCheckCache(store: store, clock: clock.call);
      await keeping.writeTransactionCheck(
          firstTransfer, _result(tier: RiskTier.high, fetchedAt: clock.now));
      expect(await keeping.readTransactionCheck(firstTransfer), isNotNull);

      final optedOut = DefaultCheckCache(
        store: store,
        policy: CachePolicy.defaultPolicy
            .copyWith(transactionCheckRetention: Duration.zero),
        clock: clock.call,
      );
      await optedOut.writeTransactionCheck(
          firstTransfer, _result(tier: RiskTier.high, fetchedAt: clock.now));

      expect(await optedOut.readTransactionCheck(firstTransfer), isNull,
          reason: 'turning retention off takes the records already written');
    });
  });

  group('one check, several transactions', () {
    test('both transfers get a card from one billed check', () async {
      final clock = _MutableClock(start);
      final cache = CheckCache.inMemory(clock: clock.call);

      await cache.write(
          scammer, _result(tier: RiskTier.high, fetchedAt: clock.now));
      final shownFirst = await cache.read(scammer);
      await cache.writeTransactionCheck(firstTransfer, shownFirst!);

      clock.advance(const Duration(days: 7));

      final shownAgain = await cache.read(scammer);
      expect(shownAgain, isNotNull,
          reason: 'a HIGH answer is still live after a week');
      await cache.writeTransactionCheck(secondTransfer, shownAgain!);

      final first = await cache.readTransactionCheck(firstTransfer);
      final second = await cache.readTransactionCheck(secondTransfer);
      expect(first!.riskTier, RiskTier.high);
      expect(second!.riskTier, RiskTier.high);
      expect(first.fetchedAt, second.fetchedAt,
          reason: 'both cards report the one check they shared');
      expect(second.origin, Origin.cache,
          reason: 'the second transfer spent no credit, and it has to say so');
    });

    test('a later check leaves an earlier transaction alone', () async {
      // The reason a record is a snapshot rather than a pointer into the cache.
      // The account is clean in September and reported by October; a pointer
      // would rewrite September's card to say the user was warned — an audit
      // trail that blames them for a warning they were never shown.
      final clock = _MutableClock(start);
      final cache = CheckCache.inMemory(clock: clock.call);

      final clean = _result(tier: RiskTier.none, fetchedAt: clock.now);
      await cache.write(scammer, clean);
      await cache.writeTransactionCheck(firstTransfer, clean);

      clock.advance(const Duration(days: 30));

      final reported = _result(tier: RiskTier.high, fetchedAt: clock.now);
      await cache.write(scammer, reported);
      await cache.writeTransactionCheck(secondTransfer, reported);

      final first = await cache.readTransactionCheck(firstTransfer);
      expect(first!.riskTier, RiskTier.none,
          reason: "September's card must still say what it said");
      expect(first.fetchedAt, start);

      final second = await cache.readTransactionCheck(secondTransfer);
      expect(second!.riskTier, RiskTier.high);
    });
  });

  group('what is kept', () {
    test('narratives are dropped but the call\'s own fields survive', () async {
      // The projection differs from the cache's on purpose. `checkId` and
      // `billing` describe the one call this record *is*, so they are what a
      // dispute is reconciled against; the report narratives are other people's
      // prose and have no place in a record that lives 90 days.
      final clock = _MutableClock(start);
      final cache = CheckCache.inMemory(clock: clock.call);

      await cache.writeTransactionCheck(
        firstTransfer,
        _result(
          tier: RiskTier.high,
          fetchedAt: clock.now,
          checkId: 'chk_01J9ZQ',
          full: true,
        ),
      );

      final record = await cache.readTransactionCheck(firstTransfer);
      expect(record!.topChronologies, isNull,
          reason: 'report narratives must not be archived on the device');
      expect(record.comments, isNull, reason: 'nor the comments');
      expect(record.checkId, 'chk_01J9ZQ',
          reason: 'the check id is what a dispute is reconciled by');
      expect(record.billing, isNotNull);
      expect(record.origin, Origin.server,
          reason: 'a live check stays a live check on the record');
    });

    test('the reference never reaches the stored row', () async {
      final clock = _MutableClock(start);
      final store = MemoryCheckCacheStore();
      final cache = DefaultCheckCache(store: store, clock: clock.call);

      await cache.writeTransactionCheck(
          firstTransfer, _result(tier: RiskTier.high, fetchedAt: clock.now));

      final row = await store.read(transactionRecordKeyFor(firstTransfer));
      expect(row, isNotNull);
      expect(row!.cacheKey, isNot(contains(firstTransfer)));
      expect(row.payload, isNot(contains(firstTransfer)));
    });
  });

  group('lifecycle', () {
    test('removing one side leaves the other', () async {
      final clock = _MutableClock(start);
      final cache = CheckCache.inMemory(clock: clock.call);
      final shown = _result(tier: RiskTier.high, fetchedAt: clock.now);

      await cache.write(scammer, shown);
      await cache.writeTransactionCheck(firstTransfer, shown);
      await cache.writeTransactionCheck(secondTransfer, shown);

      // Forcing a fresh check must not wipe the history for the same account.
      expect(await cache.remove(scammer), isTrue);
      expect(await cache.read(scammer), isNull);
      expect(await cache.readTransactionCheck(firstTransfer), isNotNull);

      expect(await cache.removeTransactionCheck(firstTransfer), isTrue);
      expect(await cache.readTransactionCheck(firstTransfer), isNull);
      expect(await cache.readTransactionCheck(secondTransfer), isNotNull,
          reason:
              'records are independent; dropping one must not touch another');
    });

    test('clear takes the records with it', () async {
      final clock = _MutableClock(start);
      final cache = CheckCache.inMemory(clock: clock.call);

      await cache.write(
          scammer, _result(tier: RiskTier.high, fetchedAt: clock.now));
      await cache.writeTransactionCheck(
          firstTransfer, _result(tier: RiskTier.high, fetchedAt: clock.now));
      await cache.clear();

      expect(await cache.readTransactionCheck(firstTransfer), isNull,
          reason: 'clear() is what sign-out calls');
    });

    test('records are evicted last when the cap is reached', () async {
      // Eviction takes the rows closest to expiring, and a record outlives
      // every tier by default. The ordering is the right way round: an evicted
      // answer costs one credit to fetch again, an evicted record cannot be
      // recovered at all.
      final clock = _MutableClock(start);
      final cache = DefaultCheckCache(
        store: MemoryCheckCacheStore(),
        policy: CachePolicy.defaultPolicy.copyWith(maxEntries: 2),
        clock: clock.call,
      );

      await cache.write(
          scammer, _result(tier: RiskTier.none, fetchedAt: clock.now));
      await cache.write(TraciveQuery.phone('+6287777777777'),
          _result(tier: RiskTier.none, fetchedAt: clock.now));
      await cache.writeTransactionCheck(
          firstTransfer, _result(tier: RiskTier.none, fetchedAt: clock.now));

      expect(await cache.prune(), 1, reason: 'one row is over the cap of two');
      expect(await cache.readTransactionCheck(firstTransfer), isNotNull,
          reason: 'the record must be the survivor');
    });
  });

  group('the id as a key', () {
    test('whitespace is folded away but case is not', () async {
      final clock = _MutableClock(start);
      final cache = CheckCache.inMemory(clock: clock.call);

      await cache.writeTransactionCheck(' $firstTransfer ',
          _result(tier: RiskTier.high, fetchedAt: clock.now));

      expect(await cache.readTransactionCheck(firstTransfer), isNotNull,
          reason: 'a trimmed id finds its record');
      expect(
          await cache.readTransactionCheck(firstTransfer.toLowerCase()), isNull,
          reason: "case is not folded: a host's reference format is its own");
    });

    test('every entry point rejects a blank id', () async {
      final cache = CheckCache.inMemory(clock: _MutableClock(start).call);
      final result = _result(tier: RiskTier.high, fetchedAt: start);

      expect(
          () => cache.writeTransactionCheck('  ', result), throwsArgumentError);
      expect(() => cache.readTransactionCheck(''), throwsArgumentError);
      expect(() => cache.removeTransactionCheck('\t'), throwsArgumentError);
    });

    test('a disabled cache keeps nothing but still rejects a blank id',
        () async {
      // Worth pinning because it is the trap: a host that never wires a cache
      // gets a working check path and a transaction-detail card that is always
      // empty, with nothing to say why.
      const cache = CheckCache.disabled();

      await cache.writeTransactionCheck(
          firstTransfer, _result(tier: RiskTier.high, fetchedAt: start));
      expect(await cache.readTransactionCheck(firstTransfer), isNull);
      expect(() => cache.readTransactionCheck(' '), throwsArgumentError);
    });
  });
}

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
      firstReportOn: DateTime.utc(2025, 1, 2, 3, 4, 5),
      lastReportOn: DateTime.utc(2026, 7, 1, 10),
      fraudAmount: const <String, double>{'IDR': 87400000},
      tags: const <String>['investment'],
      relatedScammerCount: 4,
      topChronologies: full
          ? <Chronology>[
              const Chronology(
                chronology: 'Promised 30% monthly returns.',
                riskLevel: 3,
                incidentDate: '2026-06-01',
              ),
            ]
          : null,
      comments: full
          ? <Comment>[
              const Comment(
                date: '2026-06-02',
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

/// A clock the tests move by hand. `clock.call` is the [CacheClock].
class _MutableClock {
  _MutableClock(this.now);

  DateTime now;

  DateTime call() => now;

  void advance(Duration by) => now = now.add(by);
}
