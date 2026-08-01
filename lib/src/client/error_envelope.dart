// Copyright (c) Tracive. Licensed under the Apache License, Version 2.0.
//
// Error-envelope parsing.
//
// The error-code table (code -> typed exception) lives in `lib/src/exception.dart`
// as `TraciveException.fromApiError` / `fromErrorBody`. This file is the layer
// beneath it: turning an HTTP response into the arguments that table needs,
// without ever throwing on the way.
//
// The rule that shapes every function here: **a malformed error response must
// still produce a typed error.** A caller who gets a 502 of nginx HTML, an
// empty 500, or a JSON array where an object was promised must see
// `TraciveServerException`, not a `FormatException` from inside the SDK. The
// error path is exactly where a crash is least affordable.

import 'dart:convert';

import '../exception.dart';
import 'http_transport.dart';

/// Decodes a JSON body, or `null` if it is not JSON at all.
///
/// Never throws: an HTML error page from a proxy is a perfectly ordinary thing
/// to receive and is not a programming error.
Object? decodeJsonBody(String body) {
  if (body.trim().isEmpty) return null;
  try {
    return jsonDecode(body);
  } on FormatException {
    return null;
  }
}

/// Decodes a JSON **object** body, or `null` for anything else (a JSON array,
/// a bare string, HTML, an empty body).
Map<String, Object?>? decodeJsonObject(String body) {
  final decoded = decodeJsonBody(body);
  if (decoded is Map<String, Object?>) return decoded;
  if (decoded is Map) {
    return <String, Object?>{
      for (final entry in decoded.entries) '${entry.key}': entry.value,
    };
  }
  return null;
}

/// The `error.code` in [response]'s envelope, lower-cased, or `null`.
///
/// Used for the branches that must act on a specific code before the generic
/// mapping runs — the `expired_token` refresh and `grant_revoked` teardown.
String? errorCodeOf(TraciveHttpResponse response) {
  final body = decodeJsonObject(response.body);
  if (body == null) return null;
  final error = body['error'];
  if (error is String) return error.trim().toLowerCase();
  if (error is Map) {
    final code = error['code'];
    if (code is String) return code.trim().toLowerCase();
  }
  return null;
}

/// The `Retry-After` value on [response], for 429s.
///
/// Only the delta-seconds form is read. The HTTP-date form yields `null`
/// rather than a wrong answer: parsing it correctly needs `dart:io`'s
/// `HttpDate`, which does not exist on web, and a locale-sensitive hand-rolled
/// parser would be worse than admitting ignorance. A `null` here means "back
/// off on your own schedule", which is what a caller should do anyway.
Duration? retryAfterOf(TraciveHttpResponse response) =>
    TraciveRateLimitedException.parseRetryAfter(response.header('retry-after'));

/// Maps a non-2xx [response] to the typed error from the error-code table.
///
/// Total: every input produces a `TraciveException`, never a throw.
TraciveException mapErrorResponse(TraciveHttpResponse response) =>
    TraciveException.fromErrorBody(
      response.statusCode,
      decodeJsonBody(response.body),
      retryAfter: retryAfterOf(response),
    );

/// Maps a token-endpoint failure.
///
/// OAuth 2.0 token endpoints answer with RFC 6749 §5.2's envelope —
/// `{"error":"invalid_grant","error_description":"…"}` — which is a *flat*
/// object, not the API's nested `{"error":{"code":…}}`. Both shapes are
/// accepted here so that a server which answers either way still maps to a
/// typed error.
///
/// `invalid_grant` on a refresh is the shape refresh-token reuse detection
/// takes on the wire, so it is mapped to [TraciveGrantRevokedException] — the
/// case that clears local tokens and does **not** retry.
TraciveException mapTokenErrorResponse(TraciveHttpResponse response) {
  final body = decodeJsonObject(response.body);
  final rawError = body?['error'];

  // Nested envelope: hand it to the error-code table unchanged.
  if (rawError is Map) return mapErrorResponse(response);

  final code = rawError is String ? rawError.trim().toLowerCase() : null;
  final description = body?['error_description'];
  final message = description is String && description.trim().isNotEmpty
      ? description.trim()
      : null;

  switch (code) {
    case 'invalid_grant':
    case 'grant_revoked':
      return TraciveGrantRevokedException(
        message ?? 'The Tracive user revoked this grant, or it expired',
        code: code,
        statusCode: response.statusCode,
      );
    case 'expired_token':
      return TraciveExpiredTokenException(
        message ?? 'The token has expired',
        code: code,
        statusCode: response.statusCode,
      );
    case 'invalid_token':
      return TraciveInvalidTokenException(
        message ?? 'The token was rejected',
        code: code,
        statusCode: response.statusCode,
      );
    case 'invalid_scope':
      return TraciveMissingScopeException(
        message ?? 'The requested scope was refused',
        code: code,
        statusCode: response.statusCode,
      );
  }

  return TraciveException.fromApiError(
    statusCode: response.statusCode,
    code: code,
    message: message,
    retryAfter: retryAfterOf(response),
  );
}

/// Wraps a transport-level failure as `TraciveException.Network(cause)`.
///
/// Passes an already-typed [TraciveException] through untouched, so a
/// custom transport that speaks the SDK's error types is not double-wrapped.
TraciveException asTraciveException(Object error, StackTrace stackTrace) =>
    error is TraciveException
        ? error
        : TraciveNetworkException(error, stackTrace);
