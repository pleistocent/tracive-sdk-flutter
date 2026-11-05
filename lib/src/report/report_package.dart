// Copyright 2026 PT Pleistocent Teknologi Nusantara.
// Licensed under the Apache License, Version 2.0.
//
// The report package (v1) and the fallback link — the wire contract with the
// Tracive app, pinned by `test/fixtures/report-package-vectors.json`, which is
// vendored byte-identically into every Tracive SDK.
//
// The package is UTF-8 JSON:
//
//   {"v":1,"query":"…","incidentDate":"YYYY-MM-DD","attachments":[
//     {"name":"attachment-1.png","mimeType":"image/png","data":"<base64>"}]}
//
// `incidentDate` is omitted when absent; `data` is standard base64 with
// padding and no line breaks; names are generated from the position and the
// type. The app ignores unknown keys and refuses any `v` but 1, and it checks
// every rule below again on receipt, because any app on the phone can send it a
// package. The SDK checks them first so that nothing is accepted here and then
// silently dropped there.

import 'dart:convert';
import 'dart:typed_data';

import 'report_attachment.dart';
import 'report_form_result.dart';

/// The only package version the app accepts.
const int reportPackageVersion = 1;

/// A PDF must be strictly smaller than this.
const int reportPdfMaxBytesExclusive = 1048576;

/// Attachments per report; [reportMaxAttachmentsPhone] for a phone number.
const int reportMaxAttachments = 5;

/// Attachments per report when the query is a phone number.
const int reportMaxAttachmentsPhone = 10;

/// The cap on the encoded package. The app holds the whole package in memory
/// and enforces the same number.
const int reportPackageMaxBytes = 20971520;

/// Accepted types, canonical spelling, to the extension of the generated name.
const Map<String, String> _extensionByMimeType = <String, String>{
  'image/jpeg': 'jpg',
  'image/png': 'png',
  'image/webp': 'webp',
  'image/heic': 'heic',
  'image/heif': 'heif',
  'image/bmp': 'bmp',
  'application/pdf': 'pdf',
};

const List<String> _heifBrands = <String>[
  'heic',
  'heix',
  'hevc',
  'hevx',
  'heim',
  'heis',
  'mif1',
  'msf1',
];

/// The canonical type for [declared], or `null` when it is not accepted.
///
/// Case-insensitive over ASCII only, and `image/jpg` becomes `image/jpeg`.
/// Nothing is trimmed: the contract names exact types, and a leniency one SDK
/// added alone would accept there what the others refuse.
String? canonicalReportMimeType(String declared) {
  final lower = String.fromCharCodes(
    declared.codeUnits.map((c) => c >= 0x41 && c <= 0x5A ? c + 0x20 : c),
  );
  final canonical = lower == 'image/jpg' ? 'image/jpeg' : lower;
  return _extensionByMimeType.containsKey(canonical) ? canonical : null;
}

/// Whether [bytes] start the way a file of [canonicalMimeType] does.
bool reportBytesMatch(String canonicalMimeType, Uint8List bytes) {
  bool at(int offset, List<int> expected) {
    if (bytes.length < offset + expected.length) return false;
    for (var i = 0; i < expected.length; i++) {
      if (bytes[offset + i] != expected[i]) return false;
    }
    return true;
  }

  return switch (canonicalMimeType) {
    'image/jpeg' => at(0, const <int>[0xFF, 0xD8, 0xFF]),
    'image/png' =>
      at(0, const <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
    'image/webp' => at(0, ascii.encode('RIFF')) && at(8, ascii.encode('WEBP')),
    'image/bmp' => at(0, ascii.encode('BM')),
    'image/heic' || 'image/heif' => at(4, ascii.encode('ftyp')) &&
        _heifBrands.any((brand) => at(8, ascii.encode(brand))),
    'application/pdf' => at(0, ascii.encode('%PDF-')),
    _ => false,
  };
}

/// Either the encoded package or the first rule it broke — never both.
typedef ReportPackageOutcome = ({Uint8List? bytes, ReportFormError? error});

/// Checks every rule, in the contract's order, and encodes the package.
///
/// [query] is a record key (`TraciveQuery.searchQueryIndex`). Only the
/// year, month and day of [incidentDate] and [today] are read, with no time
/// zone conversion: they are calendar dates.
ReportPackageOutcome buildReportPackage({
  required String query,
  required DateTime? incidentDate,
  required List<ReportAttachment> attachments,
  required DateTime today,
}) {
  ReportPackageOutcome fail(ReportFormError error) =>
      (bytes: null, error: error);

  if (incidentDate != null && _dayNumber(incidentDate) > _dayNumber(today)) {
    return fail(const ReportFormIncidentDateInFuture());
  }

  final max = query.startsWith('PHONE_')
      ? reportMaxAttachmentsPhone
      : reportMaxAttachments;
  if (attachments.length > max) return fail(ReportFormTooManyAttachments(max));

  final mimeTypes = <String>[];
  for (var i = 0; i < attachments.length; i++) {
    final attachment = attachments[i];
    final mimeType = canonicalReportMimeType(attachment.mimeType);
    if (mimeType == null) return fail(ReportFormUnsupportedType(i));
    if (!reportBytesMatch(mimeType, attachment.bytes)) {
      return fail(ReportFormContentMismatch(i));
    }
    if (mimeType == 'application/pdf' &&
        attachment.bytes.length >= reportPdfMaxBytesExclusive) {
      return fail(ReportFormPdfTooLarge(i));
    }
    mimeTypes.add(mimeType);
  }

  // Sized before anything is encoded, so an oversized receipt is refused
  // without first allocating three copies of it.
  final head = utf8.encode(
    '{"v":$reportPackageVersion,"query":${jsonEncode(query)}'
    '${incidentDate == null ? '' : ',"incidentDate":"${formatReportDate(incidentDate)}"'}'
    ',"attachments":[',
  );
  final openers = <Uint8List>[
    for (var i = 0; i < mimeTypes.length; i++)
      utf8.encode(
        '${i == 0 ? '' : ','}{"name":"attachment-${i + 1}.'
        '${_extensionByMimeType[mimeTypes[i]]}","mimeType":"${mimeTypes[i]}",'
        '"data":"',
      ),
  ];
  final closer = utf8.encode('"}');
  final tail = utf8.encode(']}');

  var total = head.length + tail.length;
  for (var i = 0; i < attachments.length; i++) {
    total += openers[i].length +
        _base64Length(attachments[i].bytes.length) +
        closer.length;
  }
  if (total > reportPackageMaxBytes) {
    return fail(const ReportFormPackageTooLarge(reportPackageMaxBytes));
  }

  final out = Uint8List(total);
  var offset = 0;
  void put(List<int> chunk) {
    out.setRange(offset, offset + chunk.length, chunk);
    offset += chunk.length;
  }

  put(head);
  for (var i = 0; i < attachments.length; i++) {
    put(openers[i]);
    // base64 is ASCII, so its code units are its UTF-8 bytes, and none of its
    // characters needs escaping inside a JSON string.
    put(base64Encode(attachments[i].bytes).codeUnits);
    put(closer);
  }
  put(tail);
  return (bytes: out, error: null);
}

/// `YYYY-MM-DD` from the date's own fields.
String formatReportDate(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';

/// The link an app too old for the package is opened with:
/// `<scheme>://report/create?media=<query>`.
///
/// Everything outside RFC 3986 unreserved (`A–Z a–z 0–9 - . _ ~`) is
/// percent-encoded, UTF-8, upper-case hex. `Uri.encodeQueryComponent` would
/// write a space as `+`, and Android's `Uri.getQueryParameter` reads a bare
/// `+` back as a space, so `PHONE_+62…` would arrive as `PHONE_ 62…`.
Uri buildReportLink(String scheme, String query) =>
    Uri.parse('$scheme://report/create?media=${_encodeUnreserved(query)}');

String _encodeUnreserved(String value) {
  const hex = '0123456789ABCDEF';
  final out = StringBuffer();
  for (final byte in utf8.encode(value)) {
    final unreserved = (byte >= 0x41 && byte <= 0x5A) ||
        (byte >= 0x61 && byte <= 0x7A) ||
        (byte >= 0x30 && byte <= 0x39) ||
        byte == 0x2D ||
        byte == 0x2E ||
        byte == 0x5F ||
        byte == 0x7E;
    if (unreserved) {
      out.writeCharCode(byte);
    } else {
      out
        ..write('%')
        ..write(hex[byte >> 4])
        ..write(hex[byte & 0x0F]);
    }
  }
  return out.toString();
}

int _base64Length(int byteCount) => 4 * ((byteCount + 2) ~/ 3);

int _dayNumber(DateTime date) =>
    date.year * 10000 + date.month * 100 + date.day;
