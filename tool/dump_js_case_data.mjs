// Copyright 2026 PT Pleistocent Teknologi Nusantara.
// Licensed under the Apache License, Version 2.0.
//
// Dumps the JavaScript engine's own case-mapping and case-property tables.
//
// The Tracive API folds query keys in JavaScript, so JavaScript's answer is the
// contract. This script asks the engine directly rather than transcribing
// Unicode data files, which means the output is exactly what the server does —
// including whichever Unicode release the engine was built against.
//
// Run it through `tool/generate_js_case_data.dart`, which turns the output into
// `lib/src/query/js_case_data.dart`:
//
//     dart run tool/generate_js_case_data.dart
//
// The result is written to stdout as JSON.

const SURROGATE_START = 0xd800;
const SURROGATE_END = 0xdfff;
const MAX_CODE_POINT = 0x10ffff;

/** Every code point whose upper- or lowercase mapping is not the identity. */
function mappings() {
  const rows = [];
  for (let cp = 0; cp <= MAX_CODE_POINT; cp++) {
    if (cp >= SURROGATE_START && cp <= SURROGATE_END) continue;
    const one = String.fromCodePoint(cp);
    const upper = one.toUpperCase();
    const lower = one.toLowerCase();
    if (upper === one && lower === one) continue;
    rows.push([cp, upper === one ? null : upper, lower === one ? null : lower]);
  }
  return rows;
}

/** Contiguous ranges of code points matching `pattern`, as [start, end] pairs. */
function ranges(pattern) {
  const out = [];
  let start = -1;
  for (let cp = 0; cp <= MAX_CODE_POINT; cp++) {
    const inSurrogates = cp >= SURROGATE_START && cp <= SURROGATE_END;
    const hit = !inSurrogates && pattern.test(String.fromCodePoint(cp));
    if (hit && start < 0) {
      start = cp;
    } else if (!hit && start >= 0) {
      out.push([start, cp - 1]);
      start = -1;
    }
  }
  if (start >= 0) out.push([start, MAX_CODE_POINT]);
  return out;
}

// The two derived properties the Final_Sigma condition is defined in terms of.
// Taken from the same engine as the mappings, so they can never be one Unicode
// release out of step with them.
const cased = ranges(/\p{Cased}/u);
const caseIgnorable = ranges(/\p{Case_Ignorable}/u);

process.stdout.write(
  JSON.stringify({
    engine: `node ${process.version}`,
    icuVersion: process.versions.icu,
    unicodeVersion: process.versions.unicode,
    mappings: mappings(),
    cased,
    caseIgnorable,
  }),
);
