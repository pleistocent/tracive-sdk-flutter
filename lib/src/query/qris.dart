// Copyright 2026 PT Pleistocent Teknologi Nusantara.
// Licensed under the Apache License, Version 2.0.
//
// The QRIS half of the query grammar: the `QRIS_PAYLOAD`, `QRIS_NMID` and
// `QRIS_PAN` rules of `test/fixtures/query-grammar-vectors.json`, and only the
// parts of a QRIS payload that decide its key. Not exported: the public surface
// is `TraciveQuery.qris`, `qrisNmid` and `qrisPan`.

import 'dart:convert';

import '../exception.dart';
import 'js_string.dart';

// Exactly tab, LF, CR, space and U+00A0. Not `\s` and not `jsTrim`: both strip
// more (U+2003, U+200B is not even in `\s`), and the vectors pin this set.
final RegExp _spaceRun = RegExp('[\t\n\r  ]+');
final RegExp _edgeSpaces = RegExp('^[\t\n\r  ]+|[\t\n\r  ]+\$');

final RegExp _nmidPattern = RegExp(r'^ID[0-9]{13}$');
final RegExp _twoDigits = RegExp(r'^[0-9]{2}$');
final RegExp _eighteenDigits = RegExp(r'^[0-9]{18}$');
final RegExp _nineteenDigits = RegExp(r'^[0-9]{19}$');

const List<String> _criteria = <String>['UMI', 'UKE', 'UME', 'UBE'];

// Micro and small businesses only: no other QRIS is ever indexed, so a check
// on one could only be a billed miss.
const List<String> _indexedCriteria = <String>['UMI', 'UKE'];

/// The NMID a QRIS sticker prints, or `null` when [raw] is not one.
String? normalizeNmid(String raw) {
  final nmid = jsToUpperCase(raw.replaceAll(_spaceRun, ''));
  return _nmidPattern.hasMatch(nmid) ? nmid : null;
}

/// The 18-digit merchant PAN, or `null` when [raw] is not one. A 19-digit value
/// is a receipt's PAN plus its Luhn digit, folded only when that digit checks.
String? normalizePan(String raw) {
  final digits = raw.replaceAll(_spaceRun, '');
  if (_eighteenDigits.hasMatch(digits)) return digits;
  if (_nineteenDigits.hasMatch(digits) && _luhnValid(digits)) {
    return digits.substring(0, 18);
  }
  return null;
}

/// The NMID a QRIS payload is indexed under.
///
/// Throws [TraciveQueryException] with, in this order: `not_a_qris`,
/// `qris_crc_mismatch`, `qris_no_nmid`, `qris_not_indexed`.
String nmidOfPayload(String raw) {
  final payload = raw.replaceAll(_edgeSpaces, '');
  if (!payload.startsWith('000201')) throw _notAQris;

  final tlv = _readTlv(payload);
  if (tlv == null) throw _notAQris;
  final (lastTag, lastValue) = tlv.last;
  if (lastTag != '63' || lastValue.length != 4) throw _notAQris;
  final signed = payload.substring(0, payload.length - 4);
  if (qrisCrc(signed) != jsToUpperCase(lastValue)) {
    throw const TraciveQueryException(
      QueryRejectionReason.qrisCrcMismatch,
      message: 'QRIS payload fails its CRC: the QR was edited or misread',
    );
  }

  final top = _firstByTag(tlv);
  final national = _subTags(top['51']);
  final nmidField = national['02'];
  final nmid = nmidField == null ? null : normalizeNmid(nmidField);
  if (nmid == null) {
    throw const TraciveQueryException(
      QueryRejectionReason.qrisNoNmid,
      message: 'QRIS payload carries no NMID',
    );
  }

  final criteria = _criteriaOf(national['03']) ?? _acquirerCriteria(top);
  if (!_indexedCriteria.contains(criteria)) {
    throw const TraciveQueryException(
      QueryRejectionReason.qrisNotIndexed,
      message: 'Only QRIS of micro and small businesses (UMI, UKE) are in '
          "Tracive's reports",
    );
  }
  return nmid;
}

/// CRC-16/CCITT-FALSE (poly 0x1021, init 0xFFFF) as four upper-case hex
/// digits.
///
/// Over the UTF-8 bytes, while every TLV length counts UTF-16 code units: the
/// two disagree on any non-ASCII merchant name, and the vectors carry one.
String qrisCrc(String data) {
  var crc = 0xFFFF;
  for (final byte in utf8.encode(data)) {
    crc ^= byte << 8;
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc & 0x8000) != 0
          ? ((crc << 1) ^ 0x1021) & 0xFFFF
          : (crc << 1) & 0xFFFF;
    }
  }
  return crc.toRadixString(16).toUpperCase().padLeft(4, '0');
}

const TraciveQueryException _notAQris = TraciveQueryException(
  QueryRejectionReason.notAQris,
  message: 'Not a QRIS payload',
);

bool _luhnValid(String digits) {
  var sum = 0;
  for (var i = 0; i < digits.length; i++) {
    var digit = digits.codeUnitAt(digits.length - 1 - i) - 0x30;
    if (i.isOdd) {
      digit *= 2;
      if (digit > 9) digit -= 9;
    }
    sum += digit;
  }
  return sum % 10 == 0;
}

/// Tag, two-digit length, value; `null` when the framing breaks. Indices and
/// lengths are UTF-16 code units, which is what a Dart `String` counts in.
List<(String, String)>? _readTlv(String data) {
  final out = <(String, String)>[];
  var i = 0;
  while (i < data.length) {
    if (i + 4 > data.length) return null;
    final tag = data.substring(i, i + 2);
    final length = data.substring(i + 2, i + 4);
    if (!_twoDigits.hasMatch(tag) || !_twoDigits.hasMatch(length)) return null;
    final end = i + 4 + int.parse(length);
    if (end > data.length) return null;
    out.add((tag, data.substring(i + 4, end)));
    i = end;
  }
  return out;
}

/// A repeated tag keeps its first value.
Map<String, String> _firstByTag(List<(String, String)> tlv) {
  final map = <String, String>{};
  for (final (tag, value) in tlv) {
    map.putIfAbsent(tag, () => value);
  }
  return map;
}

/// A template whose value is not TLV inside reads as having no sub-tags.
Map<String, String> _subTags(String? value) =>
    _firstByTag(value == null ? const [] : _readTlv(value) ?? const []);

String? _criteriaOf(String? value) {
  if (value == null) return null;
  final upper = jsToUpperCase(value);
  return _criteria.contains(upper) ? upper : null;
}

/// Sub-tag 03 of the first merchant account template, in tag order (26–45),
/// that has a sub-tag 00.
String? _acquirerCriteria(Map<String, String> top) {
  for (var tag = 26; tag <= 45; tag++) {
    final value = top['$tag'];
    if (value == null) continue;
    final sub = _subTags(value);
    if (sub.containsKey('00')) return _criteriaOf(sub['03']);
  }
  return null;
}
