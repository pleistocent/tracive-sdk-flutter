// Copyright 2026 PT Pleistocent Teknologi Nusantara.
// Licensed under the Apache License, Version 2.0.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('this package and tracive_sdk ship one version', () {
    final base = File('../pubspec.yaml');
    if (!base.existsSync()) {
      markTestSkipped('Outside the repository, as in a published package.');
      return;
    }
    String versionIn(String pubspec) =>
        RegExp(r'^version: (.+)$', multiLine: true)
            .firstMatch(pubspec)!
            .group(1)!;
    expect(
      versionIn(File('pubspec.yaml').readAsStringSync()),
      versionIn(base.readAsStringSync()),
    );
  });
}
