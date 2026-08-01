// Copyright (c) Tracive. Licensed under the Apache License, Version 2.0.
//
// The anti-drift contract test.
//
// `test/fixtures/query-grammar-vectors.json` is vendored verbatim into the
// Kotlin, Flutter and Swift SDK repos. Every `vectors[]` entry must fold to its
// `expected` string byte-for-byte, and every `rejected[]` entry must throw with
// the stated `reason`. If this file fails, this SDK has drifted from the other
// two and from the backend - fix the fold, not the fixture.
//
// NO NETWORK. Nothing here (and nothing in `lib/src/query/`) opens a socket.
// Query folding is pure string work by design: validation has to happen before
// a request is sent, because a key that cannot match is still billed.
//
// Non-ASCII is written with explicit \u escapes throughout. A test that pastes
// a composed and a decomposed 'e-acute' as raw characters is one editor save
// away from being vacuously true, and NFC is the whole point of half of these.

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tracive_sdk/tracive_sdk.dart';
// Imported directly rather than through the barrel: the document-id guard is
// an internal invariant, not public surface, but the fixture's `RAW` vectors
// are raw keys and can only be exercised against the guard itself.
import 'package:tracive_sdk/src/query/document_id.dart';
// Same reasoning: the JavaScript-semantics helpers are internal, but the
// fixture's `crossLanguageSemantics` block is a statement about them, so it can
// only be executed against them directly.
import 'package:tracive_sdk/src/query/js_string.dart';

void main() {
  final fixture = _loadFixture();
  final vectors = (fixture['vectors'] as List).cast<Map<String, Object?>>();
  final rejected = (fixture['rejected'] as List).cast<Map<String, Object?>>();

  setUp(() {
    // Every vector is folded with the shipped normalizer, so an injected one
    // from another test can never leak in.
    TraciveNormalization.normalizer = const DefaultNormalizer();
  });

  group('fixture', () {
    test('is the version this SDK was written against', () {
      // Version 2 added `crossLanguageSemantics`, `documentIdGuard` and the
      // eight vectors that pin JavaScript's string semantics down (full case
      // mapping, the JS trim set, ASCII-only \D). Version 3 corrected
      // `nfcScope`, which used to read as though NFC applied to the social and
      // chain platform codes but not to a bank code, and added the vector that
      // pins the bank code's NFC step down.
      expect(fixture['version'], 3);
    });

    test('carries the vectors it is supposed to', () {
      expect(vectors, hasLength(34));
      expect(rejected, hasLength(11));
    });

    test('carries the sections version 2 added', () {
      expect(fixture['crossLanguageSemantics'], isA<Map<String, Object?>>());
      expect(fixture['documentIdGuard'], isA<Map<String, Object?>>());
    });

    test('uses only rejection reasons this SDK knows', () {
      for (final entry in rejected) {
        expect(
          QueryRejectionReason.values,
          contains(entry['reason']),
          reason: 'unknown reason in vector ${entry['id']}',
        );
      }
    });

    test('still forbids a DOMAIN builder', () {
      // The plan lists a DOMAIN input type; the backend dropped it, so a
      // `DOMAIN_...` key could never match - and a miss is billed. There is
      // deliberately no `TraciveQuery.domain()`, and `QueryType` has no
      // `domain` member. If this assertion ever fails because the fixture
      // changed, that is the signal to add the builder - not before.
      expect(fixture['notImplemented'], contains('DOMAIN'));
      expect(
        QueryType.values.map((type) => type.wireValue),
        isNot(contains('DOMAIN')),
      );
    });
  });

  group('vectors', () {
    for (final vector in vectors) {
      final id = vector['id'] as String;
      final expected = vector['expected'] as String;
      test('$id -> $expected', () {
        expect(_build(vector).searchQueryIndex, expected);
      });
    }

    test('every folded key is a valid record key', () {
      for (final vector in vectors) {
        expect(
          isValidDocumentId(vector['expected'] as String),
          isTrue,
          reason: 'vector ${vector['id']}',
        );
      }
    });

    test('folding is idempotent - folding a folded value changes nothing', () {
      // Matters because the server folds caller-supplied keys again on the read
      // path. A fold that is not idempotent would resolve to a different
      // document there than the one the cache key was built from.
      for (final vector in vectors) {
        final query = _build(vector);
        expect(
          _refoldSameType(query),
          query.searchQueryIndex,
          reason: 'vector ${vector['id']}',
        );
      }
    });
  });

  group('rejected', () {
    for (final vector in rejected) {
      final id = vector['id'] as String;
      final reason = vector['reason'] as String;
      test('$id -> $reason', () {
        expect(
          () => _build(vector),
          throwsA(
            isA<TraciveQueryException>().having(
              (error) => error.reason,
              'reason',
              reason,
            ),
          ),
        );
      });
    }

    test('the rejected input never appears in the exception', () {
      // A phone number or e-mail address inside an exception message ends up in
      // crash reports and log aggregators. It must not be there.
      for (final vector in rejected) {
        final input = (vector['input'] as Map).values.whereType<String>();
        try {
          _build(vector);
          fail('vector ${vector['id']} should have been rejected');
        } on TraciveQueryException catch (error) {
          final rendered = '${error.message} $error';
          for (final value in input) {
            if (value.trim().isEmpty) continue;
            expect(
              rendered,
              isNot(contains(value)),
              reason: 'vector ${vector['id']} leaked its input',
            );
          }
        }
      }
    });
  });

  // --------------------------------------------------------------------------
  // The `documentIdGuard` block, driven directly. Version 2 of the fixture
  // states the guard as data rather than prose, so it is executed as data.
  // --------------------------------------------------------------------------
  group('document-id guard (fixture-driven)', () {
    final guard = (fixture['documentIdGuard'] as Map).cast<String, Object?>();
    final cases = (guard['cases'] as List).cast<Map<String, Object?>>();

    test('the fixture actually carries cases to run', () {
      // Guards against this whole group passing vacuously if the section is
      // ever renamed: an empty list would satisfy every assertion below.
      expect(cases, isNotEmpty);
    });

    for (final entry in cases) {
      final value = entry['value'] as String;
      final safe = entry['safe'] as bool;
      test('${jsonEncode(value)} is ${safe ? 'accepted' : 'rejected'}', () {
        expect(isValidDocumentId(value), safe);
      });
    }

    test('the byte limit is the one the fixture states', () {
      expect(guard['maxUtf8Bytes'], maxDocumentIdBytes);
    });

    test('every character the fixture calls out as legal really is', () {
      // `explicitlyAllowed` is prose, not literals, so the mapping to concrete
      // ids is written out here rather than parsed.
      const allowed = <String>[
        'a b', // spaces
        'a.b', // '.' inside the string
        'EMAIL_budi@gmail.com', // @
        'PHONE_+6281234567891', // +
        'a#b', 'a\$b', 'a[b]', 'a*b', 'a~b', // punctuation
        '\u{1F600}', // emoji
        '__x', 'x__', '_', // underscores that are not the reserved pattern
      ];
      for (final id in allowed) {
        expect(isValidDocumentId(id), isTrue, reason: 'id ${jsonEncode(id)}');
      }
    });

    test('rejects a lone UTF-16 surrogate', () {
      // The fixture lists this among the rejected shapes. It matters because
      // `utf8.encode` substitutes U+FFFD for an unpaired surrogate, so a naive
      // byte-length check would wave it through and the key would be rejected
      // by the API instead - after the credit was spent.
      const highOnly = 'A\uD83D';
      const lowOnly = 'A\uDE00';
      expect(isValidDocumentId(highOnly), isFalse);
      expect(isValidDocumentId(lowOnly), isFalse);
      expect(
        isValidDocumentId('A😀'),
        isTrue,
        reason: 'a well-formed pair is an emoji, which is explicitly allowed',
      );
    });

    test('the byte limit is applied to the folded key, not the input', () {
      // 'ß' uppercases to 'SS', so folding grows the account segment. The guard
      // must measure what actually becomes the document id.
      final account = 'ß' * 800; // 800 chars in, 1600 chars out.
      expect(
        () => TraciveQuery.bankAccount(
          countryAlpha3: 'DEU',
          bankCode: 'DB',
          account: account,
        ),
        throwsA(
          isA<TraciveQueryException>().having(
            (error) => error.reason,
            'reason',
            QueryRejectionReason.invalidDocumentId,
          ),
        ),
      );
    });
  });

  // --------------------------------------------------------------------------
  // The `crossLanguageSemantics` block. The backend folds in JavaScript; these
  // tests assert this SDK reproduces JS semantics rather than Dart's, and each
  // one also asserts that Dart's built-in would have given a *different*
  // answer - otherwise the test would pass whether or not `js_string.dart`
  // existed, and would prove nothing.
  // --------------------------------------------------------------------------
  group('cross-language semantics', () {
    final semantics =
        (fixture['crossLanguageSemantics'] as Map).cast<String, Object?>();

    test('jsTrim strips exactly the fixture trim set', () {
      final trimSet = (semantics['trimSet'] as Map).cast<String, Object?>();
      final stripped = (trimSet['codepoints'] as List).cast<String>();
      expect(stripped, isNotEmpty);
      for (final name in stripped) {
        final char = String.fromCharCode(_parseCodePoint(name));
        expect(
          jsTrim('$char' 'x' '$char'),
          'x',
          reason: 'jsTrim must strip $name',
        );
      }
      expect(
        jsWhitespace.map(_formatCodePoint).toSet(),
        stripped.toSet(),
        reason: 'the shipped set and the fixture set must be the same set',
      );

      for (final name in (trimSet['notStripped'] as List).cast<String>()) {
        final char = String.fromCharCode(_parseCodePoint(name));
        final subject = '$char' 'x' '$char';
        expect(jsTrim(subject), subject, reason: 'jsTrim must keep $name');
      }
    });

    test("jsTrim differs from Dart's trim at U+0085", () {
      // The reason this SDK cannot just call String.trim(). JS leaves NEL
      // alone; Dart strips it. Without this assertion the test above would
      // still pass using the built-in.
      const nel = '\u0085';
      expect('${nel}x$nel'.trim(), 'x', reason: "Dart's trim strips NEL");
      expect(jsTrim('${nel}x$nel'), '${nel}x$nel', reason: 'JS does not');
    });

    test('case mapping is full and length-changing, not simple', () {
      final examples = ((semantics['caseMapping'] as Map)['examples'] as Map)
          .cast<String, Object?>();
      expect(examples[r'ß -> uppercase'], 'SS');

      expect(jsToUpperCase('ß'), 'SS');
      expect('ß'.toUpperCase(), 'ß', reason: "Dart's is simple");

      expect(jsToLowerCase('İ'), 'i̇');
      expect('İ'.toLowerCase(), 'i', reason: "Dart's drops the mark");

      // A PDF or bank-statement paste is where these actually turn up.
      expect(jsToUpperCase('ﬃ'), 'FFI'); // ffi ligature
      expect(jsToUpperCase('ﬁ'), 'FI'); // fi ligature
    });

    test('case mapping is locale-invariant', () {
      // Dart has no locale-sensitive case API, so there is no locale to pass
      // wrong - but the dotted/dotless Turkish pair is asserted anyway, because
      // that is the exact value a Turkish locale would change.
      expect(jsToLowerCase('I'), 'i');
      expect(jsToUpperCase('i'), 'I');
      expect(jsToLowerCase('İ'), 'i̇');
    });

    test(r'\D is ASCII [^0-9]: Arabic-Indic digits are stripped', () {
      // U+0669 ARABIC-INDIC NINE is removed, never turned into '9'.
      expect(
        TraciveQuery.phone('+62812345678٩').searchQueryIndex,
        'PHONE_+62812345678',
      );
      expect(
        RegExp(r'\d').hasMatch('٩'),
        isFalse,
        reason: r"Dart's \d is already ASCII-only; ICU's would not be",
      );
    });

    test('NFC applies to email, username and every code field, nothing else',
        () {
      expect(semantics['nfcScope'], contains('email'));

      // A decomposed 'e' + U+0301 composes in an e-mail...
      expect(
        TraciveQuery.email('café@x.com').searchQueryIndex,
        'EMAIL_café@x.com',
      );
      // ...and in a username handle.
      expect(
        TraciveQuery.username(
          platform: 'IG',
          handle: 'café',
        ).searchQueryIndex,
        'USERNAME_IG_café',
      );
      // ...and in a bank code, which is a code field like the social platform
      // and the chain are. 'A' + U+0301 composes to U+00C1 before uppercasing,
      // so an implementation that skips NFC here builds a key that misses.
      expect(
        TraciveQuery.bankAccount(
          countryAlpha3: 'IDN',
          bankCode: 'BCÁ',
          account: '1234567890',
        ).searchQueryIndex,
        'BANK_IDN_BCÁ_1234567890',
        reason: 'a bank code is NFC-folded before it is uppercased',
      );
      // ...but NOT in a crypto address...
      expect(
        TraciveQuery.crypto(
          chain: 'BTC',
          address: 'éx',
        ).searchQueryIndex,
        'CRYPTO_BTC_éx',
        reason: 'a crypto address is never NFC-folded',
      );
      // ...nor in a bank account id.
      expect(
        TraciveQuery.bankAccount(
          countryAlpha3: 'IDN',
          bankCode: 'BCA',
          account: 'ÉX',
        ).searchQueryIndex,
        'BANK_IDN_BCA_ÉX',
        reason: 'a bank account id is never NFC-folded',
      );
    });

    test('the EVM fold requires a lowercase 0x prefix', () {
      const address = '0X52908400098527886E0F7030069857D2E4169EE7';
      expect(
        TraciveQuery.crypto(chain: 'ETH', address: address).searchQueryIndex,
        'CRYPTO_ETH_$address',
        reason: 'an uppercase 0X address is deliberately left unfolded',
      );
    });

    test('the bank account fold has no separate trim step', () {
      // foldOrder: "bank account: uppercase -> strip [\\s-] (NO separate
      // trim)". Stripping the class already removes surrounding whitespace, so
      // a trim would be redundant - but U+200B is in neither, and must survive
      // at the edges exactly as it does in the middle.
      expect(
        TraciveQuery.bankAccount(
          countryAlpha3: 'IDN',
          bankCode: 'BCA',
          account: ' 12 34 ',
        ).searchQueryIndex,
        'BANK_IDN_BCA_1234',
      );
      expect(
        TraciveQuery.bankAccount(
          countryAlpha3: 'IDN',
          bankCode: 'BCA',
          account: '\u200B1234',
        ).searchQueryIndex,
        'BANK_IDN_BCA_\u200B1234',
      );
    });

    test('a phone key is folded client-side because the server never folds it',
        () {
      expect(semantics['phoneFolding'], contains('client-side'));
      expect(
        TraciveQuery.phone('  +62 (812) 3456-7891  ').searchQueryIndex,
        'PHONE_+6281234567891',
      );
    });
  });

  group('document-id guard', () {
    test('rejects a slash produced by an otherwise valid builder call', () {
      // Proves the guard runs on built keys, not only on the fixture's RAW
      // strings: an account number containing '/' survives the account fold.
      expect(
        () => TraciveQuery.bankAccount(
          countryAlpha3: 'IDN',
          bankCode: 'BCA',
          account: '12/34',
        ),
        throwsA(
          isA<TraciveQueryException>().having(
            (error) => error.reason,
            'reason',
            QueryRejectionReason.invalidDocumentId,
          ),
        ),
      );
    });

    test('rejects "." and ".."', () {
      expect(isValidDocumentId('.'), isFalse);
      expect(isValidDocumentId('..'), isFalse);
      expect(isValidDocumentId('...'), isTrue);
    });

    test('measures the 1500 limit in UTF-8 bytes, not characters', () {
      final asciiAtLimit = 'A' * maxDocumentIdBytes;
      expect(isValidDocumentId(asciiAtLimit), isTrue);
      expect(isValidDocumentId('$asciiAtLimit!'), isFalse);

      // U+00E9 is two UTF-8 bytes, so half as many characters fit.
      const eAcute = '\u00E9';
      final twoByteAtLimit = eAcute * (maxDocumentIdBytes ~/ 2);
      expect(utf8.encode(twoByteAtLimit), hasLength(maxDocumentIdBytes));
      expect(isValidDocumentId(twoByteAtLimit), isTrue);
      expect(isValidDocumentId(twoByteAtLimit + eAcute), isFalse);
    });

    test('rejects the empty id', () {
      expect(isValidDocumentId(''), isFalse);
    });

    test('rejects reserved keys', () {
      expect(isValidDocumentId('__proto__'), isFalse);
      expect(isValidDocumentId('__id7__'), isFalse);
      expect(isValidDocumentId('__lead'), isTrue);
      expect(isValidDocumentId('PHONE_+6281234567891'), isTrue);
    });
  });

  group('folding details the fixture pins down but does not spell out', () {
    test('a phone number without "+" is rejected, never up-converted', () {
      expect(
        () => TraciveQuery.phone('081234567891'),
        throwsA(
          isA<TraciveQueryException>().having(
            (e) => e.reason,
            'reason',
            QueryRejectionReason.notE164,
          ),
        ),
      );
    });

    test('E.164 boundary lengths', () {
      // 7 digits total is the shortest the pattern admits, 15 the longest.
      expect(TraciveQuery.phone('+1234567').searchQueryIndex, 'PHONE_+1234567');
      expect(
        TraciveQuery.phone('+123456789012345').searchQueryIndex,
        'PHONE_+123456789012345',
      );
      expect(() => TraciveQuery.phone('+123456'), throwsA(_queryError));
      expect(
        () => TraciveQuery.phone('+1234567890123456'),
        throwsA(_queryError),
      );
    });

    test('a bech32 address keeps its case; an EVM address does not', () {
      expect(
        TraciveQuery.crypto(
          chain: 'BTC',
          address: 'BC1QAR0SRRR7XFKVY5L643LYDNW9RE59GTZZWF5MDQ',
        ).searchQueryIndex,
        'CRYPTO_BTC_BC1QAR0SRRR7XFKVY5L643LYDNW9RE59GTZZWF5MDQ',
        reason: r'only ^0x[0-9a-fA-F]{40}$ is case-folded',
      );
    });

    test('a 39-digit hex address is not treated as EVM', () {
      final short = '0x${'A' * 39}';
      expect(
        TraciveQuery.crypto(chain: 'ETH', address: short).searchQueryIndex,
        'CRYPTO_ETH_$short',
      );
    });

    test('the account fold uppercases before stripping', () {
      expect(
        TraciveQuery.iban('de89-3704 0044-0532 0130 00').searchQueryIndex,
        'BANK_IBAN_DE89370400440532013000',
      );
    });

    test(
      'underscores are stripped from the bank code only, not the account',
      () {
        expect(
          TraciveQuery.bankAccount(
            countryAlpha3: 'IDN',
            bankCode: '_B_C_A_',
            account: 'AB_12',
          ).searchQueryIndex,
          'BANK_IDN_BCA_AB_12',
          reason: 'the account segment is last, so it may keep underscores',
        );
      },
    );

    test('a lowercase alpha-3 country is accepted, alpha-2 is not', () {
      expect(
        TraciveQuery.bankAccount(
          countryAlpha3: ' idn ',
          bankCode: 'BCA',
          account: '1',
        ).searchQueryIndex,
        'BANK_IDN_BCA_1',
      );
      for (final country in <String>['ID', 'IDNA', '1DN', '']) {
        expect(
          () => TraciveQuery.bankAccount(
            countryAlpha3: country,
            bankCode: 'BCA',
            account: '1',
          ),
          throwsA(
            isA<TraciveQueryException>().having(
              (e) => e.reason,
              'reason',
              QueryRejectionReason.countryNotAlpha3,
            ),
          ),
          reason: 'country "$country"',
        );
      }
    });

    test('queries with the same folded key are equal', () {
      expect(
        TraciveQuery.phone('+62 812 3456 7891'),
        TraciveQuery.phone('+6281234567891'),
      );
      expect(
        TraciveQuery.phone('+6281234567891').hashCode,
        TraciveQuery.phone('+62-812-3456-7891').hashCode,
      );
    });

    test('toString never prints the identifier', () {
      final rendered = TraciveQuery.email('budi@gmail.com').toString();
      expect(rendered, isNot(contains('budi')));
      expect(rendered, isNot(contains('gmail')));
      expect(rendered, contains('redacted'));
    });
  });

  // --------------------------------------------------------------------------
  // NFC. Read `lib/src/query/normalizer.dart` before changing anything here.
  //
  // Dart's core library has no NFC. `DefaultNormalizer` therefore ships the
  // composition half of the algorithm - canonical ordering plus canonical
  // composition over every BMP primary composite, plus algorithmic Hangul -
  // which is exactly NFC for already-decomposed input. That is what the
  // `email-nfc-decomposed` vector above exercises for real: its input really is
  // 'e' + U+0301, not a precomposed U+00E9 (asserted below).
  //
  // It is NOT full NFC, and these tests say so out loud rather than pretending
  // otherwise: there is no canonical *decomposition* step, so singletons and
  // composition-excluded characters come out unchanged. Where that matters,
  // inject a full implementation - the last test here proves the seam works.
  // --------------------------------------------------------------------------
  group('NFC (DefaultNormalizer)', () {
    const normalizer = DefaultNormalizer();

    test('the fixture vector really is decomposed input', () {
      final vector = vectors.firstWhere(
        (v) => v['id'] == 'email-nfc-decomposed',
      );
      final input = (vector['input'] as Map)['value'] as String;
      expect(
        input.runes,
        contains(0x0301),
        reason: 'if this fails the vector no longer tests NFC at all',
      );
      expect(input.runes, isNot(contains(0x00E9)));
    });

    test('composes Latin, Vietnamese, Greek, Cyrillic and Kana', () {
      // e + combining acute -> U+00E9
      expect(normalizer.nfc('cafe\u0301'), 'caf\u00E9');
      // e + circumflex + tilde -> U+1EC5 (Vietnamese)
      expect(normalizer.nfc('nguye\u0302\u0303n'), 'nguy\u1EC5n');
      // Greek alpha + acute -> U+03AC
      expect(normalizer.nfc('\u03B1\u0301'), '\u03AC');
      // Cyrillic i + breve -> U+0439
      expect(normalizer.nfc('\u0438\u0306'), '\u0439');
      // Kana ka + voiced sound mark -> U+304C
      expect(normalizer.nfc('\u304B\u3099'), '\u304C');
    });

    test('composes Hangul jamo algorithmically', () {
      // L U+1112 + V U+1161 + T U+11AB -> U+D55C
      expect(normalizer.nfc('\u1112\u1161\u11AB'), '\uD55C');
      // L + V alone -> the LV syllable U+D558
      expect(normalizer.nfc('\u1112\u1161'), '\uD558');
    });

    test('reorders combining marks by canonical class before composing', () {
      // U+0323 (below, class 220) sorts before U+0307 (above, class 230);
      // a + U+0323 then composes to U+1EA1 and U+0307 is left over.
      expect(normalizer.nfc('a\u0307\u0323'), '\u1EA1\u0307');
    });

    test('does not compose across a blocking mark', () {
      // Both marks are class 230, so U+0301 is blocked from the starter: only
      // the first one composes.
      expect(normalizer.nfc('a\u0307\u0301'), '\u0227\u0301');
    });

    test('leaves ASCII and already-composed text untouched', () {
      expect(normalizer.nfc('budi@gmail.com'), 'budi@gmail.com');
      expect(normalizer.nfc('caf\u00E9'), 'caf\u00E9');
      expect(normalizer.nfc(''), '');
    });

    test('DOCUMENTED LIMITATION: singletons are not decomposed', () {
      // Full NFC maps U+212B ANGSTROM SIGN to U+00C5 and U+2126 OHM SIGN to
      // U+03A9. This normalizer has no decomposition step, so it does not.
      // The consequence is real: such a key would differ from the server's,
      // and the resulting miss would still be billed. Inject a full normalizer
      // if your input can contain these.
      expect(normalizer.nfc('\u212B'), '\u212B');
      expect(normalizer.nfc('\u2126'), '\u2126');
    });

    test('DOCUMENTED LIMITATION: non-BMP code points pass through', () {
      // Nothing outside the BMP composes here, but it must survive intact -
      // and composition around it must still work.
      expect(normalizer.nfc('\u{1F600}'), '\u{1F600}');
      expect(normalizer.nfc('\u{1F600}e\u0301'), '\u{1F600}\u00E9');
    });

    test('an injected normalizer is what the builders actually use', () {
      addTearDown(() {
        TraciveNormalization.normalizer = const DefaultNormalizer();
      });

      // The platform segment folds NFC -> uppercase, and U+212B is its own
      // uppercase, so the shipped normalizer leaves the singleton in the key.
      expect(
        TraciveQuery.username(platform: '\u212B', handle: 'x').searchQueryIndex,
        'USERNAME_\u212B_x',
      );

      TraciveNormalization.normalizer = const _AngstromAwareNormalizer();
      expect(
        TraciveQuery.username(platform: '\u212B', handle: 'x').searchQueryIndex,
        'USERNAME_\u00C5_x',
        reason: 'the seam must reach every fold that requires NFC',
      );
    });
  });
}

final Matcher _queryError = isA<TraciveQueryException>();

/// Parses a `"U+00A0"` style name from the fixture into a code point.
int _parseCodePoint(String name) {
  expect(name, startsWith('U+'), reason: 'malformed code point name $name');
  return int.parse(name.substring(2), radix: 16);
}

/// The inverse of [_parseCodePoint], so the shipped set can be compared to the
/// fixture's set in the fixture's own spelling.
String _formatCodePoint(int codePoint) =>
    'U+${codePoint.toRadixString(16).toUpperCase().padLeft(4, '0')}';

/// Stands in for a full-Unicode implementation (`unorm_dart`) in the injection
/// test: it fixes exactly the singleton `DefaultNormalizer` documents leaving
/// alone.
class _AngstromAwareNormalizer implements Normalizer {
  const _AngstromAwareNormalizer();

  @override
  String nfc(String input) =>
      const DefaultNormalizer().nfc(input.replaceAll('\u212B', '\u00C5'));
}

/// Builds the query a fixture entry describes.
TraciveQuery _build(Map<String, Object?> vector) {
  final input = (vector['input'] as Map).cast<String, Object?>();
  switch (vector['type'] as String) {
    case 'PHONE':
      return TraciveQuery.phone(input['value'] as String);
    case 'EMAIL':
      return TraciveQuery.email(input['value'] as String);
    case 'BANK':
      if (input['isIban'] == true) {
        return TraciveQuery.iban(input['iban'] as String);
      }
      return TraciveQuery.bankAccount(
        countryAlpha3: input['country'] as String,
        bankCode: input['bankCode'] as String,
        account: input['accountId'] as String,
      );
    case 'CRYPTO':
      return TraciveQuery.crypto(
        chain: input['chain'] as String,
        address: input['address'] as String,
      );
    case 'USERNAME':
      return TraciveQuery.username(
        platform: input['platform'] as String,
        handle: input['handle'] as String,
      );
    case 'RAW':
      // A raw key, not builder input: it exercises the document-id guard.
      validateDocumentId(input['value'] as String);
      fail('RAW vector ${vector['id']} was accepted by the guard');
    default:
      fail('unknown vector type ${vector['type']} in ${vector['id']}');
  }
}

/// Feeds a folded key back through the builder for its own type, so the fold
/// can be checked for idempotency.
String _refoldSameType(TraciveQuery query) {
  final key = query.searchQueryIndex;
  switch (query.type) {
    case QueryType.phone:
      return TraciveQuery.phone(
        key.substring('PHONE_'.length),
      ).searchQueryIndex;
    case QueryType.email:
      return TraciveQuery.email(
        key.substring('EMAIL_'.length),
      ).searchQueryIndex;
    case QueryType.bank:
      final parts = key.substring('BANK_'.length).split('_');
      if (parts.first == 'IBAN') {
        return TraciveQuery.iban(parts.sublist(1).join('_')).searchQueryIndex;
      }
      return TraciveQuery.bankAccount(
        countryAlpha3: parts[0],
        bankCode: parts[1],
        account: parts.sublist(2).join('_'),
      ).searchQueryIndex;
    case QueryType.crypto:
      final rest = key.substring('CRYPTO_'.length);
      final split = rest.indexOf('_');
      return TraciveQuery.crypto(
        chain: rest.substring(0, split),
        address: rest.substring(split + 1),
      ).searchQueryIndex;
    case QueryType.username:
      final rest = key.substring('USERNAME_'.length);
      final split = rest.indexOf('_');
      return TraciveQuery.username(
        platform: rest.substring(0, split),
        handle: rest.substring(split + 1),
      ).searchQueryIndex;
  }
}

/// Loads the vendored fixture, tolerating either the package root or `test/`
/// as the working directory.
Map<String, Object?> _loadFixture() {
  const relative = 'test/fixtures/query-grammar-vectors.json';
  const alternative = 'fixtures/query-grammar-vectors.json';
  for (final candidate in <String>[relative, alternative]) {
    final file = File(candidate);
    if (file.existsSync()) {
      return jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
    }
  }
  throw StateError(
    'Could not find $relative. Run `dart test` from the package root.',
  );
}
