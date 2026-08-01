# Proxy mode — the phase 2 contract

> **Proxy mode is not implemented.** `TraciveMode.proxy(...)` exists in this
> release as a *type only*. Every call made in that mode throws
> `TraciveNotImplementedException('Proxy mode arrives in phase 2')`.
>
> This document is the contract phase 2 will implement. Nothing here is live.
> Do not build against it expecting it to work today; build against it so that
> switching a single constructor argument later is all it takes.

---

## Why the type exists now

Adding a whole authentication mode to a shipped SDK is a breaking change if the
mode did not exist. Adding *behaviour* to a mode that already exists is not.
the contract asks for the type up front for exactly that reason, so:

```dart
final client = TraciveClient(
  mode: TraciveMode.proxy(
    baseUrl: 'https://api.yourcompany.example/tracive',
    authHeaders: {'X-Company-Auth': backendIssuedToken},
  ),
);

await client.checkScammer(query);
// throws TraciveNotImplementedException: Proxy mode arrives in phase 2
```

compiles today, fails loudly today, and will simply work when phase 2 ships —
no code change, no version-gated branch in your app.

Note what the failure is **not**: it is not a silent empty `CheckResult`, and it
is not a network call to a URL that does not exist. It throws before touching
anything.

---

## What the two modes are actually for

| | OAuth mode (phase 1) | Proxy mode (phase 2) |
|---|---|---|
| Who consents | The end user, in the Tracive app | Nobody — the partner is the customer |
| Who is billed | The end user's credits (`creditSource: "USER"`) | The partner's prepaid balance |
| Who holds the credential | The device, as a short-lived PKCE token | The partner's backend |
| What the SDK talks to | `api.tracive.id` | The **partner's own** endpoint |
| Who talks to Tracive | The SDK | The partner's backend |

Proxy mode is for the case where the partner does not want its users to have
individual Tracive accounts. The SDK then talks only to the partner's server,
and the partner's server talks to Tracive with its own credentials.

**This still involves no Tracive API key on the device.** `authHeaders` are the
*partner's* credentials for the *partner's* proxy — whatever their backend
expects, issued per session by that backend. The invariant is unchanged: there
is no API-key parameter anywhere in this SDK's surface, in any mode, and there
never will be.

---

## What a partner proxy must implement

A conforming proxy accepts the same requests this SDK sends in OAuth mode,
minus the Tracive bearer token, at `{baseUrl}`.

### `POST {baseUrl}/scammer-checks`

Request headers: whatever `authHeaders` contains, plus
`content-type: application/json` and an optional `Idempotency-Key`.

Request body — **identical to OAuth mode except `creditSource`**:

```json
{
  "creditSource": "PARTNER",
  "detail": "minimal",
  "locale": "id",
  "query": "PHONE_+6281234567891"
}
```

- `query` is the **already-folded** `searchQueryIndex`. The proxy must forward
  it as `query`, not re-fold it and not send it as `input`. The SDK folded it,
  and that same string is the local cache key; re-folding it upstream is how the
  device's cache key and the server's stop agreeing.
- `creditSource` becomes `"PARTNER"`. phase 1 always sends `"USER"`.

Response body: exactly the `CheckResult` shape this SDK decodes. The proxy
may pass Tracive's response through unchanged; that is the intended
implementation.

- **`billing.creditSource` must say `PARTNER`,** and
  `billing.partnerBalanceRemaining` is what the partner's dashboard shows.
- **`cacheTtlSeconds` must be forwarded if present.** It is the fleet-wide
  invalidation lever (see `doc/caching.md`); a proxy that strips it leaves stale
  verdicts on devices with no way to reach them.
- **`disclaimer` must be forwarded.** The host app is required to surface it.
- Adding fields is fine. This SDK ignores unknown JSON fields by design.

### `GET {baseUrl}/credits` and `GET {baseUrl}/profile`

Optional. In Proxy mode there is no end-user Tracive account, so `profile()`
has no obvious meaning; a proxy that does not implement these should return
`404` with the error envelope below, and the SDK will surface a typed error.

### Errors

The envelope is the same:

```json
{ "error": { "code": "insufficient_partner_balance", "message": "…", "checkId": "…" } }
```

Map upstream failures onto the documented error codes rather than inventing new
ones — the SDK
maps every code in that table to a typed exception. An unrecognised code does
not crash; it degrades to `TraciveServerException` (5xx) or
`TraciveUnknownException`, carrying the raw code so the caller can still branch
on it. The two codes a proxy is most likely to need:

| Situation | HTTP | `error.code` |
|---|---|---|
| Partner's prepaid balance exhausted | 402 | `insufficient_partner_balance` |
| Partner account suspended | 403 | `partner_suspended` |

`429` should carry a `Retry-After` header in delta-seconds; the SDK reads it into
`TraciveRateLimitedException.retryAfter`. (Only the delta-seconds form is
parsed — the HTTP-date form yields `null`.)

### Idempotency

The SDK sends `Idempotency-Key` on **every** check — the caller's when they
supplied one, otherwise a generated per-call key prefixed `sdk-`. The proxy must
honour it end to end: the same key with the same body returns the first response
without charging again, and the same key with a *different* body is
`409 idempotency_conflict`. Without
that, the retry policy is unsafe and this SDK will refuse to auto-retry a
check — which is the correct behaviour, but it means the partner absorbs every
transient failure as a failed check.

---

## What does not change in Proxy mode

- **The query grammar.** `searchQueryIndex` is folded identically. The
  anti-drift fixture (`test/fixtures/query-grammar-vectors.json`) applies to the
  proxy's upstream calls too.
- **The cache.** Same key, same TTLs, same `cacheTtlSeconds` override, same
  "never cache full detail" rule. A cached hit in Proxy mode costs the partner
  nothing, which is the whole point.
- **The error types.** Same `TraciveException` subclasses.
- **No API key in the surface.** Still true. Still not negotiable.

## What will change when phase 2 lands

- `TraciveClient` will stop throwing in Proxy mode.
- There is no OAuth flow: `authorize()`, `handleCallback()` and `signOut()` have
  no meaning against a partner proxy and will continue to throw
  `TraciveNotImplementedException` there. Sign-out is the partner's own concern.
- `credits()` will report the partner balance rather than a user's credits, if
  the proxy implements it.

None of that is a breaking change to code written against this release.
