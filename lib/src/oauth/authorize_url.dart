// Copyright (c) Tracive. Licensed under the Apache License, Version 2.0.
//
// URL construction for the OAuth flow.
//
// Split out from `tracive_oauth.dart` so each URL can be asserted on directly
// in a test, byte for byte, without running a flow. Two of them carry
// invariants that are easy to break and impossible to notice afterwards:
//
//   * the authorize URL must always say `code_challenge_method=S256`, and
//   * the install link must carry **no OAuth parameters at all**.

import '../model/tracive_environment.dart';
import 'pkce.dart';

/// Path of the authorization endpoint.
///
/// Only a custom environment resolves it against the base URL; production and
/// sandbox have their own origin. See [TraciveEnvironment.authorizeEndpoint].
const String authorizePath = 'oauth/authorize';

/// Path of the token endpoint.
const String tokenPath = 'oauth/token';

/// Path of the revocation endpoint, used by `signOut`.
const String revokePath = 'oauth/revoke';

/// Builds the authorization request URL (RFC 6749 §4.1.1 + RFC 7636 §4.3).
///
/// This URL is opened with the OS handler, never a WebView, so that the Tracive
/// app's App Link / Universal Link claims it.
///
/// `code_challenge_method` is hard-wired to `S256`. It is not a parameter of
/// this function because it is not a decision: see [PkcePair].
Uri buildAuthorizeUrl({
  required TraciveEnvironment environment,
  required String clientId,
  required String redirectUri,
  required List<String> scopes,
  required String state,
  required String codeChallenge,
  String? partnerUserId,
}) {
  return environment.authorizeEndpoint.replace(
    queryParameters: <String, String>{
      'response_type': 'code',
      'client_id': clientId,
      'redirect_uri': redirectUri,
      if (scopes.isNotEmpty) 'scope': scopes.join(' '),
      'state': state,
      'code_challenge': codeChallenge,
      'code_challenge_method': PkcePair.codeChallengeMethod,
      if (partnerUserId != null && partnerUserId.trim().isNotEmpty)
        'partner_user_id': partnerUserId.trim(),
    },
  );
}

/// Every parameter name that would make an install link an OAuth link.
///
/// Exposed so the test that guards the clean install link checks the same list
/// the builder
/// strips, rather than a copy of it that can drift.
const Set<String> oauthParameterNames = <String>{
  'response_type',
  'client_id',
  'redirect_uri',
  'scope',
  'state',
  'code',
  'code_challenge',
  'code_challenge_method',
  'code_verifier',
  'grant_type',
  'access_token',
  'refresh_token',
  'partner_user_id',
  'token',
  'id_token',
};

/// Query parameter carrying the attribution tag that names the OAuth client.
const String installAttributionParameter = 'ref';

/// Value of `utm_source` on the install link: which SDK sent the user there.
///
/// It names the *SDK*, not the partner and not the user.
const String installUtmSource = 'tracive-sdk-flutter';

/// Builds the **clean** install link.
///
/// Clean means no OAuth parameter of any kind travels on it. Two optional,
/// non-sensitive query parameters are all that is added: `ref`, the OAuth
/// client id, and `utm_source`, naming this SDK.
///
/// Why "clean" is load-bearing: the user is about to leave for an app store and
/// come back through an install-attribution service, and every hop in that
/// chain (the link shortener, the store referrer, the attribution SDK, the
/// clipboard on some platforms) logs the URL it was handed. A `state` or
/// `code_challenge` that travels that route is a `state` or `code_challenge`
/// sitting in a third party's analytics warehouse, and a `partner_user_id` that
/// travels it hands that third party the partner's own user identifier. There
/// is also nothing to gain: there is **no deferred resume** — the user retries
/// in the partner app after installing, and a fresh PKCE pair is generated
/// then.
///
/// [clientId] is the PARTNER's identifier, never the end user's, and it is
/// public by definition (it ships inside the app binary), so `ref` leaks
/// nothing. It is omitted entirely when null or empty.
///
/// Any OAuth parameter already present on [installUrl] is **stripped**, not
/// trusted — a misconfigured link constant must not be able to defeat this.
Uri buildInstallUrl(String installUrl, {String? clientId}) {
  final base = Uri.parse(installUrl);
  final parameters = <String, String>{
    for (final entry in base.queryParameters.entries)
      if (!oauthParameterNames.contains(entry.key.toLowerCase()))
        entry.key: entry.value,
    if (clientId != null && clientId.trim().isNotEmpty)
      installAttributionParameter: clientId.trim(),
    'utm_source': installUtmSource,
  };
  return base.replace(queryParameters: parameters);
}

/// Body of the authorization-code exchange (RFC 6749 §4.1.3 + RFC 7636 §4.5).
///
/// No `client_secret`. A public client has none — that is what PKCE replaces —
/// and a secret shipped in a mobile binary is a published secret. A
/// confidential client never reaches this function: it stops at
/// `AuthResult.codeReceived` and its own backend performs the exchange (
/// step 6).
Map<String, String> buildTokenExchangeForm({
  required String code,
  required String codeVerifier,
  required String redirectUri,
  required String clientId,
}) =>
    <String, String>{
      'grant_type': 'authorization_code',
      'code': code,
      'redirect_uri': redirectUri,
      'client_id': clientId,
      'code_verifier': codeVerifier,
    };

/// Body of a refresh (RFC 6749 §6).
Map<String, String> buildRefreshForm({
  required String refreshToken,
  required String clientId,
}) =>
    <String, String>{
      'grant_type': 'refresh_token',
      'refresh_token': refreshToken,
      'client_id': clientId,
    };

/// Body of a revocation (RFC 7009 §2.1).
///
/// The **refresh** token is revoked, not the access token: revoking the refresh
/// token ends the grant, whereas revoking one access token leaves the grant
/// alive and re-issuable.
Map<String, String> buildRevokeForm({
  required String token,
  required String clientId,
  String tokenTypeHint = 'refresh_token',
}) =>
    <String, String>{
      'token': token,
      'token_type_hint': tokenTypeHint,
      'client_id': clientId,
    };

/// Encodes a form body as `application/x-www-form-urlencoded`.
String encodeForm(Map<String, String> fields) =>
    Uri(queryParameters: fields).query;
