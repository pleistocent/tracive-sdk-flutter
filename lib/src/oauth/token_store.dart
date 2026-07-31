// Copyright (c) Tracive. Licensed under the Apache License, Version 2.0.
//
// Token storage — the SDK specification §6.
//
//   "Access token (JWT, 1 h) + rotating opaque refresh token stored in
//    Keystore/Keychain — **never** in SharedPreferences/UserDefaults/plain
//    files."
//
// The interface is here, in pure Dart; the Keystore/Keychain implementation is
// `SecureStorageTokenStore` in `platform_flutter.dart`, selected automatically
// on Flutter. Splitting them is what lets `dart test` exercise the OAuth logic
// with no Flutter engine and no platform channels — and, more importantly, what
// lets a host app substitute its own vault without forking the SDK.
//
// PRIVACY: nothing in this file prints a token. Not in `toString`, not in an
// exception message, not in an assertion. A refresh token in a crash report is
// a refresh token in someone else's hands.

import 'dart:convert';

import '../model/json.dart';

/// The tokens issued for one grant.
///
/// Immutable. A refresh **replaces** the whole record rather than mutating the
/// access token in place: the refresh token rotates too (§6), and writing the
/// pair in one operation is what makes the replacement atomic. A store that
/// wrote them separately could be interrupted between the two and leave a new
/// access token beside a spent refresh token — which is indistinguishable, from
/// the server's side, from a stolen-token replay.
class TraciveTokens {
  /// Creates a token record.
  const TraciveTokens({
    required this.accessToken,
    this.refreshToken,
    this.expiresAt,
    this.grantedScopes = const <String>[],
    this.tokenType = 'Bearer',
  });

  /// Builds a record from an RFC 6749 §5.1 token response.
  ///
  /// [now] anchors `expires_in` (a *duration*) to an instant. [previous] is the
  /// record being replaced, if any: a server that rotates refresh tokens sends
  /// a new one, but one that does not simply omits the field, and dropping the
  /// old one there would strand the grant. [fallbackScopes] is used when the
  /// response omits `scope`, which RFC 6749 permits when the granted scope
  /// equals the requested scope.
  factory TraciveTokens.fromTokenResponse(
    Map<String, Object?> json, {
    required DateTime now,
    TraciveTokens? previous,
    List<String> fallbackScopes = const <String>[],
  }) {
    final expiresIn = asIntOrNull(json['expires_in']);
    final scope = asString(json['scope']);
    final scopes =
        scope?.split(' ').where((s) => s.isNotEmpty).toList(growable: false);
    return TraciveTokens(
      accessToken: asStringOr(json['access_token'], ''),
      refreshToken: asString(json['refresh_token']) ?? previous?.refreshToken,
      expiresAt: expiresIn == null
          ? null
          : now.toUtc().add(Duration(seconds: expiresIn)),
      grantedScopes: scopes ?? (previous?.grantedScopes ?? fallbackScopes),
      tokenType: asStringOr(json['token_type'], 'Bearer'),
    );
  }

  /// Reads back what [toStorageJson] wrote.
  factory TraciveTokens.fromStorageJson(Map<String, Object?> json) =>
      TraciveTokens(
        accessToken: asStringOr(json['accessToken'], ''),
        refreshToken: asString(json['refreshToken']),
        expiresAt: asUtcDateTime(json['expiresAt']),
        grantedScopes: asStringList(json['grantedScopes']),
        tokenType: asStringOr(json['tokenType'], 'Bearer'),
      );

  /// The bearer token sent on every API call.
  final String accessToken;

  /// The opaque, rotating refresh token. `null` if the server issued none.
  final String? refreshToken;

  /// When [accessToken] stops being accepted, in UTC. `null` if unknown.
  final DateTime? expiresAt;

  /// Scopes the server actually granted — not necessarily those requested.
  final List<String> grantedScopes;

  /// Almost always `Bearer`.
  final String tokenType;

  /// Whether there is an access token at all.
  bool get hasAccessToken => accessToken.isNotEmpty;

  /// Whether a refresh is possible without sending the user back through
  /// consent.
  bool get canRefresh => (refreshToken ?? '').isNotEmpty;

  /// Whether [accessToken] is expired at [now], counting [skew] as expired.
  ///
  /// The skew is not paranoia about clock drift so much as about flight time: a
  /// token with four seconds left is a token that will be rejected by the time
  /// the request lands, and that rejection costs a round trip and a refresh
  /// anyway. An unknown [expiresAt] is treated as **not** expired — the 401
  /// path will catch it, and guessing "expired" would refresh on every single
  /// call.
  bool isExpiredAt(DateTime now,
      {Duration skew = const Duration(seconds: 60)}) {
    final expiry = expiresAt;
    if (expiry == null) return false;
    return !now.toUtc().isBefore(expiry.toUtc().subtract(skew));
  }

  /// The `Authorization` header value.
  String get authorizationHeader => '$tokenType $accessToken';

  /// Serialised form for a [TokenStore]. Written to secure storage only.
  Map<String, Object?> toStorageJson() => <String, Object?>{
        'accessToken': accessToken,
        if (refreshToken != null) 'refreshToken': refreshToken,
        if (expiresAt != null) 'expiresAt': toIso8601Utc(expiresAt),
        'grantedScopes': grantedScopes,
        'tokenType': tokenType,
      };

  /// Copy with replacements.
  TraciveTokens copyWith({
    String? accessToken,
    String? refreshToken,
    DateTime? expiresAt,
    List<String>? grantedScopes,
    String? tokenType,
  }) =>
      TraciveTokens(
        accessToken: accessToken ?? this.accessToken,
        refreshToken: refreshToken ?? this.refreshToken,
        expiresAt: expiresAt ?? this.expiresAt,
        grantedScopes: grantedScopes ?? this.grantedScopes,
        tokenType: tokenType ?? this.tokenType,
      );

  /// **Never** prints either token. Lengths only, so a "did I get a refresh
  /// token?" question is still answerable from a log.
  @override
  String toString() => 'TraciveTokens(tokenType: $tokenType, '
      'accessToken: ${accessToken.length} chars redacted, '
      'refreshToken: ${refreshToken == null ? 'none' : 'redacted'}, '
      'expiresAt: $expiresAt, grantedScopes: $grantedScopes)';
}

/// An authorization that has been started and is waiting for its redirect.
///
/// Persisted, not merely held in a field: on Android the OS is entitled to kill
/// the host app while the user is in the browser consenting, and a verifier
/// that lived only in memory would be gone when the App Link brings the app
/// back. Losing it turns a successful consent into an unexplained failure.
class PendingAuthorization {
  /// Creates a pending authorization.
  const PendingAuthorization({
    required this.state,
    required this.codeVerifier,
    required this.redirectUri,
    required this.createdAt,
  });

  /// Reads back what [toStorageJson] wrote.
  factory PendingAuthorization.fromStorageJson(Map<String, Object?> json) =>
      PendingAuthorization(
        state: asStringOr(json['state'], ''),
        codeVerifier: asStringOr(json['codeVerifier'], ''),
        redirectUri: asStringOr(json['redirectUri'], ''),
        createdAt: asUtcDateTime(json['createdAt']) ?? DateTime.utc(1970),
      );

  /// The CSRF nonce sent in the authorization request.
  final String state;

  /// The PKCE verifier whose challenge was sent.
  final String codeVerifier;

  /// The redirect URI sent, which the token exchange must repeat.
  final String redirectUri;

  /// When the flow was started, in UTC. Used to expire an abandoned attempt.
  final DateTime createdAt;

  /// Whether this attempt is older than [maxAge] at [now].
  bool isStaleAt(DateTime now,
          {Duration maxAge = const Duration(minutes: 30)}) =>
      now.toUtc().difference(createdAt.toUtc()) > maxAge;

  /// Serialised form for a [TokenStore]. Written to secure storage only.
  Map<String, Object?> toStorageJson() => <String, Object?>{
        'state': state,
        'codeVerifier': codeVerifier,
        'redirectUri': redirectUri,
        'createdAt': toIso8601Utc(createdAt),
      };

  /// **Never** prints [codeVerifier] or [state].
  @override
  String toString() => 'PendingAuthorization(redirectUri: $redirectUri, '
      'createdAt: $createdAt, state: redacted, codeVerifier: redacted)';
}

/// Where the SDK keeps tokens and the in-flight authorization.
///
/// The shipped implementation is `SecureStorageTokenStore`
/// (`flutter_secure_storage` → Android Keystore / iOS Keychain), chosen
/// automatically. Implement this yourself only if your app already owns a
/// vault — and if you do, honour §6: **never** SharedPreferences,
/// NSUserDefaults, a plain file, or an unencrypted database.
///
/// Every method may be called concurrently. Implementations do not need to
/// serialise themselves; the single-flight refresh above them already ensures
/// only one writer is in flight at a time.
abstract class TokenStore {
  /// Allows `const` implementations.
  const TokenStore();

  /// The stored tokens, or `null` when the user has not authorized.
  Future<TraciveTokens?> read();

  /// Replaces the stored tokens. Must be atomic with respect to [read].
  Future<void> write(TraciveTokens tokens);

  /// Erases the tokens. Called on sign-out and on `grant_revoked` (§6).
  Future<void> clear();

  /// The authorization waiting for its redirect, or `null`.
  Future<PendingAuthorization?> readPending();

  /// Stores (or, with `null`, erases) the pending authorization.
  Future<void> writePending(PendingAuthorization? pending);
}

/// A [TokenStore] that lives in this process and dies with it.
///
/// Use it in tests, and in a short-lived non-Flutter process (a script, a
/// server-side isolate) where there is no Keychain to write to. **Do not use it
/// in an app**: the user would be sent back through consent on every cold
/// start, which trains them to approve OAuth prompts without reading them.
class InMemoryTokenStore extends TokenStore {
  /// Creates an empty store, optionally pre-seeded with [tokens].
  InMemoryTokenStore({TraciveTokens? tokens}) : _tokens = tokens;

  TraciveTokens? _tokens;
  PendingAuthorization? _pending;

  /// How many times [write] has been called. For tests that need to prove a
  /// rotated refresh token was persisted exactly once.
  int writeCount = 0;

  /// How many times [clear] has been called.
  int clearCount = 0;

  @override
  Future<TraciveTokens?> read() async => _tokens;

  @override
  Future<void> write(TraciveTokens tokens) async {
    _tokens = tokens;
    writeCount++;
  }

  @override
  Future<void> clear() async {
    _tokens = null;
    _pending = null;
    clearCount++;
  }

  @override
  Future<PendingAuthorization?> readPending() async => _pending;

  @override
  Future<void> writePending(PendingAuthorization? pending) async {
    _pending = pending;
  }

  @override
  String toString() => 'InMemoryTokenStore(hasTokens: ${_tokens != null}, '
      'hasPending: ${_pending != null})';
}

/// Encodes a storage record. Kept here so every [TokenStore] serialises
/// identically and a store written by one implementation can be read by
/// another.
String encodeStorageJson(Map<String, Object?> json) => jsonEncode(json);

/// Decodes a storage record written by [encodeStorageJson].
///
/// Returns `null` for anything unreadable rather than throwing. A corrupted
/// entry — a partial write, a key rotation, a restored backup from another
/// device — must present as "not signed in", which is recoverable, rather than
/// as an exception on the first API call, which is not.
Map<String, Object?>? decodeStorageJson(String? raw) {
  if (raw == null || raw.trim().isEmpty) return null;
  try {
    final decoded = jsonDecode(raw);
    if (decoded is Map<String, Object?>) return decoded;
    if (decoded is Map) {
      return <String, Object?>{
        for (final entry in decoded.entries) '${entry.key}': entry.value,
      };
    }
  } on FormatException {
    return null;
  }
  return null;
}
