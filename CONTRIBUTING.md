# Contributing

```sh
flutter pub get
dart format --output=none --set-exit-if-changed .
flutter analyze --fatal-infos --fatal-warnings
flutter test
```

All four are gates in CI, so running them locally is not optional politeness — it is the whole
check, minus the example app.

> **CI is off.** The workflow is set to manual dispatch only, to stop metered Actions minutes on a
> private repository — see the note at the top of `.github/workflows/ci.yml`, and re-enable it when
> there is budget. Everything below still describes real gates; the only change is that **nothing
> runs them for you**. Run `the four commands above` before you push, and read the rest of this file as instructions
> for a human rather than a description of a robot.

**Use the pinned Flutter version: 3.29.3.** CI pins it rather than tracking `stable`, because a
floating channel lets a Flutter release turn a green pull request red with no change in this
repository — and the formatter in particular changes its output between versions. If `flutter` on
your `PATH` is a different build, reach for the pinned one directly (fvm keeps it under
`~/fvm/versions/3.29.3/bin/flutter`). A formatting diff that appears out of nowhere is almost always
this.

`analysis_options.yaml` makes `unawaited_futures` an error and requires documentation on every
public member, so `analyze` is a real gate rather than a style suggestion.

The example app under `example/` is analyzed, tested and built as a debug Android APK in its own
job. It consumes the package the way an integrator does, so a break in the public surface fails
there before it fails for them.

Nothing in this repository talks to a server: every test injects a fake transport, so the suite
never depends on either Tracive environment being up. If a step ever starts needing a credential,
something has gone wrong.

---

## The grammar fixture is not yours to edit

`test/fixtures/query-grammar-vectors.json` is vendored **byte-identically** into four SDK
repositories, and its expected values were produced by executing the server's own key normalizer.
CI pins it by sha256 and refuses any change. If your implementation disagrees with a vector, your
implementation is wrong.

A grammar change starts at the Tracive API and lands in all four SDKs together, or it drifts.

`test/fixtures/bank-codes.json` is vendored the same way, and the SDK ships it as the string
constant in `lib/src/query/bank_codes_json.dart`. After re-vendoring it, run
`dart run tool/embed_bank_codes.dart`; `test/bank_codes_test.dart` fails while the two differ.

### And nothing may sit between a fixture value and the assertion that reads it

Pinning the file is only half of it. The pin proves the *bytes* did not move; it says nothing about
whether a test still asserts what they mean. So: no exception map, no ternary on a "pending" or
"known-failing" lookup, no allow-list of vector ids, no filter applied to the vector list before it
is iterated. A fixture value goes straight into the assertion, and if a vector genuinely cannot be
satisfied, a red build is the correct outcome and the conversation belongs upstream.

This is written down because it happened in the React Native SDK, and nothing about it was React
Native-specific. A test there declared an empty map of "pending" guard cases and consulted it before
each expectation:

```ts
expect(isValidRecordKey(value)).toBe(pending ? PENDING_GUARD_CASES[value] : safe);
```

It was empty, so it changed no outcome — and that is exactly what made it worth removing. The
fixture stayed byte-identical, its hash check passed, the pinned vector counts still matched, and
every one of those guards would have stayed green while a single entry in that map let that SDK
disagree with the shared contract in silence. A mechanism whose only purpose is to opt out of the
anti-drift contract while staying green should not exist, empty or not.

No tool catches this, and none can: while that map was empty the behaviour was identical, so there
was nothing for a check to observe — and once it held an entry, the test would pass *because* of it.
It is on you and on the reviewer, at the moment the line is written.

---

## Dart's string built-ins are not JavaScript's

The server folds identifiers in JavaScript, and the folded key **is** the record key. A key that
differs by a single code point resolves to a record that does not exist, so the check misses — and a
miss is still billed to the caller. That is why `lib/src/query/js_string.dart` and its companion
table exist, and why they look like they are reinventing things Dart already has.

They are not. Dart's `trim()`, its case mapping and its notion of whitespace each diverge from
JavaScript's somewhere, and the divergences were **measured against this SDK rather than assumed** —
the file header names them. One of them is worth internalising before you touch that code: an
earlier version compensated only for the case mappings that change a string's *length*, which left
hundreds of code points folding differently from the server, and the Dart VM and dart2js did not
even agree with each other. Everything passed.

So: no `toLowerCase()` shortcuts in folding code, no locale-sensitive comparison, and no "surely
Dart does the same thing here". The fixture's `crossLanguageSemantics` block is the specification;
the platform is not.

---

## The native module is small on purpose

`android/` (Kotlin) and `ios/` (Swift) exist for one feature, the report form, and do one thing:
write the package Dart built and hand it to the Tracive app. Validation, encoding, the fallback
chain and the iOS bundle-id check all live in Dart (`lib/src/report/`), so that every branch is
covered by `flutter test` with a fake `ReportFormLauncher`. Keep it that way: logic that moves into
Kotlin or Swift moves out of reach of the suite, because no device runs in this repository's gates.

What the gates can still say about native code:

```sh
cd example
flutter build apk --debug                                  # the Kotlin compiles and the manifest merges
(cd android && ./gradlew :tracive_sdk:testDebugUnitTest)   # ReportPackageStore, on the JVM
flutter build ios --simulator --debug --no-codesign        # the Swift compiles (macOS only)
```

`test/report_platform_test.dart` reads the Kotlin and Swift sources and the plugin's manifest, and
fails if they stop agreeing with Dart on the channel's argument names or outcomes, or if the
provider becomes exported. It is a text check, not an execution; the hand-off itself is verified on
devices.

**Nothing merges into an `Info.plist`.** Android's manifest is merged, so the plugin declares its
`<queries>` and its provider itself. iOS's `LSApplicationQueriesSchemes` is the integrator's to
add, and a missing scheme fails silently (`canOpenURL` answers no). If you document a platform
requirement, say who is responsible for it.

---

## Documentation lives in `doc/`, singular

Not `docs/`. That is the Dart and pub.dev convention, and the README's documentation table links
into it. Two directories one letter apart would be worse than either.

---

## Things that look like nits and are not

**Do not add an API key parameter anywhere, in either mode.** There is none, by design: a long-lived
secret shipped inside a mobile binary is a published secret.

**Do not retry a check without an idempotency key.** The SDK cannot tell whether the first attempt
was billed, so a blind retry risks charging a partner twice for one answer.

**Do not add a `domain()` query builder.** The Tracive API indexes five identifier types. A domain
key would match nothing, and the miss is billed.

**Do not let `Detail.full` touch the cache, in either direction.** The stored projection keeps
`tags` and `disclaimer`, both localized, under a key that carries no locale — and full detail is the
only level that sends one. The gate is the safety property; the projection is not locale-proof.

**Do not clear the pending authorization on a `state` mismatch.** Any app on the device can hand
yours a URL. Clearing there would let a stray or hostile redirect cancel a consent in progress for
the cost of one `open`. A spent attempt is cleared by whichever branch spends it, and an abandoned
one by the ten-minute expiry.

**Never open a WebView**, and never add a method that would let a caller ask for one. App Links do
not fire from an embedded browser, and RFC 8252 §8.12 forbids it because the embedding app can read
the user's credentials. `AuthLauncher` has exactly one opening method for that reason.

---

---

## Differences from the sibling SDKs that are deliberate

Two separate audits have now raised these as findings. They are decisions, and this list exists so a
third does not spend its budget re-deriving them. Anything that differs across the four SDKs and is
**not** on this list is drift, and worth reporting.

- **`close()` exists here and not in Swift or React Native.** Dart's HTTP client owns a connection
  pool that has to be released explicitly; `URLSession` and `fetch` do not, and React Native's link
  listener already returns its own unsubscribe. A no-op `close()` over there would be worse than its
  absence: it teaches a reader that calling it matters.

- **`cacheInitializationError` is Swift-only, and should stay there.** Swift is the only SDK that
  opens a default cache itself and degrades to a no-op one on failure, so it is the only one with a
  failure to report. This SDK rethrows the open failure to whoever asked, and records the last one.

- **`onAuthResult` and `startLinkListener` are React Native-only.** Android delivers the redirect as
  an intent and iOS as `onOpenURL`; React Native has neither, so its SDK owns the `Linking`
  subscription. Nothing to mirror here.

- **The client fronts consent in all four now.** `authorize`, `handleCallback`, `isAuthorized` and
  `clearCache` sit on the client everywhere, delegating to the OAuth flow. Kotlin gained them last;
  they were added rather than removed from the other three because the surface had already shipped
  to partners.

- **A 401 naming something other than the bearer still costs one refresh.** The rule is: the
  terminal codes surface, everything else refreshes once and replays. A hypothetical
  `invalid_api_key` would therefore spend a refresh — which buys nothing, and costs nothing either,
  because there is no API key in this SDK to be invalid and the second 401 surfaces. Narrowing the
  trigger to one exact code is the change that would actually hurt: a bare 401 from a gateway or a
  reverse proxy carries no code at all, and that is the case the rule exists for.

- **The spent-refresh-token history is not persisted.** It dies with the process, on purpose —
  `TraciveOAuth._spentRefreshTokens` says what that costs (one re-consent after a rolled-back store)
  and why paying it beats writing dead refresh tokens to disk forever.

- **The single-flight latch on checks covers different ground in each pair.** Kotlin and Swift keep
  the cache write inside the flight, so a collapsed check is stored once; Flutter and React Native
  latch the network call alone and let each caller write. The request count — the thing that is
  billed — is identical, and so is what a caller observes.
- **All four app-presence probes follow the environment, but Kotlin's asks a different question.**
  This package, React Native and Swift probe the app's URL scheme, which is all a pure-Dart or
  pure-TS package can reach. Kotlin has real Android code, so it checks the exact application id
  through `PackageManager` and takes its package visibility from a `<queries><intent>` on the
  authorize App Link — a scheme any app may declare, an App Link only the build named in the host's
  assetlinks can. Kotlin is therefore the strictest of the four, and this package cannot be brought
  up to it without the Android module it deliberately does not ship. This used to read "Kotlin's
  probe does not follow the environment", which was true, and was caused by a hygiene rule that has
  since been corrected.

- **The pending-authorization window is configurable everywhere except Swift.** Kotlin, Flutter and
  React Native all take it as a parameter, so an integration spanning more than one can set the same
  number in each; Swift refuses on purpose, so there is exactly one place its number lives. Kotlin's
  parameter is spelled `private val`, which privatises the generated property and not the parameter
  — an earlier version of this list read that as "not configurable", which Kotlin's own CHANGELOG
  contradicts.

## Tests

No unit test opens a socket, touches secure storage on a real device, or launches a browser. Every
capability that reaches outside the process is an injectable seam; the fakes already written are in
the test directory.

When you add a test, check that it can fail. Change the value it asserts and watch it go red before
you commit it. This is not a formality here: the pending-authorization window was "covered" by a
test that advanced the clock two hours, which passes at any window size and asserted nothing about
the one it was named after. The value drifted from its sibling SDKs in silence for exactly that
reason.

---

## The public-hygiene rule

**This repository is published.** Nothing in it — source, comments, documentation, test names, error
strings or commit messages — may name any of the following:

- an internal repository or an internal design document;
- a backend commit, source path or symbol;
- a server-side function name;
- the backend's database product, or any internal collection path;
- roadmap phase jargon in any language other than English.

Say **"the Tracive API"** or **"the server"**. Say **"record key"**. Say **"phase 1" / "phase 2"**.

Android application ids are exempt, production and sandbox alike, plus this repository's own GitHub
path. Withholding an application id protects nothing: each authorize host publishes its own, and its
signing-certificate fingerprints, at `/.well-known/assetlinks.json`, because that is what an App
Link association is. This rule used to ban the sandbox id on the grounds that naming one "only
discloses that it exists"; that reason was void from the day the sandbox App Link went live.

As it happens this package names none of them. It probes a URL scheme, not a package, so the
exemption is here for consistency with the other three SDKs rather than because anything needs it.

The second half of that is not a loophole, it is the difference between an *internal* repository and
this one. A published package has to name where it lives: the path is in `pubspec.yaml`'s
`repository` and `issue_tracker`, in the README's CI badge, in `SECURITY.md`'s reporting address and
in the changelog's compare links, and it is the install instruction. The rule as written forbade
what the package necessarily ships, which makes it a rule nobody can follow rather than a rule
anybody breaks. Any *other* repository under that organisation is still an internal name, with two
exact exceptions for `tracive_sdk_extended`: its Maven Central artifact, and the releases path of
the public Swift SDK, where its XCFramework is fetched from.

`node tool/check-hygiene.js` scans for all of this, and CI runs it. It proves every one of its rules can still
fire — against its own self-test corpus — before it scans anything, and refuses to run if one
matches nothing: a check that cannot fail is worse than no check, because it reads as coverage.

It arrived on 2 August 2026, after the author shipped 39 Indonesian-language fixture notes into
four published repositories. Only React Native had a scanner; it caught them, and the other
three took the same file without a word. The scan does not replace reading your diff the way a
stranger would — it catches the class of mistake a tired reviewer waves through.
