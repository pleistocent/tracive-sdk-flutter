# Changelog

All notable changes to `tracive_sdk` are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this package
follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html) — with the
`0.x` caveat that **the public surface may still change in a minor release**
until it is frozen at `1.0.0`.

## [Unreleased]

### Fixed

- **The query fold now reproduces JavaScript's string semantics, not Dart's.**
  The API folds in JavaScript, and the folded key *is* the record key, so a
  one-code-point difference is a guaranteed miss — and a miss is billed. Three
  divergences were measured and closed, in the new internal
  `lib/src/query/js_string.dart` and its generated tables:
  - **Case mapping, length-changing.** Dart's `toUpperCase()`/`toLowerCase()`
    apply the Unicode *simple* mapping; JavaScript applies the *full* one, which
    can change a string's length. `ß` now uppercases to `SS` (it used to stay
    `ß`) and `İ` now lowercases to `i` + U+0307 (it used to lose the combining
    mark), along with the `ﬁ`/`ﬃ` ligatures a PDF or bank-statement paste
    carries.
  - **Case mapping, out-of-date.** Dart's simple table is several Unicode
    releases behind the engine the API folds in. Measured over every code point
    `U+0000`–`U+10FFFF`: **576 uppercase and 466 lowercase code points**
    disagreed, covering Adlam, Cherokee, Georgian Mkhedruli/Mtavruli, Osage,
    Warang Citi, Medefaidrin, Old Hungarian, Vithkuqi, Latin Extended-D,
    Cyrillic, Greek, Armenian, Coptic and Glagolitic. `lib/src/query/
    js_case_data.dart` is generated from a real engine and closes all of them;
    `tool/verify_js_case_fold.dart` re-measures on demand and currently reports
    zero.
  - **Greek final sigma.** `Σ` lowercases to `ς` at the end of a word and `σ`
    elsewhere. It is a context rule, so no per-code-point table can express it;
    it is implemented directly. Dart always produced `σ`, so every Greek
    identifier ending in sigma built a key that could not match.

  One divergence is **not** closed, and is documented at the top of
  `js_string.dart` rather than left to be discovered: the tables are a snapshot
  of one Unicode release, and 94 code points across two very recently
  bicameral scripts (Garay, Beria Erfe) would disagree with an older engine.
- **The reserved-key rule no longer spans a newline.** The server's pattern is
  `^__.*__$` with no `s` flag, so `.` does not match a newline and a key such
  as `__a\nb__` is one the server *accepts*. This SDK compiled the same pattern
  with `dotAll` on, which made the guard stricter than the server and threw
  `invalid_document_id` for a key that would have matched — turning a lookup
  that works into one the caller cannot make at all. The flag is off, and the
  fixture now carries the case. (`^` and `$` stay end-of-*input* anchors, as
  they are in JavaScript: `__ab__\n` and `\n__ab__` are accepted.)
- **The document-id guard rejects a lone UTF-16 surrogate.** `utf8.encode`
  silently substitutes U+FFFD for an unpaired surrogate, so such a key used to
  pass the 1500-byte check and then be rejected by the API — after the credit
  was spent.

### Added

- **`TraciveScopes` holds the OAuth scope names as constants** —
  `TraciveScopes.scammerCheck` (`scammer.check`), `creditsRead`
  (`credits.read`) and `profileRead` (`profile.read`) — matching the other
  Tracive SDKs. A scope name is only ever validated by the authorization
  server, which rejects the whole consent request when it does not recognise
  one, so a mistyped literal is not a narrower grant: it is an integration that
  cannot authorize at all, discoverable only against a live server. A test pins
  the three strings as literals, so renaming a constant fails the build instead
  of quietly redefining the contract. Nothing changed on the wire — the names
  were already correct everywhere — and the list is exactly the scopes this
  SDK's own calls need rather than the server's whole catalogue.
- **`UnormNormalizer` is now shipped by the SDK** (`lib/src/query/
  unorm_normalizer.dart`) and exported. `unorm_dart` was already a declared
  dependency, but the full-Unicode adapter that uses it had to be hand-copied
  into every host app. It is still opt-in — `DefaultNormalizer` remains the
  default, because changing the default would change existing integrators'
  folded and cached keys.
- Test coverage driving the fixture's new `documentIdGuard` and
  `crossLanguageSemantics` sections directly, rather than restating them in
  prose.
- **`TraciveQuery.email()` rejects an address with no `@`, with the new reason
  `not_an_email`.** It used to reject only an empty value, so
  `TraciveQuery.email('budi')` built `EMAIL_budi` and sent it. The server
  applies no shape validation to an e-mail — that is a legal record key — so
  the lookup happened, missed, and was **billed**. Client-side rejection is the
  only thing that prevents the charge, exactly as `phone()`'s E.164 check
  already does for a local-format number. The check is deliberately minimal, an
  `@`-presence test rather than an address grammar: `budi@localhost` and
  `budi@[192.168.0.1]` are keys the server would match, and rejecting them
  would be the worse failure. An empty value still reports `empty_value`.

### Changed

- **An empty crypto address now reports `empty_address` and an empty username
  platform `empty_platform`**, instead of both reporting the generic
  `empty_value`. They were already rejected — the fold could only ever have
  produced `CRYPTO_ETH_` or `USERNAME__budi`, which can only miss, and a miss is
  billed — but one token for two different mistakes gave a caller nothing to
  branch on and no way to know which field to put the error message next to.
  Every empty field now names itself. `empty_value` remains the empty-e-mail
  case. **If you switch on `TraciveQueryException.reason`, update those two
  branches.**
- **`installUrl` is optional again, and defaults to
  `TraciveOAuth.defaultInstallUrl` (`https://tracive.chottu.link/install`).**
  This is the link the SDK opens when the Tracive app is not installed, and it
  is now the same one in every Tracive SDK. It was briefly a required argument
  because the URL was not yet confirmed and a wrong default would have been
  invisible in development while being a 404 for every partner's first user
  without the app; the URL is confirmed now, so the argument goes back to being
  an override. Passing one still works and still wins. Omitting it means "use
  the default"; a blank one is rejected — see the next entry.
- **A blank `installUrl` now throws instead of being passed through.
  ⚠️ Breaking for anyone who passed a blank on purpose.** `TraciveOAuth`'s
  constructor — and therefore `TraciveClient`, which forwards the value
  unchanged — raises `ArgumentError` when `installUrl` is empty or
  whitespace-only, with the cross-SDK reason token `blank_install_url` in the
  message. Omitting the parameter is untouched and still yields
  `TraciveOAuth.defaultInstallUrl`: absence is a real answer, and no app that
  never mentions `installUrl` can start throwing.

  This reverses the behaviour documented and pinned one entry above, so it is
  worth being explicit about what was wrong with it. The argument for passing a
  blank through was a comparison against *silently substituting the default*,
  and that comparison still holds: substituting sends a partner's users to a
  link the partner never configured, and nobody can tell, because `authorize()`
  returns `AuthAppNotInstalled` either way and this SDK logs nothing. What the
  argument stopped short of checking is what passing the blank through actually
  produces. It is not the partner's link either: `installUrl: ''` builds
  `?ref=…&utm_source=…` — no scheme, no host, nothing an operating system will
  open — and `'   '` builds `%20%20%20?ref=…`. That failure is every bit as
  silent as the one it was chosen over. It reaches only a user without the
  Tracive app, only after release, and it surfaces nowhere unless the host app
  happens to be watching. "Blank passes through" was never the safe option; it
  was the second quiet one.

  So the choice is not between the default and the blank, but between a quiet
  failure and a loud one. The constructor is the loudest point available: it
  runs once, in host-app code, on every run, in development, before any end user
  is involved. A blank `installUrl` is nearly always a build variable that did
  not expand, and that is precisely the mistake a constructor throw catches on
  the developer's own machine.

  This is **not** URL validation, and no non-blank value's behaviour changed.
  Anything non-blank is still used verbatim — untrimmed, unparsed, and
  unjudged, including a value that is plainly wrong. Which links Tracive issues
  is not this SDK's to adjudicate, and a stricter check would reject link
  formats that do not exist yet.

  **If you pass `installUrl` from a build variable, make sure it is set, or stop
  passing it.** The migration is one line either way: drop the argument to take
  the shared default, or pass a real URL.
- **The install link now carries `ref=<clientId>` and
  `utm_source=tracive-sdk-flutter`**, replacing `utm_source=<clientId>` and
  `utm_medium=tracive_sdk_flutter`, to match the other Tracive SDKs. Both
  parameters are optional and non-sensitive: `ref` is the OAuth client id — the
  partner's identifier, which already ships in the app binary, never the end
  user's — and it is omitted when there is none. The link still carries **no**
  OAuth parameter of any kind, and still strips any that the configured URL
  arrives with.
- **`TraciveClient`, `openTraciveCache`, `CheckCache`, `TraciveOAuth`,
  `TokenStore`, `HttpTransport` and the rest of the client/cache/OAuth surface
  are now exported from `package:tracive_sdk/tracive_sdk.dart`.** They existed
  but were unreachable through the public barrel, so the quickstart in
  `README.md` did not compile and the example app had to import
  `package:tracive_sdk/src/...` paths. Nothing was renamed; only the barrel
  changed.
- The vendored fixture is version 5 (34 vectors, up from 25; 14 rejected
  vectors and 9 document-id guard cases).

## [0.1.0] — 2026-07-31

First release. phase 1: **OAuth mode only, and the backend Open API is not live
yet.** Everything below is built against a frozen contract; no code path in
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
  constructor argument (`installUrl`) with no default: at this release its URL
  was not yet confirmed, and a wrong default would have been invisible until it
  was a 404 for a user without the Tracive app. Resolved in Unreleased, where
  the confirmed link becomes the default.

[Unreleased]: https://github.com/pleistocent/tracive-sdk-flutter/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/pleistocent/tracive-sdk-flutter/releases/tag/v0.1.0
