// Copyright 2026 PT Pleistocent Teknologi Nusantara.
// Licensed under the Apache License, Version 2.0.

/// Where a check may be answered from.
///
/// Client-side only: this never travels on the wire. It decides whether the
/// local cache may answer, and therefore whether the call costs a credit.
enum Source {
  /// Live cache entry wins; otherwise call the server. The default.
  cacheFirst,

  /// Always call the server. Costs a credit even when a live entry exists.
  server,

  /// Call the server, and fall back on a live cache entry when the call fails
  /// for a **transport-shaped** reason: a network error, a 5xx, a 429. The
  /// fallback result is still stamped `Origin.cache`.
  ///
  /// A failure that carries a verdict about the caller is never masked this
  /// way — a revoked grant, a missing scope, a rejected token, or a 402. See
  /// `TraciveClient.checkScammer`.
  serverFirst,

  /// Cache only, never any network I/O. A miss raises
  /// `TraciveCacheMissException` — it never returns a silent empty result that
  /// would read as "not a scammer".
  cache;

  /// Whether this source is allowed to read the local cache.
  bool get readsCache => this != Source.server;

  /// Whether this source is allowed to make a network call.
  bool get readsNetwork => this != Source.cache;
}
