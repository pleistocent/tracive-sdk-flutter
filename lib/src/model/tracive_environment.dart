// Copyright (c) Tracive. Licensed under the Apache License, Version 2.0.

/// Which Tracive deployment the client talks to — the SDK specification §2.
///
/// **The Open API is not live yet.** These hosts are the documented contract,
/// not a running service; see the README. Nothing in this SDK can be tested
/// against them, and no test in this repo tries.
class TraciveEnvironment {
  const TraciveEnvironment._(this.baseUrl, this.name);

  /// A partner proxy or a local server, for testing and for phase 2 proxy
  /// deployments.
  ///
  /// A trailing slash is trimmed so that `'$baseUrl/scammer-checks'` is always
  /// well-formed. The URL must be absolute; anything else throws
  /// [ArgumentError] here rather than failing later inside the transport.
  factory TraciveEnvironment.custom(String baseUrl) {
    final trimmed = baseUrl.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(baseUrl, 'baseUrl', 'must not be empty');
    }
    final uri = Uri.tryParse(trimmed);
    if (uri == null || !uri.hasScheme || !uri.hasAuthority) {
      throw ArgumentError.value(
        baseUrl,
        'baseUrl',
        'must be an absolute URL, e.g. https://proxy.example.com/v1',
      );
    }
    return TraciveEnvironment._(_withoutTrailingSlash(trimmed), 'custom');
  }

  /// `https://api.tracive.id/v1`
  static const TraciveEnvironment production = TraciveEnvironment._(
    'https://api.tracive.id/v1',
    'production',
  );

  /// `https://api-sandbox.tracive.id/v1`
  static const TraciveEnvironment sandbox = TraciveEnvironment._(
    'https://api-sandbox.tracive.id/v1',
    'sandbox',
  );

  /// Base URL including the `/v1` path segment, without a trailing slash.
  final String baseUrl;

  /// `production`, `sandbox` or `custom`. For logs and diagnostics.
  final String name;

  /// Resolves an API path against [baseUrl], e.g. `resolve('scammer-checks')`.
  Uri resolve(String path) {
    final suffix = path.startsWith('/') ? path.substring(1) : path;
    return Uri.parse('$baseUrl/$suffix');
  }

  static String _withoutTrailingSlash(String value) {
    var out = value;
    while (out.endsWith('/')) {
      out = out.substring(0, out.length - 1);
    }
    return out;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TraciveEnvironment &&
          other.baseUrl == baseUrl &&
          other.name == name;

  @override
  int get hashCode => Object.hash(baseUrl, name);

  @override
  String toString() => 'TraciveEnvironment($name, $baseUrl)';
}
