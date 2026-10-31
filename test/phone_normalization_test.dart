// Copyright 2026 PT Pleistocent Teknologi Nusantara.
// Licensed under the Apache License, Version 2.0.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tracive_sdk/tracive_sdk.dart';

/// Drives the vendored `phone-normalization-vectors.json` — the app/SDK
/// anti-drift contract.
///
/// Expected values came from executing the Tracive app's own normalizer. If this
/// SDK disagrees with a vector, this SDK is wrong: app and SDK must fold the
/// same person to the same record key.
void main() {
  final Map<String, dynamic> fixture = jsonDecode(
    File('test/fixtures/phone-normalization-vectors.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  final List<dynamic> vectors = fixture['vectors'] as List<dynamic>;
  final List<dynamic> rejected = fixture['rejected'] as List<dynamic>;
  final List<dynamic> countries = fixture['countries'] as List<dynamic>;

  group('normalizePhoneNumber', () {
    test('every vector folds byte for byte', () {
      expect(vectors, isNotEmpty,
          reason: 'a fixture with no vectors passes vacuously');
      for (final dynamic raw in vectors) {
        final Map<String, dynamic> v = raw as Map<String, dynamic>;
        expect(
          normalizePhoneNumber(v['country'] as String, v['input'] as String),
          v['expected'],
          reason:
              '${v['country']} / ${v['input']} did not fold as the app folds it',
        );
      }
    });

    test('every rejection is refused with its exact reason', () {
      expect(rejected, isNotEmpty);
      for (final dynamic raw in rejected) {
        final Map<String, dynamic> r = raw as Map<String, dynamic>;
        expect(
          () => normalizePhoneNumber(
              r['country'] as String, r['input'] as String),
          throwsA(
            isA<TraciveQueryException>().having(
              (TraciveQueryException e) => e.reason,
              'reason',
              r['reason'],
            ),
          ),
          reason: 'accepted an unusable input: ${r['country']} / ${r['input']}',
        );
      }
    });

    test('the country table matches the contract', () {
      expect(
        Country.values.length,
        fixture['countryCount'],
        reason: 'the table drifted from the fixture',
      );
      expect(
        Country.values.map((Country c) => c.alpha3).toSet().length,
        Country.values.length,
        reason: 'two countries share an alpha-3 code',
      );
      for (final dynamic raw in countries) {
        final Map<String, dynamic> row = raw as Map<String, dynamic>;
        final Country? c = Country.fromAlpha3(row['alpha3'] as String);
        expect(c, isNotNull, reason: '${row['alpha3']} missing from the table');
        expect(c!.dialCode, row['dialCode'], reason: 'dial code drifted');
        expect(c.alpha2, row['alpha2'], reason: 'alpha-2 drifted');
      }
    });

    // Every dial code and every length up to 17: a number typed without '+'
    // that starts with its own dial code keeps those digits only as the
    // fixture's nationalNumberLengths says. The 5s keep trunk rules out of it.
    test('a number starting with its dial code is read by the lengths table',
        () {
      final Map<String, dynamic> lengths =
          fixture['nationalNumberLengths'] as Map<String, dynamic>;
      expect(lengths, isNotEmpty);
      final Set<String> dialCodes = countries
          .map((dynamic c) => (c as Map<String, dynamic>)['dialCode'] as String)
          .toSet()
        ..remove('1');
      for (final String dialCode in dialCodes) {
        final List<dynamic> national =
            lengths[dialCode] as List<dynamic>? ?? <dynamic>[];
        for (int length = dialCode.length + 1; length <= 17; length++) {
          final String rest = '5' * (length - dialCode.length);
          final String typed = dialCode + rest;
          final bool keep = national.contains(length) &&
              !national.contains(length - dialCode.length);
          expect(normalizePhoneNumber(dialCode, typed),
              '+$dialCode${keep ? typed : rest}',
              reason: '$dialCode / $typed');
        }
      }
    });

    test('alpha-3 lookup ignores case and surrounding space', () {
      expect(Country.fromAlpha3('idn'), Country.idn);
      expect(Country.fromAlpha3('  IDN  '), Country.idn);
      expect(
        Country.fromAlpha3('ID'),
        isNull,
        reason: 'alpha-2 must not resolve; this SDK speaks alpha-3',
      );
    });

    test('the result is accepted by the query builder', () {
      final TraciveQuery query = TraciveQuery.phone(
        normalizePhoneNumber('IDN', '0857-1860-9079'),
      );
      expect(query.searchQueryIndex, 'PHONE_+6285718609079');
      expect(
        TraciveQuery.phone(
          normalizePhoneNumberFor(Country.idn, '0857 1860 9079'),
        ).searchQueryIndex,
        query.searchQueryIndex,
        reason: 'alpha-3 and the enum must produce one key, not two',
      );
    });
  });
}
