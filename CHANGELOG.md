# Changelog

All notable changes to `tracive_sdk` are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this package
follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html) — with the
`0.x` caveat that **the public surface may still change in a minor release**
until it is frozen at `1.0.0`.

## [Unreleased]

### Fixed

- **Your `idempotencyKey` now goes out exactly as you wrote it.** It was
  trimmed on the way to the wire, so a key of `'  9f3c-1  '` reached the server
  as `'9f3c-1'`. The justification was that a stray space would make a replay a
  different key; it would not, because the replay reuses the string the call
  already captured. What trimming did change is reconciliation: the key you
  recorded against a transaction is the key the server deduplicates on, and a
  disputed charge cannot be matched against a ledger holding a different string.
  Kotlin, Swift and React Native never trimmed it, so this SDK was the outlier.

  Only the question *"is there a key here at all"* still trims: `null`, `''`
  and `'   '` all still count as no key, and still get a generated `sdk-<uuid>`.

- **A blank token now means whitespace-only as well as empty.** The repair for
  a damaged grant asked whether the stored access token was *empty*, so a value
  of `'   '` was read as a token that is present and went out as
  `Authorization: Bearer    `. That is answered `invalid_token`, which this SDK
  treats as terminal, so the record failed every call from then on and failed by
  telling the user to authorize again — while the refresh token beside it was a
  live credential the whole time. This is one step past the empty-token case
  fixed earlier, and it survived because the rule was written as "empty" rather
  than "blank".

  Every place that decides whether a token is present now tests blankness:
  `TraciveTokens.hasAccessToken`, `TraciveTokens.canRefresh` and therefore
  `isUsable` and `TraciveOAuth.isAuthorized`, the token store's own read, the
  revocation call's choice of credential, and the reply from the token
  endpoint — a response carrying `"access_token": "   "` is now rejected as
  malformed instead of stored.

  The refresh token matters more here than it looks. Presenting one marks it
  spent *before* the answer arrives, and a request that dies without an answer
  leaves that marker in place on purpose, so offering a whitespace-only value
  bought a certain rejection and could then let a single timeout refuse a grant
  that was never renewable to begin with.

  **What you will observe:** nothing, on a healthy grant. On a damaged one, the
  blank access token is repaired with a single refresh — as an empty one already
  was — rather than being sent. The repair now hands the refresh the damaged
  value itself instead of a literal `''`: the refresh compares the stored token
  against that argument to recognise a caller who lost a race, so a hard-coded
  empty string made every such caller look raced and handed the damaged record
  straight back. Kotlin already tested blankness.

- **A refresh token is never handed to the server twice — and a server that did
  not rotate is no longer mistaken for one that did.** The single-flight latch
  is already clear by the time a slow store read hands a second caller the token
  the first caller has just spent, so `TraciveOAuth` also remembers the refresh
  tokens it has actually presented and turns such a caller away on the token's
  identity rather than on timing. Presenting a rotated refresh token twice is
  what the server's reuse detection looks for, and its answer is revocation of
  the whole grant: a full re-consent for the end user, caused by nothing worse
  than a slow keychain read. A flight also never sends the snapshot it was
  started from — it re-reads the store and sends whatever is live there — which
  is what keeps that memory an optimisation rather than a boundary someone has
  to pick the right depth for.

  **When a token comes back off that list is the part worth reading**, because
  the obvious rule is wrong. An error response releases it: a token endpoint
  that answers with an error has issued no tokens (RFC 6749 §5.2), so one 500
  must not end the grant. A request that got **no answer at all** does not
  release it — a socket timeout is indistinguishable from a success whose reply
  was lost, so the marker stays and the caller is told to authorize again, which
  is the strictly better trade rather than the merely cautious one.

  And a success releases it **only if the server handed back the same refresh
  token it was given**. RFC 6749 §6 does not oblige a token endpoint to rotate:
  it may answer with the same refresh token, or omit `refresh_token` entirely to
  mean "keep the one you have", which this SDK honours by carrying the stored
  value forward. In both cases the token then in the store is the exact string
  in the spent history, so reading a 2xx as proof of consumption refused the
  *next* refresh locally, with no request sent, reporting that the stored
  refresh token had already been used — and, since the history is cleared only
  on sign-out, it stayed refused for the life of the process. The guard against
  a server-side revocation would have become a client-side one, against a server
  that did nothing wrong. The comparison against the token that went out is the
  safety of that release and not a tidy-up: a token the server really did rotate
  away from stays marked, because the store may still be holding it — a `write`
  that refuses leaves exactly that — and handing it to the next refresh is the
  reuse the history exists to prevent. Kotlin and React Native release on the
  same condition.

  **What you will observe:** against a server that rotates, which is what the
  Tracive API does, nothing at all — every refresh rotates, every marker stays,
  and a stale snapshot is still turned away without reaching the wire. Against
  one that re-issues or omits the refresh token, refreshes after the first now
  work instead of throwing `TraciveInvalidTokenException`.

- **Overlapping identical checks are now one request and one charge.** Two
  checks of the same identifier that were in flight at the same time both read
  the cache, both missed, both POSTed and both were billed — the cache write is
  the only point where the two are serialised, and it happens after both
  requests have already left. A double-tapped button, or a list screen that
  renders the same identifier in two cells, doubled the bill, and nothing
  anywhere reported that it had happened.

  `TraciveOAuth.refreshTokens` has had the correct shape all along. This is the
  same latch in the one place where getting it wrong costs money rather than a
  round trip. The React Native SDK had it; Kotlin, Swift and this SDK did not.

  **What you will observe:** a second `checkScammer` for the same identifier,
  detail level, locale and `idempotencyKey`, started while the first is still on
  the wire, joins that request and both callers get the same answer, stamped
  `Origin.server`. The latch is released the moment the request settles —
  successfully or not — so it never serves a stale answer and never pins a
  failure in place. Checks that do not overlap are unaffected: that is the
  cache's job, and its rules have not changed. The detail level and the locale
  are part of the key, so a minimal result is never handed to a caller who asked
  for full.

  **Your own `idempotencyKey` is part of the key too**, and it is the one piece
  of it that is a statement of intent rather than a description of the question.
  Two overlapping checks carrying two different keys of yours are two
  transactions you deliberately told this client apart, so they are two
  requests, each sent under the key you gave it — collapsing them would have put
  only the first key on the wire and left the second transaction never made. A
  check carrying one of your keys likewise never joins a flight started without
  one, which is what keeps its retry budget: only a key of yours makes a check
  safe to repeat after a 5xx or a timeout, and joining would have taken that
  away silently. The per-call key this SDK generates when you supply none is
  *not* in the latch key — it is unique per call, so it would give every check a
  flight of its own — and a blank key is no key here, exactly as on the wire.
  Two unkeyed checks, which is what a double-tapped button and a list cell
  rendered twice both are, still share one request and one charge.

- **A 401 now triggers the refresh whenever it is not terminal**, rather than
  only when the body carries exactly `expired_token`. A bare
  `401 Unauthorized` — no body, or a `WWW-Authenticate` header and nothing else
  — is what CDNs, API gateways and misconfigured reverse proxies emit, and this
  SDK is explicitly designed to sit behind a partner gateway. Against one, no
  error code could be read, the branch never fired, and every call failed
  identically until the app happened to call `authorize()` again — while the
  user's grant was fine the whole time.

  `grant_revoked` keeps its own branch: the grant is gone, so there is nothing
  to refresh into, and the local tokens are cleared. `invalid_token` stays
  excluded for the same reason at one remove — the server is saying the
  credential is not usable at all, so minting a fresh one earns nothing.

  Everything that made the branch safe is unchanged: it fires at most once per
  request, it does not consume the retry budget, and the replay now carries an
  `Idempotency-Key` in every case (see above), so it no longer rests on the
  assumption that a 401 is rejected before billing.

  The React Native SDK made this change first; the other three carried the bug.

- **Every check now leaves with an `Idempotency-Key`.** One was sent only when
  the caller supplied it — yet the client re-sends the identical POST after a
  401 refresh, and without a key those two attempts are indistinguishable to the
  server. Any billing that happens before or during authorisation was therefore
  charged twice, with no way for the caller to detect it.

  The replay was justified by "a 401 is rejected before billing": an assumption
  about a server that is not deployed, and the one premise this SDK otherwise
  refuses to make anywhere. Generating a key removes the need to assume
  anything. Swift already did this.

  **What you will observe:** an unkeyed check carries a generated
  `Idempotency-Key` of the form `sdk-<uuid v4>`, prefixed so a server-side log
  can tell an SDK-invented key from yours when a charge is disputed, and
  regenerated per call so two deliberate re-checks of one identifier stay two
  operations. It does **not** buy you a retry budget: a 5xx, a 429 or a timeout
  on an unkeyed check is still surfaced immediately, exactly as `README.md` and
  `SECURITY.md` promise, because that budget still keys off *your* key.

- **`TraciveClient.signOut()` now empties the result cache as well as the
  tokens.** It only cleared the tokens, so the cached rows stayed readable
  afterwards: the departing user's check history — a list of who they suspected
  of fraud — sitting on the device for whoever picked it up next, and served to
  them at zero cost with no network call, so nothing anywhere recorded that one
  person had read another's result. Kotlin was the only SDK doing this.

  **What you will observe:** the first check for each identifier after a
  sign-out costs a credit, which is the correct price for the first check of a
  new session. `signOut()` now surfaces a failure from the cache rather than
  completing silently — the tokens are discarded first, so a cache that refuses
  to empty cannot leave a live grant behind, but you are told that the verdicts
  survived when the grant did not.

- **`TraciveOAuth.authorize()` and `handleCallback()` no longer throw at their
  caller.** Both delegate to collaborators that can fail outside this SDK's
  control — the secure store, the app-presence probe, the browser launch — and
  those failures escaped as exceptions. Only `TraciveException`s raised by the
  token exchange were being turned into `AuthResult.failed`.

  `handleCallback` is where that matters. Its caller is the host app's App Link
  / Universal Link handler: a platform callback, usually two lines, essentially
  never wrapped in a `try`. An exception escaping into it is an unhandled
  exception in someone else's app, on a code path they did not write, for a
  reason — a locked Keychain, a Keystore entry that will not decrypt after a
  backup restore, a platform channel that is not registered — with nothing to do
  with the deep link they were routing.

  Both now return `AuthFailed`, as the Kotlin, Swift and React Native SDKs do.

  **What you will observe:** one `switch` over `AuthResult` covers every
  outcome and there is nothing to catch alongside it. A non-Tracive failure
  arrives as `AuthFailed` carrying `TraciveInvalidRequestException` with a
  message that names the situation. The underlying platform error is
  deliberately not quoted in it: that text comes from whichever store the host
  installed, and it would travel to a crash reporter from a frame whose
  neighbouring values are a PKCE verifier and a refresh token.

- **`Source.serverFirst` no longer answers a 402 from the cache.** The fallback
  set included `TraciveInsufficientCreditsException`, so a partner whose credit
  balance had run out received a cached verdict instead of the error: no
  exception, no flag on the result, nothing to log, and `origin` reading `cache`
  exactly as it does on a healthy offline fallback.

  The failure that produces is quiet and then sudden. The integration looks
  healthy for as long as the cache holds entries, and then every check starts
  failing at once — on a payment screen, days after the balance actually
  emptied, with nothing to connect the two. An exhausted balance is not a
  transient server condition; it is a fact about the account that will not
  change on its own, and the only useful moment to learn it is the first one.

  The fallback set is now transport-shaped failures only: a network error, a
  5xx, a 429. Every failure that carries a verdict about the caller — a revoked
  grant, a missing scope, a rejected token, a 402 — is rethrown.

  **What you will observe:** a `serverFirst` check against an empty balance now
  throws `TraciveInsufficientCreditsException` even when a live cached entry
  exists. Handle it the way `checkScammer` has always documented. Nothing else
  in the fallback behaviour moved.

- **Unicode NFC is now full NFC by default.** `TraciveNormalization` installed
  `DefaultNormalizer`, which does canonical ordering and canonical composition
  but **no canonical decomposition step**. Its own documentation measured the
  gap and then left it as the default: **565 of the 63 488 BMP code points**
  fold to a different key from the server's when they arrive raw rather than
  pre-decomposed — 493 singleton decompositions such as U+212B ANGSTROM SIGN,
  plus 72 composition-excluded pairs such as U+0958 DEVANAGARI QA. Full
  correctness was available, as `UnormNormalizer`, behind an opt-in line in
  `main()` that an integrator had to read the source to discover.

  The folded key **is** the record key. Each of those 565 code points therefore
  produced a lookup for a record that does not exist: the check missed, the miss
  was billed, and nothing in the response distinguished it from a genuine "no
  reports on file". The Kotlin, Swift and React Native SDKs all fold with full
  NFC and offer no opt-in at all, so this was also the one place where four SDKs
  disagreed about what a given identifier is called.

  `UnormNormalizer` is now the default. `DefaultNormalizer` remains exported as
  a deliberate opt-*out* for an app that has measured the fold as too expensive
  and knows its identifiers stay in scope.

  **What you will observe:** an identifier containing one of those code points
  now folds to the same `searchQueryIndex` the server computes — so a check that
  used to miss now hits. Everything already correct is unchanged: 20 000
  randomly generated multi-code-point sequences and every already-decomposed
  input fold byte-identically to before. Cached rows written by an earlier
  version under the old fold are orphaned for the affected identifiers only;
  they expire on their own TTL.

  **What it costs:** nothing to install — `unorm_dart` was already a declared,
  non-optional dependency of this package, so it was being resolved and shipped
  either way. Throughput goes from about 25 ns to about 3 µs per fold for an
  ASCII identifier. One fold happens per check, against a network round trip of
  tens of milliseconds.

  **One known divergence, stated rather than hidden:** `unorm_dart` decomposes
  U+D7A4, which is unassigned — the Hangul Syllables block ends at U+D7A3 — so
  a key containing it still folds differently from the server's. It is left
  uncorrected: no input method produces an unassigned code point, and patching
  around a third-party bug means re-verifying the patch on every release of that
  package. Verified against Python 3 `unicodedata` at Unicode 16.0.0: 63 487 of
  63 488 BMP code points agree, and this is the one that does not.

- **A stored grant whose access token is blank now refreshes instead of asking
  the user to authorize again.** `TraciveOAuth.ensureAccessToken()` treated a
  blank access token exactly like an empty store: it threw
  `TraciveInvalidTokenException`, and the only move left to the integrator was
  to send the user back through `authorize()` — through consent in the Tracive
  app — while the refresh token sitting beside it was a live credential the
  whole time. That refresh token is now spent and the access token it mints is
  returned.

  **What you will observe:** on such a record, a call that used to throw
  `TraciveInvalidTokenException` now succeeds, after one extra round trip to
  `POST /oauth/token`. Nothing else moved. A blank access token with **no**
  refresh token beside it still throws the same exception with the same message
  and sends nothing; an empty store is untouched; and a stored access token is
  still handed over exactly as before, with no expiry check and no extra work.

  The state is reachable from a damaged storage record — a partial write, a save
  interrupted by process death, a restored backup — because
  `TraciveTokens.fromStorageJson` defaults a missing `accessToken` to `''`. It
  never arrives from the token endpoint, whose answer is rejected when it
  carries no `access_token`.

  Leaving it to the reactive 401 path was not an option, which is why the branch
  is in `ensureAccessToken()` rather than next to the refresh-on-401. An empty
  bearer is not answered `401 expired_token`; a malformed one is
  `invalid_token`, and every Tracive SDK treats `invalid_token` as terminal — no
  refresh, grant discarded. The damaged record therefore never healed itself on
  the next request: it failed permanently, and it failed by demanding a consent
  that was not needed. This is the branch every Tracive SDK is standardising on;
  the React Native SDK already recovers here.

  The shipped `SecureStorageTokenStore` keeps such a record now, and
  `isAuthorized` reports it as authorized, so the repair is reached on the
  default store. Both ask `TraciveTokens.isUsable`, which is true when *either*
  credential is live. If you implement your own `TokenStore`, hand back what you
  stored rather than dropping a record whose access token is blank — dropping it
  is what turns a repairable grant into a fresh consent.
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

- **`TraciveOAuth.cancelPendingAuthorization()` and
  `TraciveOAuth.pendingAuthorizationId`.** A browser that closes without a
  redirect produces no signal the SDK can see, so a flow the user walked away
  from left its record on the device — a live PKCE verifier beside a `state`
  still acceptable — until it aged out ten minutes later. The host app is the
  only party that knows the browser closed; now it can say so. The Kotlin and
  Swift SDKs already had this.

  Pass `authorizationId` when you can: a browser-closed signal arrives from a
  lifecycle callback, not from the code that started the flow, and it can
  arrive late enough to cancel an attempt that has already superseded it. See
  [`doc/oauth.md`](doc/oauth.md).

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

- **The retry defaults are now the set all four Tracive SDKs share**, and each
  number has its reasoning written beside it. `initialBackoff` moves from 300 ms
  to **500 ms**, `maxBackoff` from 5 s to **8 s**, and a **`jitter` of 0.2** is
  added — this SDK had none at all. `maxAttempts` (3) and `backoffMultiplier`
  (2.0) already agreed.

  The values had drifted because nothing asserted them and nothing explained
  them: three of the four SDKs shipped three different initial backoffs and two
  jitter ratios, with no reason recorded anywhere for any of them. Behavioural
  tests cannot catch that, so each value is now pinned by name.

  `jitter` shaves up to 20% off each computed delay and is **one-sided — it only
  ever shortens a wait**, so `maxBackoff` stays a true ceiling. Pass `jitter: 0`
  for a fully deterministic schedule, or a seeded `Random` to `backoffFor` when
  a test needs one.

  None of these numbers is measured; the Tracive API is not deployed. They are
  defensible starting points with their reasoning attached, and the first real
  production data should be allowed to move them — in all four SDKs together.

- **BREAKING: `handleCallback` returns `AuthResult?`, and `null` means "this
  link was not addressed here".** Before acting on a URL it is now checked
  against the client's own `redirectUri` and must carry at least one of `state`,
  `code` or `error`. A URL failing either check returns `null` with nothing
  touched — not even a read of the store. The Kotlin SDK has had this; this SDK
  acted on whatever URL it was handed.

  It matters because hosts are told to route their whole deep-link surface
  through this method, and any app on the device can register a scheme and fire
  a URL at yours. Without the check, an unrelated link — your own marketing
  link, a share intent, a stray redirect — was judged as an OAuth redirect, and
  the honest verdict on a link carrying no `state` is
  `TraciveStateMismatchException`: an error raised at the user about a consent
  that is perfectly fine.

  **What you need to change:** add a `case null:` to your `switch`, and treat it
  as "carry on with my own routing". The comparison is deliberately loose —
  scheme, authority and path, case-insensitive, trailing slashes ignored — so a
  browser that normalises the URL on the way back cannot cost a user the consent
  they just gave. `state` still decides whether a code may be redeemed; nothing
  past the gate moved.

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
- **Tokens are now refreshed only when the server rejects them, never ahead of
  `expiresAt`. ⚠️ Breaking: `TraciveOAuth`'s `refreshSkew` parameter is gone,
  and so is `skew:` on `TraciveTokens.isExpiredAt`.** `ensureAccessToken()` hands
  over the stored access token without consulting its expiry; a `401
  expired_token` is what triggers the single-flight refresh and the one replay,
  as it always did. Every Tracive SDK is standardising on this one strategy.

  **The migration is deletion.** If you construct `TraciveOAuth` yourself and
  pass `refreshSkew: …`, remove the argument — nothing replaces it, and
  `TraciveClient` never accepted one. If you called `isExpiredAt(now, skew: d)`,
  call `isExpiredAt(now.add(d))` instead; the method itself stays. An integration
  that mentions neither is unaffected, and nothing changed on the wire.

  The reason is not that proactive refresh was expensive. It is that the reactive
  path is **mandatory regardless** — a token can be revoked, and a token can
  expire between the check and the send — so a pre-check could never replace it,
  only run in front of it. That made two mechanisms for one job, and the
  redundant one hid bugs in the mandatory one: the skew always won first, so the
  401 path was the branch that hardly ever ran in production. Removing the skew
  exposed exactly one such gap, which now has a test: a **cold start holding an
  already-expired token**, where nothing has refreshed yet and the session's very
  first request is the one that 401s. That path works, and it had never run.

  The second reason is that the comparison could only ever be against **the
  device's clock, which this SDK does not own**. A phone running ten minutes fast
  declared every token expired and refreshed on every single call — and with
  rotating refresh tokens and server-side reuse detection, a stream of rotations
  is not just wasted traffic, it is repeated exposure to a revocation that signs
  the user out. The 60 seconds was also a number nobody had derived: the one
  sibling SDK that refreshed proactively used 30, and neither of them recorded a
  reason.

  What it costs is one wasted round trip per token lifetime, paid by a single
  caller because the refresh is single-flight, and **not billed** — authorization
  is checked before billing, so a request carrying an unusable bearer token is
  answered with a 401 rather than with a check.

  **`expiresAt` is still stored**, still serialised by `TokenStore`, and still
  readable, as is `isExpiredAt`. Nothing in the SDK reads either one. They are
  there for an integrator who wants to warm a session before a user-visible
  action, or to display "signed in until", and who can then call
  `refreshTokens()` — a decision made by code that knows whether its own clock is
  trustworthy, rather than a default applied to every call on every device.
- **A started-but-unfinished authorization now expires ten minutes after
  `authorize()`, not thirty**, which is the window every Tracive SDK uses.
  `pendingAuthorizationMaxAge` is still a constructor parameter and a value you
  pass still wins; only the default moved. It also has a name now —
  `PendingAuthorization.defaultMaxAge` — so that the constructor default and
  `PendingAuthorization.isStaleAt`'s own default are one constant instead of two
  literals free to drift apart, which is exactly what they had already done here
  relative to the sibling SDKs.

  Ten is not a shorter guess at how long a user takes to consent. It is the
  lifetime of the authorization code the pending record exists to redeem —
  RFC 6749 §4.1.2 recommends a maximum of ten minutes for it — and once that
  code has expired, the exchange cannot succeed no matter what the device still
  holds. So the extra twenty minutes bought no recovery whatsoever. What they
  did buy was exposure: for that whole time the PKCE `code_verifier` sat in
  secure storage as the proof of possession for a code that no longer exists,
  next to a `state` this SDK would still accept — which is to say a replay
  window for a redirect the user never finished. Three times the exposure, for
  none of the recovery, and no way to notice, because nothing pinned the number.

  **What changes for a caller is narrow.** A redirect arriving between ten and
  thirty minutes after `authorize()` now returns
  `AuthFailed(TraciveInvalidRequestException)` — "the authorization attempt
  expired; start it again" — instead of attempting an exchange the server would
  reject anyway; the user is told to start over without the round trip. Inside
  ten minutes nothing changed. If you have a reason to want a wider window, pass
  `pendingAuthorizationMaxAge` explicitly and know that you are widening a
  replay window to do it.
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
