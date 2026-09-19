// Copyright (c) Tracive. Licensed under the Apache License, Version 2.0.
//
// Retry policy.
//
// The one rule that matters here, quoted:
//
//   "never auto-retry a `checkScammer` on 5xx/timeout without an
//    `Idempotency-Key`; a blind retry risks a double charge."
//
// So retrying is not a property of the *error*, it is a property of the
// *request*. A timeout on `POST /scammer-checks` is indistinguishable from a
// success whose response was lost: the server may already have charged a
// credit. With an `Idempotency-Key` the server can collapse the replay; without
// one, the only safe move is to surface the failure and let the caller decide.
//
// `GET /credits` and `GET /profile` are safe to retry unconditionally — they
// change nothing and cost nothing.

import 'dart:math';

import '../exception.dart';

/// The source of randomness for [RetryPolicy.jitter].
///
/// One per isolate rather than one per policy, because [RetryPolicy] is `const`
/// and a `const` object cannot hold a `Random`. Not `Random.secure()`: this
/// decides how long to sleep, not anything an attacker gains from predicting,
/// and the secure generator is materially slower.
final Random _jitterRandom = Random();

/// When the client may repeat a failed request, and how long it waits first.
///
/// ## The default numbers, and why each one is what it is
///
/// | Parameter | Default | Why |
/// |---|---|---|
/// | [maxAttempts] | `3` | Two retries after the first send. |
/// | [backoffMultiplier] | `2.0` | Binary exponential backoff. |
/// | [initialBackoff] | `500 ms` | Long enough to be a different moment; short enough to go unnoticed. |
/// | [jitter] | `0.2` | Breaks up a synchronised fleet without making the schedule unreadable. |
/// | [maxBackoff] | `8 s` | A ceiling that binds only if a caller raises [maxAttempts]. |
///
/// **The four Tracive SDKs share this set exactly**, and until recently they did
/// not: three different initial backoffs and two jitter ratios, with no reason
/// recorded anywhere for any of them. That is how a value nobody chose survives
/// review in four repositories at once. The paragraphs below are written down as
/// much to stop the next silent divergence as to justify the numbers.
///
/// **None of it is measured.** The numbers were chosen before the API carried
/// any traffic, so there was no p99 to fit a curve to and no observed failure
/// distribution to tune against.
/// These are defensible starting points with their reasoning attached, not tuned
/// constants — and the first real production data should be allowed to move
/// them, in all four SDKs together.
///
/// * **[maxAttempts] `3`** bounds two things at once. Worst-case latency becomes
///   three round trips plus roughly 1.5 s of waiting, on a screen where a user
///   is usually about to send money; and it bounds how many times one logical
///   check can be *sent*, which matters because a check is billed.
///   Deduplication is the server's job and the `Idempotency-Key` is what asks
///   for it, and nobody has measured how the server honours it, so keeping the
///   number of sends small keeps the cost of being wrong about that small too.
/// * **[backoffMultiplier] `2.0`** because each retry should back off
///   meaningfully rather than incrementally, and doubling is the value every
///   reader recognises on sight. There is nothing to discover here; the reason
///   it is written down is that an unexplained `2.0` invites someone to
///   "improve" it to 1.5.
/// * **[initialBackoff] `500 ms`** is the number the four SDKs disagreed
///   hardest about — this one shipped 300 ms. Too short and the retry arrives
///   while the server is still in whatever state produced the 5xx, spending an
///   attempt to learn nothing. Too long and it is visible: half a second is
///   under the threshold at which a user starts suspecting the app has stalled,
///   and two retries at 0.5 s and 1.0 s keep the whole schedule inside that
///   budget.
/// * **[jitter] `0.2`** shaves up to 20% off each computed delay. The failure it
///   prevents is a fleet of banking apps that all saw the same 503 retrying in
///   lockstep and re-creating the stampede. Twenty percent is enough spread to
///   break the synchronisation and small enough that the schedule is still
///   recognisable in a support log — "about half a second, then about a second"
///   — rather than a smear.
/// * **[maxBackoff] `8 s`** never binds at the default [maxAttempts], where the
///   schedule stops at 1.0 s. It exists for the caller who raises
///   [maxAttempts], and it is the point past which a mobile user has already
///   decided the app is broken, so waiting longer buys a result nobody is still
///   waiting for.
class RetryPolicy {
  /// Creates a policy.
  const RetryPolicy({
    this.maxAttempts = 3,
    this.initialBackoff = const Duration(milliseconds: 500),
    this.backoffMultiplier = 2.0,
    this.maxBackoff = const Duration(seconds: 8),
    this.jitter = 0.2,
    this.retryServerErrors = true,
    this.retryNetworkErrors = true,
  })  : assert(maxAttempts >= 1, 'maxAttempts must be at least 1'),
        assert(jitter >= 0 && jitter <= 1, 'jitter must be within 0..1');

  /// Three attempts, 500 ms then 1 s, capped at 8 s, 20% jitter. The default.
  ///
  /// The same five numbers as the Kotlin, Swift and React Native SDKs. Changing
  /// one here without changing it there is the divergence this set was
  /// assembled to end, which is why each value is asserted by name in
  /// `test/client_test.dart` rather than left to be inferred from behaviour.
  static const RetryPolicy defaultPolicy = RetryPolicy();

  /// Never retry anything. Every failure surfaces on the first attempt.
  static const RetryPolicy none = RetryPolicy(maxAttempts: 1);

  /// Total attempts, including the first. `1` disables retrying.
  final int maxAttempts;

  /// Wait before the second attempt.
  final Duration initialBackoff;

  /// Growth factor applied to [initialBackoff] for each further attempt.
  final double backoffMultiplier;

  /// Upper bound on any single wait.
  final Duration maxBackoff;

  /// Fraction of each computed delay that is randomly shaved off, in `0..1`.
  ///
  /// Set it to `0` for a fully deterministic schedule.
  ///
  /// **One-sided on purpose: it only ever shortens a wait, never lengthens
  /// one.** That keeps [maxBackoff] a true ceiling, so the worst case is the
  /// one written on the tin rather than the one written on the tin plus twenty
  /// percent.
  final double jitter;

  /// Whether 5xx responses are retried.
  final bool retryServerErrors;

  /// Whether transport failures (timeout, socket, DNS, TLS) are retried.
  final bool retryNetworkErrors;

  /// How long to wait before attempt number [nextAttempt] (1-based, so the
  /// first retry is `nextAttempt == 2`).
  ///
  /// [random] is a seam for tests that need the schedule to be reproducible
  /// while [jitter] is non-zero. Production passes nothing.
  Duration backoffFor(int nextAttempt, {Random? random}) {
    if (nextAttempt <= 1) return Duration.zero;
    var micros = initialBackoff.inMicroseconds.toDouble();
    for (var i = 2; i < nextAttempt; i++) {
      micros *= backoffMultiplier;
    }
    var capped = micros.clamp(0, maxBackoff.inMicroseconds.toDouble());
    if (jitter > 0 && capped > 0) {
      // Applied after the cap, not before, so the shave is taken off the value
      // the caller was actually going to wait.
      capped *= 1 - (random ?? _jitterRandom).nextDouble() * jitter;
    }
    return Duration(microseconds: capped.round());
  }

  /// Whether the client may repeat a request that failed with [error].
  ///
  /// [safeToRepeat] is the caller's promise that repeating cannot double-charge
  /// — a GET, or a POST carrying an `Idempotency-Key`. When it is `false` this
  /// method returns `false` for every error, no matter how transient: the
  /// contract puts
  /// the money risk above the availability win.
  ///
  /// [attemptsSoFar] counts attempts already made, including the failed one.
  ///
  /// 429 is deliberately **not** retried automatically. The server has said
  /// how long to wait (`Retry-After`, carried on
  /// [TraciveRateLimitedException.retryAfter]); burning the SDK's retry budget
  /// inside a few hundred milliseconds only deepens the hole, and the caller
  /// is the only party that knows whether waiting is acceptable on its screen.
  bool shouldRetry(
    TraciveException error, {
    required bool safeToRepeat,
    required int attemptsSoFar,
  }) {
    if (!safeToRepeat) return false;
    if (attemptsSoFar >= maxAttempts) return false;
    if (error is TraciveNetworkException) return retryNetworkErrors;
    if (error is TraciveServerException) return retryServerErrors;
    return false;
  }

  /// Copy with replacements.
  RetryPolicy copyWith({
    int? maxAttempts,
    Duration? initialBackoff,
    double? backoffMultiplier,
    Duration? maxBackoff,
    double? jitter,
    bool? retryServerErrors,
    bool? retryNetworkErrors,
  }) =>
      RetryPolicy(
        maxAttempts: maxAttempts ?? this.maxAttempts,
        initialBackoff: initialBackoff ?? this.initialBackoff,
        backoffMultiplier: backoffMultiplier ?? this.backoffMultiplier,
        maxBackoff: maxBackoff ?? this.maxBackoff,
        jitter: jitter ?? this.jitter,
        retryServerErrors: retryServerErrors ?? this.retryServerErrors,
        retryNetworkErrors: retryNetworkErrors ?? this.retryNetworkErrors,
      );

  @override
  String toString() => 'RetryPolicy(maxAttempts: $maxAttempts, '
      'initialBackoff: $initialBackoff, multiplier: $backoffMultiplier, '
      'maxBackoff: $maxBackoff, jitter: $jitter)';
}
