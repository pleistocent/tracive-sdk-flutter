// Copyright (c) Tracive. Licensed under the Apache License, Version 2.0.

/// Where a check may be answered from.
///
/// Client-side only: this never travels on the wire. It decides whether the
/// local cache may answer, and therefore whether the call costs a credit.
enum Source {
  /// Live cache entry wins; otherwise call the server. The default.
  cacheFirst,

  /// Always call the server. Costs a credit even when a live entry exists.
  server,

  /// Call the server, and fall back on a live cache entry if the call fails.
  /// The fallback result is still stamped `Origin.cache`.
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
