// Copyright (c) Tracive. Licensed under the Apache License, Version 2.0.
//
// Query builders and the string-folding grammar — the SDK specification §3.
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

/// Whitespace plus the ASCII hyphen — the `/[\s-]/` the Node backend strips
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
/// backend indexes and exposes it as [searchQueryIndex]. Construction either
/// yields a key that *could* match, or throws [TraciveQueryException] — it
/// never yields a key that is guaranteed to miss, because a miss is billed
/// (§3.2).
///
/// PRIVACY: [searchQueryIndex] contains the raw identifier by construction.
/// Never log it. [toString] is redacted for exactly this reason, and the cache
/// stores `SHA-256(searchQueryIndex)` rather than the key itself (§5).
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
  /// Fold: Unicode NFC, then lowercase, then trim — in that order, matching
  /// the server's `normalizeEmailValue`.
  ///
  /// See [DefaultNormalizer] for the exact NFC guarantees this SDK ships with;
  /// Dart has no core-library NFC.
  factory TraciveQuery.email(String value) {
    final folded = jsTrim(jsToLowerCase(_nfc(value)));
    if (folded.isEmpty) {
      throw const TraciveQueryException(
        QueryRejectionReason.emptyValue,
        message: 'E-mail address is empty',
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
    final country = jsTrim(jsToUpperCase(countryAlpha3));
    if (!_alpha3Pattern.hasMatch(country)) {
      throw const TraciveQueryException(
        QueryRejectionReason.countryNotAlpha3,
        message: 'Country must be an ISO 3166-1 alpha-3 code (three letters)',
      );
    }
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
      // Not covered by the fixture (it has no empty-address vector); reusing
      // `empty_value` keeps the reason inside the frozen set of §3 strings.
      throw const TraciveQueryException(
        QueryRejectionReason.emptyValue,
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
      // Not covered by the fixture (it has no empty-platform vector); reusing
      // `empty_value` keeps the reason inside the frozen set of §3 strings.
      throw const TraciveQueryException(
        QueryRejectionReason.emptyValue,
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

  static String _nfc(String raw) => TraciveNormalization.normalizer.nfc(raw);

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
