// Copyright (c) Tracive. Licensed under the Apache License, Version 2.0.

import 'json.dart';

/// Answer of `GET /profile`.
///
/// PRIVACY: this is personal data about the authenticated Tracive user. Do not
/// log it; [toString] deliberately omits [name].
class ProfileInfo {
  /// Creates a profile snapshot.
  const ProfileInfo({
    required this.sub,
    this.name,
    this.country,
    this.tier,
    this.memberSince,
  });

  /// Decodes the `/profile` body. Unknown fields are ignored.
  factory ProfileInfo.fromJson(Map<String, Object?> json) => ProfileInfo(
        sub: asStringOr(json['sub'], ''),
        name: asString(json['name']),
        country: asString(json['country']),
        tier: asString(json['tier']),
        memberSince: asUtcDateTime(json['memberSince']),
      );

  /// OIDC subject — the stable user identifier inside the access token.
  final String sub;

  /// Display name, when the grant includes the scope for it.
  final String? name;

  /// Country, as the server spells it.
  final String? country;

  /// Subscription tier name.
  final String? tier;

  /// When the account was created, in UTC.
  final DateTime? memberSince;

  /// Wire form.
  Map<String, Object?> toJson() => <String, Object?>{
        'sub': sub,
        if (name != null) 'name': name,
        if (country != null) 'country': country,
        if (tier != null) 'tier': tier,
        if (memberSince != null) 'memberSince': toIso8601Utc(memberSince),
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ProfileInfo &&
          other.sub == sub &&
          other.name == name &&
          other.country == country &&
          other.tier == tier &&
          other.memberSince == memberSince;

  @override
  int get hashCode => Object.hash(sub, name, country, tier, memberSince);

  /// [name] is omitted on purpose — it is personal data.
  @override
  String toString() => 'ProfileInfo(sub: $sub, country: $country, tier: $tier, '
      'memberSince: $memberSince, name: ${name == null ? 'null' : 'redacted'})';
}
