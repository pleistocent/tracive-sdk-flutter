// Copyright 2026 PT Pleistocent Teknologi Nusantara.
// Licensed under the Apache License, Version 2.0.
//
// Regenerates `lib/src/query/bank_codes_json.dart` from the vendored
// `test/fixtures/bank-codes.json`.
//
// The table ships as a Dart string constant rather than a Flutter asset: the
// query builders are synchronous pure Dart, and an asset can only be read
// asynchronously, through a Flutter binding. `test/bank_codes_test.dart` fails
// when the constant and the vendored file differ by a single byte.
//
// HOW TO RUN
// ----------
//     dart run tool/embed_bank_codes.dart
//
// After re-vendoring `test/fixtures/bank-codes.json` from the Tracive API,
// byte for byte. Never edit either file by hand.
//
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

const String _sourcePath = 'test/fixtures/bank-codes.json';
const String _outputPath = 'lib/src/query/bank_codes_json.dart';

void main() {
  final json = File(_sourcePath).readAsStringSync();

  // A raw ''' string has no escapes: it ends at the first ''' and cannot end
  // on a quote, so the data may contain neither.
  if (json.contains("'''") || json.endsWith("'")) {
    stderr.writeln('$_sourcePath would end the Dart string literal early.');
    exitCode = 1;
    return;
  }
  jsonDecode(json);

  File(_outputPath).writeAsStringSync('''
// Copyright 2026 PT Pleistocent Teknologi Nusantara.
// Licensed under the Apache License, Version 2.0.
//
// GENERATED FILE - DO NOT EDIT BY HAND.
//
// Regenerate with:  dart run tool/embed_bank_codes.dart
// Source of truth:  $_sourcePath

/// `bank-codes.json`, byte for byte as vendored from the Tracive API. Parsed
/// on first use, in `bank_codes.dart`.
const String bankCodesJson = r\'\'\'
$json\'\'\';
''');
  print('Wrote $_outputPath (${utf8.encode(json).length} bytes of JSON).');
}
