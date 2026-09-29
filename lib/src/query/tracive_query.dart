// Copyright 2026 PT Pleistocent Teknologi Nusantara.
// Licensed under the Apache License, Version 2.0.
//
// Query builders and the string-folding grammar.
//
// The folding rules below are transcribed from the `rules` block of
// `test/fixtures/query-grammar-vectors.json`, which is vendored verbatim into
// every SDK repo and is the anti-drift contract. If you change a fold here,
// you are changing the contract: the fixture (and the Kotlin and Swift SDKs,
// and the backend) must change with it. `test/query_grammar_test.dart` fails
// loudly if this file and the fixture disagree.
//
// Why fold client-side at all, when the server folds caller-supplied keys on
// the read path? Because the folded key is *also* the local cache key. An
// unfolded key would split one entity into several cache entries, and every
// extra entry is a paid server round trip.

import '../exception.dart';
import 'bank_codes.dart';
import 'document_id.dart';
import 'js_string.dart';
import 'normalizer.dart';
import 'query_type.dart';

/// E.164: `+`, a non-zero country digit, then 6–14 more digits.
final RegExp _e164Pattern = RegExp(r'^\+[1-9]\d{6,14}$');

/// ISO 3166-1 alpha-3 shape.
final RegExp _alpha3Pattern = RegExp(r'^[A-Z]{3}$');

/// An EVM address, the only crypto address family that is case-folded.
final RegExp _evmAddressPattern = RegExp(r'^0x[0-9a-fA-F]{40}$');

/// Everything that is not an ASCII digit.
final RegExp _nonDigitPattern = RegExp(r'[^0-9]');

/// Whitespace plus the ASCII hyphen — the `/[\s-]/` the server strips
/// from an account number.
///
/// Built from [jsWhitespace] rather than written as `[\s-]` so that this class
/// and [jsTrim] can never disagree: they are the same 25 code points, from one
/// source. Dart's `\s` happens to match ECMAScript's today, but "happens to" is
/// not a contract, and this fold decides whether a key hits or is billed as a
/// miss.
final RegExp _whitespaceOrHyphenPattern = RegExp(
  '[-${jsWhitespace.map(_regExpEscape).join()}]',
);

/// Renders a code point as a `\uXXXX` escape for use inside a character class.
/// Every member of [jsWhitespace] is in the BMP, so four hex digits suffice.
String _regExpEscape(int codePoint) =>
    '\\u${codePoint.toRadixString(16).padLeft(4, '0')}';

/// A checked, folded lookup key.
///
/// Build one with a factory below; each folds its input to the exact string the
/// API indexes and exposes it as [searchQueryIndex]. Construction either
/// yields a key that *could* match, or throws [TraciveQueryException] — it
/// never yields a key that is guaranteed to miss, because a miss is billed.
///
/// PRIVACY: [searchQueryIndex] contains the raw identifier by construction.
/// Never log it. [toString] is redacted for exactly this reason, and the cache
/// stores `SHA-256(searchQueryIndex)` rather than the key itself.
class TraciveQuery {
  const TraciveQuery._(this.type, this.searchQueryIndex);

  /// Which input family this key belongs to.
  final QueryType type;

  /// The folded key: what goes on the wire as `query`, and what the cache key
  /// is derived from.
  final String searchQueryIndex;

  /// A phone number in E.164 form, e.g. `+6281234567891`.
  ///
  /// Fold: strip every character that is not an ASCII digit, preserving a
  /// single leading `+`. Formatting — spaces, dashes, dots, parentheses —
  /// collapses away, so every printed form of one number yields one key.
  ///
  /// Throws `not_e164` if the result is not `^\+[1-9]\d{6,14}$`. A local-format
  /// number (`081234567891`) is **rejected, not up-converted**: the server
  /// cannot know the dial code at that layer either, so a local number would
  /// silently become a different entity — and the miss would still be billed.
  factory TraciveQuery.phone(String e164) {
    // Trim first: the '+' must be leading once surrounding whitespace is gone.
    final trimmed = jsTrim(e164);
    final hasPlus = trimmed.startsWith('+');
    final digits = trimmed.replaceAll(_nonDigitPattern, '');
    final folded = hasPlus ? '+$digits' : digits;
    if (!_e164Pattern.hasMatch(folded)) {
      // The message carries no example number on purpose: anything that looks
      // like a phone number in a log line is indistinguishable from the user's
      // own, and gets treated as personal data by whoever reads the log.
      throw const TraciveQueryException(
        QueryRejectionReason.notE164,
        message: 'Phone number must be E.164: a leading "+", a non-zero '
            'country digit, then six to fourteen more digits',
      );
    }
    return _build(QueryType.phone, 'PHONE_$folded');
  }

  /// An e-mail address.
  ///
  /// Fold: Unicode NFC, then lowercase, then trim — in that order, which is
  /// the order the API folds an e-mail address in.
  ///
  /// Throws `not_an_email` if the folded value contains no `@`. The server
  /// applies **no** shape validation to an e-mail — `EMAIL_budi` is a legal
  /// record key, so it is looked up, missed, and billed — which makes this
  /// check the only thing standing between a typo and a charge, exactly as
  /// [TraciveQuery.phone]'s E.164 check is.
  ///
  /// The check is deliberately an `@`-presence test and **not** an address
  /// grammar. Over-validating is the worse failure: `budi@localhost` and
  /// `budi@[192.168.0.1]` are keys the server would match, and a stricter
  /// client would lock the caller out of a lookup that works.
  ///
  /// See [DefaultNormalizer] for the exact NFC guarantees this SDK ships with;
  /// Dart has no core-library NFC.
  factory TraciveQuery.email(String value) {
    final folded = jsTrim(jsToLowerCase(_nfc(value)));
    // Order matters: '' contains no '@' either, so the empty check has to run
    // first or an empty address would report `not_an_email` and contradict the
    // fixture's `email-empty` vector.
    if (folded.isEmpty) {
      throw const TraciveQueryException(
        QueryRejectionReason.emptyValue,
        message: 'E-mail address is empty',
      );
    }
    if (!folded.contains('@')) {
      // The message carries no example address, for the same reason the phone
      // message carries no example number: anything address-shaped in a log
      // line is treated as personal data by whoever reads the log.
      throw const TraciveQueryException(
        QueryRejectionReason.notAnEmail,
        message: 'E-mail address must contain "@"',
      );
    }
    return _build(QueryType.email, 'EMAIL_$folded');
  }

  /// A domestic bank account: ISO 3166-1 **alpha-3** country, bank code, and
  /// account number.
  ///
  /// Fold: country uppercased and trimmed (and required to be alpha-3); bank
  /// code NFC → uppercase → trim → underscores removed (the key is split on
  /// `_`, so an underscore in the code would corrupt the parse); account number
  /// uppercased, then whitespace and ASCII hyphens removed, so `3242-4242-422`
  /// and `32424242422` are one account.
  ///
  /// Alpha-2 is rejected (`country_not_alpha3`) rather than up-converted. The
  /// server would up-convert it, which is precisely the problem: the local
  /// cache key would no longer match the key the server used.
  factory TraciveQuery.bankAccount({
    required String countryAlpha3,
    required String bankCode,
    required String account,
  }) {
    final country = _foldCountry(countryAlpha3);
    final code = jsTrim(jsToUpperCase(_nfc(bankCode))).replaceAll('_', '');
    if (code.isEmpty) {
      throw const TraciveQueryException(
        QueryRejectionReason.emptyBankCode,
        message: 'Bank code is empty',
      );
    }
    final accountId = _foldAccountId(account);
    if (accountId.isEmpty) {
      throw const TraciveQueryException(
        QueryRejectionReason.emptyAccountId,
        message: 'Account id is empty',
      );
    }
    return _build(QueryType.bank, 'BANK_${country}_${code}_$accountId');
  }

  /// A domestic bank account, with the bank named by its national bank code —
  /// `014` for BCA in Indonesia — rather than by Tracive's bank code.
  ///
  /// The code is translated to Tracive's bank code through a table shipped
  /// inside the SDK, offline, so this builds exactly the key
  /// [TraciveQuery.bankAccount] builds for that bank: `IDN` + `014` and `IDN` +
  /// `BCA` are one key and share cache entries. Case, whitespace, `.` and `-`
  /// are ignored, and leading zeros are optional, so `14` finds `014`.
  /// [countryAlpha3] and [account] fold exactly as in
  /// [TraciveQuery.bankAccount].
  ///
  /// The country is checked first (`country_not_alpha3`). Throws
  /// `unknown_bank_code` when the table does not list the code for that
  /// country: no key built from it could hit, and a miss is billed.
  factory TraciveQuery.bankAccountByShortCode({
    required String countryAlpha3,
    required String bankShortCode,
    required String account,
  }) {
    final country = _foldCountry(countryAlpha3);
    final bankCode = bankCodeByShortCode(country, bankShortCode);
    if (bankCode == null) {
      throw const TraciveQueryException(
        QueryRejectionReason.unknownBankCode,
        message: 'Bank short code is not one Tracive lists for this country',
      );
    }
    return TraciveQuery.bankAccount(
      countryAlpha3: country,
      bankCode: bankCode,
      account: account,
    );
  }

  /// A domestic bank account, with the bank named by its BIC — `CENAIDJA` or
  /// `CENAIDJAXXX` for BCA — rather than by Tracive's bank code.
  ///
  /// Translated like [TraciveQuery.bankAccountByShortCode], from the same
  /// table, so this builds the key [TraciveQuery.bankAccount] builds for that
  /// bank. An 11-character BIC is looked up by its first 8 (the branch is
  /// ignored), within [countryAlpha3] only; case and whitespace are ignored.
  ///
  /// The country is checked first (`country_not_alpha3`). Throws
  /// `unknown_bank_code` when the BIC is malformed or the table does not list
  /// it for that country.
  factory TraciveQuery.bankAccountByBic({
    required String countryAlpha3,
    required String bic,
    required String account,
  }) {
    final country = _foldCountry(countryAlpha3);
    final bankCode = bankCodeByBic(country, bic);
    if (bankCode == null) {
      throw const TraciveQueryException(
        QueryRejectionReason.unknownBankCode,
        message: 'BIC is malformed or not one Tracive lists for this country',
      );
    }
    return TraciveQuery.bankAccount(
      countryAlpha3: country,
      bankCode: bankCode,
      account: account,
    );
  }

  /// An IBAN. Its country is embedded in the IBAN itself, so no country
  /// argument is taken and the key carries the literal segment `IBAN`.
  ///
  /// Fold: uppercase, **then** remove whitespace and ASCII hyphens (that order
  /// is what the server does), so the printed four-character groups collapse.
  /// NFC is deliberately not applied — an IBAN is ASCII by definition.
  factory TraciveQuery.iban(String iban) {
    final accountId = _foldAccountId(iban);
    if (accountId.isEmpty) {
      throw const TraciveQueryException(
        QueryRejectionReason.emptyAccountId,
        message: 'IBAN is empty',
      );
    }
    return _build(QueryType.bank, 'BANK_IBAN_$accountId');
  }

  /// A crypto address on a named chain (`ETH`, `BTC`, `TRX`, …).
  ///
  /// Fold: chain NFC → uppercase → trim. Address trimmed, and lowercased **if
  /// and only if** it is an EVM address (`^0x[0-9a-fA-F]{40}$`) — EIP-55
  /// checksum casing is presentational. Base58 (BTC, TRX, SOL) and bech32
  /// addresses are left exactly as given: Base58 is case-*sensitive*, so
  /// folding it would produce a different, invalid address.
  factory TraciveQuery.crypto({
    required String chain,
    required String address,
  }) {
    final foldedChain = jsTrim(jsToUpperCase(_nfc(chain)));
    if (foldedChain.isEmpty) {
      throw const TraciveQueryException(
        QueryRejectionReason.emptyChain,
        message: 'Crypto chain is empty',
      );
    }
    var foldedAddress = jsTrim(address);
    if (_evmAddressPattern.hasMatch(foldedAddress)) {
      foldedAddress = jsToLowerCase(foldedAddress);
    }
    if (foldedAddress.isEmpty) {
      // `empty_address` rather than the generic `empty_value` it used to be: a
      // caller has to know which of the two fields to put the error next to,
      // and `CRYPTO_ETH_` can only miss - which is billed.
      throw const TraciveQueryException(
        QueryRejectionReason.emptyAddress,
        message: 'Crypto address is empty',
      );
    }
    return _build(QueryType.crypto, 'CRYPTO_${foldedChain}_$foldedAddress');
  }

  /// A social handle on a named platform (`INSTAGRAM`, `TIKTOK`, …).
  ///
  /// Fold: platform NFC → uppercase → trim; handle NFC → lowercase → trim.
  ///
  /// A leading `@` is **kept**. The server does not strip it, so stripping it
  /// here would build a key that misses every report filed with the `@`.
  /// Underscores inside the handle survive too: the key is split on the first
  /// underscore after the platform only.
  factory TraciveQuery.username({
    required String platform,
    required String handle,
  }) {
    final foldedPlatform = jsTrim(jsToUpperCase(_nfc(platform)));
    if (foldedPlatform.isEmpty) {
      // `empty_platform` rather than the generic `empty_value` it used to be,
      // for the same reason `crypto()` names its address: `USERNAME__budi`
      // cannot match any stored key, and the miss is billed.
      throw const TraciveQueryException(
        QueryRejectionReason.emptyPlatform,
        message: 'Username platform is empty',
      );
    }
    final foldedHandle = jsTrim(jsToLowerCase(_nfc(handle)));
    if (foldedHandle.isEmpty) {
      throw const TraciveQueryException(
        QueryRejectionReason.emptyHandle,
        message: 'Username handle is empty',
      );
    }
    return _build(
      QueryType.username,
      'USERNAME_${foldedPlatform}_$foldedHandle',
    );
  }

  /// Uppercase first, then strip whitespace and ASCII hyphens. Shared by
  /// [TraciveQuery.bankAccount] and [TraciveQuery.iban]; NFC is not applied.
  static String _foldAccountId(String raw) =>
      jsToUpperCase(raw).replaceAll(_whitespaceOrHyphenPattern, '');

  static String _foldCountry(String countryAlpha3) {
    final country = jsTrim(jsToUpperCase(countryAlpha3));
    if (!_alpha3Pattern.hasMatch(country)) {
      throw const TraciveQueryException(
        QueryRejectionReason.countryNotAlpha3,
        message: 'Country must be an ISO 3166-1 alpha-3 code (three letters)',
      );
    }
    return country;
  }

  static String _nfc(String raw) => TraciveNormalization.fold(raw);

  static TraciveQuery _build(QueryType type, String key) {
    validateDocumentId(key);
    return TraciveQuery._(type, key);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TraciveQuery &&
          other.type == type &&
          other.searchQueryIndex == searchQueryIndex;

  @override
  int get hashCode => Object.hash(type, searchQueryIndex);

  /// Redacted on purpose: [searchQueryIndex] is a raw identifier, and this
  /// value ends up in logs and crash reports.
  @override
  String toString() =>
      'TraciveQuery(${type.wireValue}, ${searchQueryIndex.length} chars, '
      'value redacted)';
}
