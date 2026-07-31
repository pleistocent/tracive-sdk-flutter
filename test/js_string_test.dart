// Copyright (c) Tracive. Licensed under the Apache License, Version 2.0.
//
// Edge cases for the JavaScript string semantics in `lib/src/query/js_string.dart`.
//
// `test/query_grammar_test.dart` proves those helpers satisfy the vendored
// fixture. This file covers what the fixture does not reach: the boundary
// between the fast and slow case-mapping paths, astral code points, lone
// surrogates, and — the one that actually matters — that every entry in the
// generated special-case tables is IDEMPOTENT. The server re-folds
// caller-supplied keys on the read path, so a mapping that changes a value a
// second time would resolve to a different document than the one the cache key
// was built from, and the resulting miss would still be billed.
//
// The tables were generated mechanically (by diffing Dart's simple case mapping
// against the Unicode full mapping); this is the test that says the generator's
// output is sane rather than merely present.

import 'package:test/test.dart';
import 'package:tracive_sdk/src/query/js_string.dart';

void main() {
  test('special case mixed with non-BMP survives', () {
    // Slow path (ß forces it) with an astral code point alongside.
    expect(jsToUpperCase('ß\u{1F600}a'), 'SS\u{1F600}A');
    expect(jsToUpperCase('\u{1F600}'), '\u{1F600}');
  });

  test('fast path and slow path agree where both are valid', () {
    for (final s in <String>['abc', 'ABC', 'éx', '', 'a b']) {
      expect(jsToUpperCase(s), s.toUpperCase(), reason: 'fast path for "$s"');
    }
  });

  test('empty and whitespace-only', () {
    expect(jsTrim(''), '');
    expect(jsTrim('   '), '');
    expect(jsTrim(' ﻿'), '');
    expect(jsToUpperCase(''), '');
  });

  test('trim does not touch interior whitespace', () {
    expect(jsTrim('  a  b  '), 'a  b');
  });

  test('a lone surrogate does not crash the case mappers', () {
    expect(() => jsToUpperCase('a\uD83D'), returnsNormally);
    expect(() => jsToLowerCase('a\uDE00'), returnsNormally);
  });

  test('every table entry is actually reachable and idempotent-safe', () {
    // Uppercasing an already-uppercased value must not change it again, or the
    // fold would not be idempotent and the read path would disagree.
    for (final entry in jsUppercaseSpecialCases.entries) {
      final once = jsToUpperCase(String.fromCharCode(entry.key));
      expect(once, entry.value);
      expect(jsToUpperCase(once), once,
          reason: 'U+${entry.key.toRadixString(16)}');
    }
    for (final entry in jsLowercaseSpecialCases.entries) {
      final once = jsToLowerCase(String.fromCharCode(entry.key));
      expect(once, entry.value);
      expect(jsToLowerCase(once), once,
          reason: 'U+${entry.key.toRadixString(16)}');
    }
  });
}
