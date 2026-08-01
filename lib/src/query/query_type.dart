// Copyright (c) Tracive. Licensed under the Apache License, Version 2.0.

/// The five input types the Tracive API actually indexes.
///
/// The names mirror the `type` field of
/// `test/fixtures/query-grammar-vectors.json`. Both bank flavours (country+code
/// and IBAN) are [bank]; they differ only in the shape of the key.
///
/// There is no `domain` member. A `DOMAIN_…` key could not match anything,
/// because the API indexes no such type — and a miss is still billed. The
/// fixture's `notImplemented` block records this, and the grammar test asserts
/// that this enum keeps agreeing with it.
enum QueryType {
  /// `PHONE_<e164>`
  phone('PHONE'),

  /// `EMAIL_<address>`
  email('EMAIL'),

  /// `BANK_<country>_<bankCode>_<accountId>` or `BANK_IBAN_<accountId>`
  bank('BANK'),

  /// `CRYPTO_<chain>_<address>`
  crypto('CRYPTO'),

  /// `USERNAME_<platform>_<handle>`
  username('USERNAME');

  const QueryType(this.wireValue);

  /// The uppercase prefix this type contributes to `searchQueryIndex`.
  final String wireValue;

  /// Decodes [wireValue] case-insensitively; `null` for anything unknown
  /// (forward compatibility — a phase 2 server may index more types).
  static QueryType? fromWire(String? value) {
    if (value == null) return null;
    final needle = value.trim().toUpperCase();
    for (final type in QueryType.values) {
      if (type.wireValue == needle) return type;
    }
    return null;
  }
}
