// Copyright 2026 PT Pleistocent Teknologi Nusantara.
// Licensed under the Apache License, Version 2.0.

import '../exception.dart';
import 'country.dart';

/// Turns a phone number written the way people in a country actually write it
/// into E.164.
///
/// [TraciveQuery.phone] deliberately refuses a local format such as
/// `081234567891`, and says why: the SDK cannot know the caller's dial code, and
/// a wrong guess still costs a credit. This function is where that missing dial
/// code comes from, so the strictness downstream stays intact:
///
/// ```dart
/// TraciveQuery.phone(normalizePhoneNumber('IDN', '0857-1860-9079'));
/// TraciveQuery.phone(normalizePhoneNumber('+62', '0857 1860 9079'));
/// ```
///
/// It is a top-level function on purpose: a partner needs the E.164 form for
/// their own records, logging and outbound messaging, not only for a lookup.
///
/// The rules are a deliberate copy of the Tracive app's normalizer, heuristics
/// included — if the app folded a number one way and this SDK another, one
/// person would become two record keys, and a report filed in the app would be
/// invisible to a check made here. `phone-normalization-vectors.json` pins the
/// agreement and is vendored byte-identically into all four SDK repositories.
///
/// [countryOrDialCode] is an ISO 3166-1 **alpha-3** code (`IDN`, `USA` —
/// case-insensitive) or a dial code with or without `+` (`+62`, `62`). They are
/// told apart by shape: letters mean alpha-3, digits mean a dial code. Alpha-2
/// (`ID`) is refused, because this SDK speaks alpha-3 everywhere.
///
/// Throws [TraciveQueryException] with [QueryRejectionReason.emptyCountry],
/// [QueryRejectionReason.unknownCountry],
/// [QueryRejectionReason.emptyPhoneNumber] or
/// [QueryRejectionReason.countryConflict]. Never returns an empty string.
String normalizePhoneNumber(String countryOrDialCode, String phoneNumber) {
  final String dialCode = _resolveDialCode(countryOrDialCode);
  String digits = _digitsOf(phoneNumber);
  if (digits.isEmpty) {
    throw const TraciveQueryException(QueryRejectionReason.emptyPhoneNumber);
  }

  // A leading `+` is the caller stating "this is already international". If the
  // code that follows disagrees with the country they named, the two arguments
  // contradict each other, and guessing which one is right is exactly what
  // costs a credit: ('IDN', '+64857…') used to yield +626485718609079, a New
  // Zealand number wearing an Indonesian dial code.
  //
  // Three deliberate departures from the Tracive app's normalizer live here, and
  // they are not the same kind of thing. A dial code that disagrees with the
  // country named is safe to reject: every such input produced an unusable key
  // in the app too. `+00<dial>` is not — the app accepts it and folds it
  // correctly, so here the SDK is genuinely stricter. That is the intended
  // trade: `+` and `00` are alternative spellings, not stackable ones; what
  // follows `+` must be a country code, and `00` is none. An earlier version of
  // this comment claimed the first reason covered both.
  //
  // A third, quieter one: emptiness is re-checked *after* the trunk prefix is
  // stripped, so `000`, `62` and `1` are refused. The app folds those to `+62`
  // and `+1`, which cannot match any record, so this belongs with the first
  // kind — safe, not stricter.
  final bool international = _trimLeftCanonically(phoneNumber).startsWith('+');
  if (international && !digits.startsWith(dialCode)) {
    throw const TraciveQueryException(QueryRejectionReason.countryConflict);
  }

  if (digits.startsWith('00$dialCode')) {
    digits = digits.substring(2 + dialCode.length);
  } else if (digits.startsWith(dialCode) &&
      (international || !_isNationalNumber(dialCode, digits))) {
    // Without a `+`, digits that are a national number merely starting with
    // the dial code's own digits keep them (Kazakh 701…).
    digits = digits.substring(dialCode.length);
  }

  switch (dialCode) {
    // Russia and Kazakhstan: trunk prefix 8, local numbers are 10 digits.
    case '7':
      if (digits.startsWith('8') && digits.length == 11) {
        digits = digits.substring(1);
      }
    // Italy and San Marino: the leading 0 IS part of the number for landlines.
    case '39':
    case '378':
      break;
    // Côte d'Ivoire, Benin and the Republic of the Congo have no trunk prefix,
    // and their regulators require the 0 after the country code (+225 07…,
    // +229 01…, +242 06…).
    case '225':
    case '229':
    case '242':
      break;
    // Hungary: the trunk prefix is 06. A national number may start with 6
    // (Szeged is 62), so the pair is dropped, never a 0 and then a 6 on its own.
    case '36':
      if (digits.startsWith('06')) digits = digits.substring(2);
      digits = _withoutLeadingZeros(digits);
    // A trunk 8 (Lithuania's until March 2024, 0 since). Some national numbers
    // start with 8 themselves (Belarusian 801 and Lithuanian 800 freephone,
    // Uzbek 88 mobile), so the 8 goes only when exactly a national number's
    // length follows it.
    case '375':
    case '370':
    case '992':
    case '993':
    case '998':
      if (digits.startsWith('8') &&
          digits.length == _digitsAfterTrunk8[dialCode]! + 1) {
        digits = digits.substring(1);
      }
      digits = _withoutLeadingZeros(digits);
    // North America: trunk prefix 1, local numbers are 10 digits.
    case '1':
      if (digits.startsWith('1') && digits.length == 11) {
        digits = digits.substring(1);
      }
    // Everywhere else, including Indonesia, the UK and Germany: trunk prefix 0.
    default:
      digits = _withoutLeadingZeros(digits);
  }

  // A number that is nothing but zeros is refused here, not left to `phone()`. For most countries the
  // trunk-prefix rule strips the zeros away and the emptiness check above catches it — but Italy, San
  // Marino, Côte d'Ivoire, Benin, the Congo, North America and Russia do not strip leading zeros, so
  // `+390000000` survived, matched E.164, reached the network and was billed for a miss it could
  // only ever be. Refusing it here also makes the reason the same in every country instead of
  // `empty_phone_number` in Indonesia and `not_e164` in Italy for the identical input.
  if (digits.isEmpty || !digits.split('').any((String c) => c != '0')) {
    throw const TraciveQueryException(QueryRejectionReason.emptyPhoneNumber);
  }
  return '+$dialCode$digits';
}

/// Normalizes [phoneNumber] for a known [country].
///
/// Prefer this over the string form when the country is known at compile time:
/// a typo in `'IDN'` is found at run time, a typo in `Country.idn` is not
/// compiled.
String normalizePhoneNumberFor(Country country, String phoneNumber) =>
    normalizePhoneNumber(country.dialCode, phoneNumber);

/// Every length a national number can have, for the dial codes whose national
/// numbers can start with the dial code's own digits (libphonenumber 9.0.42
/// metadata, all number types). The same table as `nationalNumberLengths` in
/// `phone-normalization-vectors.json`, which the tests sweep.
const Map<String, Set<int>> _nationalNumberLengths = <String, Set<int>>{
  '7': <int>{10, 14},
  '20': <int>{8, 9, 10},
  '27': <int>{5, 6, 7, 8, 9, 10},
  '31': <int>{5, 6, 7, 8, 9, 10, 11},
  '32': <int>{8, 9},
  '33': <int>{9},
  '36': <int>{8, 9},
  '39': <int>{6, 7, 8, 9, 10, 11, 12},
  '41': <int>{9, 12},
  '43': <int>{4, 5, 6, 7, 8, 9, 10, 11, 12, 13},
  '45': <int>{8},
  '46': <int>{6, 7, 8, 9, 10, 12},
  '47': <int>{5, 8},
  '48': <int>{6, 7, 8, 9, 10},
  '49': <int>{4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
  '51': <int>{8, 9},
  '53': <int>{6, 7, 8, 10},
  '55': <int>{8, 9, 10, 11},
  '62': <int>{7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17},
  '63': <int>{6, 8, 9, 10, 11, 12, 13},
  '65': <int>{8, 10, 11},
  '66': <int>{8, 9, 10, 13},
  '84': <int>{7, 8, 9, 10},
  '90': <int>{7, 10, 12, 13},
  '91': <int>{8, 9, 10, 11, 12, 13},
  '92': <int>{8, 9, 10, 11, 12},
  '95': <int>{6, 7, 8, 9, 10},
  '213': <int>{8, 9},
  '216': <int>{8},
  '218': <int>{9},
  '220': <int>{7, 9},
  '222': <int>{8},
  '230': <int>{7, 8, 10},
  '231': <int>{7, 8, 9},
  '233': <int>{8, 9},
  '238': <int>{7},
  '241': <int>{7, 8},
  '243': <int>{7, 8, 9, 10},
  '244': <int>{9},
  '247': <int>{5, 6},
  '250': <int>{8, 9},
  '251': <int>{9},
  '252': <int>{6, 7, 8, 9},
  '255': <int>{9},
  '262': <int>{9},
  '266': <int>{8},
  '267': <int>{7, 8, 10},
  '290': <int>{4, 5},
  '298': <int>{6},
  '299': <int>{6},
  '355': <int>{6, 7, 8, 9},
  '358': <int>{5, 6, 7, 8, 9, 10, 11, 12},
  '359': <int>{6, 7, 8, 9, 12},
  '370': <int>{8},
  '373': <int>{8},
  '376': <int>{6, 8, 9},
  '377': <int>{8, 9},
  '379': <int>{6, 7, 8, 9, 10, 11, 12},
  '380': <int>{9, 10},
  '383': <int>{8, 9, 10, 11, 12},
  '386': <int>{5, 6, 7, 8},
  '387': <int>{8, 9},
  '421': <int>{6, 7, 9},
  '500': <int>{5},
  '501': <int>{7, 11},
  '502': <int>{8, 11},
  '503': <int>{7, 8, 11},
  '506': <int>{8, 10},
  '507': <int>{7, 8, 10, 11},
  '508': <int>{6, 9},
  '590': <int>{9},
  '594': <int>{9},
  '596': <int>{9},
  '677': <int>{5, 7},
  '679': <int>{7, 11},
  '680': <int>{7},
  '683': <int>{4, 7},
  '685': <int>{5, 6, 7, 10},
  '850': <int>{8, 10},
  '853': <int>{7, 8},
  '855': <int>{8, 9, 10},
  '886': <int>{7, 8, 9, 10, 11},
  '960': <int>{7, 10},
  '961': <int>{7, 8},
  '962': <int>{8, 9},
  '963': <int>{8, 9},
  '965': <int>{7, 8},
  '968': <int>{7, 8, 9},
  '971': <int>{5, 6, 7, 8, 9, 10, 11, 12},
  '972': <int>{7, 8, 9, 10, 11, 12},
  '973': <int>{8},
  '976': <int>{8, 9, 10},
  '992': <int>{9},
  '994': <int>{9},
  '996': <int>{9, 10},
  '998': <int>{9},
};

/// Digits that start with [dialCode] are a national number when their length
/// is a national length and their length without the dial code is not. When
/// both are (Indonesia's `62812…`, Italy's `393…`), the dial code is stripped as
/// before, so a number typed with its country code never changes key.
bool _isNationalNumber(String dialCode, String digits) {
  final Set<int>? lengths = _nationalNumberLengths[dialCode];
  if (lengths == null) return false;
  return lengths.contains(digits.length) &&
      !lengths.contains(digits.length - dialCode.length);
}

/// Countries whose trunk prefix is 8, with how many digits follow that 8.
/// Belarus counts the 0 it writes after the 8 (`8 029 123 45 67`); the
/// leading-zero strip removes it afterwards. Source: ITU "Dialling procedures"
/// and each country's numbering plan filed with the ITU.
const Map<String, int> _digitsAfterTrunk8 = <String, int>{
  '375': 10, // Belarus
  '370': 8, // Lithuania
  '992': 9, // Tajikistan
  '993': 8, // Turkmenistan
  '998': 9, // Uzbekistan
};

String _digitsOf(String value) {
  final StringBuffer out = StringBuffer();
  for (int i = 0; i < value.length; i++) {
    final int c = value.codeUnitAt(i);
    if (c >= 0x30 && c <= 0x39) out.writeCharCode(c);
  }
  return out.toString();
}

String _withoutLeadingZeros(String value) {
  int i = 0;
  while (i < value.length && value.codeUnitAt(i) == 0x30) {
    i++;
  }
  return value.substring(i);
}

/// Alpha-3 in, dial code out; or digits in, the same digits out.
String _resolveDialCode(String countryOrDialCode) {
  final String trimmed = _trimCanonically(countryOrDialCode);
  if (trimmed.isEmpty) {
    throw const TraciveQueryException(QueryRejectionReason.emptyCountry);
  }

  final String digits = _digitsOf(trimmed);
  if (digits.isNotEmpty) {
    final String stripped = _withoutLeadingZeros(digits);
    if (stripped.isEmpty) {
      throw const TraciveQueryException(QueryRejectionReason.emptyCountry);
    }
    return stripped;
  }

  final Country? country = Country.fromAlpha3(trimmed);
  if (country == null) {
    throw const TraciveQueryException(QueryRejectionReason.unknownCountry);
  }
  return country.dialCode;
}

/// The characters trimmed from a country or dial code, defined here rather than
/// delegated to `String.trim()`.
///
///
/// ASCII whitespace only, and deliberately **not** U+FEFF. A byte-order mark inside a data value is
/// an encoding fault upstream; swallowing it here would tell a partner their pipeline is clean while
/// the same mark waits to land in a phone number or an account id, where nothing trims it and the key
/// comes out wrong. Each platform's own trim() disagrees about this — Kotlin's follows Unicode
/// White_Space plus U+FEFF, JavaScript's strips a different set — which made one input behave two
/// ways across the four SDKs.
const List<int> _trimmedCodeUnits = <int>[0x20, 0x09, 0x0A, 0x0B, 0x0C, 0x0D];

String _trimCanonically(String value) {
  var start = 0;
  var end = value.length;
  while (start < end && _trimmedCodeUnits.contains(value.codeUnitAt(start))) {
    start++;
  }
  while (end > start && _trimmedCodeUnits.contains(value.codeUnitAt(end - 1))) {
    end--;
  }
  return value.substring(start, end);
}

String _trimLeftCanonically(String value) {
  var start = 0;
  while (start < value.length &&
      _trimmedCodeUnits.contains(value.codeUnitAt(start))) {
    start++;
  }
  return value.substring(start);
}
