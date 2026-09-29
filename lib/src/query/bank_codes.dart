// Copyright 2026 PT Pleistocent Teknologi Nusantara.
// Licensed under the Apache License, Version 2.0.
//
// A partner's own bank identifier -> Tracive's bank code, per ISO 3166-1
// alpha-3 country: the `BANK_SHORT_CODE` and `BANK_BIC` rules of
// `test/fixtures/query-grammar-vectors.json`.
//
// The server translates a national bank code (`014`) or a BIC (`CENAIDJA`) to
// the bank code (`BCA`) before it builds `BANK_<country>_<bankCode>_<account>`.
// This does the same on the device, from the same table, because that key is
// also the local cache key: keyed on the untranslated code, a check could never
// hit the cache and every one would be billed.

import 'dart:convert';

import 'bank_codes_json.dart';
import 'js_string.dart';
import 'normalizer.dart';

final RegExp _asciiDigits = RegExp(r'^[0-9]+$');
final RegExp _leadingZeros = RegExp(r'^0+(?=[0-9])');
final RegExp _bicPattern = RegExp(
  r'^[A-Z]{4}[A-Z]{2}[A-Z0-9]{2}([A-Z0-9]{3})?$',
);

const int _dot = 0x2E;
const int _hyphen = 0x2D;

/// The embedded bank-code table.
///
/// A top-level variable is initialised on first read, so neither importing the
/// SDK nor creating a client parses it: the first bank-code lookup does, once.
final BankCodeTable bankCodeTable = BankCodeTable.parse(bankCodesJson);

/// `bank-codes.json`, parsed into hash maps keyed by alpha-3 country.
///
/// Dart maps have no inherited members, so a code such as `constructor` or
/// `__proto__` is an ordinary miss — the case a plain JavaScript object gets
/// wrong.
final class BankCodeTable {
  BankCodeTable._(this.shortCode, this.bareShortCode, this.bic);

  /// Parses [json], which has the shape of `bank-codes.json`.
  factory BankCodeTable.parse(String json) {
    final root = jsonDecode(json) as Map<String, Object?>;
    final countries = root['countries']! as Map<String, Object?>;
    final shortCode = <String, Map<String, String>>{};
    final bareShortCode = <String, Map<String, String>>{};
    final bic = <String, Map<String, String>>{};
    for (final MapEntry(key: country, value: raw) in countries.entries) {
      final codes = raw! as Map<String, Object?>;
      final short = _stringMap(codes['shortCode']);
      shortCode[country] = short;
      bic[country] = _stringMap(codes['bic']);
      // bank_codes_test.dart proves no two all-digit codes of one country
      // collide once stripped, so iteration order never picks between banks.
      bareShortCode[country] =
          Map<String, String>.unmodifiable(<String, String>{
        for (final MapEntry(:key, :value) in short.entries)
          if (_asciiDigits.hasMatch(key)) stripLeadingZeros(key): value,
      });
    }
    return BankCodeTable._(
      Map<String, Map<String, String>>.unmodifiable(shortCode),
      Map<String, Map<String, String>>.unmodifiable(bareShortCode),
      Map<String, Map<String, String>>.unmodifiable(bic),
    );
  }

  /// Country -> national bank code, as [foldBankShortCode] folds it -> bank
  /// code.
  final Map<String, Map<String, String>> shortCode;

  /// The all-digit entries of [shortCode] only, keyed by [stripLeadingZeros].
  final Map<String, Map<String, String>> bareShortCode;

  /// Country -> 8-character BIC -> bank code.
  final Map<String, Map<String, String>> bic;

  static Map<String, String> _stringMap(Object? json) =>
      Map<String, String>.unmodifiable(<String, String>{
        for (final MapEntry(:key, :value)
            in (json! as Map<String, Object?>).entries)
          key: value! as String,
      });
}

/// Tracive's bank code for the national bank code [raw] in [country], or
/// `null` when the table does not list it.
///
/// [country] must already be folded to upper-case alpha-3.
String? bankCodeByShortCode(String country, String raw) {
  final code = foldBankShortCode(raw);
  final exact = bankCodeTable.shortCode[country]?[code];
  if (exact != null) return exact;
  // National codes are fixed-width (`014`), but a partner that stores them as
  // numbers sends `14`.
  if (!_asciiDigits.hasMatch(code)) return null;
  return bankCodeTable.bareShortCode[country]?[stripLeadingZeros(code)];
}

/// Tracive's bank code for the 8- or 11-character BIC [raw] in [country], or
/// `null` when it is malformed or the table does not list it for [country].
///
/// [country] must already be folded to upper-case alpha-3.
String? bankCodeByBic(String country, String raw) {
  final bic = foldBic(raw);
  return bic == null ? null : bankCodeTable.bic[country]?[bic];
}

/// A national bank code folded the way the table stores it: NFC, JavaScript
/// uppercase, then every JavaScript `\s` character, `.` and `-` removed — the
/// server's `replace(/[\s.-]/g, "")`.
String foldBankShortCode(String raw) =>
    _removeCodeUnits(_nfcUpper(raw), (unit) => unit == _dot || unit == _hyphen);

/// A BIC folded to the 8-character institution part the table stores: NFC,
/// JavaScript uppercase, every JavaScript `\s` character removed, then checked
/// against `^[A-Z]{4}[A-Z]{2}[A-Z0-9]{2}([A-Z0-9]{3})?$`. `null` when it is not
/// a BIC.
///
/// `.` and `-` are not removed here, unlike [foldBankShortCode]: the server
/// does not remove them from a BIC either, so `CENA-IDJA` is malformed.
String? foldBic(String raw) {
  final bic = _removeCodeUnits(_nfcUpper(raw), (_) => false);
  return _bicPattern.hasMatch(bic) ? bic.substring(0, 8) : null;
}

/// `digits.replace(/^0+(?=\d)/, "")`: the last digit always stays, so `000`
/// becomes `0`.
String stripLeadingZeros(String digits) =>
    digits.replaceFirst(_leadingZeros, '');

String _nfcUpper(String raw) => jsToUpperCase(TraciveNormalization.fold(raw));

/// Removes [jsWhitespace] and whatever else [alsoRemove] names. Filtering code
/// units is safe: no removed character is a surrogate half.
String _removeCodeUnits(String value, bool Function(int unit) alsoRemove) =>
    String.fromCharCodes(
      value.codeUnits.where(
        (unit) => !jsWhitespace.contains(unit) && !alsoRemove(unit),
      ),
    );
