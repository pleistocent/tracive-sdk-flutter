// Copyright (c) Tracive. Licensed under the Apache License, Version 2.0.
//
// Edge cases for the JavaScript string semantics in `lib/src/query/js_string.dart`.
//
// `test/query_grammar_test.dart` proves those helpers satisfy the vendored
// fixture. This file covers what the fixture does not reach: the boundary
// between the fast and slow case-mapping paths, astral code points, lone
// surrogates, the Final_Sigma rule, and — the one that actually matters — that
// every entry in the generated delta tables is IDEMPOTENT. The server re-folds
// caller-supplied keys on the read path, so a mapping that changes a value a
// second time would resolve to a different record than the one the cache key
// was built from, and the resulting miss would still be billed.
//
// The expected values below are JavaScript's, taken from a real engine (see
// `tool/dump_js_case_data.mjs`), not from Dart. Every case-mapping assertion is
// paired with the answer Dart's own built-in gives, so that a test which would
// have passed without `js_string.dart` is visible as such.
//
// This file samples; `tool/verify_js_case_fold.dart` is the exhaustive check.
//
// Non-ASCII is written with explicit \u escapes throughout: this file is about
// individual code points, and a raw paste is one editor save away from being a
// different one.

import 'package:test/test.dart';
import 'package:tracive_sdk/src/query/js_case_data.dart';
import 'package:tracive_sdk/src/query/js_string.dart';

void main() {
  test('special case mixed with non-BMP survives', () {
    // Slow path (U+00DF forces it) with an astral code point alongside.
    expect(jsToUpperCase('\u{DF}\u{1F600}a'), 'SS\u{1F600}A');
    expect(jsToUpperCase('\u{1F600}'), '\u{1F600}');
  });

  test('fast path and slow path agree where both are valid', () {
    for (final subject in <String>['abc', 'ABC', '\u{E9}x', '', 'a b']) {
      expect(
        jsToUpperCase(subject),
        subject.toUpperCase(),
        reason: 'fast path for "$subject"',
      );
    }
  });

  test('empty and whitespace-only', () {
    expect(jsTrim(''), '');
    expect(jsTrim('   '), '');
    expect(jsTrim(' \u{FEFF}'), '');
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
    for (final entry in jsUppercaseDeltas.entries) {
      final once = jsToUpperCase(String.fromCharCode(entry.key));
      expect(once, entry.value);
      expect(
        jsToUpperCase(once),
        once,
        reason: 'U+${entry.key.toRadixString(16)}',
      );
    }
    for (final entry in jsLowercaseDeltas.entries) {
      final once = jsToLowerCase(String.fromCharCode(entry.key));
      expect(once, entry.value);
      expect(
        jsToLowerCase(once),
        once,
        reason: 'U+${entry.key.toRadixString(16)}',
      );
    }
  });

  // --------------------------------------------------------------------------
  // The gap the delta tables close: Dart's simple case mapping is several
  // Unicode releases behind the engine the Tracive API folds in, so entire
  // living scripts used to fold to a key that could not match. One case per
  // script family, each asserted against what Dart alone would have produced.
  // --------------------------------------------------------------------------
  group('scripts where Dart alone builds an unmatchable key', () {
    void expectsFold(
      String label, {
      required String input,
      required String javaScript,
      required bool upper,
    }) {
      test(label, () {
        expect(
          upper ? jsToUpperCase(input) : jsToLowerCase(input),
          javaScript,
          reason: 'this is what the server folds $label to',
        );
        expect(
          upper ? input.toUpperCase() : input.toLowerCase(),
          isNot(javaScript),
          reason: "Dart's own mapping would have missed, so this test is real",
        );
      });
    }

    expectsFold(
      'Adlam capitals lowercase',
      input: '\u{1E900}\u{1E901}\u{1E902}',
      javaScript: '\u{1E922}\u{1E923}\u{1E924}',
      upper: false,
    );
    expectsFold(
      'Cherokee capitals lowercase',
      input: '\u{13A0}\u{13A1}',
      javaScript: '\u{AB70}\u{AB71}',
      upper: false,
    );
    expectsFold(
      'Cherokee small letters uppercase',
      input: '\u{AB70}\u{AB71}',
      javaScript: '\u{13A0}\u{13A1}',
      upper: true,
    );
    expectsFold(
      'Georgian Mkhedruli uppercases to Mtavruli',
      input: '\u{10D0}\u{10D1}',
      javaScript: '\u{1C90}\u{1C91}',
      upper: true,
    );
    expectsFold(
      'Georgian Mtavruli lowercases to Mkhedruli',
      input: '\u{1C90}\u{1C91}',
      javaScript: '\u{10D0}\u{10D1}',
      upper: false,
    );
    expectsFold(
      'Latin Extended-D lowercases',
      input: '\u{A7B0}',
      javaScript: '\u{29E}',
      upper: false,
    );
    expectsFold(
      'Latin Extended-D uppercases',
      input: '\u{AB53}',
      javaScript: '\u{A7B3}',
      upper: true,
    );
    expectsFold(
      'Cyrillic Komi lowercases',
      input: '\u{524}',
      javaScript: '\u{525}',
      upper: false,
    );
    expectsFold(
      'Osage uppercases',
      input: '\u{104D8}',
      javaScript: '\u{104B0}',
      upper: true,
    );
    expectsFold(
      'Warang Citi uppercases',
      input: '\u{118C0}',
      javaScript: '\u{118A0}',
      upper: true,
    );
    expectsFold(
      'Medefaidrin uppercases',
      input: '\u{16E60}',
      javaScript: '\u{16E40}',
      upper: true,
    );
    expectsFold(
      'Old Hungarian uppercases',
      input: '\u{10CC0}',
      javaScript: '\u{10C80}',
      upper: true,
    );

    test('a supplementary-plane delta is not missed by the fast-path scan', () {
      // The scan used to walk code UNITS, and a supplementary code point's
      // surrogate halves are never table keys — so a string of nothing but
      // Adlam took the fast path and came back unfolded. Asserted separately
      // from the mapping itself because the mapping was never the problem: only
      // a string with no other trigger in it shows the scan bug.
      expect(jsToLowerCase('\u{1E900}'), '\u{1E922}');
      expect(jsToUpperCase('\u{1E922}'), '\u{1E900}');
    });
  });

  // --------------------------------------------------------------------------
  // Final_Sigma: the one mapping no per-code-point table can express.
  // --------------------------------------------------------------------------
  group('Greek final sigma', () {
    test('a word-final sigma lowercases to U+03C2, not U+03C3', () {
      // The word for "street": four capitals in, a final sigma out.
      expect(
        jsToLowerCase('\u{39F}\u{394}\u{39F}\u{3A3}'),
        '\u{3BF}\u{3B4}\u{3BF}\u{3C2}',
      );
      expect(
        '\u{39F}\u{394}\u{39F}\u{3A3}'.toLowerCase(),
        '\u{3BF}\u{3B4}\u{3BF}\u{3C3}',
        reason: "Dart's own mapping always produces the medial form",
      );
    });

    test('a sigma with a cased letter after it stays medial', () {
      expect(
        jsToLowerCase('\u{39F}\u{394}\u{39F}\u{3A3}\u{391}'),
        '\u{3BF}\u{3B4}\u{3BF}\u{3C3}\u{3B1}',
      );
    });

    test('a sigma with no cased letter before it stays medial', () {
      expect(jsToLowerCase('\u{3A3}'), '\u{3C3}');
      expect(jsToLowerCase('.\u{3A3}'), '.\u{3C3}');
    });

    test('case-ignorable characters do not break the run either way', () {
      // U+00AD SOFT HYPHEN is case-ignorable, so it neither supplies the cased
      // letter before nor shields the cased letter after.
      expect(jsToLowerCase('\u{391}\u{AD}\u{3A3}'), '\u{3B1}\u{AD}\u{3C2}');
      expect(
        jsToLowerCase('\u{391}\u{3A3}\u{AD}\u{391}'),
        '\u{3B1}\u{3C3}\u{AD}\u{3B1}',
      );
      expect(jsToLowerCase('\u{391}\u{3A3}\u{AD}'), '\u{3B1}\u{3C2}\u{AD}');
    });

    test('the rule reads the original string, not the folded one', () {
      // Two sigmas in a row: only the second one is word-final.
      expect(jsToLowerCase('\u{391}\u{3A3}\u{3A3}'), '\u{3B1}\u{3C3}\u{3C2}');
    });

    test('an @ ends a word, so a Greek handle folds with the final form', () {
      // The shape a real e-mail local part takes.
      expect(
        jsToLowerCase('\u{39D}\u{399}\u{39A}\u{39F}\u{3A3}@X'),
        '\u{3BD}\u{3B9}\u{3BA}\u{3BF}\u{3C2}@x',
      );
    });
  });

  test('the tables record which Unicode release they came from', () {
    // Not decoration: the delta between Dart and JavaScript is a function of
    // the engine's Unicode release, so a table with no release on it cannot be
    // checked against the server's engine. If this constant changes, the tables
    // were regenerated against a different engine — a deliberate act, not a
    // refactor. See the divergence note at the top of `js_string.dart`.
    expect(jsCaseUnicodeVersion, '17.0');
  });
}
