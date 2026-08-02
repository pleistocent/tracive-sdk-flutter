// Copyright (c) Tracive. Licensed under the Apache License, Version 2.0.
//
// Error surface for the Tracive SDK — ("Error mapping").
//
// PACKAGING NOTE (for whoever owns pubspec.yaml): this file depends on nothing
// outside dart:core. It does use Dart 3 class modifiers (`sealed`, `final
// class`), so the package must declare `environment: sdk: ^3.0.0` (or newer).
//
// Naming: the cross-SDK contract writes the error cases in Kotlin
// sealed-subclass form
// (`TraciveException.NotImplemented`). Dart has no nested class names and a
// package must not squat on bare identifiers like `Server` or `Network`, so
// each case is rendered as `Tracive<Case>Exception`. The mapping is 1:1 and is
// spelled out here so a reader can check it against the other SDKs:
//
//   InvalidRequest            -> TraciveInvalidRequestException
//   UnsupportedInputType      -> TraciveUnsupportedInputTypeException
//   UnsupportedCreditSource   -> TraciveUnsupportedCreditSourceException
//   InvalidToken              -> TraciveInvalidTokenException
//   ExpiredToken              -> TraciveExpiredTokenException
//   GrantRevoked              -> TraciveGrantRevokedException
//   InvalidApiKey             -> TraciveInvalidApiKeyException
//   InsufficientCredits(which)-> TraciveInsufficientCreditsException(which)
//   MissingScope              -> TraciveMissingScopeException
//   DetailNotPermitted        -> TraciveDetailNotPermittedException
//   CredentialMismatch        -> TraciveCredentialMismatchException
//   PartnerSuspended          -> TracivePartnerSuspendedException
//   IdempotencyConflict       -> TraciveIdempotencyConflictException
//   RateLimited(retryAfter)   -> TraciveRateLimitedException(retryAfter)
//   Network(cause)            -> TraciveNetworkException(cause)
//   Server(status, code?)     -> TraciveServerException(statusCode, code)
//   NotImplemented(message)   -> TraciveNotImplementedException
//   CacheMiss                 -> TraciveCacheMissException
//   stateMismatch             -> TraciveStateMismatchException
//   (unrecognised code)       -> TraciveUnknownException(code)
//
// PRIVACY: no constructor here ever takes a raw identifier (phone / account /
// e-mail) or a token, and no `toString()` prints one.
//
// That second promise needs a mechanism, not just care, because a message is
// not always this SDK's: `fromApiError` puts the server's own `error.message`
// on the exception, and an `invalid_request` that echoes the offending query
// would carry an identifier this SDK never chose to handle. Such a message is
// marked `messageFromServer`, kept on `.message` for a caller who wants it, and
// left out of `toString()` — which is the thing that reaches crash reports.

/// Base type for every error the Tracive SDK raises.
///
/// Sealed so a `switch` over the concrete cases can be checked exhaustively by
/// the analyser. Callers who only want "did the call fail" can catch this type.
sealed class TraciveException implements Exception {
  const TraciveException(
    this.message, {
    this.code,
    this.statusCode,
    this.checkId,
    this.messageFromServer = false,
  });

  /// Human-readable description.
  ///
  /// When [messageFromServer] is `false` this is a sentence written in this
  /// SDK, and it contains no raw identifier and no token. When it is `true`,
  /// the text came off the wire and this SDK cannot make that promise about
  /// it — which is why [toString] leaves it out.
  final String message;

  /// Whether [message] is the server's own `error.message` rather than one of
  /// this SDK's.
  ///
  /// Server text is useful and is kept, but it is not this SDK's to vouch for:
  /// an `invalid_request` that echoes the offending query would put a phone
  /// number or a bank account into [message], and [toString] lands in crash
  /// reports and log aggregators. So the text stays reachable on [message] for
  /// a caller who deliberately wants it, and stays out of [toString].
  final bool messageFromServer;

  /// The wire `error.code` when this error came from the API, else `null`.
  final String? code;

  /// The HTTP status this error was mapped from, when applicable.
  final int? statusCode;

  /// `error.checkId` from the response envelope, useful for support tickets.
  final String? checkId;

  /// Whether retrying the very same call could plausibly succeed.
  ///
  /// Note: a `checkScammer` retry is only safe with an `Idempotency-Key`;
  /// this flag says "the failure is transient", not "retrying is free".
  bool get isRetryable => false;

  /// Spec-shaped shorthand for `TraciveException.NotImplemented(message)`.
  const factory TraciveException.notImplemented(String message) =
      TraciveNotImplementedException;

  /// Spec-shaped shorthand for `TraciveException.Network(cause)`.
  factory TraciveException.network(Object cause, [StackTrace? stackTrace]) =
      TraciveNetworkException;

  /// A diagnostic line safe to put in a log or a crash report.
  ///
  /// Deliberately omits [message] when [messageFromServer] is `true`. This SDK
  /// controls every message it writes and none of them carries an identifier;
  /// it controls none of the server's, and an `invalid_request` that echoes the
  /// offending query would put a phone number or a bank account into every
  /// crash report the app ever files. The type, the code, the status and the
  /// `checkId` are what a reader needs to act, and all four are this SDK's or
  /// the protocol's rather than free text.
  @override
  String toString() {
    final buffer = StringBuffer(runtimeType.toString());
    if (!messageFromServer) {
      buffer
        ..write(': ')
        ..write(message);
    }
    if (code != null) buffer.write(' (code: $code)');
    if (statusCode != null) buffer.write(' (http: $statusCode)');
    if (checkId != null) buffer.write(' (checkId: $checkId)');
    if (messageFromServer) buffer.write(' (server message omitted)');
    return buffer.toString();
  }

  /// Maps an API error envelope (`{"error":{"code","message","checkId"}}`) to a
  /// typed exception, per the error-code table.
  ///
  /// An unrecognised `code` never throws and never crashes: 5xx becomes
  /// [TraciveServerException] and anything else [TraciveUnknownException], both
  /// carrying the raw code so a caller can still branch on it.
  static TraciveException fromApiError({
    required int statusCode,
    String? code,
    String? message,
    String? checkId,
    Duration? retryAfter,
  }) {
    final normalizedCode = code?.trim().toLowerCase();
    // Whether the sentence below is the server's or this SDK's. It decides
    // whether `toString()` may print it — see
    // [TraciveException.messageFromServer].
    final fromServer = message != null && message.trim().isNotEmpty;
    final text = fromServer
        ? message.trim()
        : _defaultMessageFor(statusCode, normalizedCode);

    switch (normalizedCode) {
      case 'invalid_request':
        return TraciveInvalidRequestException(
          text,
          code: normalizedCode,
          statusCode: statusCode,
          checkId: checkId,
          messageFromServer: fromServer,
        );
      case 'unsupported_input_type':
        return TraciveUnsupportedInputTypeException(
          text,
          code: normalizedCode,
          statusCode: statusCode,
          checkId: checkId,
          messageFromServer: fromServer,
        );
      case 'unsupported_credit_source':
        return TraciveUnsupportedCreditSourceException(
          text,
          code: normalizedCode,
          statusCode: statusCode,
          checkId: checkId,
          messageFromServer: fromServer,
        );
      case 'invalid_token':
        return TraciveInvalidTokenException(
          text,
          code: normalizedCode,
          statusCode: statusCode,
          checkId: checkId,
          messageFromServer: fromServer,
        );
      case 'expired_token':
        return TraciveExpiredTokenException(
          text,
          code: normalizedCode,
          statusCode: statusCode,
          checkId: checkId,
          messageFromServer: fromServer,
        );
      case 'grant_revoked':
        return TraciveGrantRevokedException(
          text,
          code: normalizedCode,
          statusCode: statusCode,
          checkId: checkId,
          messageFromServer: fromServer,
        );
      case 'invalid_api_key':
        return TraciveInvalidApiKeyException(
          text,
          code: normalizedCode,
          statusCode: statusCode,
          checkId: checkId,
          messageFromServer: fromServer,
        );
      case 'insufficient_user_credits':
        return TraciveInsufficientCreditsException(
          InsufficientCreditsKind.user,
          message: text,
          statusCode: statusCode,
          checkId: checkId,
          messageFromServer: fromServer,
        );
      case 'insufficient_credits':
        return TraciveInsufficientCreditsException(
          InsufficientCreditsKind.account,
          message: text,
          statusCode: statusCode,
          checkId: checkId,
          messageFromServer: fromServer,
        );
      case 'insufficient_partner_balance':
        return TraciveInsufficientCreditsException(
          InsufficientCreditsKind.partnerBalance,
          message: text,
          statusCode: statusCode,
          checkId: checkId,
          messageFromServer: fromServer,
        );
      case 'missing_scope':
        return TraciveMissingScopeException(
          text,
          code: normalizedCode,
          statusCode: statusCode,
          checkId: checkId,
          messageFromServer: fromServer,
        );
      case 'detail_not_permitted':
        return TraciveDetailNotPermittedException(
          text,
          code: normalizedCode,
          statusCode: statusCode,
          checkId: checkId,
          messageFromServer: fromServer,
        );
      case 'credential_mismatch':
        return TraciveCredentialMismatchException(
          text,
          code: normalizedCode,
          statusCode: statusCode,
          checkId: checkId,
          messageFromServer: fromServer,
        );
      case 'partner_suspended':
        return TracivePartnerSuspendedException(
          text,
          code: normalizedCode,
          statusCode: statusCode,
          checkId: checkId,
          messageFromServer: fromServer,
        );
      case 'idempotency_conflict':
        return TraciveIdempotencyConflictException(
          text,
          code: normalizedCode,
          statusCode: statusCode,
          checkId: checkId,
          messageFromServer: fromServer,
        );
      case 'rate_limited':
        return TraciveRateLimitedException(
          retryAfter: retryAfter,
          message: text,
          statusCode: statusCode,
          checkId: checkId,
          messageFromServer: fromServer,
        );
    }

    // Unrecognised (or absent) code: fall back on the status class. Never crash
    // — a phase 2 server may invent codes this build has never heard of.
    if (statusCode >= 500) {
      return TraciveServerException(
        statusCode: statusCode,
        code: normalizedCode,
        message: text,
        checkId: checkId,
        messageFromServer: fromServer,
      );
    }
    if (statusCode == 429) {
      return TraciveRateLimitedException(
        retryAfter: retryAfter,
        message: text,
        statusCode: statusCode,
        checkId: checkId,
        messageFromServer: fromServer,
      );
    }
    return TraciveUnknownException(
      text,
      code: normalizedCode,
      statusCode: statusCode,
      checkId: checkId,
    );
  }

  /// Convenience wrapper over [fromApiError] that digs `code`/`message`/
  /// `checkId` out of a decoded JSON body. Tolerates a missing or malformed
  /// envelope (a proxy returning HTML, an empty 502, …).
  static TraciveException fromErrorBody(
    int statusCode,
    Object? body, {
    Duration? retryAfter,
  }) {
    String? code;
    String? message;
    String? checkId;
    if (body is Map) {
      final error = body['error'];
      if (error is Map) {
        final rawCode = error['code'];
        final rawMessage = error['message'];
        final rawCheckId = error['checkId'];
        if (rawCode is String) code = rawCode;
        if (rawMessage is String) message = rawMessage;
        if (rawCheckId is String) checkId = rawCheckId;
      } else if (error is String) {
        code = error;
      }
    }
    return fromApiError(
      statusCode: statusCode,
      code: code,
      message: message,
      checkId: checkId,
      retryAfter: retryAfter,
    );
  }

  static String _defaultMessageFor(int statusCode, String? code) {
    if (code != null && code.isNotEmpty) return 'Request failed: $code';
    return 'Request failed with HTTP $statusCode';
  }
}

/// 400 `invalid_request`.
final class TraciveInvalidRequestException extends TraciveException {
  /// Creates the exception from a decoded error envelope: [message],
  /// [code], [statusCode] and [checkId] all come off the wire.
  const TraciveInvalidRequestException(
    super.message, {
    super.code,
    super.statusCode,
    super.checkId,
    super.messageFromServer,
  });
}

/// 400 `unsupported_input_type` — the server does not index this input type.
///
/// The most likely cause is a key this SDK cannot build (there is deliberately
/// no `domain()` builder; see [TraciveQueryException]).
final class TraciveUnsupportedInputTypeException extends TraciveException {
  /// Creates the exception from a decoded error envelope: [message],
  /// [code], [statusCode] and [checkId] all come off the wire.
  const TraciveUnsupportedInputTypeException(
    super.message, {
    super.code,
    super.statusCode,
    super.checkId,
    super.messageFromServer,
  });
}

/// 400 `unsupported_credit_source`.
final class TraciveUnsupportedCreditSourceException extends TraciveException {
  /// Creates the exception from a decoded error envelope: [message],
  /// [code], [statusCode] and [checkId] all come off the wire.
  const TraciveUnsupportedCreditSourceException(
    super.message, {
    super.code,
    super.statusCode,
    super.checkId,
    super.messageFromServer,
  });
}

/// 401 `invalid_token`.
final class TraciveInvalidTokenException extends TraciveException {
  /// Creates the exception from a decoded error envelope: [message],
  /// [code], [statusCode] and [checkId] all come off the wire.
  const TraciveInvalidTokenException(
    super.message, {
    super.code,
    super.statusCode,
    super.checkId,
    super.messageFromServer,
  });
}

/// 401 `expired_token` — triggers the single-flight refresh. Callers
/// normally never see this: the client refreshes and replays the request once.
final class TraciveExpiredTokenException extends TraciveException {
  /// Creates the exception from a decoded error envelope: [message],
  /// [code], [statusCode] and [checkId] all come off the wire.
  const TraciveExpiredTokenException(
    super.message, {
    super.code,
    super.statusCode,
    super.checkId,
    super.messageFromServer,
  });

  @override
  bool get isRetryable => true;
}

/// 401 `grant_revoked` — stored tokens must be cleared and the user re-consents.
/// **Do not retry**: retrying is what trips refresh-token reuse detection.
final class TraciveGrantRevokedException extends TraciveException {
  /// Creates the exception from a decoded error envelope: [message],
  /// [code], [statusCode] and [checkId] all come off the wire.
  const TraciveGrantRevokedException(
    super.message, {
    super.code,
    super.statusCode,
    super.checkId,
    super.messageFromServer,
  });
}

/// 401 `invalid_api_key`.
///
/// This SDK never sends an API key — there is no API-key parameter anywhere in
/// the public surface, by design. The case exists only so that a
/// server that emits this code (for example behind a partner proxy that adds
/// its own credentials) maps to something typed instead of "unknown".
final class TraciveInvalidApiKeyException extends TraciveException {
  /// Creates the exception from a decoded error envelope: [message],
  /// [code], [statusCode] and [checkId] all come off the wire.
  const TraciveInvalidApiKeyException(
    super.message, {
    super.code,
    super.statusCode,
    super.checkId,
    super.messageFromServer,
  });
}

/// Which balance ran out, for [TraciveInsufficientCreditsException].
enum InsufficientCreditsKind {
  /// `insufficient_user_credits` — the end user's own credit balance.
  user('insufficient_user_credits'),

  /// `insufficient_credits` — the generic/unattributed balance.
  account('insufficient_credits'),

  /// `insufficient_partner_balance` — the partner's prepaid balance.
  partnerBalance('insufficient_partner_balance');

  const InsufficientCreditsKind(this.wireCode);

  /// The `error.code` this kind is decoded from.
  final String wireCode;
}

/// 402 — a credit balance was exhausted.
///
/// Handle *this* instead of polling `credits()` before every check; it
/// saves one round trip per transaction.
final class TraciveInsufficientCreditsException extends TraciveException {
  /// Creates the exception for the [which] balance the server reported
  /// exhausted. The default message names that balance, never an amount.
  TraciveInsufficientCreditsException(
    this.which, {
    String? message,
    int? statusCode = 402,
    super.checkId,
    super.messageFromServer,
  }) : super(
          message ?? 'Insufficient credits (${which.wireCode})',
          code: which.wireCode,
          statusCode: statusCode,
        );

  /// Which balance was insufficient.
  final InsufficientCreditsKind which;
}

/// 403 `missing_scope`.
final class TraciveMissingScopeException extends TraciveException {
  /// Creates the exception from a decoded error envelope: [message],
  /// [code], [statusCode] and [checkId] all come off the wire.
  const TraciveMissingScopeException(
    super.message, {
    super.code,
    super.statusCode,
    super.checkId,
    super.messageFromServer,
    this.requiredScope,
  });

  /// The scope the server said was missing, when it named one.
  final String? requiredScope;
}

/// 403 `detail_not_permitted` — this grant may not request `detail = full`.
final class TraciveDetailNotPermittedException extends TraciveException {
  /// Creates the exception from a decoded error envelope: [message],
  /// [code], [statusCode] and [checkId] all come off the wire.
  const TraciveDetailNotPermittedException(
    super.message, {
    super.code,
    super.statusCode,
    super.checkId,
    super.messageFromServer,
  });
}

/// 403 `credential_mismatch`.
final class TraciveCredentialMismatchException extends TraciveException {
  /// Creates the exception from a decoded error envelope: [message],
  /// [code], [statusCode] and [checkId] all come off the wire.
  const TraciveCredentialMismatchException(
    super.message, {
    super.code,
    super.statusCode,
    super.checkId,
    super.messageFromServer,
  });
}

/// 403 `partner_suspended`.
final class TracivePartnerSuspendedException extends TraciveException {
  /// Creates the exception from a decoded error envelope: [message],
  /// [code], [statusCode] and [checkId] all come off the wire.
  const TracivePartnerSuspendedException(
    super.message, {
    super.code,
    super.statusCode,
    super.checkId,
    super.messageFromServer,
  });
}

/// 409 `idempotency_conflict` — the same `Idempotency-Key` was replayed with a
/// different body.
final class TraciveIdempotencyConflictException extends TraciveException {
  /// Creates the exception from a decoded error envelope: [message],
  /// [code], [statusCode] and [checkId] all come off the wire.
  const TraciveIdempotencyConflictException(
    super.message, {
    super.code,
    super.statusCode,
    super.checkId,
    super.messageFromServer,
  });
}

/// 429 `rate_limited`.
final class TraciveRateLimitedException extends TraciveException {
  /// Creates the exception. [retryAfter] carries the server's `Retry-After`
  /// header when it sent one; the request is retryable either way.
  const TraciveRateLimitedException({
    this.retryAfter,
    String message = 'Rate limited',
    int? statusCode = 429,
    super.checkId,
    bool messageFromServer = false,
  }) : super(message,
            code: 'rate_limited',
            statusCode: statusCode,
            messageFromServer: messageFromServer);

  /// Value of the `Retry-After` response header, when the server sent one.
  final Duration? retryAfter;

  @override
  bool get isRetryable => true;

  /// Parses a `Retry-After` header value.
  ///
  /// Only the delta-seconds form is understood; the HTTP-date form returns
  /// `null` (the caller should then fall back on its own backoff). Returns
  /// `null` for anything unparsable rather than throwing.
  static Duration? parseRetryAfter(String? headerValue) {
    if (headerValue == null) return null;
    final seconds = int.tryParse(headerValue.trim());
    if (seconds == null || seconds < 0) return null;
    return Duration(seconds: seconds);
  }
}

/// Transport failure — DNS, TLS, socket, timeout. No HTTP response was parsed.
final class TraciveNetworkException extends TraciveException {
  /// Wraps the transport-level [cause] that stopped the request before any
  /// HTTP response existed. [stackTrace] is kept when the transport gave one.
  TraciveNetworkException(this.cause, [this.stackTrace])
      : super('Network failure: $cause');

  /// The underlying transport error.
  final Object cause;

  /// Stack trace of [cause], when the transport supplied one.
  final StackTrace? stackTrace;

  @override
  bool get isRetryable => true;
}

/// 5xx, or any unrecognised server-side failure.
final class TraciveServerException extends TraciveException {
  /// Creates the exception for a 5xx or otherwise unrecognised failure.
  /// [statusCode] is required because it is the only thing that classifies it.
  const TraciveServerException({
    required int statusCode,
    String? code,
    String message = 'Server error',
    String? checkId,
    bool messageFromServer = false,
  }) : super(message,
            code: code,
            statusCode: statusCode,
            checkId: checkId,
            messageFromServer: messageFromServer);

  @override
  bool get isRetryable => true;
}

/// An error code this build does not recognise. Carries the raw `code` so the
/// caller can still branch on it. Never thrown for a code in the error-code
/// table.
final class TraciveUnknownException extends TraciveException {
  /// Creates the exception from a decoded error envelope: [message],
  /// [code], [statusCode] and [checkId] all come off the wire.
  const TraciveUnknownException(
    super.message, {
    super.code,
    super.statusCode,
    super.checkId,
    super.messageFromServer,
  });
}

/// Raised where a surface exists but the behaviour lands in a later release.
///
/// The only such place in phase 1 is Proxy mode: `TraciveMode.proxy(...)` is
/// accepted by the constructor so that adding it in phase 2 is not a breaking
/// change, but every call made in that mode throws this.
final class TraciveNotImplementedException extends TraciveException {
  /// Creates the exception with [message] — the exact sentence the contract
  /// requires for the surface that is not live yet.
  const TraciveNotImplementedException(super.message);
}

/// `source: Source.cache` found no live entry.
///
/// A cache-only lookup must fail loudly rather than return a silent empty
/// result that reads as "not a scammer".
final class TraciveCacheMissException extends TraciveException {
  /// Creates the exception. The default message deliberately names no
  /// identifier, because this value reaches logs.
  const TraciveCacheMissException([super.message = 'No cached result']);
}

/// The `state` parameter on the OAuth redirect did not match the one this SDK
/// generated. Treated as a hostile redirect: the code is discarded.
final class TraciveStateMismatchException extends TraciveException {
  /// Creates the exception. The message never quotes either `state` value.
  const TraciveStateMismatchException([
    super.message = 'OAuth state mismatch; the redirect was discarded',
  ]);
}

/// The reason strings carried by [TraciveQueryException].
///
/// These are the exact `reason` values in `test/fixtures/query-grammar-vectors
/// .json`; they are part of the cross-SDK contract, so they are constants
/// rather than an enum (the wire form must stay byte-identical).
abstract final class QueryRejectionReason {
  /// The phone number is not E.164 after folding (`^\+[1-9]\d{6,14}$`).
  static const String notE164 = 'not_e164';

  /// The bank country is not an ISO 3166-1 alpha-3 code.
  static const String countryNotAlpha3 = 'country_not_alpha3';

  /// A country or dial code with no letters and no digits was given to
  /// [normalizePhoneNumber].
  static const String emptyCountry = 'empty_country';

  /// Something that looks like a country code but names no country. An alpha-2
  /// code such as `ID` lands here: this SDK uses alpha-3 everywhere.
  static const String unknownCountry = 'unknown_country';

  /// The phone number has no digits, or was only a trunk prefix.
  static const String emptyPhoneNumber = 'empty_phone_number';

  /// The number carries a `+` whose dial code disagrees with the country named.
  /// Both cannot be right, and guessing would produce a key that can never
  /// match — billed as a miss.
  static const String countryConflict = 'country_conflict';

  /// The account id folded to the empty string.
  static const String emptyAccountId = 'empty_account_id';

  /// The bank code folded to the empty string.
  static const String emptyBankCode = 'empty_bank_code';

  /// The e-mail address folded to the empty string.
  ///
  /// The generic spelling is historical: it is the fixture's reason for the
  /// `email-empty` vector and is a wire string, so it stays. Every other empty
  /// field names itself — [emptyAccountId], [emptyBankCode], [emptyChain],
  /// [emptyAddress], [emptyPlatform], [emptyHandle].
  static const String emptyValue = 'empty_value';

  /// The e-mail address contains no `@`.
  ///
  /// Deliberately an `@`-presence check and not an address grammar: the server
  /// applies no shape validation at all, so anything stricter would reject a
  /// key the server would have matched.
  static const String notAnEmail = 'not_an_email';

  /// The username handle folded to the empty string.
  static const String emptyHandle = 'empty_handle';

  /// The crypto chain folded to the empty string.
  static const String emptyChain = 'empty_chain';

  /// The crypto address folded to the empty string.
  static const String emptyAddress = 'empty_address';

  /// The username platform folded to the empty string.
  static const String emptyPlatform = 'empty_platform';

  /// The built key is not a legal record key.
  static const String invalidDocumentId = 'invalid_document_id';

  /// Every reason string, for tests and exhaustiveness checks.
  static const List<String> values = <String>[
    notE164,
    countryNotAlpha3,
    emptyAccountId,
    emptyBankCode,
    emptyValue,
    notAnEmail,
    emptyHandle,
    emptyChain,
    emptyAddress,
    emptyPlatform,
    invalidDocumentId,
    emptyCountry,
    unknownCountry,
    emptyPhoneNumber,
    countryConflict,
  ];
}

/// Thrown by the `TraciveQuery` builders for input that cannot produce a key
/// the backend could ever match.
///
/// Validation runs **before** any network call: a key that cannot hit is still
/// billed as a miss, so it must never leave the device.
///
/// [reason] is one of [QueryRejectionReason]'s constants — identical across the
/// Kotlin, Flutter and Swift SDKs.
///
/// PRIVACY: the offending input is deliberately **not** stored on, or printed
/// by, this exception. A phone number or e-mail address in an exception message
/// ends up in crash reports and logs.
final class TraciveQueryException extends TraciveException {
  /// Creates the exception for [reason].
  ///
  /// PRIVACY: [message] must never contain the rejected input — it is a raw
  /// phone number, e-mail address or account number, and it ends up in logs.
  const TraciveQueryException(this.reason, {String? message})
      : super(message ?? 'Invalid query input: $reason', code: reason);

  /// The stable, cross-SDK rejection reason.
  final String reason;

  @override
  String toString() => 'TraciveQueryException($reason): $message';
}
