// Copyright 2026 PT Pleistocent Teknologi Nusantara.
// Licensed under the Apache License, Version 2.0.
//
// JavaScript string semantics, so that a key folded here is byte-identical to
// the key the Tracive API folds. The rules below are the ones stated in the
// `crossLanguageSemantics` block of `test/fixtures/query-grammar-vectors.json`,
// which is vendored verbatim into every Tracive SDK.
//
// ---------------------------------------------------------------------------
// WHY THIS FILE EXISTS
// ---------------------------------------------------------------------------
// The Tracive API folds query keys in JavaScript. Every SDK must produce a
// byte-identical key, because the folded key is the record key: a key that
// differs by one code point resolves to a record that does not exist, the check
// misses — and a miss is still billed to the caller.
//
// Dart's built-ins are NOT JavaScript's. Three divergences, each measured
// against this Dart SDK rather than assumed:
//
//  1. CASE MAPPING. On the Dart VM (so: on Android and iOS), `toUpperCase()`
//     and `toLowerCase()` apply Unicode *simple* (one-to-one) case mapping,
//     taken from whichever Unicode release the Dart SDK was built against.
//     JavaScript applies the *full* mapping from whichever release its engine
//     was built against. Those disagree in two independent ways:
//
//       a. The full mapping can be longer than one code point. Dart leaves
//          U+00DF alone where JavaScript yields `SS`; Dart maps U+0130 to a
//          bare `i` where JavaScript yields `i` + U+0307.
//       b. Dart's simple table is several Unicode releases behind, so whole
//          living scripts map differently or not at all — Adlam, Cherokee,
//          Georgian Mkhedruli/Mtavruli, Osage, Warang Citi, Medefaidrin, Old
//          Hungarian, Latin Extended-D, Cyrillic.
//
//     Both are covered by the generated tables in `js_case_data.dart`. See
//     [jsToUpperCase] for what is and is not guaranteed.
//
//     There is exactly one case mapping JavaScript applies that no
//     per-code-point table can express: U+03A3 GREEK CAPITAL LETTER SIGMA
//     lowercases to U+03C2 (final sigma) at the end of a word and to U+03C3
//     everywhere else. That rule is implemented directly, in [jsToLowerCase].
//     It is the *only* context-sensitive mapping: sweeping every code point
//     U+0000–U+10FFFF in four different neighbourhoods (preceded by a cased
//     letter, followed by one, preceded by a case-ignorable character, and
//     preceded by a cased letter plus a case-ignorable one) turns up U+03A3 and
//     nothing else.
//
//  2. TRIM. `String.trim()` follows the Unicode White_Space property *plus*
//     U+FEFF. JavaScript's `String.prototype.trim()` strips a different set.
//     Measured: Dart strips U+0085 NEXT LINE, JavaScript does not. Both agree
//     that U+200B ZERO WIDTH SPACE is *not* stripped, which the fixture pins
//     down explicitly.
//
//  3. DIGITS. JavaScript's `\D` is exactly `[^0-9]`, so Arabic-Indic digits are
//     REMOVED, never transliterated. That one is handled at the call site in
//     `tracive_query.dart`, which spells the class out as `[^0-9]` rather than
//     writing `\D`.
//
// Nothing here uses a locale. JavaScript's case mapping is locale-invariant,
// so a Turkish-locale device must fold exactly like every other device.
//
// ---------------------------------------------------------------------------
// WHAT IS STILL NOT GUARANTEED — read this before assuming the gap is closed
// ---------------------------------------------------------------------------
// Measured with `dart run tool/verify_js_case_fold.dart` against Node v26
// (Unicode 17.0), which is the release `jsCaseUnicodeVersion` records:
//
//     per-code-point divergences over U+0000-U+10FFFF ....... 0
//     per-string divergences over 200,013 folded samples .... 0
//
// That is a complete result *against that engine*. It is not a promise about
// the engine the Tracive API happens to run, and the difference is not
// hypothetical: case mapping is a function of the Unicode release, and two
// scripts in the tables gained their case pairings very recently.
//
//   * Garay       (U+10D50-10D85, 44 table entries) — Unicode 16.0
//   * Beria Erfe  (U+16EA0-16ED3, 50 table entries) — Unicode 17.0
//
// If the API's engine predates those releases it leaves those 94 code points
// alone and this SDK folds them, so the keys differ. Nothing else in the
// tables is younger than Unicode 14.0. Neither script is plausible in a bank
// code, a chain code or a handle today, which is why this ships — but it is a
// known, bounded divergence rather than none, and it is the reason
// `jsCaseUnicodeVersion` exists. Point `tool/generate_js_case_data.dart` at the
// API's own Node version to close it, and `tool/verify_js_case_fold.dart` to
// re-measure.
// ---------------------------------------------------------------------------

import 'js_case_data.dart';

/// U+03A3 GREEK CAPITAL LETTER SIGMA — the one code point whose lowercase form
/// depends on the characters around it.
const int _capitalSigma = 0x03A3;

/// [_capitalSigma] as a string, for the fast-path scan.
const String _capitalSigmaText = '\u{3A3}';

/// U+03C2 GREEK SMALL LETTER FINAL SIGMA.
const String _finalSigma = '\u{3C2}';

/// U+03C3 GREEK SMALL LETTER SIGMA.
const String _medialSigma = '\u{3C3}';

/// The code points JavaScript's `String.prototype.trim()` strips.
///
/// Transcribed from `crossLanguageSemantics.trimSet.codepoints` in the vendored
/// fixture — deliberately written out rather than delegated to
/// [String.trim] or to a `\s` character class, because both differ from this
/// set (see the note at the top of this file).
///
/// U+0085 NEXT LINE and U+200B ZERO WIDTH SPACE are absent on purpose.
const Set<int> jsWhitespace = <int>{
  0x0009, // CHARACTER TABULATION
  0x000A, // LINE FEED
  0x000B, // LINE TABULATION
  0x000C, // FORM FEED
  0x000D, // CARRIAGE RETURN
  0x0020, // SPACE
  0x00A0, // NO-BREAK SPACE
  0x1680, // OGHAM SPACE MARK
  0x2000, // EN QUAD
  0x2001, // EM QUAD
  0x2002, // EN SPACE
  0x2003, // EM SPACE
  0x2004, // THREE-PER-EM SPACE
  0x2005, // FOUR-PER-EM SPACE
  0x2006, // SIX-PER-EM SPACE
  0x2007, // FIGURE SPACE
  0x2008, // PUNCTUATION SPACE
  0x2009, // THIN SPACE
  0x200A, // HAIR SPACE
  0x2028, // LINE SEPARATOR
  0x2029, // PARAGRAPH SEPARATOR
  0x202F, // NARROW NO-BREAK SPACE
  0x205F, // MEDIUM MATHEMATICAL SPACE
  0x3000, // IDEOGRAPHIC SPACE
  0xFEFF, // ZERO WIDTH NO-BREAK SPACE (BOM)
};

/// Strips leading and trailing [jsWhitespace], exactly as JavaScript's
/// `String.prototype.trim()` does.
///
/// Use this instead of [String.trim] anywhere the result becomes part of a
/// query key.
String jsTrim(String value) {
  var start = 0;
  var end = value.length;
  while (start < end && jsWhitespace.contains(value.codeUnitAt(start))) {
    start++;
  }
  while (end > start && jsWhitespace.contains(value.codeUnitAt(end - 1))) {
    end--;
  }
  if (start == 0 && end == value.length) return value;
  return value.substring(start, end);
}

/// Uppercases [value] with JavaScript's locale-invariant full case mapping.
///
/// ## What this guarantees
///
/// For every code point in Unicode [jsCaseUnicodeVersion], this returns what
/// `String.prototype.toUpperCase()` returns in a JavaScript engine built
/// against that release — on the Dart VM, on AOT, and on dart2js alike. The
/// tables in `js_case_data.dart` hold the engine's answer rather than a patch
/// to Dart's, so applying them on dart2js (where Dart's own case methods
/// already compile to JavaScript's) changes nothing.
///
/// ## What it does not guarantee
///
/// The tables are a snapshot of one Unicode release. If the Tracive API's
/// JavaScript engine is built against a *different* release, the two disagree
/// on exactly the code points whose case mapping changed between them — in
/// practice, the letters of scripts that gained a case pairing in the newer
/// release. Regenerate against the API's engine with
/// `dart run tool/generate_js_case_data.dart` when that happens;
/// `--verify` checks the committed tables without writing.
String jsToUpperCase(String value) {
  if (!_containsAnyOf(value, jsUppercaseDeltas)) return value.toUpperCase();
  final buffer = StringBuffer();
  for (final rune in value.runes) {
    final mapped = jsUppercaseDeltas[rune];
    buffer.write(mapped ?? String.fromCharCode(rune).toUpperCase());
  }
  return buffer.toString();
}

/// Lowercases [value] with JavaScript's locale-invariant full case mapping,
/// including the Final_Sigma rule.
///
/// The same guarantees and the same Unicode-release caveat as [jsToUpperCase],
/// plus one rule that is not a table lookup: U+03A3 GREEK CAPITAL LETTER SIGMA
/// lowercases to U+03C2 when it ends a word and to U+03C3 otherwise, so
/// `ΟΔΟΣ` folds to `οδος` and `ΟΔΟΣΑ` folds to `οδοσα`. Dart's own
/// `toLowerCase` always produces U+03C3, which would build a key that misses
/// for any Greek identifier ending in sigma.
String jsToLowerCase(String value) {
  final needsSigmaRule = value.contains(_capitalSigmaText);
  if (!needsSigmaRule && !_containsAnyOf(value, jsLowercaseDeltas)) {
    return value.toLowerCase();
  }
  // Decoded up front because the Final_Sigma condition looks both ways from the
  // sigma, and it is defined over the *original* string, not the folded one.
  final runes = value.runes.toList(growable: false);
  final buffer = StringBuffer();
  for (var index = 0; index < runes.length; index++) {
    final rune = runes[index];
    if (rune == _capitalSigma) {
      buffer.write(_isFinalSigmaAt(runes, index) ? _finalSigma : _medialSigma);
      continue;
    }
    final mapped = jsLowercaseDeltas[rune];
    buffer.write(mapped ?? String.fromCharCode(rune).toLowerCase());
  }
  return buffer.toString();
}

/// Whether [value] contains any code point [table] maps.
///
/// Iterating runes rather than code units matters: the tables contain
/// supplementary-plane code points (Adlam, Osage, Warang Citi, Medefaidrin,
/// Old Hungarian), and a code-unit scan would only ever see their surrogate
/// halves — which are not keys — and would wrongly take the fast path.
///
/// When nothing matches, Dart's own whole-string mapping is already the right
/// answer: JavaScript's case mapping is per-code-point everywhere except
/// U+03A3, which [jsToLowerCase] handles separately, so mapping the whole
/// string and mapping it code point by code point agree.
bool _containsAnyOf(String value, Map<int, String> table) {
  for (final rune in value.runes) {
    if (table.containsKey(rune)) return true;
  }
  return false;
}

/// The Unicode `Final_Sigma` condition from `SpecialCasing.txt`, evaluated at
/// [index] of [runes].
///
/// It holds when the sigma is preceded by a cased letter (case-ignorable
/// characters in between do not break the run) and is *not* followed by one on
/// the same terms. It carries no language condition, so JavaScript's
/// locale-invariant `toLowerCase()` applies it and Dart's does not.
bool _isFinalSigmaAt(List<int> runes, int index) {
  var before = index - 1;
  while (before >= 0 && _inRanges(caseIgnorableRanges, runes[before])) {
    before--;
  }
  if (before < 0 || !_inRanges(casedRanges, runes[before])) return false;

  var after = index + 1;
  while (after < runes.length && _inRanges(caseIgnorableRanges, runes[after])) {
    after++;
  }
  return after >= runes.length || !_inRanges(casedRanges, runes[after]);
}

/// Binary search over a flattened, sorted list of inclusive `[start, end]`
/// pairs.
bool _inRanges(List<int> ranges, int codePoint) {
  var low = 0;
  var high = (ranges.length >> 1) - 1;
  while (low <= high) {
    final middle = (low + high) >> 1;
    if (codePoint < ranges[middle << 1]) {
      high = middle - 1;
    } else if (codePoint > ranges[(middle << 1) + 1]) {
      low = middle + 1;
    } else {
      return true;
    }
  }
  return false;
}
