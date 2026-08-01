// Copyright (c) Tracive. Licensed under the Apache License, Version 2.0.

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
  }) =>
      CachePolicy(
        enabled: enabled ?? this.enabled,
        highTtl: highTtl ?? this.highTtl,
        elevatedTtl: elevatedTtl ?? this.elevatedTtl,
        cautionTtl: cautionTtl ?? this.cautionTtl,
        noneTtl: noneTtl ?? this.noneTtl,
        honourServerTtl: honourServerTtl ?? this.honourServerTtl,
        maxEntries: maxEntries ?? this.maxEntries,
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
          other.maxEntries == maxEntries;

  @override
  int get hashCode => Object.hash(
        enabled,
        highTtl,
        elevatedTtl,
        cautionTtl,
        noneTtl,
        honourServerTtl,
        maxEntries,
      );

  @override
  String toString() => 'CachePolicy(enabled: $enabled, high: $highTtl, '
      'elevated: $elevatedTtl, caution: $cautionTtl, none: $noneTtl, '
      'honourServerTtl: $honourServerTtl, maxEntries: $maxEntries)';
}
