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

import '../exception.dart';

/// When the client may repeat a failed request, and how long it waits first.
class RetryPolicy {
  /// Creates a policy.
  const RetryPolicy({
    this.maxAttempts = 3,
    this.initialBackoff = const Duration(milliseconds: 300),
    this.backoffMultiplier = 2.0,
    this.maxBackoff = const Duration(seconds: 5),
    this.retryServerErrors = true,
    this.retryNetworkErrors = true,
  }) : assert(maxAttempts >= 1, 'maxAttempts must be at least 1');

  /// Three attempts, exponential backoff from 300 ms. The default.
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

  /// Whether 5xx responses are retried.
  final bool retryServerErrors;

  /// Whether transport failures (timeout, socket, DNS, TLS) are retried.
  final bool retryNetworkErrors;

  /// How long to wait before attempt number [nextAttempt] (1-based, so the
  /// first retry is `nextAttempt == 2`).
  Duration backoffFor(int nextAttempt) {
    if (nextAttempt <= 1) return Duration.zero;
    var micros = initialBackoff.inMicroseconds.toDouble();
    for (var i = 2; i < nextAttempt; i++) {
      micros *= backoffMultiplier;
    }
    final capped = micros.clamp(0, maxBackoff.inMicroseconds.toDouble());
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
    bool? retryServerErrors,
    bool? retryNetworkErrors,
  }) =>
      RetryPolicy(
        maxAttempts: maxAttempts ?? this.maxAttempts,
        initialBackoff: initialBackoff ?? this.initialBackoff,
        backoffMultiplier: backoffMultiplier ?? this.backoffMultiplier,
        maxBackoff: maxBackoff ?? this.maxBackoff,
        retryServerErrors: retryServerErrors ?? this.retryServerErrors,
        retryNetworkErrors: retryNetworkErrors ?? this.retryNetworkErrors,
      );

  @override
  String toString() => 'RetryPolicy(maxAttempts: $maxAttempts, '
      'initialBackoff: $initialBackoff, multiplier: $backoffMultiplier, '
      'maxBackoff: $maxBackoff)';
}
