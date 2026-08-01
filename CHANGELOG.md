# Changelog

All notable changes to `tracive_sdk` are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this package
follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html) — with the
`0.x` caveat that **the public surface may still change in a minor release**
until it is frozen at `1.0.0`.

## [Unreleased]

### Fixed

- **The query fold now reproduces JavaScript's string semantics, not Dart's.**
  The backend folds in JS, and the folded key *is* the record key, so
  a one-code-point difference is a guaranteed miss — and a miss is billed. Two
  divergences were measured and closed, both in the new internal
  `lib/src/query/js_string.dart`:
  - **Case mapping.** Dart's `toUpperCase()`/`toLowerCase()` apply the Unicode
    *simple* mapping; JavaScript applies the *full* one, which can change a
    string's length. `ß` now uppercases to `SS` (it used to stay `ß`) and `İ`
    now lowercases to `i` + U+0307 (it used to lose the combining mark). 103
    code points were affected, including the `ﬁ`/`ﬃ` ligatures that a PDF or
    bank-statement paste carries.
  - **Trim.** Dart's `String.trim()` strips U+0085 NEXT LINE; JavaScript's does
    not. `jsTrim` strips exactly the 25 code points the vendored fixture lists,
    and the `[\s-]` class used by the account fold is now built from that same
    set rather than from Dart's `\s`.
- **The document-id guard rejects a lone UTF-16 surrogate.** `utf8.encode`
  silently substitutes U+FFFD for an unpaired surrogate, so such a key used to
  pass the 1500-byte check and then be rejected by the API — after the credit
  was spent.

### Added

- **`UnormNormalizer` is now shipped by the SDK** (`lib/src/query/
  unorm_normalizer.dart`) and exported. `unorm_dart` was already a declared
  dependency, but the full-Unicode adapter that uses it had to be hand-copied
  into every host app. It is still opt-in — `DefaultNormalizer` remains the
  default, because changing the default would change existing integrators'
  folded and cached keys.
- Test coverage driving the fixture's new `documentIdGuard` and
  `crossLanguageSemantics` sections directly, rather than restating them in
  prose.

### Changed

- **`TraciveClient`, `openTraciveCache`, `CheckCache`, `TraciveOAuth`,
  `TokenStore`, `HttpTransport` and the rest of the client/cache/OAuth surface
  are now exported from `package:tracive_sdk/tracive_sdk.dart`.** They existed
  but were unreachable through the public barrel, so the quickstart in
  `README.md` did not compile and the example app had to import
  `package:tracive_sdk/src/...` paths. Nothing was renamed; only the barrel
  changed.
- The vendored fixture is version 2 (33 vectors, up from 25).

## [0.1.0] — 2026-07-31

First release. phase 1: **OAuth mode only, and the backend Open API is not live
yet.** Everything below is built against a frozen contract
; no code path in
this package has ever spoken to a Tracive server, because there is not one to
speak to. Treat the wire-level behaviour as unverified against a live
implementation until the API ships.

### Added

- **`TraciveClient`** — `checkScammer()`, `credits()`, `profile()`,
  `authorize()`, `handleCallback()`, `signOut()`. The HTTP transport and the
  clock are injectable, which is what lets the whole client be tested with no
  network.
- **`TraciveQuery`** builders for phone, e-mail, bank account, IBAN, crypto
  address and social handle, each exposing the folded `searchQueryIndex`.
  Validation runs before any network call, because a miss is billed.
  There is deliberately **no `domain()` builder**: the backend dropped that
  input type, so such a key could only ever miss.
- **OAuth 2.0 with PKCE (S256)** — app-presence pre-check before any redirect,
  Custom Tabs / Universal Link (never a WebView), `state` verification, tokens
  in the Android Keystore / iOS Keychain, single-flight refresh on
  `401 expired_token`, refresh-token rotation, and `signOut()` that revokes
  best-effort and clears locally regardless of the outcome.
- **`ClientType.confidential`** — the SDK stops at the authorization code and
  returns `AuthResult.codeReceived`, for partners whose own backend holds the
  `client_secret`.
- **Encrypted local cache** — `sqflite_sqlcipher`, key in the platform secret
  store, `SHA-256(searchQueryIndex)` as the row key so no raw identifier is
  ever stored, per-tier TTLs (`HIGH` 30 d, `ELEVATED` 7 d, `CAUTION` 24 h,
  `NONE` 1 h), the server's `cacheTtlSeconds` override honoured as the
  fleet-wide invalidation lever, lazy expiry on read, a prune pass on open, and
  schema-version invalidation. Full-detail content, `billing` and `checkId` are
  never written.
- **Typed errors** for every documented `error.code`, with an unrecognised code
  degrading to `TraciveServerException` / `TraciveUnknownException` rather than
  crashing.
- **`TraciveMode.proxy(...)`** as a *type only*. Every call in Proxy mode throws
  `TraciveNotImplementedException('Proxy mode arrives in phase 2')`. It exists
  now so that shipping Proxy mode later is not a breaking change.

### Security

- **There is no API-key parameter anywhere in the public surface, in any mode.**
  This is a design invariant, not an omission — see `SECURITY.md`.
- No raw identifier (phone, account, e-mail) and no token is ever logged. Every
  `toString()` on a type that holds one is redacted.

### Known limitations

- `unorm_dart` is declared at `^0.3.2`, not the `^2.0.0` named in the comment at
  the top of `lib/src/query/normalizer.dart`: that version has never been
  published, and depending on it makes `flutter pub get` fail outright. The API
  the comment asks for is unchanged. See `doc/integration.md`.
- The bundled `DefaultNormalizer` implements the composition half of Unicode
  NFC. It is exact for ASCII, Latin, Greek, Cyrillic and Hangul, and for any
  already-decomposed input; it diverges on singleton decompositions and
  composition-excluded characters. Inject `unorm_dart` if your app accepts
  identifiers where those are plausible — `doc/integration.md` has the adapter.
- `lib/src/cache/tracive_cache.dart` — the ~120 lines binding
  `sqflite_sqlcipher` and `flutter_secure_storage` — is covered by on-device
  integration testing, not by the unit suite. `doc/caching.md` says what to run.
- The install link used when the Tracive app is missing is a **required**
  constructor argument (`installUrl`) with no default. This package cannot
  derive it, so it asks for it rather than guessing.

[Unreleased]: https://github.com/pleistocent/tracive-sdk-flutter/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/pleistocent/tracive-sdk-flutter/releases/tag/v0.1.0
