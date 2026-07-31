// Copyright (c) Tracive. Licensed under the Apache License, Version 2.0.

import 'json.dart';

/// Answer of `GET /credits` — the SDK specification §4.
///
/// §3.3, and the README must repeat it: **do not call `credits()` before every
/// check.** Handle the 402 (`TraciveInsufficientCreditsException`) instead —
/// that saves one round trip per transaction.
class CreditsInfo {
  /// Creates a credits snapshot.
  const CreditsInfo({
    required this.subscriptionCredits,
    required this.tier,
    this.nextResetAt,
  });

  /// Decodes the `/credits` body. Unknown fields are ignored.
  factory CreditsInfo.fromJson(Map<String, Object?> json) => CreditsInfo(
        subscriptionCredits: asInt(json['subscriptionCredits']),
        tier: asStringOr(json['tier'], ''),
        nextResetAt: asUtcDateTime(json['nextResetAt']),
      );

  /// Credits left in the current subscription window.
  final int subscriptionCredits;

  /// Subscription tier name, as the server spells it.
  final String tier;

  /// When the allowance next resets, in UTC.
  final DateTime? nextResetAt;

  /// Wire form.
  Map<String, Object?> toJson() => <String, Object?>{
        'subscriptionCredits': subscriptionCredits,
        'tier': tier,
        if (nextResetAt != null) 'nextResetAt': toIso8601Utc(nextResetAt),
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CreditsInfo &&
          other.subscriptionCredits == subscriptionCredits &&
          other.tier == tier &&
          other.nextResetAt == nextResetAt;

  @override
  int get hashCode => Object.hash(subscriptionCredits, tier, nextResetAt);

  @override
  String toString() => 'CreditsInfo(subscriptionCredits: $subscriptionCredits, '
      'tier: $tier, nextResetAt: $nextResetAt)';
}
