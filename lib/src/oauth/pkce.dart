// Copyright (c) Tracive. Licensed under the Apache License, Version 2.0.
//
// PKCE — step 2 of the flow in `doc/oauth.md`, RFC 7636.
//
//   "Generate `code_verifier` (43-128 chars, unreserved set) and
//    `code_challenge = BASE64URL(SHA256(verifier))`, plus a random `state`.
//    **S256 only — never `plain`.**"
//
// `plain` is not offered here, not even as an option. A public mobile client
// using `plain` is a public mobile client with no PKCE protection at all: the
// verifier travels in the authorization request, so anything that could
// intercept the redirect could already have read it. RFC 7636 §7.2 says a
// client that supports S256 MUST use it, and every client that can run this
// SDK supports S256.

import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// A PKCE verifier and its S256 challenge.
///
/// PRIVACY: [codeVerifier] is a one-time secret. It is never logged — see
/// [toString] — and it leaves this SDK only in the token-exchange request, or
/// in `AuthResult.codeReceived` for a confidential client, which is exactly the
/// party entitled to it.
class PkcePair {
  const PkcePair._(this.codeVerifier, this.codeChallenge);

  /// Derives the challenge for an existing [codeVerifier].
  ///
  /// Used when resuming a flow whose verifier was persisted across a process
  /// death, and by the RFC 7636 appendix B test vector.
  ///
  /// Throws [ArgumentError] if [codeVerifier] is outside RFC 7636's grammar —
  /// a malformed verifier produces an authorization request the server will
  /// reject after the user has already consented, which is the worst possible
  /// moment to find out.
  factory PkcePair.fromVerifier(String codeVerifier) {
    if (codeVerifier.length < minVerifierLength ||
        codeVerifier.length > maxVerifierLength) {
      throw ArgumentError.value(
        codeVerifier.length,
        'codeVerifier.length',
        'must be $minVerifierLength-$maxVerifierLength characters (RFC 7636 §4.1)',
      );
    }
    if (!_unreservedPattern.hasMatch(codeVerifier)) {
      throw ArgumentError.value(
        '<redacted>',
        'codeVerifier',
        'must use only the unreserved set [A-Za-z0-9-._~] (RFC 7636 §4.1)',
      );
    }
    return PkcePair._(codeVerifier, challengeFor(codeVerifier));
  }

  /// Generates a fresh pair.
  ///
  /// [random] defaults to [Random.secure]. Pass a seeded [Random] **only** in
  /// tests: a predictable verifier defeats the entire mechanism.
  ///
  /// [verifierLength] defaults to 64 characters — comfortably inside RFC 7636's
  /// 43-128 window, and ~380 bits of entropy from the 66-character unreserved
  /// alphabet.
  factory PkcePair.generate({Random? random, int verifierLength = 64}) {
    if (verifierLength < minVerifierLength ||
        verifierLength > maxVerifierLength) {
      throw ArgumentError.value(
        verifierLength,
        'verifierLength',
        'must be $minVerifierLength-$maxVerifierLength (RFC 7636 §4.1)',
      );
    }
    final source = random ?? Random.secure();
    final buffer = StringBuffer();
    for (var i = 0; i < verifierLength; i++) {
      buffer.write(_unreserved[source.nextInt(_unreserved.length)]);
    }
    final verifier = buffer.toString();
    return PkcePair._(verifier, challengeFor(verifier));
  }

  /// RFC 7636 §4.1 lower bound.
  static const int minVerifierLength = 43;

  /// RFC 7636 §4.1 upper bound.
  static const int maxVerifierLength = 128;

  /// The only challenge method this SDK will ever send.
  static const String codeChallengeMethod = 'S256';

  /// RFC 3986 §2.3 unreserved characters — the verifier alphabet.
  static const String _unreserved =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';

  static final RegExp _unreservedPattern = RegExp(r'^[A-Za-z0-9\-._~]+$');

  /// The one-time secret. Sent only with the token exchange.
  final String codeVerifier;

  /// `BASE64URL(SHA256(ASCII(codeVerifier)))`, unpadded. Sent in the
  /// authorization request.
  final String codeChallenge;

  /// `BASE64URL-ENCODE(SHA256(ASCII(verifier)))` — RFC 7636 §4.2.
  ///
  /// Unpadded, per RFC 7636's definition of base64url encoding ("with all
  /// trailing '=' characters omitted"). A padded challenge is a challenge the
  /// server will not match.
  static String challengeFor(String verifier) {
    final digest = sha256.convert(ascii.encode(verifier));
    return base64Url.encode(digest.bytes).replaceAll('=', '');
  }

  /// Generates the `state` parameter: 32 random bytes, base64url, unpadded.
  ///
  /// `state` is not a secret in the way the verifier is — it is a CSRF nonce —
  /// but it must be unguessable, so it comes from the same source.
  static String generateState({Random? random, int byteLength = 32}) {
    final source = random ?? Random.secure();
    final bytes = List<int>.generate(
      byteLength,
      (_) => source.nextInt(256),
      growable: false,
    );
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  /// **Never** prints [codeVerifier].
  @override
  String toString() =>
      'PkcePair(method: $codeChallengeMethod, challenge: $codeChallenge, '
      'verifier: redacted)';
}
