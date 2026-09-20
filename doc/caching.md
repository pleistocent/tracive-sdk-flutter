# Caching

> This document explains the parts of the caching contract that are
> decisions rather than rules, and records what is *not* covered by the unit
> suite.

The cache exists for one reason: **a check costs a credit, and a miss is billed
too.** Everything below follows from that.

---

## What a hit costs

A cache hit costs **zero credits and does no network I/O at all**. It is
returned with `origin == Origin.cache` and `checkId == null` — nothing was
checked, so nothing was assigned an id.

`fetchedAt` on a hit is the instant the **server** produced the answer, not the
instant you read it. That is deliberate: it is what TTL is measured from, and it
is what you should show a user if you display the age of a verdict.

```dart
final result = await client.checkScammer(query);
if (result.isFromCache) {
  showAgeBadge(DateTime.now().toUtc().difference(result.fetchedAt));
}
```

---

## Where the rows live

| Piece | Implementation |
|---|---|
| Storage | `sqflite_sqlcipher` — SQLCipher, encrypted at rest |
| Encryption key | Android Keystore / iOS Keychain, via `flutter_secure_storage` |
| Row key | `SHA-256(searchQueryIndex)`, lowercase hex |
| Payload | `CheckResult.cacheable()`, JSON |

One call opens it:

```dart
final cache = await openTraciveCache();
final client = TraciveClient(mode: mode, cache: cache);
```

`openTraciveCache()` **never throws.** A cache is an optimisation; an app must
not fail to start because a database file is locked or a Keystore entry is
unreadable. When the open fails, every read simply misses and the error is left
in `cache.lastStoreError`. **Watch that value in your telemetry** — a cache that
has quietly stopped working does not break anything, it just means every check
from that device now costs a credit.

If you pass no `cache:`, the client builds `CheckCache.inMemory()`. That is a
real cache with the same rules; it just does not survive a restart. A
constructor must not silently open a database file and a Keystore entry, so the
persistent one is opt-in.

### At-rest encryption, stated honestly

The contract asks for "AES-GCM with a random 96-bit nonce per record". That is literally what
the **Swift** SDK does, because it has no SQLCipher and encrypts row by row with
CryptoKit. On Flutter the encryption is SQLCipher's: **AES-256-CBC per page with
a per-page random IV, plus an HMAC-SHA512 per page** for tamper detection. It is
not GCM, and it is per page rather than per record.

The property being bought — *the cache is unreadable without a key held in the
platform keystore* — holds either way, and `sqflite_sqlcipher` is what the contract
prescribes for Flutter. This paragraph exists so nobody has to rediscover the
discrepancy from the source.

### Recovery from a key mismatch

If the database file will not open — almost always because a device backup
restored app files without the (deliberately non-backed-up) Keychain entry — the
file is **deleted and rebuilt**. Every cache entry is a copy of an answer the
server can produce again, so that much costs only credits; any transaction
records in the file go too, and those cannot be re-fetched — see
[Recording what a transaction was shown](#recording-what-a-transaction-was-shown)
for why that is survivable. The alternative is an SDK whose cache never opens
again on that device.

The Keychain entry is written with `first_unlock_this_device`: readable after
the first unlock following a boot, never synced to iCloud, never included in a
backup. A cache key that follows a user's iCloud account around is a worse
problem than a cold cache.

---

## TTL

Default, by tier:

| `riskTier` | TTL | Why |
|---|---|---|
| `HIGH` | 30 days | A `HIGH` verdict rarely reverses |
| `ELEVATED` | 7 days | |
| `CAUTION` | 24 hours | |
| `NONE` | 1 hour | The answer most likely to change tomorrow |

Override them if you have a reason:

```dart
final cache = await openTraciveCache(
  policy: const CachePolicy(noneTtl: Duration(minutes: 15)),
);
```

Three properties of the implementation are worth knowing:

- **TTL is measured from `fetchedAt`, not from the write.** A result that was
  already fifty minutes old when it was stored expires ten minutes later, not
  an hour later.
- **The live policy decides, not the stamp written at write time.** The
  `expires_at` column is a *prune hint*; freshness is re-derived on every read
  from the `CachePolicy` currently in force. So shipping a build with a shorter
  TTL takes effect on rows that are already on the device, instead of waiting
  them out.
- **Expiry is lazy, on read.** A stale row is deleted as it is found, which
  keeps a device that checks the same handful of numbers from accumulating dead
  rows between prune passes.

### The tier ladder is the whole policy

`policy.defaultTtlFor(tier)` is the lifetime, and nothing in a response can
change it. The backend used to be able to send a `cacheTtlSeconds` that replaced
the tier default; that duplicated the ladder above on the server, so it is gone.
A `cacheTtlSeconds` still arriving from a proxy is an unknown JSON key and is
ignored, not an error.

A tier TTL of `Duration.zero` means *do not cache this tier*, and it does more
than skip the write — it **deletes whatever row is already there**. Honouring it
only for new writes would leave a superseded answer in place to be served for
the rest of its old lifetime.

---

## What is never cached

`CheckResult.cacheable()` drops four things on the way in:

| Field | Why it is dropped |
|---|---|
| `topChronologies` | `detail = full` only, and varies with `locale` |
| `comments` | same |
| `billing` | single-use — replaying a charge would misreport spend |
| `checkId` | nothing was checked on a hit, so there is no id |

`disclaimer` and `tags` are **kept**, and they do vary with `locale` — so the
table above is not the whole rule.

The cache key is the **query alone**; it mentions neither `detail` nor `locale`.
That is sound only because of a second rule, enforced in `TraciveClient`:
**a `detail: Detail.full` call neither writes to the cache nor reads from it.**
A minimal request carries no `locale` at all, so every cached row holds the one
language the server returns when it is not told which to use.

Both directions matter. Writing a full-detail answer would put an Indonesian
`disclaimer` under a key an English minimal caller reads — in the one string
this SDK asks every integrator to put on screen. Reading one would answer a
caller who asked for chronologies and comments with a row that has neither, and
say nothing about it.

If a future version ever wants to cache full-detail or localized content,
**the key must first become `(query, detail, locale)`**. The same note is in
the code, on `CheckResult.cacheable()` and on `cacheKeyFor`; all of them have to
change together.

---

## Privacy

Three rules hold everywhere in `lib/src/cache/`:

1. **The raw identifier is never stored.** The row key is
   `SHA-256(searchQueryIndex)`. There is no column for the query, and
   `StoredCheck` has no field for it — a storage layer cannot leak a phone
   number it was never given.
2. **Nothing full-detail is written.** See the table above.
3. **Nothing logs.** No `print`, no `debugPrint`, no analytics hook.
   `StoredCheck.toString()` truncates the key, because a full hash is a stable
   identifier for "someone checked this thing".

Hashing is **not** encryption. An attacker holding the database file and a list
of candidate phone numbers can confirm a guess by hashing each one. That is why
the database is *also* encrypted at rest. What hashing buys is that a database
read on its own does not enumerate who the user checked.

---

## Recording what a transaction was shown

`read(query)` answers "what does Tracive say about this account **now**". A transaction-detail screen
asks something else: "what was this user shown **before they sent the money**". Those two answers
diverge, and the cache cannot give you the second one — it holds the latest answer per identifier and
expires it as soon as it stops being trustworthy, so by the next morning a `RiskTier.none` result is
gone and the card on yesterday's transfer would be blank.

So record it against your own transaction id:

```dart
// 1. On the confirmation screen, before the PIN.
final result = await client.checkScammer(query);
showCheckResult(result);                       // tier, counts, and result.disclaimer

// 2. Once the transfer exists and has a reference number.
await client.cache.writeTransactionCheck('TRF26090814320771', result);

// 3. Weeks later, on the transaction detail.
final shown = await client.cache.readTransactionCheck('TRF26090814320771');
if (shown != null) renderSecurityCheckCard(shown);   // never "no reports" when it is null
```

It is a separate call rather than a parameter on `checkScammer` because of the order those two things
happen in: the check runs on the confirmation screen, and the reference number is minted after the
PIN. There is no transaction id to pass when the check is made.

**Each record is a snapshot, not a pointer into the cache.** That is the whole design decision, and
it is what makes the card truthful. A user transfers to the same account in September, when it is
clean, and again in October, after it has been reported. A pointer would rewrite September's card to
show October's verdict — an audit trail saying the user was warned before a transfer where they were
shown nothing of the kind. Two records, two answers, neither one editing the other.

**One check can serve several transactions.** The second transfer to an account you already checked
is a cache hit: no request, no credit, and `writeTransactionCheck` called a second time with that
transfer's id. Both details get a card, and the second one's `origin` is `Origin.cache`, which is how
your UI knows that transfer spent nothing.

| | `write` / `read` | `writeTransactionCheck` / `readTransactionCheck` |
|---|---|---|
| Keyed on | the identifier | your transaction id, hashed, under a `txn:` prefix |
| Lifetime | tier TTL, 1 hour to 30 days | `transactionCheckRetention`, 90 days by default |
| Overwritten by a later check | yes | no |
| `origin` on read | restamped `Origin.cache` | kept as recorded |
| `checkId`, `billing` | dropped | kept — this record *is* that one call |
| `topChronologies`, `comments` | dropped | dropped |

Both kinds of row live in the one table. A cache key is 64 hex digits and `:` is not a hex digit, so
a `txn:`-prefixed key cannot collide with one — which is what lets them share a table without a
`kind` column. Such a column would sort a stolen database into "answers held" and "transfers made"
before anyone had to decrypt it.

Four things to know before you build a screen on it:

- **`null` means "no check is on file", never "nothing was found".** A transfer where the user chose
  to skip the check has no record, and rendering that as a clean result invents a reassurance nobody
  gave. Show nothing.
- **The id is hashed, and it is matched verbatim** apart from a trim. `TRF-1` and `trf-1` are two
  records; normalise your own reference before it gets here if its case can vary. A blank id is an
  `ArgumentError` rather than a shared row that would hand a transaction someone else's verdict.
- **`clear()` takes the records with it**, so a Tracive sign-out empties the cards on transactions
  that are still in your history. That follows from whose data it is: the verdict was read under a
  grant that no longer exists.
- **Records are counted by `maxEntries`** and, with the defaults, evicted last: eviction drops
  whatever is closest to expiry, and 90 days outlives every tier TTL. That ordering is a consequence
  of the numbers, not a rule — raise a tier TTL above `transactionCheckRetention`, or lower the
  retention below one, and records start going first. If you record more transactions than
  `maxEntries`, raise it: an evicted cache entry costs a credit to replace and an evicted record
  cannot be replaced at all.

And the reason this lives in the SDK rather than in your backend: the partner terms forbid uploading
Tracive results, derived values included — a risk tier and a report count are as much our database as
the rows behind them. Local storage on the user's own device is the permitted place for them, which
is exactly what these rows are. What may go to your server is the user's *decision*: `riskAccepted`,
`riskAcceptedAt`. That is the audit trail you can defend, and it contains no result at all.

## Housekeeping

```dart
await cache.prune();   // delete expired rows, then trim to maxEntries
await cache.clear();   // empty it — do this on sign-out
await cache.close();   // terminal — release the file and stop using this cache
```

`close()` is one-way. A closed cache stays closed: `read` and `write` degrade to
misses, and `remove`, `clear` and `prune` throw. It used to reopen on the next
use, which reads as convenient and is a race. Build a new `CheckCache` if you
need one again.

`prune()` runs automatically as part of `open()`, so a cold start pays for
whatever expired while the app was closed. Eviction past `CachePolicy.maxEntries`
(default 5000) drops the rows **closest to expiry first**: they have the least
value left, and in practice that means a one-hour `NONE` goes long before a
thirty-day `HIGH` — which is also the more valuable one to keep, since a `HIGH`
is what a user looks at twice.

`client.close()` deliberately does **not** close the cache: a cache can be
shared between clients and is often owned by the host app. Close the one you
opened.

### Sign-out

```dart
await client.signOut();   // revoke, clear tokens, then empty the cache
```

`signOut()` empties the cache itself. The cache holds no identifiers, but it
does hold the *answers* to one user's questions, and the next user of the device
must not inherit them. `client.clearCache()` does the same on its own, for a
user who stays signed in.

---

## Schema version

`checkCacheSchemaVersion` (in `lib/src/cache/sql_check_cache_store.dart`) is
written to SQLite's `PRAGMA user_version`. On open, a file whose recorded
version is not the current one has its table **dropped and rebuilt** — that is
the SDK's only way to invalidate a fleet's worth of caches from inside a release.

**Bump it** on any change to the table, to the payload's shape, or to the
meaning of a stored field. It costs one credit per identifier afterwards, so
bump it when the alternative is serving a wrong answer, not for a cosmetic
change.

A pragma that cannot be read is treated as a mismatch, which rebuilds the table.
That is the safe direction.

**Transaction records go with the table, and that half is not disposable.** The
rebuild drops every row, and by design there is no column that could tell the
two kinds apart, so a bump empties the check card on every transaction in the
user's history as well. A cache entry that goes costs one credit; a record that
goes cannot be recovered at all. So bump only when the alternative is a wrong
answer, and do not build a flow that *depends* on a record still being there —
the card is something a transaction detail shows when it can, not the audit
trail. The audit trail is the `riskAccepted` / `riskAcceptedAt` pair on your own
server.

---

## Testing

`test/cache_test.dart` runs the whole of the cache's decision-making — key
derivation, TTL per tier, the server override, the full-detail rule, lazy
expiry, prune, eviction order, schema-version invalidation, and the SQL
statements themselves — **with no device, no database binary and no network**.
The clock is injected, so a thirty-day TTL is tested in microseconds.

That is possible because `lib/src/cache/` is split in two:

| File | Depends on | Tested by |
|---|---|---|
| `check_cache.dart`, `check_cache_store.dart`, `sql_check_cache_store.dart`, `cache_database.dart`, `cache_secret_store.dart` | `dart:*` and `package:crypto` only | `dart test` / `flutter test` |
| `tracive_cache.dart` | `sqflite_sqlcipher`, `flutter_secure_storage`, `path` | on-device integration testing |

**What the unit suite does not prove**, so nobody mistakes green for complete:

- That the SQL in `SqlCheckCacheStore` is valid SQLite. The fake database in the
  test matches statements against the store's own constants; it is not an
  engine. Run them against a real database on a device.
- That SQLCipher actually encrypts the file with the key from the keystore.
- That `flutter_secure_storage` round-trips on a given OEM's Android build.
  (It is not exotic for a device's `EncryptedSharedPreferences` to become
  undecryptable after a backup/restore. The SDK treats an unreadable secret
  store as an empty one and rebuilds — that path is worth exercising too.)

To cover the bottom half, run the example app on a device or emulator and:

1. Check a number, kill the app, reopen it, check the same number — the second
   result must show `origin: cache`.
2. Pull `/data/data/<your.package>/databases/tracive_check_cache.db` off an
   emulator and open it with plain `sqlite3`. **It must refuse to open**; if
   `sqlite3` reads it, the encryption is not on.
3. `grep` the same file for a phone number you checked. There must be no match —
   the row key is a hash and the payload holds no identifier.
