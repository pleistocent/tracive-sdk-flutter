// Copyright 2026 PT Pleistocent Teknologi Nusantara.
// Licensed under the Apache License, Version 2.0.

/// The input types the Tracive API indexes.
///
/// The names mirror the `type` field of
/// `test/fixtures/query-grammar-vectors.json`. Both bank flavours (country+code
/// and IBAN) are [bank]; they differ only in the shape of the key.
///
/// A class with constant instances rather than an enum, so that the next type
/// the API indexes is not a breaking change. A `switch` over an enum must name
/// every member and stops compiling when one is added; a `switch` over this
/// class needs a default branch from the start, so a new constant falls into
/// it. Compare with `==` or match the constants in a `switch`, exactly as
/// before.
///
/// There is no `domain` member. A `DOMAIN_…` key could not match anything,
/// because the API indexes no such type — and a miss is still billed. The
/// fixture's `notImplemented` block records this, and the grammar test asserts
/// that this class keeps agreeing with it.
final class QueryType {
  const QueryType._(this.wireValue);

  /// `PHONE_<e164>`
  static const QueryType phone = QueryType._('PHONE');

  /// `EMAIL_<address>`
  static const QueryType email = QueryType._('EMAIL');

  /// `BANK_<country>_<bankCode>_<accountId>` or `BANK_IBAN_<accountId>`
  static const QueryType bank = QueryType._('BANK');

  /// `CRYPTO_<chain>_<address>`
  static const QueryType crypto = QueryType._('CRYPTO');

  /// `USERNAME_<platform>_<handle>`
  static const QueryType username = QueryType._('USERNAME');

  /// `QRIS_<NMID>` or `QRIS_<PAN>`
  static const QueryType qris = QueryType._('QRIS');

  /// Every type this build knows, in the order above.
  static const List<QueryType> values = <QueryType>[
    phone,
    email,
    bank,
    crypto,
    username,
    qris,
  ];

  /// The uppercase prefix this type contributes to `searchQueryIndex`.
  final String wireValue;

  /// Decodes [wireValue] case-insensitively; `null` for anything unknown
  /// (forward compatibility — a later server may index more types).
  static QueryType? fromWire(String? value) {
    if (value == null) return null;
    final needle = value.trim().toUpperCase();
    for (final type in values) {
      if (type.wireValue == needle) return type;
    }
    return null;
  }

  @override
  String toString() => 'QueryType($wireValue)';
}
