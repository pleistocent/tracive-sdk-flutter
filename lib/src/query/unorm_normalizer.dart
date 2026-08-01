// Copyright (c) Tracive. Licensed under the Apache License, Version 2.0.
//
// Full Unicode NFC for the query grammar — and the SDK's default fold.
//
// The alternative, [DefaultNormalizer], is dependency-free and implements the
// composition half of NFC. It is exact for ASCII, Latin, Greek, Cyrillic and
// Hangul, and for any already-decomposed input — which is most of what reaches
// a mobile SDK. It diverges on singleton decompositions (U+212B ANGSTROM SIGN),
// composition-excluded characters (U+0958 DEVANAGARI QA) and a composed
// character followed by a lower-class combining mark: 565 BMP code points in
// all.
//
// Every one of those divergences produces a **different key from the server's**,
// and a miss is still billed, with nothing to notice it by. That is why this
// implementation is the default and that one is the opt-out.
//
// WHY THIS DOES NOT COST THE INTEGRATOR ANYTHING TO SHIP
// -----------------------------------------------------
// `unorm_dart` is a declared, non-optional dependency of this package (see
// pubspec.yaml). It was already resolved, downloaded and linked into every
// integrator's app before this file was the default; all that changed is which
// of the two shipped folds gets called.

import 'package:unorm_dart/unorm_dart.dart' as unorm;

import 'normalizer.dart';

/// A [Normalizer] backed by `package:unorm_dart` — full Unicode NFC, and the
/// implementation `TraciveNormalization` installs by default.
///
/// Nothing needs doing to get this: it is what folds every `TraciveQuery`
/// unless a host app deliberately installs something else. It matches the fold
/// the sibling Tracive SDKs get from their platforms (`Normalizer` on Android,
/// `precomposedStringWithCanonicalMapping` on Apple platforms,
/// `String.prototype.normalize` in JavaScript), which is the property that
/// matters: the folded key is the record key, so four SDKs disagreeing about
/// NFC is four SDKs looking up different records for one identifier.
///
/// ## Measured, not assumed
///
/// Checked against Python 3's `unicodedata` at Unicode 16.0.0, which is also
/// the release the server's JavaScript engine folds against:
///
/// * Every BMP code point fed in **raw** (not pre-decomposed): agrees on
///   63 487 of 63 488.
/// * 20 000 randomly generated multi-code-point sequences over an alphabet
///   chosen to be hostile — combining marks, Hangul jamo, Indic and Tamil
///   two-part vowels, Tibetan, Kana voicing marks, Hebrew presentation forms,
///   Arabic hamza carriers: zero divergences.
///
/// ## The one upstream bug, and the guard around it: U+D7A4
///
/// `unorm_dart` 0.3.2 treats U+D7A4 as a Hangul syllable and decomposes it to
/// U+1113 U+1161. It is not one — the Hangul Syllables block ends at U+D7A3,
/// and U+D7A4 is unassigned — so true NFC leaves it alone. `_SBase + _SCount`
/// is exactly U+D7A4, and the bound testing it is `<` where every other clause
/// beside it is half-open.
///
/// Reported upstream: https://github.com/yshrsmz/unorm-dart/issues/84
///
/// [nfc] passes that one code point through untouched rather than letting the
/// package see it. The usual objection to patching around a third-party bug is
/// that the patch has to be re-verified on every release — true of a workaround
/// that guesses at behaviour, and not true of this one. It is a single equality
/// test against a code point that is unassigned in Unicode and will stay that
/// way; no release of `unorm_dart` can make it wrong. If the fix lands upstream
/// the guard becomes redundant, not harmful, and **that is when to delete it**
/// — check the issue above when bumping the dependency.
///
/// The guard exists because "byte-identical to the other three SDKs" is worth
/// having absolutely rather than approximately. The folded key *is* the record
/// key; an exception to that rule is a thing every future reader has to learn,
/// and one comparison is cheaper than the sentence explaining it.
///
/// The composition direction was never affected — U+1113 U+1161 is not composed
/// into U+D7A4 — so ordinary Hangul text was always exact.
///
/// ## Cost
///
/// Roughly 3 µs per fold for an ASCII identifier and about 5 µs for a mixed
/// corpus, on a desktop VM, against 25 ns for [DefaultNormalizer]'s ASCII fast
/// path. The ratio looks alarming and the absolute number is what matters: one
/// fold happens per `TraciveQuery`, which is one per check, which is one
/// network round trip of tens of milliseconds. Folding 10 000 identifiers in a
/// bulk import costs about 30 ms in total.
class UnormNormalizer implements Normalizer {
  /// Creates the normalizer. `const`, stateless, safe to share.
  const UnormNormalizer();

  /// The one code point `unorm_dart` gets wrong. Unassigned, and immediately
  /// above the last Hangul syllable (U+D7A3) — see the class doc and
  /// https://github.com/yshrsmz/unorm-dart/issues/84
  static const int _unassignedAboveHangul = 0xD7A4;

  @override
  String nfc(String input) {
    if (!input.codeUnits.contains(_unassignedAboveHangul)) {
      return unorm.nfc(input);
    }
    // Split on the offending code point, fold each piece, and rejoin with it.
    // Folding around it rather than after it matters: normalization is not
    // distributive over an arbitrary cut, but it is over one made at a code
    // point that is unassigned — nothing composes with it or reorders across
    // it, because it has no canonical decomposition and no combining class.
    return input
        .split(String.fromCharCode(_unassignedAboveHangul))
        .map(unorm.nfc)
        .join(String.fromCharCode(_unassignedAboveHangul));
  }
}
