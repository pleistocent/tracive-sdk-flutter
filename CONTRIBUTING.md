# Contributing

```sh
flutter pub get
dart format --output=none --set-exit-if-changed .
flutter analyze --fatal-infos --fatal-warnings
flutter test
```

All four are gates in CI, so running them locally is not optional politeness — it is the whole
check, minus the example app.

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

Nothing in this repository talks to a server, and nothing can: the Tracive API is not live, and
every test injects a fake transport. If a step ever starts needing a credential, something has gone
wrong.

---

## The grammar fixture is not yours to edit

`test/fixtures/query-grammar-vectors.json` is vendored **byte-identically** into four SDK
repositories, and its expected values were produced by executing the server's own key normalizer.
CI pins it by sha256 and refuses any change. If your implementation disagrees with a vector, your
implementation is wrong.

A grammar change starts at the Tracive API and lands in all four SDKs together, or it drifts.

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

## This package is deliberately not a Flutter plugin

There is no `android/` or `ios/` module and no `plugin:` block in `pubspec.yaml`. It is pure Dart on
top of other people's plugins, and shipping an empty plugin module just to own a manifest was
considered and rejected.

The consequence matters more than the fact: **nothing merges a manifest fragment into the host
app.** The Android `<queries>` declaration that the app-presence probe needs is the integrator's to
add, and a code comment that once claimed otherwise cost exactly the failure you would predict —
without it, Android 11+ answers "not installed" for every user, including the ones who have the app,
and every one of them is sent to the install link. Nothing errors.

If you document a platform requirement, say who is responsible for it.

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

The single allowed exception is the Android application id `com.pleistocent.tracive`, which the
app-presence check genuinely needs. No other application id belongs here — a non-production variant
appears nowhere in shipping code, so naming one only discloses that it exists.

There is no automated scan in this repository, which puts it on you and on the reviewer. Read your
diff the way a stranger would, before it is public and permanent.
