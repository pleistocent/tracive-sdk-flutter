// Copyright (c) Tracive. Licensed under the Apache License, Version 2.0.

import '../oauth/authorize_url.dart';

/// Which Tracive deployment the client talks to.
///
/// Sandbox and production are separate registrations: a client id issued in
/// one is unknown to the other. No test in this repo reaches either host.
class TraciveEnvironment {
  const TraciveEnvironment._(this.baseUrl, this.name);

  /// A partner proxy or a local server, for testing and for phase 2 proxy
  /// deployments.
  ///
  /// A trailing slash is trimmed so that `'$baseUrl/scammer-checks'` is always
  /// well-formed. The URL must be absolute; anything else throws
  /// [ArgumentError] here rather than failing later inside the transport.
  ///
  /// **The scheme must be `https`.** Every authorized request carries
  /// `Authorization: Bearer <access token>`, and over plaintext HTTP that token
  /// is readable by anything on the path — a hotel network, a captive portal, a
  /// misconfigured corporate proxy. It is rejected here rather than warned
  /// about, because a warning in a constructor is a warning nobody reads, and
  /// the failure it prevents is silent by nature.
  ///
  /// The one exception is a loopback host — `localhost`, `127.0.0.1`, `::1` —
  /// where `http` is allowed. Traffic to loopback never leaves the machine, and
  /// a local test server with no certificate is the ordinary way to exercise
  /// proxy mode. [loopbackHosts] is the whole list.
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
    final scheme = uri.scheme.toLowerCase();
    final isLoopback = loopbackHosts.contains(uri.host.toLowerCase());
    if (scheme != 'https' && !(scheme == 'http' && isLoopback)) {
      throw ArgumentError.value(
        baseUrl,
        'baseUrl',
        'must use https — every request carries a bearer token, and over '
            'plaintext HTTP anything on the network path can read it. '
            'http is allowed only for ${loopbackHosts.join(", ")}.',
      );
    }
    return TraciveEnvironment._(_withoutTrailingSlash(trimmed), 'custom');
  }

  /// Hosts for which [TraciveEnvironment.custom] accepts `http`.
  ///
  /// Loopback only: traffic to these never leaves the machine, so there is no
  /// network path for a bearer token to be read from.
  static const Set<String> loopbackHosts = <String>{
    'localhost',
    '127.0.0.1',
    '::1',
  };

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

  /// Where the authorization request is opened.
  ///
  /// **This is not on the API host, and it cannot be derived from [baseUrl].**
  /// `api.tracive.id/v1` answers the data calls; the authorize URL points at
  /// `tracive.id`, because that is the origin the shipping Tracive app claims
  /// as an App Link and a Universal Link. Resolving this path against
  /// [baseUrl] produces a URL no Tracive build claims — it opens a web page
  /// instead of the app, and the consent flow cannot complete at all. This SDK
  /// did exactly that until 2 August 2026.
  ///
  /// A custom environment keeps the old behaviour and appends the path to its
  /// own base URL: a partner proxy or a local server is whatever the
  /// integrator points it at, and there is no app claiming it either way.
  Uri get authorizeEndpoint => switch (name) {
        'production' => Uri.parse('https://tracive.id/oauth/authorize'),
        'sandbox' => Uri.parse('https://sandbox.tracive.id/oauth/authorize'),
        _ => resolve(authorizePath),
      };

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
