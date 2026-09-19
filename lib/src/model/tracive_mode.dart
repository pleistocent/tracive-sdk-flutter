// Copyright 2026 PT Pleistocent Teknologi Nusantara.
// Licensed under the Apache License, Version 2.0.

import 'client_type.dart';
import 'tracive_scopes.dart';

/// How the client authenticates.
///
/// **There is no API-key parameter here, or anywhere else in this SDK, in any
/// mode. That is a hard design invariant — do not add one.** An API key
/// shipped inside a mobile binary is an API key that has been published.
///
/// Sealed, so a `switch` over the two modes is exhaustive.
sealed class TraciveMode {
  const TraciveMode();

  /// phase 1. The user consents in the Tracive app and this SDK acts on their
  /// behalf with a PKCE-issued token.
  factory TraciveMode.oauth({
    required String clientId,
    required String redirectUri,
    required String partnerUserId,
    List<String> scopes,
    ClientType clientType,
  }) = TraciveOAuthMode;

  /// **phase 2 — not implemented.** The type exists now so that adding the
  /// behaviour later is not a breaking change. Any call made in this
  /// mode throws `TraciveNotImplementedException`.
  ///
  /// Not `const`, unlike [TraciveMode.oauth]: this one holds a map of
  /// credentials, and it copies it so that the caller's own map cannot be
  /// changed underneath it afterwards. A `const` constructor cannot copy.
  factory TraciveMode.proxy({
    required String baseUrl,
    Map<String, String> authHeaders,
  }) = TraciveProxyMode;
}

/// OAuth mode — see [TraciveMode.oauth].
final class TraciveOAuthMode extends TraciveMode {
  /// Creates an OAuth configuration, rejecting a blank [partnerUserId].
  ///
  /// **Deliberately not `const`.** It was, and the check was an `assert`, which
  /// the AOT compiler strips — so a release build put `partner_user_id=` on the
  /// wire while debug refused it, and the difference surfaced only in
  /// production. A `const` constructor cannot call `trim()` either, so it could
  /// not have caught a whitespace-only id in any build. Losing `const` costs an
  /// integrator a keyword; keeping it cost the check.
  TraciveOAuthMode({
    required this.clientId,
    required this.redirectUri,
    required this.partnerUserId,
    this.scopes = const <String>[TraciveScopes.scammerCheck],
    this.clientType = ClientType.public,
  }) {
    if (partnerUserId.trim().isEmpty) {
      throw ArgumentError.value(
        partnerUserId,
        'partnerUserId',
        'must not be blank. The authorization request has to carry one: the '
            'Tracive app refuses a consent without it, client-side and with no '
            'redirect, so the failure would reach you as silence rather than as '
            'an error.',
      );
    }
  }

  /// The partner's registered OAuth client id. Public by nature — it is not a
  /// secret and is not treated as one.
  final String clientId;

  /// Redirect target registered with Tracive. Must be an App Link / Universal
  /// Link the host app owns; completing the flow in a WebView is forbidden.
  final String redirectUri;

  /// Scopes to request, as the exact wire strings — name them with
  /// [TraciveScopes] rather than typing them.
  ///
  /// Ask for the narrowest set that works; the default is the single scope
  /// `checkScammer` needs. The server rejects the whole consent request when it
  /// does not recognise a name, so a typo here is not a narrower grant, it is
  /// an integration that cannot authorize.
  final List<String> scopes;

  /// The partner's own opaque id for this end user.
  ///
  /// **Required, and non-blank.** The Tracive app refuses a consent without one,
  /// client-side and before any network call, and by design returns no redirect
  /// — so the partner app is handed nothing to handle and no log records the
  /// attempt. It is also what the grant is keyed on: echoed back in
  /// `grant.revoked` and `grant.superseded` so a partner can map the event to
  /// their own customer, and what enforces one partner account to one Tracive
  /// account. Never a raw phone number or email, and never used as a credential.
  final String partnerUserId;

  /// Whether this SDK completes the token exchange ([ClientType.public]) or
  /// hands the authorization code back ([ClientType.confidential]).
  final ClientType clientType;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TraciveOAuthMode &&
          other.clientId == clientId &&
          other.redirectUri == redirectUri &&
          other.partnerUserId == partnerUserId &&
          other.clientType == clientType &&
          _sameScopes(other.scopes, scopes);

  @override
  int get hashCode => Object.hash(
        clientId,
        redirectUri,
        partnerUserId,
        clientType,
        Object.hashAll(scopes),
      );

  static bool _sameScopes(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// [partnerUserId] is omitted — it identifies an end user.
  @override
  String toString() => 'TraciveMode.oauth(clientId: $clientId, '
      'redirectUri: $redirectUri, scopes: $scopes, '
      'clientType: ${clientType.wireValue})';
}

/// Proxy mode — see [TraciveMode.proxy]. **phase 2; every call throws.**
final class TraciveProxyMode extends TraciveMode {
  /// Creates a proxy configuration.
  ///
  /// [authHeaders] is copied, not captured: a mode is a value, and a caller
  /// that kept the map it passed could otherwise change the credentials this
  /// object claims to hold after it was built. `CheckResult` copies its
  /// collections for the same reason; this one holds secrets, so it is the
  /// last place to make an exception.
  TraciveProxyMode({
    required this.baseUrl,
    Map<String, String> authHeaders = const <String, String>{},
  }) : authHeaders = Map<String, String>.unmodifiable(authHeaders);

  /// The partner's own proxy endpoint.
  final String baseUrl;

  /// Headers the partner's proxy expects. Unmodifiable.
  ///
  /// These are the **partner's** credentials for the **partner's** proxy —
  /// never a Tracive API key (there is no such thing in this SDK). They are
  /// secret regardless: [toString] prints only the header names.
  final Map<String, String> authHeaders;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TraciveProxyMode &&
          other.baseUrl == baseUrl &&
          _sameHeaders(other.authHeaders, authHeaders);

  @override
  int get hashCode => Object.hash(
        baseUrl,
        Object.hashAllUnordered(
          authHeaders.entries.map((e) => Object.hash(e.key, e.value)),
        ),
      );

  static bool _sameHeaders(Map<String, String> a, Map<String, String> b) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (b[entry.key] != entry.value) return false;
    }
    return true;
  }

  /// Header **values** are never printed.
  @override
  String toString() => 'TraciveMode.proxy(baseUrl: $baseUrl, '
      'authHeaders: ${authHeaders.keys.toList()} (values redacted))';
}
