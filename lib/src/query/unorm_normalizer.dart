// Copyright (c) Tracive. Licensed under the Apache License, Version 2.0.
//
// Full Unicode NFC for the query grammar.
//
// The SDK's default [DefaultNormalizer] is dependency-free and implements the
// composition half of NFC. It is exact for ASCII, Latin, Greek, Cyrillic and
// Hangul, and for any already-decomposed input — which is most of what reaches
// a mobile SDK. It diverges on singleton decompositions (U+212B ANGSTROM SIGN),
// composition-excluded characters (U+0958 DEVANAGARI QA) and a composed
// character followed by a lower-class combining mark.
//
// Every one of those divergences produces a **different key from the server's**,
// and a miss is still billed. This adapter closes the gap.
//
// WHY IT LIVES IN THE SDK RATHER THAN IN EVERY HOST APP
// -----------------------------------------------------
// `unorm_dart` is a declared dependency of this package (see pubspec.yaml), so
// every integrator already resolves and ships it. Making each of them hand-copy
// a four-line adapter to use what they are already paying for is a
// copy-paste-and-drift hazard on the one code path where drift is billed. The
// seam is unchanged: this is still an opt-in [Normalizer], not the default.

import 'package:unorm_dart/unorm_dart.dart' as unorm;

import 'normalizer.dart';

/// A [Normalizer] backed by `package:unorm_dart` — full Unicode NFC.
///
/// Prefer this over the default [DefaultNormalizer] when your app can receive
/// e-mail addresses, social handles, platform names or chain codes containing
/// characters outside [DefaultNormalizer]'s documented scope. It is slower and
/// allocates more; that is the trade for exactness.
///
/// Install it once, at start-up, before any `TraciveQuery` is built:
///
/// ```dart
/// void main() {
///   TraciveNormalization.normalizer = const UnormNormalizer();
///   runApp(const MyApp());
/// }
/// ```
///
/// This is **not** the default. Changing the default would change every
/// existing integrator's folded keys — and therefore their cache keys — in a
/// patch release. Opting in is a decision an app makes knowingly.
class UnormNormalizer implements Normalizer {
  /// Creates the normalizer. `const`, stateless, safe to share.
  const UnormNormalizer();

  @override
  String nfc(String input) => unorm.nfc(input);
}
