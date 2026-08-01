// Copyright (c) Tracive. Licensed under the Apache License, Version 2.0.

import 'json.dart';

/// What a check cost.
///
/// Present only on a server-answered result: a cache hit costs nothing, so
/// `CheckResult.billing` is `null` there. Never cached — a replayed
/// billing record would misreport spend.
class Billing {
  /// Creates a billing record.
  const Billing({
    required this.creditSource,
    required this.unitsCharged,
    this.partnerBalanceRemaining,
  });

  /// Decodes a billing object. Unknown fields are ignored.
  factory Billing.fromJson(Map<String, Object?> json) => Billing(
        creditSource: asStringOr(json['creditSource'], userCreditSource),
        unitsCharged: asInt(json['unitsCharged']),
        partnerBalanceRemaining: asIntOrNull(json['partnerBalanceRemaining']),
      );

  /// The only credit source phase 1 sends or expects.
  static const String userCreditSource = 'USER';

  /// Which balance paid. phase 1 always sends `USER`; kept as a `String`
  /// so a phase 2 source does not have to be a breaking change.
  final String creditSource;

  /// Credits consumed by this call. `0` is legitimate (a free-tier or
  /// promotional check).
  final int unitsCharged;

  /// Partner balance left afterwards, when the server reports one.
  final int? partnerBalanceRemaining;

  /// Wire form.
  Map<String, Object?> toJson() => <String, Object?>{
        'creditSource': creditSource,
        'unitsCharged': unitsCharged,
        if (partnerBalanceRemaining != null)
          'partnerBalanceRemaining': partnerBalanceRemaining,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Billing &&
          other.creditSource == creditSource &&
          other.unitsCharged == unitsCharged &&
          other.partnerBalanceRemaining == partnerBalanceRemaining;

  @override
  int get hashCode =>
      Object.hash(creditSource, unitsCharged, partnerBalanceRemaining);

  @override
  String toString() => 'Billing(creditSource: $creditSource, '
      'unitsCharged: $unitsCharged, '
      'partnerBalanceRemaining: $partnerBalanceRemaining)';
}
