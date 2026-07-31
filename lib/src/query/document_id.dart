// Copyright (c) Tracive. Licensed under the Apache License, Version 2.0.
//
// Record-key guard — the `RAW` entries in
// `test/fixtures/query-grammar-vectors.json`.
//
// Deliberately NOT exported from `lib/tracive_sdk.dart`: it is an internal
// invariant of key construction, not part of the frozen cross-SDK surface. The
// grammar test imports it directly (`package:tracive_sdk/src/query/
// document_id.dart`) to exercise the fixture's `RAW` vectors, which are raw
// keys rather than builder input.

import 'dart:convert';

import '../exception.dart';

/// The API's hard limit on a record key, in UTF-8 bytes.
const int maxDocumentIdBytes = 1500;

/// Ids matching this pattern are reserved by the API.
final RegExp _reservedPattern = RegExp(r'^__.*__$', dotAll: true);

/// Whether [id] is a legal record key.
///
/// Mirrors the `documentIdGuard` block of the vendored fixture. Rejects: the
/// empty string, anything containing `/`, anything matching `__.*__`, `.`,
/// `..`, anything containing a lone (unpaired) UTF-16 surrogate, and anything
/// longer than [maxDocumentIdBytes] UTF-8 bytes.
///
/// The byte limit is measured in *bytes*, so a key of non-ASCII characters hits
/// it sooner than its `length` suggests — and it is checked on the **folded**
/// key, because case mapping is not length-preserving (`ß` uppercases to `SS`).
///
/// Spaces, `@`, `+`, `#`, `$`, `[`, `]`, `*`, `~`, `_`, emoji, a `.` inside the
/// string, and the prefixes/suffixes `__x` and `x__` are all explicitly legal.
bool isValidDocumentId(String id) {
  if (id.isEmpty) return false;
  if (id.contains('/')) return false;
  if (id == '.' || id == '..') return false;
  if (_reservedPattern.hasMatch(id)) return false;
  if (_hasLoneSurrogate(id)) return false;
  // Must come after the surrogate check: `utf8.encode` silently substitutes
  // U+FFFD for an unpaired surrogate, so a malformed id would otherwise be
  // measured — and accepted — as if it were well-formed.
  if (utf8.encode(id).length > maxDocumentIdBytes) return false;
  return true;
}

/// Whether [id] contains a UTF-16 surrogate code unit that is not part of a
/// well-formed pair.
///
/// Such a string cannot be encoded as UTF-8, so the API rejects it. Dart
/// permits one to exist in a [String], and it can reach here through a
/// truncated identifier pasted from another system.
bool _hasLoneSurrogate(String id) {
  for (var i = 0; i < id.length; i++) {
    final unit = id.codeUnitAt(i);
    if (unit >= 0xD800 && unit <= 0xDBFF) {
      // A high surrogate must be followed by a low surrogate.
      if (i + 1 >= id.length) return true;
      final next = id.codeUnitAt(i + 1);
      if (next < 0xDC00 || next > 0xDFFF) return true;
      i++; // Consume the well-formed pair.
    } else if (unit >= 0xDC00 && unit <= 0xDFFF) {
      // A low surrogate not preceded by a high one.
      return true;
    }
  }
  return false;
}

/// Throws [TraciveQueryException] with reason `invalid_document_id` when [id]
/// is not a legal record key.
///
/// Runs on every built key, before any network call: an illegal id can never
/// match a document, and per §3.2 a miss is billed anyway.
///
/// PRIVACY: the rejected id is never included in the message — it is the raw
/// identifier the caller passed in.
void validateDocumentId(String id) {
  if (!isValidDocumentId(id)) {
    throw const TraciveQueryException(
      QueryRejectionReason.invalidDocumentId,
      message: 'The folded key is not a valid record key',
    );
  }
}
