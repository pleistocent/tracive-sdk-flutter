// Copyright 2026 PT Pleistocent Teknologi Nusantara.
// Licensed under the Apache License, Version 2.0.

/// Where a `CheckResult` came from.
///
/// Not a request parameter: the client stamps it on the result. A [cache]
/// result cost zero credits and did no network I/O.
enum Origin {
  /// Served from the local encrypted cache.
  cache('CACHE'),

  /// Served by the API.
  server('SERVER');

  const Origin(this.wireValue);

  /// Stable string form, used when a cached record is persisted.
  final String wireValue;

  /// Decodes [wireValue] case-insensitively; unknown values fall back to
  /// [server] (the conservative reading: assume it was billed).
  static Origin fromWire(Object? value) {
    if (value is String && value.trim().toUpperCase() == 'CACHE') {
      return Origin.cache;
    }
    return Origin.server;
  }
}
