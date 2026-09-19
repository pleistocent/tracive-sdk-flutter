// Copyright 2026 PT Pleistocent Teknologi Nusantara.
// Licensed under the Apache License, Version 2.0.

import 'check_result.dart';
import 'risk_tier.dart';

/// How long a cached result stays usable.
///
/// The defaults follow how fast each tier's underlying data actually moves: a
/// `HIGH` verdict rarely reverses, so it is held for 30 days, while `NONE` is
/// the answer most likely to change tomorrow and is held for an hour.
///
/// Named `defaultPolicy` rather than `default` (which the contract writes as
/// `CachePolicy.default`) because `default` is a reserved word in Dart.
class CachePolicy {
  /// Creates a policy. Every argument defaults to the contract value.
  const CachePolicy({
    this.enabled = true,
    this.highTtl = const Duration(days: 30),
    this.elevatedTtl = const Duration(days: 7),
    this.cautionTtl = const Duration(hours: 24),
    this.noneTtl = const Duration(hours: 1),
    this.honourServerTtl = true,
    this.maxEntries = 5000,
    this.transactionCheckRetention = const Duration(days: 90),
  });

  /// The contract defaults.
  static const CachePolicy defaultPolicy = CachePolicy();

  /// Never read or write the cache. Every check then costs a credit — use it
  /// only when a caller genuinely needs live data every time.
  static const CachePolicy disabled = CachePolicy(enabled: false);

  /// Whether the cache is used at all.
  final bool enabled;

  /// TTL for [RiskTier.high]. Default 30 days.
  final Duration highTtl;

  /// TTL for [RiskTier.elevated]. Default 7 days.
  final Duration elevatedTtl;

  /// TTL for [RiskTier.caution]. Default 24 hours.
  final Duration cautionTtl;

  /// TTL for [RiskTier.none]. Default 1 hour.
  final Duration noneTtl;

  /// Whether `cacheTtlSeconds` from a response overrides the tier default.
  ///
  /// Leave this on. It is the fleet-wide invalidation lever: it is how the
  /// backend shortens the life of already-stored answers when a verdict
  /// changes. Turning it off means a wrong `HIGH` can sit on a device for
  /// 30 days.
  final bool honourServerTtl;

  /// Soft cap on stored entries, enforced by the prune pass on open.
  final int maxEntries;

  /// How long a transaction record — the answer that was shown for one of your
  /// transactions — is kept. Zero or less stores none at all.
  ///
  /// A separate knob from the TTLs above because it answers a different
  /// question. A TTL asks "is this verdict still worth trusting?", and an hour
  /// is right for a clean one. A retention asks "can the user still see what
  /// they were told before they sent the money?", and that does not decay: the
  /// record is a fact about the past, so the only thing that should end it is
  /// the host's own data-minimisation policy.
  ///
  /// 90 days matches how far back a transaction list is usually browsed. Raise
  /// it if your history screen goes back further — and raise [maxEntries] with
  /// it, since records are counted by the same cap as cache entries.
  ///
  /// [honourServerTtl] does not apply to these. `cacheTtlSeconds` retracts a
  /// verdict the backend no longer stands behind, which is the wrong lever for
  /// a record of what a user was already shown.
  final Duration transactionCheckRetention;

  /// The tier default, ignoring any server override.
  Duration defaultTtlFor(RiskTier tier) => switch (tier) {
        RiskTier.high => highTtl,
        RiskTier.elevated => elevatedTtl,
        RiskTier.caution => cautionTtl,
        RiskTier.none => noneTtl,
      };

  /// The TTL that actually applies to [result]: the server's
  /// `cacheTtlSeconds` when present and [honourServerTtl] is set, otherwise
  /// the tier default.
  ///
  /// A non-positive server TTL means "do not cache this" and yields
  /// [Duration.zero].
  Duration ttlFor(CheckResult result) {
    if (honourServerTtl) {
      final serverTtl = result.serverTtl;
      if (serverTtl != null) {
        return serverTtl.isNegative ? Duration.zero : serverTtl;
      }
    }
    return defaultTtlFor(result.riskTier);
  }

  /// When [result] stops being usable, given when it was fetched.
  DateTime expiryFor(CheckResult result) =>
      result.fetchedAt.toUtc().add(ttlFor(result));

  /// Whether [result] is still usable at [now] (UTC).
  ///
  /// A zero TTL is always stale, including at the exact instant of the fetch —
  /// that is what "do not cache this" has to mean.
  bool isFresh(CheckResult result, DateTime now) {
    if (!enabled) return false;
    final ttl = ttlFor(result);
    if (ttl <= Duration.zero) return false;
    return now.toUtc().isBefore(expiryFor(result));
  }

  /// Copy with replacements.
  CachePolicy copyWith({
    bool? enabled,
    Duration? highTtl,
    Duration? elevatedTtl,
    Duration? cautionTtl,
    Duration? noneTtl,
    bool? honourServerTtl,
    int? maxEntries,
    Duration? transactionCheckRetention,
  }) =>
      CachePolicy(
        enabled: enabled ?? this.enabled,
        highTtl: highTtl ?? this.highTtl,
        elevatedTtl: elevatedTtl ?? this.elevatedTtl,
        cautionTtl: cautionTtl ?? this.cautionTtl,
        noneTtl: noneTtl ?? this.noneTtl,
        honourServerTtl: honourServerTtl ?? this.honourServerTtl,
        maxEntries: maxEntries ?? this.maxEntries,
        transactionCheckRetention:
            transactionCheckRetention ?? this.transactionCheckRetention,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CachePolicy &&
          other.enabled == enabled &&
          other.highTtl == highTtl &&
          other.elevatedTtl == elevatedTtl &&
          other.cautionTtl == cautionTtl &&
          other.noneTtl == noneTtl &&
          other.honourServerTtl == honourServerTtl &&
          other.maxEntries == maxEntries &&
          other.transactionCheckRetention == transactionCheckRetention;

  @override
  int get hashCode => Object.hash(
        enabled,
        highTtl,
        elevatedTtl,
        cautionTtl,
        noneTtl,
        honourServerTtl,
        maxEntries,
        transactionCheckRetention,
      );

  @override
  String toString() => 'CachePolicy(enabled: $enabled, high: $highTtl, '
      'elevated: $elevatedTtl, caution: $cautionTtl, none: $noneTtl, '
      'honourServerTtl: $honourServerTtl, maxEntries: $maxEntries, '
      'transactionCheckRetention: $transactionCheckRetention)';
}
