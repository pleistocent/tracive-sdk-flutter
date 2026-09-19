// Copyright 2026 PT Pleistocent Teknologi Nusantara.
// Licensed under the Apache License, Version 2.0.
//
// The time seam: `clock: Clock? = null`, a test seam for TTL tests.
//
// Naming: the cross-SDK contract writes the type as `Clock`. This SDK spells it
// `TraciveClock` for the same reason the error surface spells `Server` as
// `TraciveServerException` — a package must not squat on a bare, extremely
// common identifier, and `Clock` collides with `package:clock` and with the
// `Clock` a great many host apps already own. The *constructor parameter* is
// still spelled `clock:`, so call sites read identically to Kotlin and Swift.

/// Supplies "now" to the parts of the SDK that measure age: cache freshness
/// and access-token expiry.
///
/// Every implementation must return a **UTC** instant. Everything downstream
/// compares against `fetchedAt` and `expiresAt`, which are UTC by construction;
/// a local-time clock would silently shift every TTL by the device's offset.
abstract class TraciveClock {
  /// Allows `const` implementations.
  const TraciveClock();

  /// The wall clock, in UTC.
  static const TraciveClock system = SystemClock();

  /// The current instant, in UTC.
  DateTime now();
}

/// The real clock. The default everywhere.
class SystemClock extends TraciveClock {
  /// Creates the system clock.
  const SystemClock();

  @override
  DateTime now() => DateTime.now().toUtc();

  @override
  String toString() => 'SystemClock()';
}

/// A clock that only moves when you move it — for tests.
///
/// TTL behaviour is otherwise untestable without sleeping for 30 days, and a
/// test that sleeps is a test nobody runs.
class MutableClock extends TraciveClock {
  /// Creates a clock reading [instant] (coerced to UTC).
  MutableClock(DateTime instant) : _now = instant.toUtc();

  DateTime _now;

  @override
  DateTime now() => _now;

  /// Moves the clock forward (or back, for a negative [amount]).
  void advance(Duration amount) => _now = _now.add(amount);

  /// Jumps the clock to [instant].
  void setTo(DateTime instant) => _now = instant.toUtc();

  @override
  String toString() => 'MutableClock($_now)';
}
