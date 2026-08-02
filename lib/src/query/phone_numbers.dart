// Copyright (c) Tracive. Licensed under the Apache License, Version 2.0.

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
  if (phoneNumber.trimLeft().startsWith('+') && !digits.startsWith(dialCode)) {
    throw const TraciveQueryException(QueryRejectionReason.countryConflict);
  }

  if (digits.startsWith('00$dialCode')) {
    digits = digits.substring(2 + dialCode.length);
  } else if (digits.startsWith(dialCode)) {
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
    // North America: trunk prefix 1, local numbers are 10 digits.
    case '1':
      if (digits.startsWith('1') && digits.length == 11) {
        digits = digits.substring(1);
      }
    // Everywhere else, including Indonesia, the UK and Germany: trunk prefix 0.
    default:
      digits = _withoutLeadingZeros(digits);
  }

  if (digits.isEmpty) {
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
  final String trimmed = countryOrDialCode.trim();
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
