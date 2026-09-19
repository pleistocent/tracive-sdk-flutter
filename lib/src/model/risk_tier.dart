// Copyright 2026 PT Pleistocent Teknologi Nusantara.
// Licensed under the Apache License, Version 2.0.

/// How dangerous the checked identifier looks.
///
/// Wire values are `UPPER_SNAKE`; Dart identifiers are lowerCamelCase.
/// The set is frozen at four members across all three SDKs.
enum RiskTier {
  /// Strong, corroborated evidence of fraud.
  high('HIGH'),

  /// Multiple credible reports, short of [high].
  elevated('ELEVATED'),

  /// Thin or ambiguous evidence — show it, do not act on it alone.
  caution('CAUTION'),

  /// Nothing on record.
  none('NONE');

  const RiskTier(this.wireValue);

  /// The value the API sends and expects.
  final String wireValue;

  /// Whether this tier is worth surfacing to a user at all.
  bool get isRisky => this != RiskTier.none;

  /// Decodes a wire value, case-insensitively and tolerant of whitespace.
  ///
  /// Deliberate fail-safe: an **unrecognised, non-empty** tier decodes to
  /// [high], not [none]. If phase 2 adds a tier this build has never heard of,
  /// over-warning is recoverable; silently reporting "clean" for a flagged
  /// account is not. A missing or empty value decodes to [none], because that
  /// is what a `found: false` response legitimately looks like.
  static RiskTier fromWire(Object? value) {
    if (value is! String) return RiskTier.none;
    final needle = value.trim().toUpperCase();
    if (needle.isEmpty) return RiskTier.none;
    for (final tier in RiskTier.values) {
      if (tier.wireValue == needle) return tier;
    }
    return RiskTier.high;
  }
}
