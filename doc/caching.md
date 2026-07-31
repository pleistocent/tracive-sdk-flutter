# Caching

> Contract: the SDK specification §5. This document explains the parts of it that are
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

§5 says "AES-GCM with a random 96-bit nonce per record". That is literally what
the **Swift** SDK does, because it has no SQLCipher and encrypts row by row with
CryptoKit. On Flutter the encryption is SQLCipher's: **AES-256-CBC per page with
a per-page random IV, plus an HMAC-SHA512 per page** for tamper detection. It is
not GCM, and it is per page rather than per record.

The property §5 is buying — *the cache is unreadable without a key held in the
platform keystore* — holds either way, and `sqflite_sqlcipher` is what §5 itself
prescribes for Flutter. This paragraph exists so nobody has to rediscover the
discrepancy from the source.

### Recovery from a key mismatch

If the database file will not open — almost always because a device backup
restored app files without the (deliberately non-backed-up) Keychain entry — the
file is **deleted and rebuilt**. Nothing of value is lost: every row is a copy of
an answer the server can produce again. The alternative is an SDK whose cache
never opens again on that device.

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

### `cacheTtlSeconds` — the invalidation lever

When a response carries `cacheTtlSeconds`, it **overrides** the tier default.
This is the fleet-wide invalidation lever: it is how the backend shortens the
life of answers that are already sitting on devices when a verdict changes.

`cacheTtlSeconds: 0` means *do not cache this*, and it does more than skip the
write — it **deletes whatever row is already there**. Honouring it only for new
writes would leave the stale answer in place, which is the exact situation the
lever exists for.

You can turn the override off with `CachePolicy(honourServerTtl: false)`.
**Leave it on.** Turning it off means a wrong `HIGH` can sit on a device for
thirty days with no way to reach it.

---

## What is never cached

`CheckResult.cacheable()` drops four things on the way in:

| Field | Why it is dropped |
|---|---|
| `topChronologies` | `detail = full` only, and varies with `locale` |
| `comments` | same |
| `billing` | single-use — replaying a charge would misreport spend |
| `checkId` | nothing was checked on a hit, so there is no id |

The cache key is the **query alone**; it mentions neither `detail` nor `locale`.
That is only sound because everything that varies with them is dropped. If a
future version ever caches full-detail content, **the key must first become
`(query, detail, locale)`** — otherwise an Indonesian full-detail answer gets
served to an English minimal-detail caller. The same note is in the code, on
`CheckResult.cacheable()` and on `cacheKeyFor`; all of them have to change
together.

A consequence worth stating: **asking for `detail: Detail.full` does not put
full detail in the cache, and does not read it from there.** A full-detail call
still writes the invariant fields, and a later minimal call can hit on them.

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

## Housekeeping

```dart
await cache.prune();   // delete expired rows, then trim to maxEntries
await cache.clear();   // empty it — do this on sign-out
await cache.close();   // release the file; it reopens on next use
```

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
await client.signOut();   // revoke + clear tokens
await client.cache.clear();
```

The cache holds no identifiers, but it does hold the *answers* to one user's
questions. Clear it when the user leaves.

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
