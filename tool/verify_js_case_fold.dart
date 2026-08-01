// Copyright (c) Tracive. Licensed under the Apache License, Version 2.0.
//
// Measures how far this SDK's fold is from the JavaScript engine's, and prints
// the number.
//
// WHY THIS IS A TOOL AND NOT A TEST
// ---------------------------------
// The claim `js_string.dart` makes — "this folds exactly like the engine the
// Tracive API runs" — is only checkable against a real engine, and `node` is
// not something a `flutter test` run may assume. So the exhaustive check lives
// here, is run by hand when the tables change, and its result is what the
// committed unit tests in `test/js_string_test.dart` sample. Those tests pin
// specific code points; this tool is what says nothing else is left.
//
// It reports two independent numbers:
//
//   1. Per code point, over all of U+0000-U+10FFFF. Catches a wrong or missing
//      table entry.
//   2. Over random multi-code-point strings drawn from a deliberately hostile
//      alphabet (every table key, an over-weighted U+03A3, cased letters,
//      case-ignorable characters, astral code points), plus hand-written
//      Final_Sigma shapes. Catches anything context-sensitive that a
//      per-code-point table cannot see — which is the whole reason the
//      Final_Sigma rule is hand-written.
//
// Both must report 0. Run:
//
//     dart run tool/verify_js_case_fold.dart
//
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:tracive_sdk/src/query/js_case_data.dart';
import 'package:tracive_sdk/src/query/js_string.dart';

/// How many random strings to fold. Large enough that every table entry is
/// exercised in several positions, small enough to finish in seconds.
const int _sampleCount = 200000;

/// Fixed so a failure is reproducible rather than a story about a seed.
const int _seed = 20260801;

Future<void> main() async {
  final perCodePoint = _verifyEveryCodePoint();
  final perString = await _verifyRandomStrings();

  print('per-code-point divergences (U+0000-U+10FFFF): $perCodePoint');
  print('per-string divergences ($_sampleCount random + targeted): $perString');
  if (perCodePoint != 0 || perString != 0) {
    stderr.writeln(
      'This SDK does not fold like the local engine. Either the tables need '
      'regenerating (dart run tool/generate_js_case_data.dart) or the local '
      'Node is a different Unicode release from the one the tables record '
      '($jsCaseUnicodeVersion).',
    );
    exitCode = 1;
  }
}

int _verifyEveryCodePoint() {
  final dump = _runNode(['tool/dump_js_case_data.mjs']) as Map<String, Object?>;
  final engineVersion = dump['unicodeVersion'] as String;
  if (engineVersion != jsCaseUnicodeVersion) {
    stderr.writeln(
      'WARNING: the local engine is Unicode $engineVersion but the committed '
      'tables were generated from Unicode $jsCaseUnicodeVersion. Differences '
      'below are release drift, not necessarily defects.',
    );
  }
  final jsUpper = <int, String>{};
  final jsLower = <int, String>{};
  for (final row in (dump['mappings']! as List).cast<List<Object?>>()) {
    final codePoint = row[0]! as int;
    if (row[1] != null) jsUpper[codePoint] = row[1]! as String;
    if (row[2] != null) jsLower[codePoint] = row[2]! as String;
  }

  var divergences = 0;
  for (var codePoint = 0; codePoint <= 0x10FFFF; codePoint++) {
    if (codePoint >= 0xD800 && codePoint <= 0xDFFF) continue;
    final one = String.fromCharCode(codePoint);
    if (jsToUpperCase(one) != (jsUpper[codePoint] ?? one)) {
      divergences++;
      _report('uppercase', codePoint);
    }
    if (jsToLowerCase(one) != (jsLower[codePoint] ?? one)) {
      divergences++;
      _report('lowercase', codePoint);
    }
  }
  return divergences;
}

Future<int> _verifyRandomStrings() async {
  final samples = _samples();
  final scratch = File('${Directory.systemTemp.path}/tracive_case_samples.json')
    ..writeAsStringSync(jsonEncode(samples));
  final folded = (_runNode(['tool/fold_samples.mjs', scratch.path]) as List)
      .cast<List<Object?>>();
  scratch.deleteSync();

  var divergences = 0;
  for (var i = 0; i < samples.length; i++) {
    if (jsToUpperCase(samples[i]) != folded[i][0]) {
      divergences++;
      _reportString('uppercase', samples[i]);
    }
    if (jsToLowerCase(samples[i]) != folded[i][1]) {
      divergences++;
      _reportString('lowercase', samples[i]);
    }
  }
  return divergences;
}

List<String> _samples() {
  final random = Random(_seed);
  final alphabet = <int>[
    ...jsUppercaseDeltas.keys,
    ...jsLowercaseDeltas.keys,
    // Over-weighted, because it is the only context-sensitive code point and
    // it needs to land next to every other kind of neighbour.
    0x03A3, 0x03A3, 0x03A3, 0x03A3,
    // Cased letters, Greek and Latin.
    0x0041, 0x0061, 0x0391, 0x03B1, 0x039F, 0x0394,
    // Case-ignorable and uncased neighbours.
    0x0020, 0x002E, 0x0027, 0x00AD, 0x0301, 0x02BC,
    // Digits, separators, an astral emoji and a CJK ideograph.
    0x0031, 0x005F, 0x0040, 0x1F600, 0x4E2D,
  ];

  final samples = <String>[
    // Hand-written Final_Sigma shapes: word-final, medial, unanchored, and the
    // shape a Greek e-mail local part actually takes.
    '\u{39F}\u{394}\u{39F}\u{3A3}',
    '\u{39F}\u{394}\u{39F}\u{3A3}\u{391}',
    '\u{3A3}',
    '\u{391}\u{3A3}',
    '\u{391}\u{3A3}.',
    '\u{391}\u{AD}\u{3A3}',
    '\u{391}\u{3A3}\u{AD}\u{391}',
    '\u{391}\u{3A3}\u{AD}',
    '.\u{3A3}',
    '\u{3A3}\u{3A3}',
    '\u{391}\u{3A3}\u{3A3}',
    '\u{39D}\u{399}\u{39A}\u{39F}\u{3A3}@X.COM',
    '\u{39F}\u{394}\u{39F}\u{3A3} \u{39F}\u{394}\u{39F}\u{3A3}',
  ];
  for (var i = 0; i < _sampleCount; i++) {
    final length = 1 + random.nextInt(6);
    final buffer = StringBuffer();
    for (var j = 0; j < length; j++) {
      buffer.writeCharCode(alphabet[random.nextInt(alphabet.length)]);
    }
    samples.add(buffer.toString());
  }
  return samples;
}

Object? _runNode(List<String> arguments) {
  final result = Process.runSync('node', arguments);
  if (result.exitCode != 0) {
    stderr.writeln('node ${arguments.join(' ')} failed:\n${result.stderr}');
    exit(1);
  }
  return jsonDecode(result.stdout as String);
}

void _report(String direction, int codePoint) {
  print(
      '  $direction diverges at U+${codePoint.toRadixString(16).toUpperCase().padLeft(4, '0')}');
}

void _reportString(String direction, String sample) {
  final hex = sample.runes.map((int r) => r.toRadixString(16)).join(' ');
  print('  $direction diverges for [$hex]');
}
