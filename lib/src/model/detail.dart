// Copyright 2026 PT Pleistocent Teknologi Nusantara.
// Licensed under the Apache License, Version 2.0.

/// How much of a report set to return.
///
/// The wire values are lowercase here (`"detail": "minimal"`), matching the
/// request body rather than the `UPPER_SNAKE` convention used for enums
/// that travel as response values.
enum Detail {
  /// Counts, tier and dates only. The default, and the only form that is
  /// cached.
  minimal('minimal'),

  /// Adds `topChronologies` and `comments`. Never cached: the payload varies
  /// with `locale`, and it is the most sensitive content in the response.
  full('full');

  const Detail(this.wireValue);

  /// The value sent in the request body.
  final String wireValue;

  /// Whether `locale` is meaningful for this level. Omit `locale` when
  /// `detail == minimal`, because the server ignores it there.
  bool get supportsLocale => this == Detail.full;

  /// Decodes [wireValue] case-insensitively; unknown values fall back to
  /// [minimal] (the cheaper, always-permitted level).
  static Detail fromWire(Object? value) {
    if (value is String && value.trim().toLowerCase() == 'full') {
      return Detail.full;
    }
    return Detail.minimal;
  }
}
