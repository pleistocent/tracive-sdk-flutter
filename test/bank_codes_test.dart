// Copyright 2026 PT Pleistocent Teknologi Nusantara.
// Licensed under the Apache License, Version 2.0.
//
// The embedded bank-code table, and the builders that name a bank by its
// national bank code or BIC. The vendored vectors run in
// `query_grammar_test.dart`; this covers what they leave out.

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tracive_sdk/tracive_sdk.dart';
// Internal on purpose, like `document_id.dart` in the grammar test: the table
// and its folds are an invariant of key construction, not public surface.
import 'package:tracive_sdk/src/query/bank_codes.dart';
import 'package:tracive_sdk/src/query/bank_codes_json.dart';

void main() {
  setUp(TraciveNormalization.resetForTesting);

  String byShortCode(
    String country,
    String code, {
    String account = '1234567890',
  }) =>
      TraciveQuery.bankAccountByShortCode(
        countryAlpha3: country,
        bankShortCode: code,
        account: account,
      ).searchQueryIndex;

  String byBic(String country, String bic, {String account = '1234567890'}) =>
      TraciveQuery.bankAccountByBic(
        countryAlpha3: country,
        bic: bic,
        account: account,
      ).searchQueryIndex;

  String byBankCode(String country, String bankCode) =>
      TraciveQuery.bankAccount(
        countryAlpha3: country,
        bankCode: bankCode,
        account: '1234567890',
      ).searchQueryIndex;

  Matcher rejectedWith(String reason) => throwsA(
        isA<TraciveQueryException>().having((e) => e.reason, 'reason', reason),
      );

  group('the embedded table', () {
    test('is the vendored file, byte for byte', () {
      final vendored = _readVendoredTable();
      expect(
        utf8.encode(bankCodesJson),
        vendored,
        reason: 'bank_codes_json.dart differs from test/fixtures/'
            'bank-codes.json. Run `dart run tool/embed_bank_codes.dart`; never '
            'edit either by hand.',
      );
    });

    test('holds every entry of the file once parsed', () {
      // Compared against the file, not the constant, so a parse that dropped a
      // country or a code - which would reject real codes as unknown - fails.
      final file =
          jsonDecode(utf8.decode(_readVendoredTable())) as Map<String, Object?>;
      final countries = file['countries']! as Map<String, Object?>;
      expect(countries, isNotEmpty);
      expect(bankCodeTable.shortCode.keys.toSet(), countries.keys.toSet());
      expect(bankCodeTable.bic.keys.toSet(), countries.keys.toSet());
      for (final MapEntry(key: country, value: codes) in countries.entries) {
        final both = codes! as Map<String, Object?>;
        expect(
          bankCodeTable.shortCode[country],
          both['shortCode'],
          reason: country,
        );
        expect(bankCodeTable.bic[country], both['bic'], reason: country);
      }
    });

    test('every listed code builds the key its bank code builds', () {
      var checked = 0;
      for (final MapEntry(key: country, value: codes)
          in bankCodeTable.shortCode.entries) {
        for (final MapEntry(key: code, value: bankCode) in codes.entries) {
          expect(foldBankShortCode(code), code, reason: '$country $code');
          expect(byShortCode(country, code), byBankCode(country, bankCode));
          checked++;
        }
      }
      for (final MapEntry(key: country, value: codes)
          in bankCodeTable.bic.entries) {
        for (final MapEntry(key: bic, value: bankCode) in codes.entries) {
          expect(foldBic(bic), bic, reason: '$country $bic');
          expect(byBic(country, bic), byBankCode(country, bankCode));
          checked++;
        }
      }
      expect(checked, greaterThan(0), reason: 'an empty table proves nothing');
    });

    test('no two all-digit codes collide once their leading zeros are gone',
        () {
      for (final MapEntry(key: country, value: codes)
          in bankCodeTable.shortCode.entries) {
        final seen = <String, String>{};
        for (final MapEntry(key: code, value: bankCode) in codes.entries) {
          if (!RegExp(r'^[0-9]+$').hasMatch(code)) continue;
          final bare = stripLeadingZeros(code);
          expect(
            seen[bare] ?? bankCode,
            bankCode,
            reason: '$country: two banks share the short code $bare',
          );
          seen[bare] = bankCode;
        }
        expect(bankCodeTable.bareShortCode[country], seen, reason: country);
      }
    });
  });

  group('lookups that must miss', () {
    const inherited = <String>[
      'constructor',
      '__proto__',
      'toString',
      'hasOwnProperty',
      'valueOf',
      'prototype',
    ];

    test('a JavaScript prototype member name is a miss, not a bank', () {
      // The builders uppercase the code before the lookup, so the lowercase
      // names only reach the maps directly - which is where a plain JavaScript
      // object would have answered from its prototype.
      for (final name in inherited) {
        expect(bankCodeTable.shortCode[name], isNull, reason: name);
        expect(bankCodeTable.bic[name], isNull, reason: name);
        expect(bankCodeTable.shortCode['IDN']![name], isNull, reason: name);
        expect(bankCodeTable.bareShortCode['IDN']![name], isNull, reason: name);
        expect(bankCodeTable.bic['IDN']![name], isNull, reason: name);
        expect(bankCodeByShortCode(name, '014'), isNull, reason: name);
        expect(bankCodeByBic(name, 'CENAIDJA'), isNull, reason: name);
        expect(
          () => byShortCode('IDN', name),
          rejectedWith(QueryRejectionReason.unknownBankCode),
          reason: name,
        );
        expect(
          () => byBic('IDN', name),
          rejectedWith(QueryRejectionReason.unknownBankCode),
          reason: name,
        );
      }
    });

    test('a country the table does not list is a miss', () {
      expect(
        () => byShortCode('XXX', '014'),
        rejectedWith(QueryRejectionReason.unknownBankCode),
      );
      expect(
        () => byBic('XXX', 'CENAIDJA'),
        rejectedWith(QueryRejectionReason.unknownBankCode),
      );
    });
  });

  group('leading zeros', () {
    test('are optional on either side', () {
      // Listed as 014.
      expect(byShortCode('IDN', '14'), 'BANK_IDN_BCA_1234567890');
      expect(byShortCode('IDN', '00014'), 'BANK_IDN_BCA_1234567890');
      // Listed as 143, with no leading zero.
      expect(byShortCode('ARG', '0143'), 'BANK_ARG_BRUBANK_1234567890');
      // Separators go before the digits check, so this is the exact code 014.
      expect(byShortCode('IDN', '0-1.4'), 'BANK_IDN_BCA_1234567890');
    });

    test('removal keeps the last digit', () {
      expect(stripLeadingZeros('000'), '0');
      expect(stripLeadingZeros('0'), '0');
      expect(stripLeadingZeros('014'), '14');
      expect(stripLeadingZeros('0100'), '100');
      expect(stripLeadingZeros('140'), '140');
    });

    test('are kept on a code that is not all ASCII digits', () {
      expect(byShortCode('NPL', 'HBL'), 'BANK_NPL_HIMALAYAN_1234567890');
      expect(
        () => byShortCode('NPL', '0HBL'),
        rejectedWith(QueryRejectionReason.unknownBankCode),
      );
      // Arabic-Indic digits are not ASCII digits: neither stripped nor matched.
      expect(
        () => byShortCode('IDN', '٠١٤'),
        rejectedWith(QueryRejectionReason.unknownBankCode),
      );
    });
  });

  group('JavaScript semantics, not Dart', () {
    test('whitespace is the JavaScript \\s class', () {
      // U+000B and U+FEFF are JavaScript \s, so both are removed.
      expect(
        byShortCode('IDN', '\u000B0 14﻿'),
        'BANK_IDN_BCA_1234567890',
      );
      expect(
        byBic('IDN', '﻿CENA IDJA\u000BXXX'),
        'BANK_IDN_BCA_1234567890',
      );
      // U+200B and U+0085 are not: they stay, and the code misses. Dart's own
      // trim() strips U+0085, so a fold built on it would accept the code.
      expect('014\u0085'.trim(), '014');
      for (final stray in <String>['​', '\u0085']) {
        expect(
          () => byShortCode('IDN', '014$stray'),
          rejectedWith(QueryRejectionReason.unknownBankCode),
          reason: 'U+${stray.codeUnitAt(0).toRadixString(16)}',
        );
        expect(
          () => byBic('IDN', 'CENAIDJA$stray'),
          rejectedWith(QueryRejectionReason.unknownBankCode),
          reason: 'U+${stray.codeUnitAt(0).toRadixString(16)}',
        );
      }
    });

    test('the fold is NFC, then full JavaScript uppercase', () {
      // Dart's own toUpperCase leaves U+00DF alone; JavaScript's yields SS.
      expect('ß'.toUpperCase(), 'ß');
      expect(foldBankShortCode('ß.-x'), 'SSX');
      // 'A' + U+0301 composes to U+00C1 before it is uppercased.
      expect(foldBankShortCode('á'), 'Á');
      expect(foldBic('cena idja'), 'CENAIDJA');
    });
  });

  group('BIC shape', () {
    test('is 8 or 11 characters of the right class', () {
      expect(byBic('IDN', 'CENAIDJA123'), 'BANK_IDN_BCA_1234567890');
      // Digits are legal from the seventh character on: well-formed, unlisted.
      expect(foldBic('CENAID1A'), 'CENAID1A');
      const malformed = <String>[
        'CENAIDJ', // 7
        'CENAIDJAX', // 9
        'CENAIDJAXX', // 10
        'CENAIDJAXXXX', // 12
        'CEN4IDJA', // a digit in the bank part
        'CENA1DJA', // a digit in the country part
        'CENA-IDJA', // '-' is not removed from a BIC
        'CENA.IDJA',
        '',
      ];
      for (final bic in malformed) {
        expect(foldBic(bic), isNull, reason: bic);
        expect(
          () => byBic('IDN', bic),
          rejectedWith(QueryRejectionReason.unknownBankCode),
          reason: bic,
        );
      }
    });
  });

  group('order of rejections', () {
    test('country, then code, then account', () {
      expect(
        () => byShortCode('ID', '999'),
        rejectedWith(QueryRejectionReason.countryNotAlpha3),
      );
      expect(
        () => byBic('ID', 'CENA'),
        rejectedWith(QueryRejectionReason.countryNotAlpha3),
      );
      expect(
        () => byShortCode('IDN', '999', account: ' '),
        rejectedWith(QueryRejectionReason.unknownBankCode),
      );
      expect(
        () => byBic('IDN', 'CENA', account: ' '),
        rejectedWith(QueryRejectionReason.unknownBankCode),
      );
      expect(
        () => byShortCode('IDN', '014', account: ' '),
        rejectedWith(QueryRejectionReason.emptyAccountId),
      );
      expect(
        () => byBic('IDN', 'CENAIDJA', account: ' '),
        rejectedWith(QueryRejectionReason.emptyAccountId),
      );
    });

    test('the reason is the wire spelling', () {
      expect(QueryRejectionReason.unknownBankCode, 'unknown_bank_code');
      expect(QueryRejectionReason.values, contains('unknown_bank_code'));
    });
  });
}

/// Reads the vendored table, tolerating either the package root or `test/` as
/// the working directory.
List<int> _readVendoredTable() {
  for (final path in <String>[
    'test/fixtures/bank-codes.json',
    'fixtures/bank-codes.json',
  ]) {
    final file = File(path);
    if (file.existsSync()) return file.readAsBytesSync();
  }
  throw StateError('Could not find test/fixtures/bank-codes.json.');
}
