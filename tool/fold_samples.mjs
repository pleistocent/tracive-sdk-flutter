// Copyright 2026 PT Pleistocent Teknologi Nusantara.
// Licensed under the Apache License, Version 2.0.
//
// Folds a JSON array of strings with the JavaScript engine's own
// `toUpperCase()` / `toLowerCase()`, and writes `[[upper, lower], ...]`.
//
// Reads the array from the file named by argv[2] and writes to stdout. Driven
// by `tool/verify_js_case_fold.dart`; see that file for why.

import { readFileSync } from 'node:fs';

const samples = JSON.parse(readFileSync(process.argv[2], 'utf8'));
process.stdout.write(
  JSON.stringify(samples.map((s) => [s.toUpperCase(), s.toLowerCase()])),
);
