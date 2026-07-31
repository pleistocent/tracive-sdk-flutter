// Copyright (c) Tracive. Licensed under the Apache License, Version 2.0.

import '../exception.dart';
import 'collection_equality.dart';

/// Outcome of an authorization attempt — the SDK specification §6.
///
/// Sealed, so `switch` over it is exhaustive and a new case in a later version
/// is a compile error rather than a silently unhandled path:
///
/// ```dart
/// switch (await client.authorize()) {
///   case AuthAuthorized(:final grantedScopes): /* proceed */
///   case AuthCodeReceived(:final code):        /* POST to your backend */
///   case AuthDenied():                         /* user said no */
///   case AuthAppNotInstalled():                /* install link was opened */
///   case AuthFailed(:final error):             /* show the error */
/// }
/// ```
sealed class AuthResult {
  const AuthResult();

  /// The user consented and this SDK holds tokens (`ClientType.public`).
  const factory AuthResult.authorized(List<String> grantedScopes) =
      AuthAuthorized;

  /// The user consented and this SDK stopped at the authorization code
  /// (`ClientType.confidential`).
  const factory AuthResult.codeReceived({
    required String code,
    required String codeVerifier,
    required String redirectUri,
  }) = AuthCodeReceived;

  /// The user declined.
  const factory AuthResult.denied() = AuthDenied;

  /// The Tracive app is not installed; the clean install link was opened.
  const factory AuthResult.appNotInstalled() = AuthAppNotInstalled;

  /// The flow failed.
  const factory AuthResult.failed(TraciveException error) = AuthFailed;
}

/// Authorized: the SDK exchanged the code and stored the tokens.
final class AuthAuthorized extends AuthResult {
  /// Creates an authorized outcome.
  const AuthAuthorized(this.grantedScopes);

  /// Scopes the server actually granted — check these rather than assuming the
  /// requested set was honoured.
  final List<String> grantedScopes;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AuthAuthorized && listEquals(other.grantedScopes, grantedScopes);

  @override
  int get hashCode => listHash(grantedScopes);

  @override
  String toString() => 'AuthResult.authorized(grantedScopes: $grantedScopes)';
}

/// Confidential clients only: the authorization code, for the partner's
/// backend to exchange with its `client_secret` (§4.2). No token is issued to
/// the device on this path.
final class AuthCodeReceived extends AuthResult {
  /// Creates a code-received outcome.
  const AuthCodeReceived({
    required this.code,
    required this.codeVerifier,
    required this.redirectUri,
  });

  /// The one-time authorization code. Forward it over TLS to your backend and
  /// nowhere else; it is a bearer credential until it is exchanged.
  final String code;

  /// The PKCE verifier that matches the challenge sent to `/oauth/authorize`.
  /// Your backend must send it with the exchange.
  final String codeVerifier;

  /// The redirect URI the exchange must repeat.
  final String redirectUri;

  /// **Never** prints [code] or [codeVerifier].
  @override
  String toString() => 'AuthResult.codeReceived(redirectUri: $redirectUri, '
      'code: redacted, codeVerifier: redacted)';
}

/// The user declined consent.
final class AuthDenied extends AuthResult {
  /// Creates a denied outcome.
  const AuthDenied();

  @override
  bool operator ==(Object other) => other is AuthDenied;

  @override
  int get hashCode => (AuthDenied).hashCode;

  @override
  String toString() => 'AuthResult.denied()';
}

/// The Tracive app is not installed.
///
/// §6: the SDK checked *before* redirecting anywhere and opened the **clean**
/// install link — no OAuth parameters on it. There is no deferred resume; the
/// user retries in the partner app after installing.
final class AuthAppNotInstalled extends AuthResult {
  /// Creates an app-not-installed outcome.
  const AuthAppNotInstalled();

  @override
  bool operator ==(Object other) => other is AuthAppNotInstalled;

  @override
  int get hashCode => (AuthAppNotInstalled).hashCode;

  @override
  String toString() => 'AuthResult.appNotInstalled()';
}

/// The flow failed. A `state` mismatch arrives here as
/// [TraciveStateMismatchException].
final class AuthFailed extends AuthResult {
  /// Creates a failed outcome.
  const AuthFailed(this.error);

  /// Why it failed.
  final TraciveException error;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is AuthFailed && other.error == error;

  @override
  int get hashCode => error.hashCode;

  @override
  String toString() => 'AuthResult.failed($error)';
}
