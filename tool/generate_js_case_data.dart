// Copyright (c) Tracive. Licensed under the Apache License, Version 2.0.
//
// Regenerates `lib/src/query/js_case_data.dart`.
//
// WHAT THIS SOLVES
// ----------------
// The Tracive API folds query keys in JavaScript, and a key that differs by one
// code point resolves to a record that does not exist — the check misses, and a
// miss is still billed. So this SDK has to reproduce JavaScript's case mapping
// exactly, on every target it compiles to.
//
// Dart's `String.toUpperCase()` / `toLowerCase()` do not do that on the VM. They
// apply Unicode *simple* (one-to-one) case mapping from whichever Unicode
// release the Dart SDK was built against, while JavaScript applies the *full*
// mapping from whichever release its engine was built against. Those two
// differ in two independent ways, and this generator captures both:
//
//   * the full mapping can be longer than one code point (U+00DF -> "SS"), and
//   * Dart's simple table is several Unicode releases behind, so whole scripts
//     — Adlam, Cherokee, Georgian Mtavruli, Osage, Warang Citi, Medefaidrin,
//     Old Hungarian, Latin Extended-D, Cyrillic — map differently or not at
//     all.
//
// Rather than transcribe Unicode data files, this asks a JavaScript engine for
// its own answer, then subtracts Dart's. What is left is the delta table the
// SDK applies. Because the table stores the *target's* answer (not a patch),
// applying it is a no-op on dart2js, where Dart's case methods already compile
// to JavaScript's — the same source then produces the same key on every target.
//
// HOW TO RUN
// ----------
//     dart run tool/generate_js_case_data.dart
//
// It needs `node` on PATH. Point it at the same Node major version the Tracive
// API runs on: the delta is Unicode-release-sensitive, and the generated file
// records which release it was built from so a mismatch is visible rather than
// silent. Pass `--verify` to check the committed file is still what this
// machine's Node produces, without writing anything.
//
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

const String _outputPath = 'lib/src/query/js_case_data.dart';
const String _dumperPath = 'tool/dump_js_case_data.mjs';

Future<void> main(List<String> arguments) async {
  final verifyOnly = arguments.contains('--verify');

  final dump = await _runDumper();
  final unicodeVersion = dump['unicodeVersion'] as String;
  final engine = dump['engine'] as String;
  final icuVersion = dump['icuVersion'] as String;

  final jsUpper = <int, String>{};
  final jsLower = <int, String>{};
  for (final row in (dump['mappings'] as List).cast<List<Object?>>()) {
    final codePoint = row[0]! as int;
    if (row[1] != null) jsUpper[codePoint] = row[1]! as String;
    if (row[2] != null) jsLower[codePoint] = row[2]! as String;
  }

  final upperDelta = _delta(jsUpper, (String one) => one.toUpperCase());
  final lowerDelta = _delta(jsLower, (String one) => one.toLowerCase());

  final generated = _render(
    engine: engine,
    icuVersion: icuVersion,
    unicodeVersion: unicodeVersion,
    upperDelta: upperDelta,
    lowerDelta: lowerDelta,
    cased: _pairs(dump['cased']! as List),
    caseIgnorable: _pairs(dump['caseIgnorable']! as List),
  );

  final output = File(_outputPath);
  if (verifyOnly) {
    final current = output.existsSync() ? output.readAsStringSync() : '';
    if (current == generated) {
      print('$_outputPath is up to date with $engine (Unicode '
          '$unicodeVersion).');
      return;
    }
    stderr.writeln(
      '$_outputPath does not match what $engine (Unicode $unicodeVersion) '
      'produces. Either this machine\'s Node is not the version the API runs, '
      'or the table needs regenerating: dart run tool/generate_js_case_data.dart',
    );
    exitCode = 1;
    return;
  }

  output.writeAsStringSync(generated);
  print('Wrote $_outputPath from $engine (ICU $icuVersion, Unicode '
      '$unicodeVersion): ${upperDelta.length} uppercase and '
      '${lowerDelta.length} lowercase deltas.');
  print('Run `dart format .` afterwards.');
}

/// Runs the Node dumper and parses its JSON.
Future<Map<String, Object?>> _runDumper() async {
  final result = await Process.run('node', [_dumperPath]);
  if (result.exitCode != 0) {
    stderr.writeln('node $_dumperPath failed:\n${result.stderr}');
    exit(1);
  }
  return jsonDecode(result.stdout as String) as Map<String, Object?>;
}

/// Every code point where Dart's own mapping disagrees with JavaScript's,
/// mapped to *JavaScript's* answer.
Map<int, String> _delta(
  Map<int, String> target,
  String Function(String) dartMapping,
) {
  final delta = <int, String>{};
  for (var codePoint = 0; codePoint <= 0x10FFFF; codePoint++) {
    if (codePoint >= 0xD800 && codePoint <= 0xDFFF) continue;
    final one = String.fromCharCode(codePoint);
    final want = target[codePoint] ?? one;
    if (dartMapping(one) != want) delta[codePoint] = want;
  }
  return delta;
}

List<List<int>> _pairs(List<Object?> raw) =>
    raw.map((Object? pair) => (pair! as List).cast<int>()).toList();

String _hex(int codePoint) =>
    '0x${codePoint.toRadixString(16).toUpperCase().padLeft(4, '0')}';

/// Renders a string as `\u{...}` escapes so the generated file stays ASCII.
/// Non-ASCII source is one bad editor save away from being silently wrong, and
/// this table is the thing that decides whether a key hits.
String _escape(String value) {
  final buffer = StringBuffer("'");
  for (final rune in value.runes) {
    if (rune >= 0x20 && rune < 0x7F && rune != 0x27 && rune != 0x5C) {
      buffer.writeCharCode(rune);
    } else {
      buffer.write('\\u{${rune.toRadixString(16).toUpperCase()}}');
    }
  }
  buffer.write("'");
  return buffer.toString();
}

String _renderMap(Map<int, String> delta) {
  final buffer = StringBuffer();
  final keys = delta.keys.toList()..sort();
  for (final key in keys) {
    buffer.writeln('  ${_hex(key)}: ${_escape(delta[key]!)},');
  }
  return buffer.toString();
}

String _renderRanges(List<List<int>> ranges) {
  final buffer = StringBuffer();
  for (var i = 0; i < ranges.length; i += 4) {
    final chunk = ranges
        .skip(i)
        .take(4)
        .map((List<int> range) => '${_hex(range[0])}, ${_hex(range[1])},')
        .join(' ');
    buffer.writeln('  $chunk');
  }
  return buffer.toString();
}

String _render({
  required String engine,
  required String icuVersion,
  required String unicodeVersion,
  required Map<int, String> upperDelta,
  required Map<int, String> lowerDelta,
  required List<List<int>> cased,
  required List<List<int>> caseIgnorable,
}) {
  return '''
// Copyright (c) Tracive. Licensed under the Apache License, Version 2.0.
//
// GENERATED FILE - DO NOT EDIT BY HAND.
//
// Regenerate with:  dart run tool/generate_js_case_data.dart
// Source of truth:  $engine (ICU $icuVersion, Unicode $unicodeVersion)
//
// Why this file exists, and why it is generated rather than written: see the
// header of `tool/generate_js_case_data.dart` and of `js_string.dart`.

/// The Unicode release the tables below were taken from.
///
/// This is the release the *JavaScript engine* used, not the one Dart's own
/// case tables come from — the whole point of the tables is that those two are
/// not the same. It is recorded so that a mismatch with the server's engine is
/// something you can read off rather than something you have to measure.
const String jsCaseUnicodeVersion = '$unicodeVersion';

/// Code points whose JavaScript uppercase mapping differs from Dart's, mapped
/// to JavaScript's answer.
///
/// Covers both halves of the gap in one table: the length-changing full
/// mappings (U+00DF -> `SS`) and the code points where Dart's simple-mapping
/// table is simply older than the engine's.
const Map<int, String> jsUppercaseDeltas = <int, String>{
${_renderMap(upperDelta)}};

/// Code points whose JavaScript lowercase mapping differs from Dart's, mapped
/// to JavaScript's answer.
///
/// U+03A3 GREEK CAPITAL LETTER SIGMA is deliberately absent: its lowercase form
/// depends on the characters around it, so it cannot live in a per-code-point
/// table. `js_string.dart` implements that rule directly, using [casedRanges]
/// and [caseIgnorableRanges].
const Map<int, String> jsLowercaseDeltas = <int, String>{
${_renderMap(lowerDelta)}};

/// The Unicode `Cased` property, as `[start, end]` pairs flattened into one
/// list and sorted. Used only by the Final_Sigma rule.
const List<int> casedRanges = <int>[
${_renderRanges(cased)}];

/// The Unicode `Case_Ignorable` property, as `[start, end]` pairs flattened
/// into one list and sorted. Used only by the Final_Sigma rule.
const List<int> caseIgnorableRanges = <int>[
${_renderRanges(caseIgnorable)}];
''';
}
